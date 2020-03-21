{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}

module Language.Dlam.Syntax.Concrete
  (
  -- * Names
    module Language.Dlam.Syntax.Concrete.Name
  , OneOrMoreBoundNames
  -- * Expressions
  , Expr(..)
  , mkAbs
  , absVar
  , absTy
  , absExpr

  -- ** Grading
  , Grade
  , Grading
  , mkGrading
  , grading
  , subjectGrade
  , subjectTypeGrade

  -- ** Naming
  , MaybeNamed(..)
  -- ** Bindings
  , Binds(..)
  , mkArg
  , BoundName
  , bindName
  , unBoundName
  , Param(..)
  , LambdaBinding
  , LambdaArg
  , LambdaArgs
  , TypedBinding
  , unTB
  , mkTypedBinding
  , PiBindings(..)
  , lambdaBindingFromTyped
  , lambdaArgFromTypedBinding
  -- ** Let bindings and patterns
  , LetBinding(..)
  , Pattern(..)
  -- * AST
  , AST(..)
  -- ** Declarations
  , FLHS(..)
  , FRHS(..)
  , Declaration(..)
  , Abstraction
  , mkImplicit
  ) where


import Prelude hiding ((<>))
import qualified Data.List.NonEmpty as NE

import Language.Dlam.Syntax.Concrete.Name
import Language.Dlam.Syntax.Common
import qualified Language.Dlam.Syntax.Common.Language as C
import Language.Dlam.Syntax.Common.Language (Binds, HasType)
import Language.Dlam.Util.Pretty


------------------------------
----- Language Specifics -----
------------------------------


type Type = Expr
type Typed = C.IsTyped Expr
type Grading = C.Grading Grade
type Graded = C.Graded Grade
type BoundName = C.BoundName CName
type OneOrMoreBoundNames = C.OneOrMoreBoundNames CName
typedWith :: a -> Type -> Typed a
typedWith = C.typedWith
gradedWith :: a -> Grading -> Graded a
gradedWith = C.gradedWith
typeOf :: (HasType a Type) => a -> Type
typeOf = C.typeOf
grading :: (C.IsGraded a Grade) => a -> Grading
grading = C.grading
subjectGrade, subjectTypeGrade :: (C.IsGraded a Grade) => a -> Grade
subjectGrade = C.subjectGrade
subjectTypeGrade = C.subjectTypeGrade
mkGrading :: Grade -> Grade -> Grading
mkGrading = C.mkGrading
bindName :: CName -> BoundName
bindName = C.bindName
unBoundName :: BoundName -> CName
unBoundName = C.unBoundName
bindsWhat :: (Binds a CName) => a -> [BoundName]
bindsWhat = C.bindsWhat


------------------
-- Declarations --
------------------


newtype AST = AST [Declaration]
  deriving Show


-- | A function clause's left-hand side.
data FLHS =
  -- Currently we only support simple identifiers.
  FLHSName CName
  deriving (Show)

-- | Right-hand side of a function clause.
data FRHS =
  -- Currently we only support simple expressions.
  FRHSAssign Expr
  deriving (Show)


-- | A Param either captures some typed names, or an @a@.
data Param a = ParamNamed TypedBinding | ParamUnnamed a
  deriving (Show, Eq, Ord)


-- | Lambda abstraction binder.
type LambdaArg = Arg (MightBe (Typed `ThenMightBe` Graded) OneOrMoreBoundNames)


mkLambdaArg :: IsHiddenOrNot -> OneOrMoreBoundNames -> Maybe (Expr, Maybe Grading) -> LambdaArg
mkLambdaArg isHid names tyGrad =
  mkArg isHid
    (maybe (itIsNot names)                                          -- no type or grades
     (\(ty, mg) -> itIs (maybe                                      -- at least a type
       (onlyFirst (`typedWith` ty))                                 -- type but no grades
       (\g -> wasBoth (`typedWith` ty) (`gradedWith` g)) mg) names) -- type and grades
     tyGrad)


