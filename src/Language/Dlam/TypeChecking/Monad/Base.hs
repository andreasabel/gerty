{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Language.Dlam.TypeChecking.Monad.Base
  (
   -- * Type checker monad
   CM

   -- * Logging
  , Verbosity
  , verbositySilent
  , verbosityInfo
  , verbosityDebug
  , TCLog
  , debug
  , debugBlock
  , info
  , formatLog

   -- * State
  , CheckerState
  , runNewChecker
  , TCResult
  , tcrLog
  , tcrRes

  , getFreshNameId

  -- ** Metas
  , getMetas
  , setMetas
  , MetaInfo
  , metaState
  , metaType
  , MetaSolution(..)
  , MetaState(..)
  , MetaType(..)
  , MetaContext
  , registerMeta
  , mkMetaSolution
  , mkSolvedMeta
  , getMetaInfo
  , getFreshMetaId
  , getMetaType
  , maybeGetMetaSolution

  -- ** Scope
  , lookupType
  , maybeLookupType
  , setType
  , lookupValue
  , maybeLookupValue
  , setValue
  , updateWithScopeInfo

  -- ** Grading
  -- DAO: temporarily out
  --, withGradedVariable
  --, lookupSubjectRemaining
  --, setSubjectRemaining

  -- * Environment
  , withLocalCheckingOf

  -- ** Free Variables
  , lookupFVType
  , withVarBound
  , withVarTypeBound

  -- * Exceptions and error handling
  , TCErr
  , isSyntaxErr
  , isScopingErr
  , isTypingErr

  -- ** Printing errors

  , displayError
  , ErrorVerbosity
  , errVerbosityNone
  , errVerbosityPartial
  , errVerbosityFullNoBuiltins
  , errVerbosityFull

  -- ** Implementation errors
  , notImplemented
  , hitABug

  -- ** Scope errors
  , scoperError

  -- ** Synthesis errors
  , cannotSynthTypeForExpr
  , cannotSynthExprForType

  -- ** Type errors
  , tyMismatch
  , expectedInferredTypeForm
  , notAType

  -- ** Pattern errors
  , patternMismatch

  -- ** Grading errors
  , usedTooManyTimes

  -- ** Parse errors
  , parseError

  -- * Helper classes
  , TCExcept
  , CMEnv
  , TCDebug
  , HasMetas
  ) where

import Control.Exception (Exception, displayException)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import qualified Data.Map as M
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)

import Language.Dlam.Builtins
import qualified Language.Dlam.Scoping.Monad.Base as SM
import qualified Language.Dlam.Scoping.Monad.Exception as SE
import Language.Dlam.Syntax.Abstract
import qualified Language.Dlam.Syntax.Common.Language as Com
import qualified Language.Dlam.Syntax.Internal as I
import Language.Dlam.Syntax.Common (NameId(..))
import qualified Language.Dlam.Syntax.Concrete.Name as C
import Language.Dlam.Syntax.Parser.Monad (ParseError)
import Language.Dlam.Util.Pretty hiding ((<>))

data GradeContext
  -- Invariant: keys are all the same
  = GradeContext
    { contextGrades     :: M.Map FreeVar (M.Map FreeVar I.Grade)
    , subjectGrades     :: M.Map FreeVar I.Grade
    , subjectTypeGrades :: M.Map FreeVar I.Grade }

data CheckerState
  = CheckerState
    { typingScope :: M.Map AName I.Type
    , valueScope :: M.Map AName I.Term
    , nextNameId :: NameId
    -- ^ Unique NameId for naming.
    , nextMetaId :: I.MetaId
    -- ^ Unique id for metas.
    , debugNesting :: Int
    -- ^ Counter used to make it easier to locate debugging messages.
    , metas :: MetaContext
    }


type CMState = MonadState CheckerState


-- TODO: take the scoper state as an argument so e.g., we can set the meta id (2020-03-25)
-- | The starting checker state.
startCheckerState :: CheckerState
startCheckerState =
  CheckerState { typingScope = builtinsTypes
               , valueScope = builtinsValues
               , nextNameId = 0
               , nextMetaId = 0
               , debugNesting = 0
               , metas = M.empty
               }


