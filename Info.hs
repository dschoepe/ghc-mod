module Info where

import Control.Applicative hiding (empty)
import Control.Monad
import Data.Maybe
import GHC
import Outputable
import PprTyThing
import Types
import NameSet
import HscTypes
import Data.List
import Control.Exception
import StringBuffer
import System.Time

type Expression = String
type ModuleString = String

----------------------------------------------------------------

typeExpr :: Options -> ModuleString -> Expression -> FilePath -> IO String
typeExpr _ modstr expr file = (++ "\n") <$> typeOf file modstr expr

inModuleContext :: FilePath -> ModuleString -> Ghc String -> IO String
inModuleContext fileName modstr action =
  withGHC $ valid `gcatch` constE invalid `gcatch` constE (return errorMessage)
  where
    valid = do
        initSession ["-w"]
        setTargetFile fileName
        loadWithLogger (\_ -> return ()) LoadAllTargets
        ok <- setContextFromTarget
        if ok
            then action
            else throw $ ErrorCall errorMessage
                 -- this will be caught anyway
    invalid = do
        initSession ["-w"]
        modgraph <- depanal [mkModuleName modstr] True
        let imports = concatMap (map (showSDoc . ppr . unLoc)) $
                      map ms_imps modgraph ++ map ms_srcimps modgraph
        importsBuf <- liftIO . stringToStringBuffer . unlines $
                     ("module " ++ sanitize modstr ++ " where") : imports
        clkTime <- liftIO getClockTime
        setTargets [Target (TargetModule $ mkModuleName modstr) True
                    (Just (importsBuf, clkTime))]
        loadWithLogger defaultWarnErrLogger LoadAllTargets
        ok <- setContextFromTarget
        if ok
          then action
          else return errorMessage
    errorMessage = "Couldn't determine type"
    sanitize = fromMaybe "SomeModule" . listToMaybe . words

typeOf :: FilePath -> ModuleString -> Expression -> IO String
typeOf fileName modstr expr = inModuleContext fileName modstr
                              (pretty <$> exprType expr)
  where pretty = showSDocForUser neverQualify . pprTypeForUser False

----------------------------------------------------------------

infoExpr :: Options -> ModuleString -> Expression -> FilePath -> IO String
infoExpr _ modstr expr file = (++ "\n") <$> info file modstr expr

info :: FilePath -> ModuleString -> FilePath -> IO String
info fileName modstr expr = inModuleContext fileName modstr (infoThing expr)
  where infoThing str = do
          names <- parseName str
          mb_stuffs <- mapM getInfo names
          let filtered = filterOutChildren (\(t,_f,_i) -> t) (catMaybes mb_stuffs)
          unqual <- getPrintUnqual
          return $ showSDocForUser unqual $ vcat (intersperse (text "") $ map (pprInfo False) filtered)

-- ghc/InteractiveUI.hs
filterOutChildren :: (a -> TyThing) -> [a] -> [a]
filterOutChildren get_thing xs
  = [x | x <- xs, not (getName (get_thing x) `elemNameSet` implicits)]
  where
      implicits = mkNameSet [getName t | x <- xs, t <- implicitTyThings (get_thing x)]

pprInfo :: PrintExplicitForalls -> (TyThing, Fixity, [GHC.Instance]) -> SDoc
pprInfo pefas (thing, fixity, insts)
  =  pprTyThingInContextLoc pefas thing
  $$ show_fixity fixity
  $$ vcat (map pprInstance insts)
  where
    show_fixity fix
        | fix == defaultFixity = empty
        | otherwise            = ppr fix <+> ppr (getName thing)

----------------------------------------------------------------

setContextFromTarget :: Ghc Bool
setContextFromTarget = do
    ms <- depanal [] False
    -- ms <- getModuleGraph -- this is the same
    top <- map ms_mod <$> filterM isTop ms
    {-
    top is a set of this module and your-defined modules.
    If this module has syntax errors, it cannot be specified.
    And if there is no your-defined modules, top is [].
    In this case, we cannot obtain the type of an expression, sigh.
    -}
    setContext top []
    return . not $ top == []
  where
    isTop ms = lookupMod `gcatch` returnFalse
      where
        lookupMod = lookupModule (ms_mod_name ms) Nothing >> return True
        returnFalse = constE $ return False

----------------------------------------------------------------

constE :: a -> (SomeException -> a)
constE func _ = func