lambdaArgFromTypedBinding :: TypedBinding -> LambdaArg
lambdaArgFromTypedBinding e =
  let isHid = isHidden  e
      ty    = typeOf    e
      names = bindsWhat e
      grades = tryIt grading (un (unTB e))
  in mkLambdaArg isHid (NE.fromList names) (Just (ty, grades))


type LambdaArgs = [LambdaArg]


data BoundTo b e = BoundTo { boundToWhat :: b, whatWasBound :: e }
  deriving (Show, Eq, Ord)


instance (Pretty b, Pretty e) => Pretty (BoundTo b e) where
  pprint b = pprint (boundToWhat b) <+> colon <+> pprint (whatWasBound b)


-- | The left-hand-side of a function type.
type LambdaBinding = Arg (MightBe (BoundTo OneOrMoreBoundNames) Expr)


lambdaBindingFromTyped :: TypedBinding -> LambdaBinding
lambdaBindingFromTyped tb =
  let boundNames = NE.fromList $ bindsWhat tb
      ty         = typeOf tb
  in mkArg (isHidden tb) (itIs (BoundTo boundNames) ty)


------------------
----- Naming -----
------------------


data MaybeNamed a = Named CName a | Unnamed a
  deriving (Show, Eq, Ord)


instance Un MaybeNamed where
  un (Named _ e) = e
  un (Unnamed e) = e


instance (Pretty e) => Pretty (Graded (Typed e)) where
  pprint x =
    let ty = typeOf x
        grades = grading x
        val = un . un $ x
    in pprint val <+> colon <+> pprint grades <+> pprint ty


-- | Typed binders are optionally graded, and can contain many bound names.
newtype TypedBinding = TB { unTB :: Arg (MightBe Graded (Typed OneOrMoreBoundNames)) }
  deriving (Show, Eq, Ord, Hiding)


instance Binds TypedBinding CName where
  bindsWhat = bindsWhat . unTB


instance HasType TypedBinding Expr where
  typeOf = typeOf . un . un . unTB


mkTypedBinding :: IsHiddenOrNot -> OneOrMoreBoundNames -> Maybe Grading -> Expr -> TypedBinding
mkTypedBinding isHid names grading t =
  let typedNames = names `typedWith` t
  in TB . mkArg isHid $ maybe
       (itIsNot typedNames)                             -- we just have a type
       (\g -> itIs (`gradedWith` g) typedNames) grading -- we have a type and grade


-- | A list of typed bindings in a dependent function space.
newtype PiBindings = PiBindings [TypedBinding]
  deriving (Show, Eq, Ord)


data Declaration
  -- | A single clause for a function.
  = FunEqn FLHS FRHS
  -- | A type signature.
  | TypeSig CName Expr
  -- | A record definition.
  | RecordDef CName (Maybe CName) [LambdaBinding] Expr [Declaration]
  -- | A record field.
  | Field CName Expr
  deriving (Show)

newtype Abstraction = Abst { getAbst :: (CName, Expr, Expr) }
  deriving (Show, Eq, Ord)

-- | Variable bound in the abstraction.
absVar :: Abstraction -> CName
absVar (Abst (v, _, _)) = v

-- | Type of the bound variable in the abstraction.
absTy :: Abstraction -> Expr
absTy (Abst (_, t, _)) = t

-- | Target expression of the abstraction.
absExpr :: Abstraction -> Expr
absExpr (Abst (_, _, t)) = t

mkAbs :: CName -> Expr -> Expr -> Abstraction
mkAbs v e1 e2 = Abst (v, e1, e2)

