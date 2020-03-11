{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}

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
  -- ** Naming
  , MaybeNamed(..)
  -- ** Bindings
  , Binds(..)
  , mkArg
  , BoundName(..)
  , Param(..)
  , LambdaBinding
  , LambdaArg
  , LambdaArgs
  , TypedBinding
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
import Language.Dlam.Syntax.Common hiding (Typed)
import qualified Language.Dlam.Syntax.Common as C
import Language.Dlam.Util.Pretty


------------------
-- Declarations --
------------------


newtype AST = AST [Declaration]
  deriving Show


-- | A function clause's left-hand side.
data FLHS =
  -- Currently we only support simple identifiers.
  FLHSName Name
  deriving (Show)

-- | Right-hand side of a function clause.
data FRHS =
  -- Currently we only support simple expressions.
  FRHSAssign Expr
  deriving (Show)


-- | A name in a binder.
data BoundName = BoundName { unBoundName :: Name }
  deriving (Show, Eq, Ord)


-- | A Param either captures some typed names, or an @a@.
data Param a = ParamNamed TypedBinding | ParamUnnamed a
  deriving (Show, Eq, Ord)


-- | Lambda abstraction binder.
type LambdaArg = Arg (MightBe Typed OneOrMoreBoundNames)


lambdaArgFromTypedBinding :: TypedBinding -> LambdaArg
lambdaArgFromTypedBinding e =
  mkArg (isHidden e) (itIs (`typedWith` (typeOf e)) (un (un (un (unTB e)))))


type LambdaArgs = [LambdaArg]


data BoundTo b e = BoundTo { boundToWhat :: b, whatWasBound :: e }
  deriving (Show, Eq, Ord)


instance (Pretty b, Pretty e) => Pretty (BoundTo b e) where
  pprint b = pprint (boundToWhat b) <+> colon <+> pprint (whatWasBound b)


type OneOrMoreBoundNames = NE.NonEmpty BoundName


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


data MaybeNamed a = Named Name a | Unnamed a
  deriving (Show, Eq, Ord)


instance Un (MaybeNamed a) a where
  un (Named _ e) = e
  un (Unnamed e) = e


-----------------
----- Typed -----
-----------------


type Typed = C.Typed Expr


-- | Things that are graded need to explain their behaviour in both
-- | the subject and subject type.
data Grading =
  Grading { gradingSubjectGrade :: Grade, gradingTypeGrade :: Grade }
  deriving (Show, Eq, Ord)


mkGrading :: Grade -> Grade -> Grading
mkGrading sg tg = Grading { gradingSubjectGrade = sg, gradingTypeGrade = tg }


class IsGraded a where
  grading :: a -> Grading


subjectGrade :: (IsGraded a) => a -> Grade
subjectGrade = gradingSubjectGrade . grading


subjectTypeGrade :: (IsGraded a) => a -> Grade
subjectTypeGrade = gradingTypeGrade . grading


instance IsGraded Grading where
  grading = id


data Graded a = Graded { gradedGrades :: Grading, unGraded :: a }
  deriving (Show, Eq, Ord)


gradedWith :: a -> Grading -> Graded a
gradedWith u g = Graded { gradedGrades = g, unGraded = u }


instance Un (Graded a) a where
  un = unGraded


instance IsGraded (Graded a) where
  grading = gradedGrades


instance (Binds a) => Binds (Graded a) where
  bindsWhat = bindsWhat . un


instance (IsTyped a t) => IsTyped (Graded a) t where
  typeOf = typeOf . un


-- | Typed binders are optionally graded, and can contain many bound names.
newtype TypedBinding = TB { unTB :: Arg (MightBe Graded (Typed OneOrMoreBoundNames)) }
  deriving (Show, Eq, Ord, Hiding, Binds)


instance IsTyped TypedBinding Expr where
  typeOf = typeOf . un . un . unTB


mkTypedBinding :: IsHiddenOrNot -> OneOrMoreBoundNames -> Maybe Grading -> Expr -> TypedBinding
mkTypedBinding isHid ns grading t =
  TB . mkArg isHid $ (maybe itIsNot (itIs . flip gradedWith) grading) (ns `typedWith` t)


class Binds a where
  bindsWhat :: a -> [BoundName]


