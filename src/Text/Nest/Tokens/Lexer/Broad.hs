{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Text.Nest.Tokens.Lexer.Broad
    ( parse
    , stringEscapes
    , isSymbolChar
    ) where

import Prelude hiding (lines)
import Text.Nest.Tokens.Types

import Data.Functor ((<&>))
import Data.Text (Text)
import Data.Void (Void)
import Text.Lightyear (Lightyear, Consume(..), Branch(..))
import Text.Nest.Tokens.Types.Broad (Payload(..))
import Text.Nest.Tokens.Lexer.Error (LexError(..), expect, panic)

import qualified Data.Char as C
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import qualified Text.Lightyear as P
import qualified Text.Nest.Tokens.Types.Broad as Broad


parse :: Text -> [Broad.Result]
parse inp = case P.runLightyear wholeFile inp undefined of
    Right toks -> toks
    Left err -> error $ "Internal Nest Error! Please report.\nLexer failed to recover: " ++ show err


type Parser c a = Lightyear c Void Text LexError a


wholeFile :: Parser 'Backtracking [Broad.Result]
wholeFile = do
    toks <- many $ (fmap Right <$> anyToken) <|> errToken
    P.endOfInput (panic "next lexer failed to reach end of input")
    pure toks

-- FIXME I'd like to return a `Broad.Result`, but that means reporting erros inside some parsers (e.g. heredoc)
anyToken :: Parser 'Backtracking (LexResult Payload)
anyToken = P.choice $ NE.fromList
    [ P.try whitespace
    , P.try word
    , P.try colonWord -- WARNING this must come before `separator` to extract words that start with a colon
    , P.try comment
    , P.try heredoc -- WARNING this must come before `string`, b/c they both start with `"`
    , P.try string
    , P.try bracket
    , P.try separator
    ]

errToken :: Parser 'Backtracking Broad.Result
errToken = fmap Left <$> do
    loc <- P.getPosition
    c <- P.any (panic "errToken")
    pure LR
        { loc
        , orig = T.singleton c
        , payload = BadChar loc c
        }

------------ Whitespace ------------

whitespace :: Parser 'Consuming (LexResult Payload)
whitespace = do
    pos0 <- P.getPosition
    (tok, orig) <- inline <|> newline
    pure $ LR
        { loc = pos0
        , orig
        , payload = tok
        }
    where
    inline = (Whitespace,) . T.concat <$> P.some (simpleInline <|> splitline)
    simpleInline = P.takeWhile1 (panic "simple whitespace") (`elem` [' ', '\t'])
    splitline = P.string (panic "split whitespace") "\\\n"
    newline = (Newline,) <$> P.string (panic "newline") "\n"

-- TODO backslash-linebreak


-- NOTE: I'm thinking that inline comments are not so useful
-- Text editors don't deal well with nesting block comments, which is what I'd like if I wanted block comments
-- Also, a comment inside a li

comment :: Parser 'Consuming (LexResult Payload)
comment = do
    pos0 <- P.getPosition
    hash <- P.char (panic "comment") '#'
    text <- P.takeWhile (/= '\n')
    let orig = hash `T.cons` text
    pure $ LR
        { loc = pos0
        , orig
        , payload = Comment
        }


------------ Syntax ------------

word :: Parser 'Consuming (LexResult Payload)
word = do
    pos0 <- P.getPosition
    orig <- P.takeWhile1 (panic "word") isSymbolChar
    pure LR
        { loc = pos0
        , orig
        , payload = Atom
        }

colonWord :: Parser 'Consuming (LexResult Payload)
colonWord = P.label (const $ expect ["colon + word"]) $ do
    pos0 <- P.getPosition
    colon <- P.char (panic "colon-word") ':'
    rest <- P.takeWhile1 (panic "colon-word") (\c -> isSymbolChar c || c == ':')
    pure LR
        { loc = pos0
        , orig = colon `T.cons` rest
        , payload = Atom
        }

-- for more options, peek around starting at https://www.compart.com/en/unicode/category
isSymbolChar :: Char -> Bool
isSymbolChar c = good && defensive
    where
    defensive = c `notElem` ("\\# \t\n\r()[]{},.;:`\'\"" :: [Char])
    good = C.isLetter c || C.isDigit c || nonModifyingSymbol || c `elem` ("~!@$%^&*-_=+|<>/?" :: [Char])
    nonModifyingSymbol = case C.generalCategory c of
        C.MathSymbol -> True
        C.CurrencySymbol -> True
        _ -> False

separator :: Parser 'Consuming (LexResult Payload)
separator = do
    pos0 <- P.getPosition
    orig <- P.takeWhile1 (panic "separator consumed") (`elem` separatorChars)
    pure $ LR
        { loc = pos0
        , orig
        , payload = Separator
        }

bracket :: Parser 'Consuming (LexResult Payload)
bracket = do
    pos0 <- P.getPosition
    (tok, c) <- P.choice $ NE.fromList $ brackets <&> \(o, c) ->
        let open = (Bracket Open o c,) <$> P.char (panic "open bracket") o
            close = (Bracket Close o c,) <$> P.char (panic "close bracket") c
        in open <|> close
    pure LR
        { loc = pos0
        , orig = T.singleton c
        , payload = tok
        }


separatorChars :: [Char]
separatorChars = ",.;:"

brackets :: [(Char, Char)]
brackets = map (\[o,c] -> (o, c)) db
    where
    db =
        [ "()"
        , "[]"
        , "{}"
        -- TODO a mix of fancier ones, or mixfixes
        -- I'm thinking that mixfixes handle one thing, but enclose and separate handles another.
        -- Thus, `operator none (_ + _) add` defines (i.e. `'operator' ('left'|'right'|'none') '(' '_'? (<name> '_')* <name>? ')' <name>`)
        -- wheras `comprehension ⟬ ⟭` would define a new parenthesis
        -- and `comprehension ⟬ , ⟭` would define one which has elements separated by commas
        -- I'm tempted to have even comprehension ⟬ , ; ⟭` which would have semicolon-separated lists of comma-separated elements
        ]


------------ Strings ------------

heredoc :: Parser 'Consuming (LexResult Payload)
heredoc = do
    pos0 <- P.getPosition
    -- parse the open mark
    quotes <- P.string (panic "start of heredoc") "\"\"\""
    fence <- grabToLine
    nl <- T.singleton <$> P.char (expect ["newline"]) '\n'
    let open = quotes <> fence <> nl
    -- parse the body
    let startLoop = endLoop "" <|> (grabToLine >>= loop)
        loop soFar = endLoop soFar <|> continue soFar
        continue soFar = P.label (const $ expect ["end of heredoc"]) $ do
            c <- P.char (panic "heredoc continue") '\n'
            line <- grabToLine
            loop (soFar <> T.cons c line)
    -- parse the close mark
        endLoop soFar = (soFar,) <$> parseFence
        parseFence = P.string (panic "heredoc fence") ("\n" <> fence <> "\"\"\"") :: Parser 'Consuming Text
    (lines, close) <- startLoop
    pure LR
        { loc = pos0
        , orig = open <> lines <> close
        , payload = String Plain lines Plain
        }
    where
    grabToLine :: Parser c Text
    grabToLine = P.takeWhile (/= '\n')

string :: Parser 'Consuming (LexResult Payload)
string = do
    pos0 <- P.getPosition
    (openChar, open) <- strTemplJoin
    (orig, body) <- biconcat <$> many stringSection
    (closeChar, close) <- strTemplJoin
    pure LR
        { loc = pos0
        , orig = openChar <> orig <> closeChar
        , payload = String open body close
        }

stringSection :: Parser 'Consuming (Text, Text)
stringSection = plain <|> escape
    where
    plain = dup <$> P.takeWhile1 (panic "plain string characters") (`notElem` ['\"', '`', '\\', '\r', '\n'])
    escape = do
        bs <- P.char (panic "string escape") '\\'
        let nextChars = fst <$> stringEscapes
        c <- P.satisfy (expect $ (:[]) <$> nextChars) (`elem` nextChars)
        case lookup c stringEscapes of
            Nothing -> error "internal error: an escape character was recognized without a corresponding escape parser"
            Just p -> do
                (orig, sem) <- p
                pure (bs `T.cons` c `T.cons` orig, sem)

strTemplJoin :: Parser 'Consuming (Text, StrTemplJoin)
strTemplJoin = do
    c <- P.satisfy (expect ["end of string", "start of splice"]) (`elem` ['\"', '`'])
    let semantic = case c of { '\"' -> Plain ; '`' -> Templ; _ -> error "Internal Nest Error" }
    pure (T.singleton c, semantic)


stringEscapes :: [(Char, Parser 'Consuming (Text, Text))]
stringEscapes = (fromBasic <$> basicEscapes) ++ fancyEscapes
    where
    fromBasic :: (Char, Char) -> (Char, Parser 'Consuming (Text, Text))
    fromBasic (c, sem) = (c, pure $ ("", T.singleton sem))
    basicEscapes :: [(Char, Char)]
    basicEscapes =
        [ ('\\', '\\')
        , ('0', '\0')
        , ('a', '\a')
        , ('b', '\b')
        , ('e', '\27')
        , ('f', '\f')
        , ('n', '\n')
        , ('r', '\r')
        , ('t', '\t')
        , ('v', '\v')
        , ('\'', '\'')
        , ('\"', '\"')
        ]
    fancyEscapes =
        -- TODO \x[0-9a-fA-F]{2}
        -- TODO \u[0-9a-fA-F]{4}
        -- TODO \U(10|0[0-9a-fA-F])[0-9a-fA-F]{4}
        -- WARNING: I am only allowing `\n` as a line separator; who wants to merge libraries with differing encodings for linesep?
        [ ('\n', do
            leading <- P.takeWhile (`elem` [' ', '\t'])
            resume <- P.char (expect ["'\\' to resume string after linebreak"]) '\\'
            pure (leading `T.snoc` resume , "\n")
          )
        , ('&', pure ("", ""))
        ]

dup :: a -> (a, a)
dup x = (x, x)

biconcat :: (Monoid a, Monoid b) => [(a, b)] -> (a, b)
biconcat [] = (mempty, mempty)
biconcat ((a, b) : rest) = (a <> restA, b <> restB)
    where (restA, restB) = biconcat rest