data Expr
  -- | Variable.
  = Ident QName

  -- | Level literals.
  | LitLevel Integer

  -- | Dependent function space.
  | Pi PiBindings Expr

  -- | Non-dependent function space.
  | Fun Expr Expr

  -- | Lambda abstraction.
  | Lam LambdaArgs Expr

  -- | Dependent tensor type.
  | ProductTy Abstraction

  -- | Pairs.
  | Pair Expr Expr

  -- | Coproduct type.
  | Coproduct Expr Expr

  -- | Coproduct eliminator.
  | CoproductCase (CName, Expr) (CName, Expr) (CName, Expr) Expr

  -- | Natural number eliminator.
  | NatCase (CName, Expr) Expr (CName, CName, Expr) Expr

  -- | Identity eliminator.
  | RewriteExpr (CName, CName, CName, Expr) (CName, Expr) Expr Expr Expr

  -- | Empty eliminator.
  | EmptyElim (CName, Expr) Expr

  | App Expr Expr -- e1 e2

  | Sig Expr Expr -- e : A

  -- | Holes for inference.
  | Hole

  -- | Implicits for synthesis.
  | Implicit


  | Let LetBinding Expr
  -- ^ Let binding (@let x in y@).

  -- | Argument wrapped in braces.
  | BraceArg (MaybeNamed Expr)

  -- | An expression in parentheses.
  | Parens Expr
  deriving (Show, Eq, Ord)


-- | Make a new, unnamed, implicit term.
mkImplicit :: Expr
mkImplicit = Implicit


-- | As we have dependent types, we should be able to treat grades
-- | as arbitrary expressions.
type Grade = Expr


------------------
-- Let bindings --
------------------


data LetBinding
  = LetPatBound Pattern Expr
  deriving (Show, Eq, Ord)


data Pattern
  = PIdent QName
  -- ^ x. (or could be a constructor).
  | PAt  CName Pattern
  -- ^ x@p.
  | PPair Pattern Pattern
  -- ^ (p1, p2).
  | PUnit
  -- ^ unit (*).
  | PApp QName [Pattern]
  -- ^ Constructor application.
  | PParens Pattern
  -- ^ Pattern in parentheses.
  deriving (Show, Eq, Ord)


---------------------------
----- Pretty printing -----
---------------------------


arrow, at, caset :: Doc
arrow = text "->"
at = char '@'
caset = text "case"


instance (Pretty e) => Pretty (MaybeNamed e) where
  isLexicallyAtomic (Unnamed e) = isLexicallyAtomic e
  isLexicallyAtomic _ = False

  pprint (Named n e) = pprint n <+> equals <+> pprint e
  pprint (Unnamed e) = pprint e


