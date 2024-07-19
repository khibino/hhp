{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hhp.GHCApi (
    withGHC,
    withGHC',
    initializeFlagsWithCradle,
    initializeFlagsWithCradle',
    setTargetFiles,
    getDynamicFlags,
    getSystemLibDir,
    withDynFlags,
    withCmdFlags,
    setNoWarningFlags,
    setAllWarningFlags,
    setDeferTypedHoles,
    setDeferTypeErrors,
    setPartialSignatures,
    setWarnTypedHoles,
    addImportPaths,
) where

import GHC (DynFlags (..), Ghc, LoadHowMuch (..))
import qualified GHC as G
import qualified GHC.Data.EnumSet as E (EnumSet, empty)
import GHC.Driver.Session (
    GeneralFlag (Opt_BuildingCabalPackage, Opt_HideAllPackages),
    ModRenaming (..),
    PackageArg (..),
    PackageFlag (ExposePackage),
    WarningFlag (Opt_WarnTypedHoles),
    gopt_set,
    parseDynamicFlagsCmdLine,
    wopt_set,
    xopt_set,
 )
import GHC.LanguageExtensions (Extension (..))
import GHC.Utils.Monad (liftIO)

import Control.Applicative ((<|>))
import Control.Monad (forM, void)
import Control.Monad.Catch (SomeException, bracket, handle)
import System.Exit (exitSuccess)
import System.IO (hPrint, hPutStr, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)

import Hhp.CabalApi
import Hhp.Gap
import Hhp.GhcPkg
import Hhp.Types

----------------------------------------------------------------

-- | Obtaining the directory for system libraries.
getSystemLibDir :: IO (Maybe FilePath)
getSystemLibDir = do
    res <- readProcess "ghc" ["--print-libdir"] []
    return $ case res of
        "" -> Nothing
        dirn -> Just (init dirn)

----------------------------------------------------------------

-- | Converting the 'Ghc' monad to the 'IO' monad.
withGHC
    :: FilePath
    -- ^ A target file displayed in an error message.
    -> Ghc a
    -- ^ 'Ghc' actions created by the Ghc utilities.
    -> IO a
withGHC file body = handle ignore $ withGHC' body
  where
    ignore :: SomeException -> IO a
    ignore e = do
        hPutStr stderr $ file ++ ":0:0:Error:"
        hPrint stderr e
        exitSuccess

withGHC' :: Ghc a -> IO a
withGHC' body = do
    mlibdir <- getSystemLibDir
    G.runGhc mlibdir body

----------------------------------------------------------------

importDirs :: [IncludeDir]
importDirs = [".", "..", "../..", "../../..", "../../../..", "../../../../.."]

data Build = CabalPkg | SingleFile deriving (Eq)

-- | Initialize the 'DynFlags' relating to the compilation of a single
-- file or GHC session according to the 'Cradle' and 'Options'
-- provided.
initializeFlagsWithCradle
    :: Options
    -> Cradle
    -> Ghc ()
initializeFlagsWithCradle opt cradle = void $ initializeFlagsWithCradle' opt cradle

type GetImportDirs = [FilePath] -> [IncludeDir]

initializeFlagsWithCradle'
    :: Options
    -> Cradle
    -> Ghc GetImportDirs
initializeFlagsWithCradle' opt cradle = case cradleCabalFile cradle of
    Just cradleFile  -> withCabal cradleFile <|> withSandbox
    Nothing          -> withSandbox
  where
    ghcopts = ghcOpts opt
    withCabal cradleFile = do
        pkgDesc <- liftIO $ parseCabalFile cradleFile
        compOpts <- liftIO $ getCompilerOptions ghcopts cradle pkgDesc
        initSession CabalPkg compOpts
        let wdir = cradleCurrentDir cradle
            rdir = cradleRootDir cradle
        return $ getImportDirectories rdir wdir pkgDesc
    withSandbox = initSession SingleFile compOpts >> return (const $ includeDirs compOpts)
      where
        pkgOpts = ghcDbStackOpts $ cradlePkgDbStack cradle
        compOpts
            | null pkgOpts = CompilerOptions ghcopts importDirs []
            | otherwise = CompilerOptions (ghcopts ++ pkgOpts) [wdir, rdir] []
        wdir = cradleCurrentDir cradle
        rdir = cradleRootDir cradle

----------------------------------------------------------------

initSession
    :: Build
    -> CompilerOptions
    -> Ghc ()
initSession build CompilerOptions{..} = do
    df <- G.getSessionDynFlags
    void $
        G.setSessionDynFlags
            =<< addCmdOpts
                ghcOptions
                ( setLinkerOptions $
                    setBuildEnv build $
                        setEmptyLogger $
                            addPackageFlags depPackages df
                )

----------------------------------------------------------------

setBuildEnv :: Build -> DynFlags -> DynFlags
setBuildEnv build = setHideAllPackages build . setCabalPackage build

-- At the moment with this option set ghc only prints different error messages,
-- suggesting the user to add a hidden package to the build-depends in his cabal
-- file for example
setCabalPackage :: Build -> DynFlags -> DynFlags
setCabalPackage CabalPkg df = setCabalPkg df
setCabalPackage _ df = df

-- | Enable hiding of all package not explicitly exposed (like Cabal does)
setHideAllPackages :: Build -> DynFlags -> DynFlags
setHideAllPackages CabalPkg df = gopt_set df Opt_HideAllPackages
setHideAllPackages _ df = df

-- | Parse command line ghc options and add them to the 'DynFlags' passed
addCmdOpts :: [GHCOption] -> DynFlags -> Ghc DynFlags
addCmdOpts cmdOpts df =
    tfst <$> parseDynamicFlagsCmdLine df (map G.noLoc cmdOpts)
  where
    tfst (a, _, _) = a

----------------------------------------------------------------

-- | Set the files as targets and load them.
setTargetFiles :: [FilePath] -> Ghc ()
setTargetFiles files = do
    targets <- forM files $ \file -> guessTarget file
    G.setTargets targets
    void $ G.load LoadAllTargets

----------------------------------------------------------------

-- | Return the 'DynFlags' currently in use in the GHC session.
getDynamicFlags :: IO DynFlags
getDynamicFlags = do
    mlibdir <- getSystemLibDir
    G.runGhc mlibdir G.getSessionDynFlags

withDynFlags :: (DynFlags -> DynFlags) -> Ghc a -> Ghc a
withDynFlags setFlag body = bracket setup teardown (const body)
  where
    setup = do
        dflag <- G.getSessionDynFlags
        void $ G.setSessionDynFlags (setFlag dflag)
        return dflag
    teardown = void . G.setSessionDynFlags

withCmdFlags :: [GHCOption] -> Ghc a -> Ghc a
withCmdFlags flags body = bracket setup teardown (const body)
  where
    setup = do
        dflag <- G.getSessionDynFlags >>= addCmdOpts flags
        void $ G.setSessionDynFlags dflag
        return dflag
    teardown = void . G.setSessionDynFlags

----------------------------------------------------------------

-- | Set 'DynFlags' equivalent to "-fdefer-typed-holes"
setDeferTypedHoles :: DynFlags -> DynFlags
setDeferTypedHoles dflag = gopt_set dflag G.Opt_DeferTypedHoles

-- | Set 'DynFlags' equivalent to "-fdefer-type-errors"
setDeferTypeErrors :: DynFlags -> DynFlags
setDeferTypeErrors dflag = gopt_set dflag G.Opt_DeferTypeErrors

-- | Set 'DynFlags' equivalent to "-Wtyped-holes"
setWarnTypedHoles :: DynFlags -> DynFlags
setWarnTypedHoles dflag = wopt_set dflag Opt_WarnTypedHoles

-- | Set 'DynFlags' equivalent to "-XPartialTypeSignatures"
setPartialSignatures :: DynFlags -> DynFlags
setPartialSignatures df = xopt_set (xopt_set df PartialTypeSignatures) NamedWildCards

-- | Set 'DynFlags' equivalent to "-w:".
setNoWarningFlags :: DynFlags -> DynFlags
setNoWarningFlags df = df{warningFlags = E.empty}

-- | Set 'DynFlags' equivalent to "-Wall".
setAllWarningFlags :: DynFlags -> DynFlags
setAllWarningFlags df = df{warningFlags = allWarningFlags}

{-# NOINLINE allWarningFlags #-}
allWarningFlags :: E.EnumSet WarningFlag
allWarningFlags = unsafePerformIO $ do
    mlibdir <- getSystemLibDir
    G.runGhc mlibdir $ do
        df <- G.getSessionDynFlags
        df' <- addCmdOpts ["-Wall"] df
        return $ G.warningFlags df'

setCabalPkg :: DynFlags -> DynFlags
setCabalPkg dflag = gopt_set dflag Opt_BuildingCabalPackage

addImportPaths :: [IncludeDir] -> DynFlags -> DynFlags
addImportPaths paths df = df{importPaths = paths ++ importPaths df}

addPackageFlags :: [Package] -> DynFlags -> DynFlags
addPackageFlags pkgs df =
    df{packageFlags = packageFlags df ++ expose `map` pkgs}
  where
    expose pkg = ExposePackage pkgid (PackageArg name) (ModRenaming True [])
      where
        (name, _, _) = pkg
        pkgid = showPkgId pkg