-- | Update the checker with information from a scope analysis. USE WITH CAUTION.
updateWithScopeInfo :: SM.SCResult a -> CM ()
updateWithScopeInfo = setNextMetaId . SM.nextImplicitId . SM.scrState
  where setNextMetaId :: MetaId -> CM ()
        setNextMetaId i = modify (\s -> s { nextMetaId = i })


-- | The checker monad.
newtype CM a =
  CM { runCM :: ExceptT TCErr (WriterT TCLog (ReaderT TCEnv (State CheckerState))) a }
  deriving ( Applicative, Functor, Monad
           , MonadReader TCEnv
           , MonadState CheckerState
           , MonadWriter TCLog
           , MonadError TCErr)


-------------------
----- Logging -----
-------------------


type TCLog = [LogMessage]


data LogMessage = InfoMessage String | DebugMessage String


instance Show LogMessage where
  show (InfoMessage s) = "INFO: " <> s
  show (DebugMessage s) = "DEBUG: " <> s


messageLevel :: LogMessage -> Verbosity
messageLevel InfoMessage{} = Info
messageLevel DebugMessage{} = Debug


data Verbosity = Silent | Info | Debug
  deriving (Eq, Ord)


verbositySilent, verbosityInfo, verbosityDebug :: Verbosity
verbositySilent = Silent
verbosityInfo = Info
verbosityDebug = Debug


type TCDebug m = (MonadWriter TCLog m, MonadState CheckerState m)


-- | Write some debugging information.
debug :: (TCDebug m) => String -> m ()
debug msg = do
  debugNest <- fmap debugNesting get
  let formattedMessage = if debugNest == 0 then msg else unwords [replicate debugNest '>', msg]
  tell . pure . DebugMessage $ formattedMessage


info :: (TCDebug m) => String -> m ()
info = tell . pure . InfoMessage


-- | Indicate we are entering a debug block.
debugOpen :: (TCDebug m) => m ()
debugOpen = modify (\s -> s { debugNesting = succ (debugNesting s) })


-- | Indicate we are leaving a debug block.
debugClose :: (TCDebug m) => m ()
debugClose = modify (\s -> s { debugNesting = pred (debugNesting s) })


-- | Wrap the action in some debugging messages. The final message can
-- | use the result of the action.
debugBlock :: (TCDebug m) => String -> String -> (a -> String) -> m a -> m a
debugBlock blockDesc' open close action = do
  let blockDesc = if blockDesc' /= "" then blockDesc' <> ": " else ""
  debug (blockDesc <> open)
  debugOpen
  res <- action
  debugClose
  debug (blockDesc <> close res)
  pure res


filterLog :: Verbosity -> TCLog -> TCLog
filterLog l = filter ((<= l) . messageLevel)


formatLog :: Verbosity -> TCLog -> String
formatLog v = unlines . fmap show . filterLog v


--------------------
----- Checking -----
--------------------


data TCResult a
  = TCResult
    { tcrLog :: TCLog
    , tcrRes :: Either TCErr a
    }


runChecker :: TCEnv -> CheckerState -> CM a -> TCResult a
runChecker env st p =
  let (res, log) = evalState (runReaderT (runWriterT $ (runExceptT (runCM p))) env) st
  in TCResult { tcrLog = log, tcrRes = res }


runNewChecker :: CM a -> TCResult a
runNewChecker = runChecker startEnv startCheckerState



-- | Get a unique NameId.
getFreshNameId :: CM NameId
getFreshNameId = get >>= \s -> let c = nextNameId s in put s { nextNameId = succ c } >> pure c


maybeLookupType :: AName -> CM (Maybe I.Type)
maybeLookupType n = M.lookup n . typingScope <$> get


lookupType :: AName -> CM I.Type
lookupType n =
  debugBlock "lookupType'"
    ("looking up type of: " <> pprintShow n)
    (\t -> "found type '" <> pprintShow t <> "' for variable '" <> pprintShow n <> "'")
    (maybeLookupType n >>= maybe (scoperError $ SE.unknownNameErr (C.Unqualified $ nameConcrete n)) pure)


