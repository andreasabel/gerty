module Language.Dlam.Syntax.Concrete.Name
  ( Name(..)
  , QName(..)
  , mkIdent
  , ignoreVar
  ) where


import Prelude hiding ((<>))

import Language.Dlam.Syntax.Common (NameId(..))
import Language.Dlam.Util.Pretty


data Name
  = Name String
  -- ^ Concrete name.
  | NoName NameId
  -- ^ Unused/generated name.
  deriving (Show, Eq, Ord)


-- | A name can be qualified or unqualified.
data QName = Qualified Name QName | Unqualified Name
  deriving (Show, Eq, Ord)


-- | Create a new identifier from a (syntactic) string.
mkIdent :: String -> Name
mkIdent = Name


-- | Name for use when the value is unused.
ignoreVar :: Name
ignoreVar = NoName (NameId 0)


instance Pretty Name where
  pprint (Name v) = text v
  pprint NoName{} = char '_'


instance Pretty QName where
  pprint (Qualified n qs) = pprint n <> char '.' <> pprint qs
  pprint (Unqualified n)  = pprint n
