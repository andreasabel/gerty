{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Language.Dlam.Syntax.Parser.Monad
    ( -- * The parser monad
      Parser
    , ParseResult(..)
    , ParseState(..)
    , ParseError(..), ParseWarning(..)
    , LexState
    , LayoutContext(..)
    , ParseFlags (..)
      -- * Running the parser
    , initState
    , defaultParseFlags
    , parse
    , parsePosString
    , parseFromSrc
      -- * Manipulating the state
    , setParsePos, setLastPos, getParseInterval
    , setPrevToken
    , getParseFlags
    , getLexState, pushLexState, popLexState
      -- ** Layout
    , topContext, popContext, pushContext
    , pushCurrentContext
      -- ** Errors
    , parseError, parseErrorAt, parseError', parseErrorRange
    , lexError
    )
    where

import Prelude hiding ((<>))

import Control.Exception (displayException)
import Control.Monad.Except (MonadError(throwError))
import Data.Int

import Data.Data (Data)

import Control.Monad.State

-- import Language.Dlam.Interaction.Options.Warnings

import Language.Dlam.Syntax.Position

-- import Language.Dlam.Utils.Except ( MonadError(throwError) )
-- import Language.Dlam.Utils.FileName
-- import Language.Dlam.Utils.List ( tailWithDefault )
-- import qualified Language.Dlam.Utils.Maybe.Strict as Strict

import Language.Dlam.Util.Pretty


type AbsolutePath = FilePath

-- import Language.Dlam.Utils.Impossible

{--------------------------------------------------------------------------
    The parse monad
 --------------------------------------------------------------------------}

-- | The parse monad.
newtype Parser a = P { _runP :: StateT ParseState (Either ParseError) a }
  deriving (Functor, Applicative, Monad, MonadState ParseState, MonadError ParseError)

-- | The parser state. Contains everything the parser and the lexer could ever
--   need.
data ParseState = PState
    { parseSrcFile  :: !SrcFile
    , parsePos      :: !PositionWithoutFile  -- ^ position at current input location
    , parseLastPos  :: !PositionWithoutFile  -- ^ position of last token
    , parseInp      :: String                -- ^ the current input
    , parsePrevChar :: !Char                 -- ^ the character before the input
    , parsePrevToken:: String                -- ^ the previous token
    , parseLayout   :: [LayoutContext]       -- ^ the stack of layout contexts
    , parseLexState :: [LexState]            -- ^ the state of the lexer
                                             --   (states can be nested so we need a stack)
    , parseFlags    :: ParseFlags            -- ^ parametrization of the parser
    }
    deriving Show

{-| For context sensitive lexing alex provides what is called /start codes/
    in the Alex documentation.  It is really an integer representing the state
    of the lexer, so we call it @LexState@ instead.
-}
type LexState = Int

-- | We need to keep track of the context to do layout. The context
--   specifies the indentation (if any) of a layout block. See
--   "Language.Dlam.Syntax.Parser.Layout" for more informaton.
data LayoutContext  = NoLayout        -- ^ no layout
                    | Layout Int32    -- ^ layout at specified column
    deriving Show

-- | Parser flags.
data ParseFlags = ParseFlags
  { parseKeepComments :: Bool
    -- ^ Should comment tokens be returned by the lexer?
  }
  deriving Show

-- | Parse errors: what you get if parsing fails.
data ParseError

  -- | Errors that arise at a specific position in the file
  = ParseError
    { errSrcFile   :: !SrcFile
                      -- ^ The file in which the error occurred.
    , errPos       :: !PositionWithoutFile
                      -- ^ Where the error occurred.
    , errInput     :: String
                      -- ^ The remaining input.
    , errPrevToken :: String
                      -- ^ The previous token.
    , errMsg       :: String
                      -- ^ Hopefully an explanation of what happened.
    }

  -- | Parse errors that concern a range in a file.
  | OverlappingTokensError
    { errRange     :: !(Range' SrcFile)
                      -- ^ The range of the bigger overlapping token
    }

  -- | Parse errors that concern a whole file.
  | InvalidExtensionError
    { errPath      :: !AbsolutePath
                      -- ^ The file which the error concerns.
    , errValidExts :: [String]
    }
  | ReadFileError
    { errPath      :: !AbsolutePath
    , errIOError   :: IOError
    }

-- | Warnings for parsing.
data ParseWarning
  -- | Parse errors that concern a range in a file.
  = OverlappingTokensWarning
    { warnRange    :: !(Range' SrcFile)
                      -- ^ The range of the bigger overlapping token
    }
  deriving Data

-- | The result of parsing something.
data ParseResult a
  = ParseOk ParseState a
  | ParseFailed ParseError
  deriving Show

-- | Old interface to parser.
unP :: Parser a -> ParseState -> ParseResult a
unP (P m) s = case runStateT m s of
  Left err     -> ParseFailed err
  Right (a, s) -> ParseOk s a

-- | Throw a parse error at the current position.
parseError :: String -> Parser a
parseError msg = do
  s <- get
  throwError $ ParseError
    { errSrcFile   = parseSrcFile s
    , errPos       = parseLastPos s
    , errInput     = parseInp s
    , errPrevToken = parsePrevToken s
    , errMsg       = msg
    }

{--------------------------------------------------------------------------
    Instances
 --------------------------------------------------------------------------}

instance Show ParseError where
  show = pprintShow

instance Pretty ParseError where
  pprint ParseError{errPos,errSrcFile,errMsg,errPrevToken,errInput} = vcat
      [ (pprint (errPos { srcFile = errSrcFile }) <> colon) <+>
        text errMsg
      , text $ errPrevToken ++ "<ERROR>"
      , text $ take 30 errInput ++ "..."
      ]
  pprint OverlappingTokensError{errRange} = vcat
      [ (pprint errRange <> colon) <+>
        text "Multi-line comment spans one or more literate text blocks."
      ]
  pprint InvalidExtensionError{errPath,errValidExts} = vcat
      [ (pprint errPath <> colon) <+>
        text "Unsupported extension."
      , text "Supported extensions are:" <+> pprintList_ errValidExts
      ]
  pprint ReadFileError{errPath,errIOError} = vcat
      [ text "Cannot read file" <+> pprint errPath
      , text "Error:" <+> text (displayException errIOError)
      ]

-- | Comma separated list, without the brackets.
pprintList_ :: Pretty a => [a] -> Doc
pprintList_ = fsep . punctuate comma . map pprint

instance HasRange ParseError where
  getRange err = case err of
      ParseError{ errSrcFile, errPos = p } -> posToRange' errSrcFile p p
      OverlappingTokensError{ errRange }   -> errRange
      InvalidExtensionError{}              -> errPathRange
      ReadFileError{}                      -> errPathRange
    where
    errPathRange = posToRange p p
      where p = startPos $ Just $ errPath err

instance Show ParseWarning where
  show = pprintShow

instance Pretty ParseWarning where
  pprint OverlappingTokensWarning{warnRange} = vcat
      [ (pprint warnRange <> colon) <+>
        text "Multi-line comment spans one or more literate text blocks."
      ]
instance HasRange ParseWarning where
  getRange OverlappingTokensWarning{warnRange} = warnRange

{--------------------------------------------------------------------------
    Running the parser
 --------------------------------------------------------------------------}

initStatePos :: Position -> ParseFlags -> String -> [LexState] -> ParseState
initStatePos pos flags inp st =
        PState  { parseSrcFile      = srcFile pos
                , parsePos          = pos'
                , parseLastPos      = pos'
                , parseInp          = inp
                , parsePrevChar     = '\n'
                , parsePrevToken    = ""
                , parseLexState     = st
                , parseLayout       = [NoLayout]
                , parseFlags        = flags
                }
  where
  pos' = pos { srcFile = () }

-- | Constructs the initial state of the parser. The string argument
--   is the input string, the file path is only there because it's part
--   of a position.
initState :: Maybe AbsolutePath -> ParseFlags -> String -> [LexState]
          -> ParseState
initState file = initStatePos (startPos file)

-- | The default flags.
defaultParseFlags :: ParseFlags
defaultParseFlags = ParseFlags { parseKeepComments = False }

-- | The most general way of parsing a string. The "Language.Dlam.Syntax.Parser" will define
--   more specialised functions that supply the 'ParseFlags' and the
--   'LexState'.
parse :: ParseFlags -> [LexState] -> Parser a -> String -> ParseResult a
parse flags st p input = parseFromSrc flags st p Nothing input

-- | The even more general way of parsing a string.
parsePosString :: Position -> ParseFlags -> [LexState] -> Parser a -> String ->
                  ParseResult a
parsePosString pos flags st p input = unP p (initStatePos pos flags input st)

-- | Parses a string as if it were the contents of the given file
--   Useful for integrating preprocessors.
parseFromSrc :: ParseFlags -> [LexState] -> Parser a -> SrcFile -> String
              -> ParseResult a
parseFromSrc flags st p src input = unP p (initState src flags input st)


{--------------------------------------------------------------------------
    Manipulating the state
 --------------------------------------------------------------------------}

setParsePos :: PositionWithoutFile -> Parser ()
setParsePos p = modify $ \s -> s { parsePos = p }

setLastPos :: PositionWithoutFile -> Parser ()
setLastPos p = modify $ \s -> s { parseLastPos = p }

setPrevToken :: String -> Parser ()
setPrevToken t = modify $ \s -> s { parsePrevToken = t }

getLastPos :: Parser PositionWithoutFile
getLastPos = gets parseLastPos

-- | The parse interval is between the last position and the current position.
getParseInterval :: Parser Interval
getParseInterval = do
  s <- get
  return $ posToInterval (parseSrcFile s) (parseLastPos s) (parsePos s)

getLexState :: Parser [LexState]
getLexState = parseLexState <$> get

-- UNUSED Liang-Ting Chen 2019-07-16
--setLexState :: [LexState] -> Parser ()
--setLexState ls = modify $ \ s -> s { parseLexState = ls }

modifyLexState :: ([LexState] -> [LexState]) -> Parser ()
modifyLexState f = modify $ \ s -> s { parseLexState = f (parseLexState s) }

pushLexState :: LexState -> Parser ()
pushLexState l = modifyLexState (l:)

popLexState :: Parser ()
popLexState = modifyLexState tail

getParseFlags :: Parser ParseFlags
getParseFlags = gets parseFlags


-- | Fake a parse error at the specified position. Used, for instance, when
--   lexing nested comments, which when failing will always fail at the end
--   of the file. A more informative position is the beginning of the failing
--   comment.
parseErrorAt :: PositionWithoutFile -> String -> Parser a
parseErrorAt p msg =
    do  setLastPos p
        parseError msg

-- | Use 'parseErrorAt' or 'parseError' as appropriate.
parseError' :: Maybe PositionWithoutFile -> String -> Parser a
parseError' = maybe parseError parseErrorAt

-- | Report a parse error at the beginning of the given 'Range'.
parseErrorRange :: HasRange r => r -> String -> Parser a
parseErrorRange = parseError' . rStart' . getRange


-- | For lexical errors we want to report the current position as the site of
--   the error, whereas for parse errors the previous position is the one
--   we're interested in (since this will be the position of the token we just
--   lexed). This function does 'parseErrorAt' the current position.
lexError :: String -> Parser a
lexError msg =
    do  p <- gets parsePos
        parseErrorAt p msg

{--------------------------------------------------------------------------
    Layout
 --------------------------------------------------------------------------}

getContext :: Parser [LayoutContext]
getContext = gets parseLayout

setContext :: [LayoutContext] -> Parser ()
setContext ctx = modify $ \ s -> s { parseLayout = ctx }

-- | Return the current layout context.
topContext :: Parser LayoutContext
topContext =
    do  ctx <- getContext
        case ctx of
            []  -> parseError "No layout context in scope"
            l:_ -> return l

popContext :: Parser ()
popContext =
    do  ctx <- getContext
        case ctx of
            []      -> parseError "There is no layout block to close at this point."
            _:ctx   -> setContext ctx

pushContext :: LayoutContext -> Parser ()
pushContext l =
    do  ctx <- getContext
        setContext (l : ctx)

-- | Should only be used at the beginning of a file. When we start parsing
--   we should be in layout mode. Instead of forcing zero indentation we use
--   the indentation of the first token.
pushCurrentContext :: Parser ()
pushCurrentContext =
    do  p <- getLastPos
        pushContext (Layout (posCol p))
