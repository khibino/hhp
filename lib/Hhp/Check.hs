module Hhp.Check (
    checkSyntax,
    check,
    expandTemplate,
    expand,
) where

import GHC (DynFlags (..), Ghc)
import GHC.Driver.Session (DumpFlag (Opt_D_dump_splices), dopt_set)

import Hhp.GHCApi
import Hhp.Logger
import Hhp.Types

----------------------------------------------------------------

-- | Checking syntax of a target file using GHC.
--   Warnings and errors are returned.
checkSyntax
    :: Options
    -> Cradle
    -> [FilePath]
    -- ^ The target files.
    -> IO String
checkSyntax _ _ [] = return ""
checkSyntax opt cradle files = withGHC sessionName $ do
    getImports <- initializeFlagsWithCradle' opt cradle
    either id id <$> check opt getImports files
  where
    sessionName = case files of
        [file] -> file
        _ -> "MultipleFiles"

----------------------------------------------------------------

-- | Checking syntax of a target file using GHC.
--   Warnings and errors are returned.
check
    :: Options
    -> ([FilePath] -> [IncludeDir])
    -> [FilePath]
    -- ^ The target files.
    -> Ghc (Either String String)
check opt getImports fileNames =
    withLogger opt (addImportPaths (getImports fileNames) . setAllWarningFlags . setPartialSignatures . setDeferTypedHoles) $
        setTargetFiles fileNames

----------------------------------------------------------------

-- | Expanding Haskell Template.
expandTemplate
    :: Options
    -> Cradle
    -> [FilePath]
    -- ^ The target files.
    -> IO String
expandTemplate _ _ [] = return ""
expandTemplate opt cradle files = withGHC sessionName $ do
    initializeFlagsWithCradle opt cradle
    either id id <$> expand opt files
  where
    sessionName = case files of
        [file] -> file
        _ -> "MultipleFiles"

----------------------------------------------------------------

-- | Expanding Haskell Template.
expand
    :: Options
    -> [FilePath]
    -- ^ The target files.
    -> Ghc (Either String String)
expand opt fileNames =
    withLogger opt (setDumpSplices . setNoWarningFlags) $
        setTargetFiles fileNames

setDumpSplices :: DynFlags -> DynFlags
setDumpSplices dflag = dopt_set dflag Opt_D_dump_splices