instance Pretty Expr where
    isLexicallyAtomic (Ident _)  = True
    isLexicallyAtomic LitLevel{} = True
    isLexicallyAtomic Pair{}     = True
    isLexicallyAtomic Hole{}     = True
    isLexicallyAtomic Implicit{} = True
    isLexicallyAtomic BraceArg{} = True
    isLexicallyAtomic Parens{}   = True
    isLexicallyAtomic _          = False

    pprint (LitLevel n)           = integer n
    pprint (Lam binders finE) =
      text "\\" <+> (hsep $ fmap pprint binders) <+> arrow <+> pprint finE
    pprint (Pi binders finTy) = pprint binders <+> arrow <+> pprint finTy
    pprint (Fun i@Fun{} o) = pprintParened i <+> arrow <+> pprint o
    pprint (Fun i o) = pprint i <+> arrow <+> pprint o
    pprint (ProductTy ab) =
      let leftTyDoc =
            case absVar ab of
              NoName{} -> pprint (absTy ab)
              _        -> pprint (absVar ab) <+> colon <> colon <+> pprint (absTy ab)
      in leftTyDoc <+> char '*' <+> pprint (absExpr ab)
    pprint (App lam@Lam{} e2) =
      pprintParened lam <+> pprintParened e2
    pprint (App (Sig e1 t) e2) =
      pprintParened (Sig e1 t) <+> pprintParened e2
    pprint (App e1 e2) = pprint e1 <+> pprintParened e2
    pprint (Pair e1 e2) = parens (pprint e1 <> comma <+> pprint e2)
    pprint (Coproduct e1 e2) = pprint e1 <+> char '+' <+> pprint e2
    pprint (CoproductCase (NoName{}, Implicit) (x, c) (y, d) e) =
      caset <+> pprint e <+> text "of"
              <+> text "Inl" <+> pprint x <+> arrow <+> pprint c <> semi
              <+> text "Inr" <+> pprint y <+> arrow <+> pprint d
    pprint (CoproductCase (z, tC) (x, c) (y, d) e) =
      caset <+> pprint z <> at <> pprintParened e <+> text "of" <> parens
              (text "Inl" <+> pprint x <+> arrow <+> pprint c <> semi
              <+> text "Inr" <+> pprint y <+> arrow <+> pprint d) <+> colon <+> pprint tC
    pprint (NatCase (x, tC) cz (w, y, cs) n) =
      caset <+> pprint x <> at <> pprintParened n <+> text "of" <+> parens
              (text "Zero" <+> arrow <+> pprint cz <> semi
              <+> text "Succ" <+> pprint w <> at <> pprint y <+> arrow <+> pprint cs)
              <+> colon <+> pprint tC
    pprint (RewriteExpr (x, y, p, tC) (z, c) a b p') =
      text "rewrite" <> parens
        (hcat $ punctuate (space <> char '|' <> space)
         [ char '\\' <> hsep [pprint x, pprint y, pprint p, arrow, pprint tC]
         , char '\\' <> pprint z <+> arrow <+> pprint c
         , pprint a
         , pprint b
         , pprint p'])
    pprint (Ident var) = pprint var
    pprint (Sig e t) = pprintParened e <+> colon <+> pprint t
    pprint Hole = char '?'
    pprint Implicit{} = char '_'
    pprint (EmptyElim (x, tC) a) =
      text "let" <+> pprint x <> at <> text "()" <+> equals <+> pprint a <+> colon <+> pprint tC
    pprint (Let lb e) = text "let" <+> pprint lb <+> text "in" <+> pprint e
    pprint (BraceArg e) = braces $ pprint e
    pprint (Parens e)   = parens $ pprint e

instance Pretty LetBinding where
  pprint (LetPatBound p e) = pprint p <+> equals <+> pprint e

instance Pretty Pattern where
  isLexicallyAtomic PIdent{} = True
  isLexicallyAtomic PPair{}  = True
  isLexicallyAtomic PAt{}    = True
  isLexicallyAtomic PUnit    = True
  isLexicallyAtomic _        = False

  pprint (PIdent v) = pprint v
  pprint (PPair l r) = parens $ pprint l <> comma <+> pprint r
  pprint (PAt v p) = pprint v <> at <> pprint p
  pprint (PApp v args) = pprint v <+> (hsep $ fmap pprintParened args)
  pprint PUnit = char '*'
  pprint (PParens p) = parens $ pprint p


instance Pretty Grading where
  pprint g = char '[' <>
             pprint (subjectGrade g) <> comma <+> pprint (subjectTypeGrade g) <> char ']'

instance Pretty TypedBinding where
  isLexicallyAtomic _ = True

  pprint tb =
    let names = bindsWhat tb
        ty    = typeOf tb
        grads = tryIt grading (un $ unTB tb)
    in (if isHidden' tb then braces else parens) $
       pprint names <+> colon <+> maybe empty pprint grads <+> pprint ty

instance Pretty PiBindings where
  pprint (PiBindings binds) = hsep (fmap pprint binds)

instance Pretty AST where
  pprint (AST decls) = vcat $ fmap pprint decls

instance Pretty FLHS where
  pprint (FLHSName n) = pprint n

instance Pretty FRHS where
  pprint (FRHSAssign e) = equals <+> pprint e

instance (Pretty a) => Pretty (Param a) where
  isLexicallyAtomic (ParamNamed nb) = isLexicallyAtomic nb
  isLexicallyAtomic (ParamUnnamed a) = isLexicallyAtomic a

  pprint (ParamNamed nb) = pprint nb
  pprint (ParamUnnamed a) = pprint a

instance Pretty Declaration where
  pprint (TypeSig n t) = pprint n <+> colon <+> pprint t
  pprint (FunEqn lhs rhs) = pprint lhs <+> pprint rhs
  pprint (RecordDef n con params ty decls) =
    text "record" <+> pprint n <+> hsep (fmap pprint params) <+> colon <+> pprint ty <+> text "where"
         $+$ vcat (fmap (nest 2) $ (maybe empty (\conName -> (text "constructor" <+> pprint conName)) con) : fmap pprint decls)
  pprint (Field n e) = text "field" <+> pprint n <+> colon <+> pprint e