setType :: AName -> I.Type -> CM ()
setType n t = modify (\s -> s { typingScope = M.insert n t (typingScope s) })


maybeLookupValue :: AName -> CM (Maybe I.Term)
maybeLookupValue n = M.lookup n . valueScope <$> get


lookupValue :: AName -> CM I.Term
lookupValue n =
  maybeLookupValue n >>= maybe (scoperError $ SE.unknownNameErr (C.Unqualified $ nameConcrete n)) pure


setValue :: AName -> I.Term -> CM ()
setValue n t = modify (\s -> s { valueScope = M.insert n t (valueScope s) })


-----------
-- Metas --
-----------


type MetaId = I.MetaId


type MetaContext = M.Map MetaId MetaInfo


instance Pretty MetaContext where
  pprint xs = vcat $ fmap pprintBinding (M.toList xs)
    where pprintBinding (n, MetaInfo mt ms) =
            let mtt = brackets $ case mt of
                        IsImplicit -> text "IMPLICIT"
                        IsMeta     -> text "META"
                mst = case ms of
                        MetaUnsolved{} -> text "(wasn't able to solve)"
                        MetaSolved (MetaSolution (I.VISType{}, t)) -> equals <+> pprint t
                        MetaSolved (MetaSolution (I.VISTerm, t)) -> equals <+> pprint t
                        MetaSolved (MetaSolution (I.VISLevel, t)) -> equals <+> pprint t
            in mtt <+> pprint n <+> mst


data MetaType = IsImplicit | IsMeta


data MetaSolution = forall t. MetaSolution (I.ISSort t, t)


data MetaState = MetaSolved MetaSolution | forall t. MetaUnsolved (I.ISSort t)


data MetaInfo = MetaInfo { metaType :: MetaType, metaState :: MetaState }


type HasMetas = MonadState CheckerState


mkMetaSolution :: (I.ISSort t, t) -> MetaSolution
mkMetaSolution = MetaSolution


mkSolvedMeta :: MetaType -> MetaSolution -> MetaInfo
mkSolvedMeta mt s = MetaInfo mt (MetaSolved s)


getMetas :: (HasMetas m) => m MetaContext
getMetas = metas <$> get


setMetas :: (HasMetas m) => MetaContext -> m ()
setMetas impls = modify (\s -> s { metas = impls })


maybeGetMetaInfo :: (HasMetas m) => MetaId -> m (Maybe MetaInfo)
maybeGetMetaInfo i = M.lookup i . metas <$> get


getMetaInfo :: (HasMetas m, TCExcept m) => MetaId -> m MetaInfo
getMetaInfo i =
  maybeGetMetaInfo i >>= maybe (hitABug $ "meta '" <> pprintShow i <> "' isn't registered.") pure


getMetaType :: (HasMetas m, TCExcept m) => MetaId -> m MetaType
getMetaType = fmap (\(MetaInfo t _) -> t) . getMetaInfo


