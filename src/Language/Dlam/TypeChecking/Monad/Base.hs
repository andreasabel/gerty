{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Language.Dlam.TypeChecking.Monad.Base
  (
   -- * Type checker monad
   CM

   -- * Logging
  , debug
  , info

   -- * State
  , CheckerState
  , runNewChecker
  , TCResult
  , tcrLog
  , tcrRes

  , getFreshNameId

  -- ** Scope
  , lookupType
  , maybeLookupType
  , lookupType'
  , setType
  , setType'
  , withTypedVariable
  , withTypedVariable'
  , lookupValue
  , maybeLookupValue
  , lookupValue'
  , setValue
  , setValue'
  , withValuedVariable

  -- ** Grading
  , withGradedVariable
  , withGradedVariable'
  , lookupSubjectRemaining
  , lookupSubjectRemaining'
  , decrementGrade
  , setSubjectRemaining
  , setSubjectRemaining'
  , grZero
  , grOne

  -- * Environment
  , withLocalCheckingOf

  -- * Exceptions and error handling
  , TCErr
  , isSyntaxErr
  , isScopingErr
  , isTypingErr

  -- ** Implementation errors
  , notImplemented

  -- ** Scope errors
  , scoperError

  -- ** Synthesis errors
  , cannotSynthTypeForExpr
  , cannotSynthExprForType

  -- ** Type errors
  , tyMismatch
  , tyMismatch'
  , expectedInferredTypeForm
  , expectedInferredTypeForm'
  , notAType

  -- ** Pattern errors
  , patternMismatch

  -- ** Grading errors
  , usedTooManyTimes

  -- ** Parse errors
  , parseError
  ) where

import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import qualified Data.Map as M

import Language.Dlam.Builtins
import qualified Language.Dlam.Builtins2 as B2
import qualified Language.Dlam.Scoping.Monad.Exception as SE
import Language.Dlam.Syntax.Abstract
import qualified Language.Dlam.Syntax.Internal as I
import Language.Dlam.Syntax.Common (NameId)
import qualified Language.Dlam.Syntax.Concrete.Name as C
import Language.Dlam.Syntax.Parser.Monad (ParseError)
import Language.Dlam.Util.Pretty (pprintShow)


data CheckerState
  = CheckerState
    { typingScope :: M.Map Name Expr
    , valueScope :: M.Map Name Expr
    , provisionScope :: M.Map Name Grading
    -- ^ Scope of provisions (how can an assumption be used---grades remaining).
    , nextNameId :: NameId
    -- ^ Unique NameId for naming.
    , typingScope' :: M.Map Name I.Type
    , valueScope' :: M.Map Name I.Term
    , provisionScope' :: M.Map Name I.Grading
    }


-- | The starting checker state.
startCheckerState :: CheckerState
startCheckerState =
  CheckerState { typingScope = builtinsTypes
               , valueScope = builtinsValues
               , provisionScope = M.empty
               , nextNameId = 0
               -- , typingScope' = M.empty
               -- , valueScope' = M.empty
               , typingScope' = B2.builtinsTypes
               , valueScope' = B2.builtinsValues
               , provisionScope' = M.empty
               }


-- | The checker monad.
newtype CM a =
  CM { runCM :: ExceptT TCErr (WriterT TCLog (ReaderT TCEnv (State CheckerState))) a }
  deriving ( Applicative, Functor, Monad
           , MonadReader TCEnv
           , MonadState CheckerState
           , MonadWriter TCLog
           , MonadError TCErr)


type TCLog = [String]


-- | Write some debugging information.
debug :: String -> CM ()
debug = tell . pure


info :: String -> CM ()
info = tell . pure


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


lookupType :: Name -> CM (Maybe Expr)
lookupType n = M.lookup n . typingScope <$> get


maybeLookupType :: Name -> CM (Maybe I.Type)
maybeLookupType n = M.lookup n . typingScope' <$> get


lookupType' :: Name -> CM I.Type
lookupType' n = do
  maybeLookupType n >>= maybe (scoperError $ SE.unknownNameErr (C.Unqualified $ nameConcrete n)) pure


setType :: Name -> Expr -> CM ()
setType n t = modify (\s -> s { typingScope = M.insert n t (typingScope s) })
setType' :: Name -> I.Type -> CM ()
setType' n t = modify (\s -> s { typingScope' = M.insert n t (typingScope' s) })


-- | Execute the action with the given identifier bound with the given type.
withTypedVariable :: Name -> Expr -> CM a -> CM a
withTypedVariable v t p = do
  st <- get
  setType v t
  res <- p
  -- restore the typing scope
  modify (\s -> s { typingScope = typingScope st})
  pure res
-- | Execute the action with the given identifier bound with the given type.
withTypedVariable' :: Name -> I.Type -> CM a -> CM a
withTypedVariable' v t p = do
  st <- get
  setType' v t
  res <- p
  -- restore the typing scope
  modify (\s -> s { typingScope' = typingScope' st})
  pure res


lookupValue :: Name -> CM (Maybe Expr)
lookupValue n = M.lookup n . valueScope <$> get

maybeLookupValue :: Name -> CM (Maybe I.Term)
maybeLookupValue n = M.lookup n . valueScope' <$> get


lookupValue' :: Name -> CM I.Term
lookupValue' n =
  maybeLookupValue n >>= maybe (scoperError $ SE.unknownNameErr (C.Unqualified $ nameConcrete n)) pure


setValue :: Name -> Expr -> CM ()
setValue n t = modify (\s -> s { valueScope = M.insert n t (valueScope s) })
setValue' :: Name -> I.Term -> CM ()
setValue' n t = modify (\s -> s { valueScope' = M.insert n t (valueScope' s) })


-- | Execute the action with the given identifier bound with the given value.
withValuedVariable :: Name -> Expr -> CM a -> CM a
withValuedVariable v t p = do
  st <- get
  setValue v t
  res <- p
  -- restore the value scope
  modify (\s -> s { valueScope = valueScope st})
  pure res


-------------
-- Grading --
-------------


lookupRemaining :: Name -> CM (Maybe Grading)
lookupRemaining n = M.lookup n . provisionScope <$> get
lookupRemaining' :: Name -> CM (Maybe I.Grading)
lookupRemaining' n = M.lookup n . provisionScope' <$> get


lookupSubjectRemaining :: Name -> CM (Maybe Grade)
lookupSubjectRemaining n = fmap subjectGrade <$> lookupRemaining n
lookupSubjectRemaining' :: Name -> CM (Maybe I.Grade)
lookupSubjectRemaining' n = fmap I.subjectGrade <$> lookupRemaining' n


decrementGrade :: Grade -> CM (Maybe Grade)
decrementGrade e = do
  case e of
    Succ' n -> pure (Just n)
    Zero' -> pure Nothing
    -- TODO: figure out how to handle implicit grades---for now just
    -- assuming we can do whatever we want with them (2020-03-11)
    Implicit -> pure (Just Implicit)
    _ -> notImplemented $ "I don't yet know how to decrement the grade '" <> pprintShow e <> "'"


grZero, grOne :: Grade
grOne = Succ' grZero
grZero = Zero'


modifyRemaining :: Name -> (Grading -> Grading) -> CM ()
modifyRemaining n f = do
  prev <- lookupRemaining n
  case prev of
    Nothing -> pure ()
    Just prev -> setRemaining n (f prev)
modifyRemaining' :: Name -> (I.Grading -> I.Grading) -> CM ()
modifyRemaining' n f = do
  prev <- lookupRemaining' n
  case prev of
    Nothing -> pure ()
    Just prev -> setRemaining' n (f prev)


setRemaining :: Name -> Grading -> CM ()
setRemaining n g = modify (\s -> s { provisionScope = M.insert n g (provisionScope s) })
setRemaining' :: Name -> I.Grading -> CM ()
setRemaining' n g = modify (\s -> s { provisionScope' = M.insert n g (provisionScope' s) })


setSubjectRemaining :: Name -> Grade -> CM ()
setSubjectRemaining n g = modifyRemaining n (\gs -> mkGrading g (subjectTypeGrade gs))
setSubjectRemaining' :: Name -> I.Grade -> CM ()
setSubjectRemaining' n g = modifyRemaining' n (\gs -> I.mkGrading g (I.subjectTypeGrade gs))


-- | Execute the action with the given identifier bound with the given grading.
withGradedVariable :: Name -> Grading -> CM a -> CM a
withGradedVariable v gr p = do
  st <- get
  setRemaining v gr
  res <- p
  -- restore the provision scope
  modify (\s -> s { provisionScope = provisionScope st})
  pure res
-- | Execute the action with the given identifier bound with the given grading.
withGradedVariable' :: Name -> I.Grading -> CM a -> CM a
withGradedVariable' v gr p = do
  st <- get
  setRemaining' v gr
  res <- p
  -- restore the provision scope
  modify (\s -> s { provisionScope' = provisionScope' st})
  pure res


------------------------------
-- * Type checking environment
------------------------------


-- | Type-checking environment.
data TCEnv = TCEnv
  { tceCurrentExpr :: Maybe Expr
  -- ^ Expression currently being checked (if any).
  }


tceSetCurrentExpr :: Expr -> TCEnv -> TCEnv
tceSetCurrentExpr e env = env { tceCurrentExpr = Just e }


startEnv :: TCEnv
startEnv = TCEnv { tceCurrentExpr = Nothing }


-- | Indicate that we are now checking the given expression when running the action.
withLocalCheckingOf :: Expr -> CM a -> CM a
withLocalCheckingOf e = local (tceSetCurrentExpr e)


-----------------------------------------
----- Exceptions and error handling -----
-----------------------------------------


data TCError
  ---------------------------
  -- Implementation Errors --
  ---------------------------

  = NotImplemented String

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

  | TypeMismatch Expr Expr
  | TypeMismatch' I.Type I.Type

  | ExpectedInferredTypeForm String Expr
  | ExpectedInferredTypeForm' String I.Type
  | NotAType

  --------------------
  -- Pattern Errors --
  --------------------

  | PatternMismatch Pattern Expr

  --------------------
  -- Grading Errors --
  --------------------

  | UsedTooManyTimes Name

  ------------------
  -- Parse Errors --
  ------------------

  | ParseError ParseError




instance Show TCError where
  show (NotImplemented e) = e
  show CannotSynthTypeForExpr = "I couldn't synthesise a type for the expression."
  show (CannotSynthExprForType t) =
    "I was asked to try and synthesise a term of type '" <> pprintShow t <> "' but I wasn't able to do so."
  show (TypeMismatch tyExpected tyActual) =
    "Expected type '" <> pprintShow tyExpected <> "' but got '" <> pprintShow tyActual <> "'"
  show (TypeMismatch' tyExpected tyActual) =
    "Expected type '" <> pprintShow tyExpected <> "' but got '" <> pprintShow tyActual <> "'"
  show (ExpectedInferredTypeForm descr t) =
    "I was expecting the expression to have a "
    <> descr <> " type, but instead I found its type to be '"
    <> pprintShow t <> "'"
  show (ExpectedInferredTypeForm' descr t) =
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


notImplemented :: String -> CM a
notImplemented descr = throwCM (NotImplemented descr)


-- | Indicate that an issue occurred when performing a scope analysis.
scoperError :: SE.SCError -> CM a
scoperError e = throwCM (ScoperError e)


cannotSynthTypeForExpr :: CM a
cannotSynthTypeForExpr = throwCM CannotSynthTypeForExpr


cannotSynthExprForType :: Expr -> CM a
cannotSynthExprForType t = throwCM (CannotSynthExprForType t)


-- | 'tyMismatch expr tyExpected tyActual' indicates that an expression
-- | was found to have a type that differs from expected.
tyMismatch :: Expr -> Expr -> CM a
tyMismatch tyExpected tyActual =
  throwCM (TypeMismatch tyExpected tyActual)

-- | 'tyMismatch expr tyExpected tyActual' indicates that an expression
-- | was found to have a type that differs from expected.
tyMismatch' :: I.Type -> I.Type -> CM a
tyMismatch' tyExpected tyActual =
  throwCM (TypeMismatch' tyExpected tyActual)


expectedInferredTypeForm :: String -> Expr -> CM a
expectedInferredTypeForm descr t =
  throwCM (ExpectedInferredTypeForm descr t)
expectedInferredTypeForm' :: String -> I.Type -> CM a
expectedInferredTypeForm' descr t =
  throwCM (ExpectedInferredTypeForm' descr t)


notAType :: CM a
notAType = throwCM NotAType


patternMismatch :: Pattern -> Expr -> CM a
patternMismatch p t = throwCM (PatternMismatch p t)


usedTooManyTimes :: Name -> CM a
usedTooManyTimes = throwCM . UsedTooManyTimes


parseError :: ParseError -> CM a
parseError = throwCM . ParseError


-----------------------------------------
----- Errors and exception handling -----
-----------------------------------------


data TCErr = TCErr
  { tcErrErr :: TCError
  -- ^ The underlying error.
  , tcErrEnv :: TCEnv
  -- ^ Environment at point of the error.
  }


instance Exception TCErr


-- | Expression being checked when failure occurred.
tcErrExpr :: TCErr -> Maybe Expr
tcErrExpr = tceCurrentExpr . tcErrEnv


throwCM :: TCError -> CM a
throwCM e = do
  env <- ask
  throwError $ TCErr { tcErrErr = e, tcErrEnv = env }


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
isSyntaxErr = (== PhaseParsing) . errPhase
isScopingErr = (== PhaseScoping) . errPhase
isTypingErr = (== PhaseTyping) . errPhase
