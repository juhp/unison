{-# LANGUAGE RankNTypes #-}
{-# Language OverloadedStrings #-}
{-# Language ScopedTypeVariables #-}
{-# Language BangPatterns #-}

module Unison.TermParser where

import           Control.Applicative
import           Control.Monad
import           Data.Char (isDigit)
import           Data.Foldable (asum,toList)
import           Data.Functor
import qualified Data.Text as Text
import           Prelude hiding (takeWhile)
import qualified Text.Parsec.Layout as L
import qualified Unison.ABT as ABT
import           Unison.Literal (Literal)
import qualified Unison.Literal as Literal
import           Unison.Parser
import           Unison.Term (Term)
import qualified Unison.Term as Term
import           Unison.Type (Type)
import qualified Unison.Type as Type
import qualified Unison.TypeParser as TypeParser
import qualified Unison.Typechecker.Components as Components
import           Unison.Var (Var)
import qualified Unison.Var as Var

import Debug.Trace
import Text.Parsec (anyChar)

pTrace s = pt <|> return ()
    where pt = attempt $
               do
                 x <- attempt $ many anyChar
                 trace (s++": " ++x) $ attempt $ char 'z'
                 fail x

traced s p = p
--traced s p = do
--  pTrace s
--  a <- p <|> trace (s ++ " backtracked") (fail s)
--  let !x = trace (s ++ " succeeded") ()
--  pure a

{-
Precedence of language constructs is identical to Haskell, except that all
operators (like +, <*>, or any sequence of non-alphanumeric characters) are
left-associative and equal precedence, and operators must have surrounding
whitespace (a + b, not a+b) to distinguish from identifiers that may contain
operator characters (like empty? or fold-left).

Sections / partial application of infix operators is not implemented.
-}

type S = TypeParser.S

type TermP v = Parser (S v) (Term v)

term :: Var v => TermP v
term = term2

term2 :: Var v => TermP v
term2 = lam term2 <|> term3

term3 :: Var v => TermP v
term3 = do
  t <- ifthen <|> infixApp
  ot <- optional (token (char ':') *> TypeParser.type_)
  pure $ case ot of
    Nothing -> t
    Just y -> Term.ann t y

infixApp :: Var v => TermP v
infixApp = chainl1 term4 (f <$> infixVar)
  where
    f :: Ord v => v -> Term v -> Term v -> Term v
    f op lhs rhs = Term.apps (Term.var op) [lhs,rhs]

term4 :: Var v => TermP v
term4 = traced "apply-chain" $ f <$> some termLeaf
  where
    f (func:args) = Term.apps func args
    f [] = error "'some' shouldn't produce an empty list"

termLeaf :: Var v => TermP v
termLeaf = traced "leaf" $
  asum [hashLit, prefixTerm, text, number, tupleOrParenthesized term, blank, vector term, bracedBlock]

ifthen :: Var v => TermP v
ifthen = do
  _ <- token (string "if")
  cond <- L.withoutLayout "then" term
  _ <- token (string "then")
  iftrue <- L.withoutLayout "else" term
  _ <- token (string "else")
  iffalse <- L.block term
  pure (Term.iff cond iftrue iffalse)

tupleOrParenthesized :: Var v => TermP v -> TermP v
tupleOrParenthesized rec =
  parenthesized $ go <$> sepBy1 (token $ string ",") rec where
    go [t] = t -- was just a parenthesized term
    go terms = foldr pair unit terms -- it's a tuple literal
    pair t1 t2 = Term.builtin "pair" `Term.app` t1 `Term.app` t2
    unit = Term.builtin "()"

text' :: Parser s Text.Text
text' =
  token $ fmap Text.pack ps
  where ps = char '"' *> Unison.Parser.takeWhile "text literal" (/= '"') <* char '"'

text :: Ord v => Parser s (Term v)
text = Term.text <$> text'

number :: Ord v => Parser s (Term v)
number = token $ do
  let digits = takeWhile1 "number" isDigit
  sign <- optional (char '+' <|> char '-')
  ds <- digits
  fraction <- optional ((:) <$> char '.' <*> digits)
  pure $ case fraction of
    Nothing -> case sign of
      Nothing -> Term.uint64 (read ds)
      Just '+' -> Term.int64 (read ds)
      Just '-' -> Term.int64 (read ('-':ds))
    Just fraction ->
      let signl = toList sign
      in Term.float (read (signl ++ ds ++ fraction))

hashLit :: Ord v => Parser s (Term v)
hashLit = token (f =<< (mark *> hash))
  where
    f h = case Term.derived' (Text.pack h) of
      Nothing -> fail "invalid base58 string"
      Just a -> pure a
    mark = char '#'
    hash = base64urlstring

blank :: Ord v => TermP v
blank = token (char '_') $> Term.blank

vector :: Ord v => TermP v -> TermP v
vector p = Term.app (Term.builtin "Vector.force") . Term.vector <$> (lbracket *> elements <* rbracket)
  where
    lbracket = token (char '[')
    elements = sepBy comma (L.withoutLayout "vector element" p)
    comma = token (char ',')
    rbracket = token (char ']')

binding :: Var v => Parser (S v) (v, Term v)
binding = label "binding" $ do
  typ <- optional typedecl <* optional semicolon
  let lhs = attempt ((\arg1 op arg2 -> (op,[arg1,arg2]))
                    <$> prefixVar <*> infixVar <*> prefixVar)
                <|> ((,) <$> prefixVar <*> many prefixVar)
  case typ of
    Nothing -> do
      -- we haven't seen a type annotation, so lookahead to '=' before commit
      (name, args) <- attempt (lhs <* token (char '='))
      body <- block
      pure $ mkBinding name args body
    Just (nameT, typ) -> do
      (name, args) <- lhs
      when (name /= nameT) $
        fail ("The type signature for ‘" ++ show (Var.name nameT) ++ "’ lacks an accompanying binding")
      body <- token (char '=') *> block
      pure $ fmap (\e -> Term.ann e typ) (mkBinding name args body)
  where
  mkBinding f [] body = (f, body)
  mkBinding f args body = (f, Term.lam'' args body)

typedecl :: Var v => Parser (S v) (v, Type v)
typedecl = (,) <$> attempt (prefixVar <* token (char ':')) <*> L.block TypeParser.type_

infixVar :: Var v => Parser s v
infixVar = (Var.named . Text.pack) <$> (backticked <|> symbolyId keywords)
  where
    backticked = attempt (char '`') *> wordyId keywords <* token (char '`')

prefixVar :: Var v => Parser s v
prefixVar = (Var.named . Text.pack) <$> label "symbol" (token prefixOp)
  where
    prefixOp = wordyId keywords
           <|> (char '(' *> symbolyId keywords <* token (char ')')) -- no whitespace w/in parens

prefixTerm :: Var v => TermP v
prefixTerm = Term.var <$> prefixVar

keywords :: [String]
keywords =
  [ "->"
  , ":"
  , "="
  , "alias"
  , "and"
  , "else"
  , "handle"
  , "if"
  , "in"
  , "namespace"
  , "or"
  , "then"
  , "where"
  ]

block'
  :: Var v
  => (forall a. Parser (S v) [a] -> Parser (S v) [a])
  -> Parser (S v) x
  -> TermP v
block' braced semi = go =<< braced (traced "statements" statements)
  where
  statements = do
    s <- statement
    o <- optional semi
    case o of
      Nothing -> pure [s]
      Just _ -> (s:) . join . toList <$> optional statements
  statement = traced "statement" $ (Right <$> binding) <|> (Left <$> blockTerm)
  toBinding (Right (v, e)) = (v,e)
  toBinding (Left e) = (Var.named "_", e)
  go bs = case reverse bs of
    (Right _e : _) -> fail "let block must end with an expression"
    -- TODO: Inform the user that we're going to rewrite the block,
    -- possibly changing the meaning of the program (which is ambiguous anyway),
    -- or fail with a helpful error message if there's a forward reference with
    -- effects.
    (Left e : bs) -> pure $ Term.letRec (toBinding <$> reverse bs) e
    [] -> fail "empty block"

block :: Var v => TermP v
block = traced "block" $ bracedBlock <|> traced "unbraced-block" (block' L.vblock L.vsemi)

bracedBlock :: Var v => TermP v
bracedBlock = traced "braced-block" $
  block' (\body -> token (string "{") *> body <* token (string "}")) semi
  where semi = L.spaced L.semi

-- We disallow type annotations and lambdas,
-- just function application and operators
blockTerm :: Var v => TermP v
blockTerm =
  bracedBlock <|> handle <|> ifthen <|> lam term <|> infixApp
  -- TODO: pattern matching in here once we have a parser for it

handle :: Var v => TermP v
handle = do
  token $ string "handle"
  handler <- term
  token $ string "in"
  b <- block
  pure $ Term.handle handler b

lam :: Var v => TermP v -> TermP v
lam p = attempt (Term.lam'' <$> vars <* arrow) <*> body
  where
    vars = some prefixVar
    arrow = token (string "->")
    body = p

alias :: Var v => Parser (S v) ()
alias = do
  _ <- token (string "alias")
  (fn:params) <- some (Var.named . Text.pack <$> wordyId keywords)
  _ <- token (char '=')
  body <- L.block TypeParser.type_
  TypeParser.Aliases s <- get
  let s' = (fn, apply)
      apply args | length args <= length params = ABT.substs (params `zip` args) body
      apply args = apply (take n args) `Type.apps` drop n args
      n = length params
  set (TypeParser.Aliases (s':s))

-- bindings :: Var v => Parser (S v) [(v, Term v)]
-- bindings = do s0 <- get; L.laidout (many alias *> binding) <* set s0 where

-- moduleBindings :: Var v => Parser (S v) [(v, Term v)]
-- moduleBindings = root bindings