maybeGetMetaSolution :: (HasMetas m) => I.ISSort t -> MetaId -> m (Maybe t)
maybeGetMetaSolution s i = do
  minfo <- maybeGetMetaInfo i
  pure $ case minfo of
           Nothing -> Nothing
           Just (MetaInfo _ MetaUnsolved{}) -> Nothing
           Just (MetaInfo _ (MetaSolved (MetaSolution (s', t)))) ->
             case (s, s') of
               (I.VISTerm, I.VISTerm) -> Just t
               (I.VISLevel, I.VISLevel) -> Just t
               (I.VISType{}, I.VISType{}) -> Just t
               (_, _) -> Nothing


registerMeta :: MetaId -> MetaType -> I.ISSort t -> CM ()
registerMeta i mt s = do
  debug $ "registering meta '" <> pprintShow i <> "'"
  metas <- getMetas
  case M.lookup i metas of
    Nothing -> setMetas (M.insert i (MetaInfo mt (MetaUnsolved s)) metas)
    Just{} -> hitABug "meta already registered"


-- | Get a unique MetaId.
getFreshMetaId :: CM I.MetaId
getFreshMetaId = get >>= \s -> let c = nextMetaId s in put s { nextMetaId = succ c } >> pure c


-------------
-- Grading --
-------------

{-
DAO: Out of date, but may need converting to the new style.

lookupRemaining :: AName -> CM (Maybe I.Grading)
lookupRemaining n = M.lookup n . provisionScope <$> get


lookupSubjectRemaining :: AName -> CM (Maybe I.Grade)
lookupSubjectRemaining n = fmap I.subjectGrade <$> lookupRemaining n


modifyRemaining :: AName -> (I.Grading -> I.Grading) -> CM ()
modifyRemaining n f = do
  prev <- lookupRemaining n
  case prev of
    Nothing -> pure ()
    Just prev -> setRemaining n (f prev)


setRemaining :: AName -> I.Grading -> CM ()
setRemaining n g = modify (\s -> s { provisionScope = M.insert n g (provisionScope s) })


setSubjectRemaining :: AName -> I.Grade -> CM ()
setSubjectRemaining n g = modifyRemaining n (\gs -> I.mkGrading g (I.subjectTypeGrade gs))


-- | Execute the action with the given identifier bound with the given grading.
withGradedVariable :: AName -> I.Grading -> CM a -> CM a
withGradedVariable v gr p = do
  st <- get
  setRemaining v gr
  res <- p
  -- restore the provision scope
  modify (\s -> s { provisionScope = provisionScope st})
  pure res

-}


------------------------------
-- * Type checking environment
------------------------------


-- | Type-checking environment.
data TCEnv = TCEnv
  { tceCurrentExpr :: Maybe Expr
  -- ^ Expression currently being checked (if any).
  , tceFVContext :: FreeVarContext
  -- ^ Current context of free variables.
  , inScopeSet :: Set.Set FreeVar
  -- ^ Currently known free variables.
  }


tceSetCurrentExpr :: Expr -> TCEnv -> TCEnv
tceSetCurrentExpr e env = env { tceCurrentExpr = Just e }


startEnv :: TCEnv
startEnv = TCEnv { tceCurrentExpr = Nothing, tceFVContext = emptyContext, inScopeSet = Set.empty }


-- | Indicate that we are now checking the given expression when running the action.
withLocalCheckingOf :: Expr -> CM a -> CM a
withLocalCheckingOf e = local (tceSetCurrentExpr e)


---------------------------
-- Free Variable Context --
---------------------------


newtype FreeVar = FreeVar { unFreeVar :: AnyName }
  deriving (Eq, Ord, Pretty)


class ToFreeVar a where
  toFreeVar :: a -> FreeVar


instance ToFreeVar AnyName where
  toFreeVar (AnyName n) = toFreeVar n


instance ToFreeVar (Name n) where
  toFreeVar n = FreeVar (AnyName (forgetSort n))


instance ToFreeVar I.FreeVar where
  toFreeVar n = toFreeVar (I.freeVarName n)


forgetSort :: Name a -> Name ()
forgetSort = translate


type FreeVarInfo =
  -- Type, context grades, subject grades, subject type grades
  (I.Type, (M.Map FreeVar I.Grade, I.Grade, I.Grade))


data FreeVarContext =
  -- Invariant: keys of fvTypes same as keys in fvGrades
  FVC { fvTypes :: M.Map FreeVar I.Type
      , fvGrades :: GradeContext }


fvcAddBinding :: FreeVar -> FreeVarInfo -> FreeVarContext -> FreeVarContext
fvcAddBinding v (ty, (delta, s, r)) (FVC types (GradeContext contextGrds subjGrds subjTyGrds)) =
  FVC (M.insert v ty types)
       (GradeContext (M.insert v delta contextGrds)
                     (M.insert v s subjGrds)
                     (M.insert v r subjTyGrds))

{- Deprecated

fvcMapOp :: (M.Map FreeVar FreeVarInfo -> a) -> FreeVarContext -> a
fvcMapOp f (FVC m) = f m


fvcMap :: (M.Map FreeVar FreeVarInfo -> M.Map FreeVar FreeVarInfo) -> FreeVarContext -> FreeVarContext
fvcMap f = fvcMapOp (FVC . f)
-}

emptyContext :: FreeVarContext
emptyContext = FVC M.empty (GradeContext M.empty M.empty M.empty)


hangTag :: (Pretty t, Pretty d) => t -> d -> Doc
hangTag t x = (pprint t) $+$ nest indent (pprint x)
  where indent = 2


keyed :: (Pretty t, Pretty d) => t -> d -> Doc
keyed k v = pprint k `beside` colon <+> pprint v


instance Pretty FreeVarContext where
  pprint ctxt = vcat $ map pprintBinding (M.assocs . fvTypes $ ctxt)
    where
      pprintBinding (n, t) = fromMaybe (error $ "No grade information for " ++ (render $ pprint n)) $ do
        sg <- M.lookup n (subjectGrades . fvGrades $ ctxt)
        st <- M.lookup n (subjectTypeGrades . fvGrades $ ctxt)
        return $ hangTag n (vcat [keyed "subGRADE" sg, keyed "tyGRADE" st, keyed "TYPE" t])


tceAddInScope :: [FreeVar] -> TCEnv -> TCEnv
tceAddInScope names env =
  env { inScopeSet = Set.union (Set.fromList names) (inScopeSet env) }


getInScope :: CM (Set.Set FreeVar)
getInScope = fmap inScopeSet ask


-- | Execute the action with the given free variables in scope.
withInScope :: [FreeVar] -> CM a -> CM a
withInScope names = local (tceAddInScope names)


getContext :: CM FreeVarContext
getContext = fmap tceFVContext ask


tceAddBinding :: FreeVar -> FreeVarInfo -> TCEnv -> TCEnv
tceAddBinding v bod env =
  env { tceFVContext = fvcAddBinding v bod (tceFVContext env) }


type CMEnv = MonadReader TCEnv


-- | Execute the action with the given free variable bound with the
-- | given grading and type.
withVarBound :: (ToFreeVar n, Pretty n, CMEnv m, TCDebug m) => n -> I.Grading -> I.Type -> m a -> m a
withVarBound n g ty act =
  debugBlock "withVarBound"
    ("binding '" <> pprintShow n <> "' with grades '" <> pprintShow g <> "' and type '" <> pprintShow ty <> "'")
    (\_ -> "unbinding '" <> pprintShow n <> "'")
    (local (tceAddBinding (toFreeVar n) (ty, (_, Com.subjectGrade g, Com.subjectTypeGrade g))) act)


-- | Execute the action with the given free variable bound with the
-- | given type (ignoring grading).
withVarTypeBound :: (ToFreeVar n, Pretty n) => n -> I.Type -> CM a -> CM a
withVarTypeBound n ty = withVarBound n I.thatMagicalGrading ty


lookupFVInfo :: (ToFreeVar n, Pretty n) => n -> CM FreeVarInfo
lookupFVInfo name = do
  (FVC types grades) <- getContext
  let n = toFreeVar name
  fromMaybe (hitABug $ "tried to look up the type of free variable '" <> pprintShow n <> "' but it wasn't in scope. Scope checking or type-checking is broken.") 
     $ (do
         ty    <- M.lookup n types
         delta <- M.lookup n (contextGrades grades)
         s     <- M.lookup n (subjectGrades grades)
         r     <- M.lookup n (subjectTypeGrades grades)
         return (pure (ty, (delta, s, r))))


lookupFVType :: I.Name n -> CM I.Type
lookupFVType = fmap fst . lookupFVInfo


-----------------------------------------
----- Exceptions and error handling -----
-----------------------------------------


type TCExcept m = (MonadError TCErr m, CMEnv m, CMState m)


data TCError
  ---------------------------
  -- Implementation Errors --
  ---------------------------

  = NotImplemented String
  | ImplementationBug String

  ------------------
  -- Scope Errors --
  ------------------

  | ScoperError SE.SCError

  ------------------
  -- Synth Errors --
  ------------------

  | CannotSynthTypeForExpr

  | CannotSynthExprForType Expr

  -----------------
  -- Type Errors --
  -----------------

  | TypeMismatch I.Type I.Type

  | ExpectedInferredTypeForm String I.Type
  | NotAType

  --------------------
  -- Pattern Errors --
  --------------------

  | PatternMismatch Pattern I.Type

  --------------------
  -- Grading Errors --
  --------------------

  | UsedTooManyTimes (I.Name ())

  ------------------
  -- Parse Errors --
  ------------------

  | ParseError ParseError




instance Show TCError where
  show (NotImplemented e) = e
  show (ImplementationBug e) = "[BUG]: " <> e
  show CannotSynthTypeForExpr = "I couldn't synthesise a type for the expression."
  show (CannotSynthExprForType t) =
    "I was asked to try and synthesise a term of type '" <> pprintShow t <> "' but I wasn't able to do so."
  show (TypeMismatch tyExpected tyActual) =
    "Expected type '" <> pprintShow tyExpected <> "' but got '" <> pprintShow tyActual <> "'"
  show (ExpectedInferredTypeForm descr t) =
    "I was expecting the expression to have a "
    <> descr <> " type, but instead I found its type to be '"
    <> pprintShow t <> "'"
  show NotAType = "I was expecting the expression to be a type, but it wasn't."
  show (PatternMismatch p t) =
    "The pattern '" <> pprintShow p <> "' is not valid for type '" <> pprintShow t <> "'"
  show (UsedTooManyTimes n) =
    "'" <> pprintShow n <> "' is used too many times."
  show (ParseError e) = show e
  show (ScoperError e) = show e

instance Exception TCError


notImplemented :: (TCExcept m) => String -> m a
notImplemented descr = throwCM (NotImplemented descr)


hitABug :: (TCExcept m) => String -> m a
hitABug descr = throwCM (ImplementationBug descr)


-- | Indicate that an issue occurred when performing a scope analysis.
scoperError :: (TCExcept m) => SE.SCError -> m a
scoperError e = throwCM (ScoperError e)


cannotSynthTypeForExpr :: CM a
cannotSynthTypeForExpr = throwCM CannotSynthTypeForExpr


cannotSynthExprForType :: (TCExcept m) => Expr -> m a
cannotSynthExprForType t = throwCM (CannotSynthExprForType t)


-- | 'tyMismatch expr tyExpected tyActual' indicates that an expression
-- | was found to have a type that differs from expected.
tyMismatch :: I.Type -> I.Type -> CM a
tyMismatch tyExpected tyActual =
  throwCM (TypeMismatch tyExpected tyActual)


expectedInferredTypeForm :: (TCExcept m) => String -> I.Type -> m a
expectedInferredTypeForm descr t =
  throwCM (ExpectedInferredTypeForm descr t)


notAType :: (TCExcept m) => m a
notAType = throwCM NotAType


patternMismatch :: (TCExcept m) => Pattern -> I.Type -> m a
patternMismatch p t = throwCM (PatternMismatch p t)


usedTooManyTimes :: (TCExcept m) => I.Name b -> m a
usedTooManyTimes = throwCM . UsedTooManyTimes . I.translate


parseError :: (TCExcept m) => ParseError -> m a
parseError = throwCM . ParseError


-----------------------------------------
----- Errors and exception handling -----
-----------------------------------------


data TCErr = TCErr
  { tcErrErr :: TCError
  -- ^ The underlying error.
  , tcErrEnv :: TCEnv
  -- ^ Environment at point of the error.
  , tcErrState :: CheckerState
  -- ^ State at point of the error.
  }


instance Exception TCErr


-- | Expression being checked when failure occurred.
tcErrExpr :: TCErr -> Maybe Expr
tcErrExpr = tceCurrentExpr . tcErrEnv


throwCM :: (TCExcept m) => TCError -> m a
throwCM e = do
  env <- ask
  st  <- get
  throwError $ TCErr { tcErrErr = e, tcErrEnv = env, tcErrState = st }


instance Show TCErr where
  show e = "The following error occurred when " <> phaseMsg <> (maybe ": " (\expr -> " '" <> pprintShow expr <> "': ") (tcErrExpr e)) <> show (tcErrErr e)
    where phaseMsg = case errPhase e of
                       PhaseParsing -> "parsing"
                       PhaseScoping -> "scope checking"
                       PhaseTyping  -> "type-checking"


data ProgramPhase = PhaseParsing | PhaseScoping | PhaseTyping
  deriving (Show, Eq, Ord)


-- | In which phase was the error raised.
errPhase :: TCErr -> ProgramPhase
errPhase = errPhase' . tcErrErr
  where errPhase' ParseError{}  = PhaseParsing
        errPhase' ScoperError{} = PhaseScoping
        errPhase' _             = PhaseTyping


isSyntaxErr, isScopingErr, isTypingErr :: TCErr -> Bool
isSyntaxErr = isPhaseErr PhaseParsing
isScopingErr = isPhaseErr PhaseScoping
isTypingErr = isPhaseErr PhaseTyping


isPhaseErr :: ProgramPhase -> TCErr -> Bool
isPhaseErr phase err = not (isImplementationErr err) && errPhase err == phase


isImplementationErr :: TCErr -> Bool
isImplementationErr e =
  case tcErrErr e of
    NotImplemented{}    -> True
    ImplementationBug{} -> True
    _                   -> False


data ErrorVerbosity = ErrVerbosityNone | ErrVerbosityPartial | ErrVerbosityFull Bool
  deriving (Eq, Ord)


errVerbosityNone, errVerbosityPartial, errVerbosityFullNoBuiltins, errVerbosityFull :: ErrorVerbosity
errVerbosityNone = ErrVerbosityNone
errVerbosityPartial = ErrVerbosityPartial
errVerbosityFullNoBuiltins = ErrVerbosityFull False
errVerbosityFull = ErrVerbosityFull True


displayError :: ErrorVerbosity -> TCErr -> String
displayError errVerbosity err =
  if verboseErrors then show (cat
    [ hangTag "ERROR" (displayException err)
    , hangTag "ENVIRONMENT" (pprintEnv (tcErrEnv err))
    , hangTag "STATE" (pprintState (tcErrState err))
    ])
  else displayException err
  where pprintEnv = hangTag "FREE-VARIABLE CONTEXT" . tceFVContext
        pprintState st = vcat $
          [ hangTag "METAS" (metas st)
          , whenScopePrinting $ pprintKMap "SIGNATURES IN SCOPE" (colon `beside` space) (typingScope st)
          , whenScopePrinting $ pprintKMap "DEFINITIONS IN SCOPE" (space `beside` equals `beside` space) (valueScope st)
          ]
        pprintKMap :: (Pretty t, Pretty v) => t -> Doc -> M.Map AName v -> Doc
        pprintKMap t sep m = hangTag t $
          let (builtins, user) = M.partitionWithKey (\k _ -> k `elem` builtinsNames) m
              pmap = vcat . M.foldrWithKey (\k v xs -> pprint k `beside` sep `beside` pprint v : xs) []
          in vcat $ [whenBuiltinsPrinting $ hangTag "BUILTINS" (pmap builtins), hangTag "USER" (pmap user)]
        verboseErrors = errVerbosity > ErrVerbosityNone
        whenScopePrinting s = if errVerbosity >= errVerbosityFullNoBuiltins then s else mempty
        whenBuiltinsPrinting s = if errVerbosity >= errVerbosityFull then s else mempty


-----------------------
----- For Unbound -----
-----------------------


instance I.LFresh CM where
  getAvoids = Set.map unFreeVar <$> getInScope
  avoid xs = withInScope (fmap toFreeVar xs)
  lfresh n = do
    let s = name2String n
    used <- getAvoids
    pure $ head (filter (\x -> not (Set.member (AnyName x) used)) (map (makeName s) [0..]))