instance (Binds a) => Binds (MightHide a) where
  bindsWhat = bindsWhat . un


instance (Binds a) => Binds (Arg a) where
  bindsWhat = bindsWhat . un


instance (Binds a) => Binds (Typed a) where
  bindsWhat = bindsWhat . unTyped


instance Binds BoundName where
  bindsWhat = pure


instance Binds [BoundName] where
  bindsWhat = id


instance Binds (NE.NonEmpty BoundName) where
  bindsWhat = bindsWhat . NE.toList


instance (Binds (t e), Binds e) => Binds (MightBe t e) where
  bindsWhat = idc bindsWhat bindsWhat


-- | A list of typed bindings in a dependent function space.
newtype PiBindings = PiBindings [TypedBinding]
  deriving (Show, Eq, Ord)


data Declaration
  -- | A single clause for a function.
  = FunEqn FLHS FRHS
  -- | A type signature.
  | TypeSig Name Expr
  -- | A record definition.
  | RecordDef Name (Maybe Name) [LambdaBinding] Expr [Declaration]
  -- | A record field.
  | Field Name Expr
  deriving (Show)

newtype Abstraction = Abst { getAbst :: (Name, Expr, Expr) }
  deriving (Show, Eq, Ord)

-- | Variable bound in the abstraction.
absVar :: Abstraction -> Name
absVar (Abst (v, _, _)) = v

-- | Type of the bound variable in the abstraction.
absTy :: Abstraction -> Expr
absTy (Abst (_, t, _)) = t

-- | Target expression of the abstraction.
absExpr :: Abstraction -> Expr
absExpr (Abst (_, _, t)) = t

mkAbs :: Name -> Expr -> Expr -> Abstraction
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
  | CoproductCase (Name, Expr) (Name, Expr) (Name, Expr) Expr

  -- | Natural number eliminator.
  | NatCase (Name, Expr) Expr (Name, Name, Expr) Expr

  -- | Identity eliminator.
  | RewriteExpr (Name, Name, Name, Expr) (Name, Expr) Expr Expr Expr

  -- | Empty eliminator.
  | EmptyElim (Name, Expr) Expr

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
  | PAt  Name Pattern
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


instance Pretty BoundName where
  pprint = pprint . unBoundName


instance Pretty [BoundName] where
  pprint = hsep . fmap pprint


instance Pretty (NE.NonEmpty BoundName) where
  pprint = pprint . NE.toList


instance (Pretty e) => Pretty (MaybeNamed e) where
  pprint (Named n e) = pprint n <+> equals <+> pprint e
  pprint (Unnamed e) = pprint e


instance Pretty Expr where
    isLexicallyAtomic (Ident _) = True
    isLexicallyAtomic LitLevel{} = True
    isLexicallyAtomic Pair{}     = True
    isLexicallyAtomic Hole{}     = True
    isLexicallyAtomic Implicit{} = True
    isLexicallyAtomic _       = False

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
  pprint tb =
    (if isHidden' tb then braces else parens) $
    (let tySide = un (unTB tb) in
     (idc (pprint . grading) (const empty) tySide) <+> pprint (typeOf tySide :: Expr))

instance Pretty PiBindings where
  pprint (PiBindings binds) = hsep (fmap pprint binds)

instance Pretty AST where
  pprint (AST decls) = vcat $ fmap pprint decls

instance Pretty FLHS where
  pprint (FLHSName n) = pprint n

instance Pretty FRHS where
  pprint (FRHSAssign e) = equals <+> pprint e

instance (Pretty a) => Pretty (Param a) where
  pprint (ParamNamed nb) = pprint nb
  pprint (ParamUnnamed a) = pprint a

instance Pretty Declaration where
  pprint (TypeSig n t) = pprint n <+> colon <+> pprint t
  pprint (FunEqn lhs rhs) = pprint lhs <+> pprint rhs
  pprint (RecordDef n con params ty decls) =
    text "record" <+> pprint n <+> hsep (fmap pprint params) <+> colon <+> pprint ty <+> text "where"
         $+$ vcat (fmap (nest 2) $ (maybe empty (\conName -> (text "constructor" <+> pprint conName)) con) : fmap pprint decls)
  pprint (Field n e) = text "field" <+> pprint n <+> colon <+> pprint e
