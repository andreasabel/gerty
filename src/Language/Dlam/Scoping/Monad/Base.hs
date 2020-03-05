{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
module Language.Dlam.Scoping.Monad.Base
  (
   -- * Scope checking monad
   SM

   -- * State
  , ScoperState
  , runNewScoper
  , SCResult
  , scrLog
  , scrRes
  , getFreshNameId

  -- * Environment

  -- ** Scope
  , ScopeInfo(..)
  , lookupLocalVar
  , withLocals
  -- *** Binding
  , bindNameCurrentScope
  , maybeResolveNameCurrentScope
  , HowBind(..)
  , NameClassifier(..)
  , pattern NCAll
  , pattern NCNone
  ) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import qualified Data.Map as M

import Language.Dlam.Builtins
import Language.Dlam.Syntax.Abstract
import qualified Language.Dlam.Syntax.Concrete as C
import Language.Dlam.Syntax.Common (NameId)
import Language.Dlam.Scoping.Monad.Exception
import Language.Dlam.Scoping.Scope


data ScoperState
  = ScoperState
    { nextNameId :: NameId
    , scScope :: Scope
    -- ^ Unique NameId for naming.
    }


-- | The starting checker state.
startScoperState :: ScoperState
startScoperState =
  ScoperState { nextNameId = 0, scScope = startScope }
    where startScope = Scope { scopeNameSpace = emptyNameSpace }
          emptyNameSpace = M.empty


-- | The checker monad.
newtype SM a =
  SM { runSM :: ExceptT SCError (WriterT SCLog (ReaderT SCEnv (State ScoperState))) a }
  deriving ( Applicative, Functor, Monad
           , MonadReader SCEnv
           , MonadState ScoperState
           , MonadWriter SCLog
           , MonadError SCError)


type SCLog = String


data SCResult a
  = SCResult
    { scrLog :: SCLog
    , scrRes :: Either SCError a
    }


runScoper :: SCEnv -> ScoperState -> SM a -> SCResult a
runScoper env st p =
  let (res, log) = evalState (runReaderT (runWriterT $ (runExceptT (runSM p))) env) st
  in SCResult { scrLog = log, scrRes = res }


runNewScoper :: SM a -> SCResult a
runNewScoper = runScoper startEnv startScoperState



-- | Get a unique NameId.
getFreshNameId :: SM NameId
getFreshNameId = get >>= \s -> let c = nextNameId s in put s { nextNameId = succ c } >> pure c


-------------------------------
-- * Scope checking environment
-------------------------------


-- | Scope-checking environment.
data SCEnv = SCEnv
  { scScopeLocals :: ScopeInfo
  -- ^ Current scope information.
  }


data ScopeInfo = ScopeInfo
  { localVars :: M.Map C.Name Name }
    -- ^ Local variables in scope.
    -- TODO: add support for mapping to multiple names for ambiguity
    -- situations (like Agda does) (2020-03-05)


startScopeInfo :: ScopeInfo
startScopeInfo =
  ScopeInfo {
    localVars = M.fromList (fmap (\b -> (nameConcrete (builtinName b), builtinName b)) builtins)
  }


startEnv :: SCEnv
startEnv = SCEnv { scScopeLocals = startScopeInfo }


addLocals :: [(C.Name, Name)] -> SCEnv -> SCEnv
addLocals locals sc =
  let oldVars = localVars (scScopeLocals sc)
  in sc { scScopeLocals = (scScopeLocals sc) { localVars = oldVars <> M.fromList locals } }


lookupLocalVar :: C.Name -> SM (Maybe Name)
lookupLocalVar n = M.lookup n . localVars <$> reader scScopeLocals


-- | Execute the given action with the specified local variables
-- | (additionally) bound. This restores the scope after checking.
withLocals :: [(C.Name, Name)] -> SM a -> SM a
withLocals locals = local (addLocals locals)


-----------------------
-- * Scopes and Binding
-----------------------


getCurrentScope :: SM Scope
getCurrentScope = scScope <$> get


modifyCurrentScope :: (Scope -> Scope) -> SM ()
modifyCurrentScope f = modify (\s -> s { scScope = f (scScope s) })


maybeResolveNameCurrentScope :: C.Name -> SM (Maybe InScopeName)
maybeResolveNameCurrentScope n = lookupInScope n <$> getCurrentScope


doesNameExistInCurrentScope :: NameClassifier -> C.Name -> SM Bool
doesNameExistInCurrentScope nc n = maybe False (any (willItClash nc) . howBound) <$> maybeResolveNameCurrentScope n


bindNameCurrentScope :: HowBind -> C.Name -> Name -> SM ()
bindNameCurrentScope hb cn an = do
  isBound <- doesNameExistInCurrentScope (hbClashesWith hb) cn
  if isBound
  then throwError $ nameClash cn
  else modifyCurrentScope (addNameToScope (hbBindsAs hb) cn an)


data NameClassifier
  -- | Clashes with the given scope type.
  = NCT InScopeType
  -- | Clashes with all of the given classifiers.
  | NCAnd [NameClassifier]
  -- | Clashes with everything except the given classifiers.
  | AllExcept [NameClassifier]


-- | Clashes with everything.
pattern NCAll :: NameClassifier
pattern NCAll = AllExcept []


-- | Doesn't clash with anything.
pattern NCNone :: NameClassifier
pattern NCNone = NCAnd []


-- | Information for performing a binding.
data HowBind = HowBind
  { hbBindsAs :: InScopeType
  , hbClashesWith :: NameClassifier
  }


willItClash :: NameClassifier -> InScopeType -> Bool
willItClash (AllExcept ps) t = not $ any (`willItClash` t) ps
willItClash (NCAnd ps) t = any (`willItClash` t) ps
willItClash (NCT t1) t2 = t1 == t2
