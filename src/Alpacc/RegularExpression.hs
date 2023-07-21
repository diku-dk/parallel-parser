module Alpacc.RegularExpression
  ( regExFromText,
    pRegEx,
    dfaFromRegEx,
    nfaFromRegEx,
    isMatch,
    isMatchPar,
    parallelLexingTable,
    mkTokenizerRegEx,
    DFA (..),
    RegEx (..)
  )
where

import Control.Monad.State
import Data.Bifunctor (Bifunctor (..))
import Data.Char (isAlphaNum)
import Data.Foldable (Foldable (..))
import Data.List qualified as List
import Data.Map (Map)
import Data.Map qualified as Map hiding (Map)
import Data.Maybe (maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set hiding (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void
import Debug.Trace (traceShow)
import Text.Megaparsec hiding (State)
import Text.Megaparsec.Char (char, space1, string)
import Text.Megaparsec.Char.Lexer qualified as Lexer
import Data.Tuple.Extra (both)

debug :: Show b => b -> b
debug x = traceShow x x

type Parser = Parsec Void Text

data RegEx t
  = Epsilon
  | Literal Char
  | Star (RegEx t)
  | Alter (RegEx t) (RegEx t)
  | Concat (RegEx t) (RegEx t)
  | Token t (RegEx t)
  deriving (Eq, Show)

space :: Parser ()
space = Lexer.space space1 empty empty

lexeme :: Parser a -> Parser a
lexeme = Lexer.lexeme space

validLiterials :: [Char]
validLiterials = ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9']

pLiteral :: Parser (RegEx t)
pLiteral = Literal <$> lexeme (satisfy (`elem` validLiterials))

many1 :: Parser a -> Parser [a]
many1 p = liftM2 (:) p (many p)

chainl1 :: Parser a -> Parser (a -> a -> a) -> Parser a
chainl1 p op = p >>= rest
  where
    rest x =
      do
        f <- op
        y <- p
        rest (f x y)
        <|> return x

pConcat :: Parser (RegEx t)
pConcat = foldl Concat Epsilon <$> many pTerm

pAlter :: Parser (RegEx t)
pAlter = pConcat `chainl1` (lexeme (string "|") >> return Alter)

pRegEx :: Parser (RegEx t)
pRegEx = pAlter

pRange :: Parser (RegEx t)
pRange =
  between (lexeme "[") (lexeme "]") $
    foldr1 Alter . concatMap toLists
      <$> many1
        ( (,)
            <$> satisfy isAlphaNum
            <* lexeme "-"
            <*> satisfy isAlphaNum
        )
  where
    toLists (a, b) = map Literal [a .. b]

pTerm :: Parser (RegEx t)
pTerm = do
  term <-
    choice
      [ pRange,
        pLiteral,
        between (lexeme "(") (lexeme ")") pRegEx
      ]
  s <- optional (many1 (char '*' <|> char '+'))
  return $ case s of
    -- I did a derivation and found (s*)+ = (s+)* = s* so it should hold if *
    -- occurs in a sequence of applied postfix operation then it will equal s*.
    -- If only + occurs in the postfix sequence then then due to (s+)+ = s+ it
    -- will simply correspond to ss*.
    Just postfixes ->
      if any (`elem` ['*']) postfixes
        then Star term
        else Concat term (Star term)
    Nothing -> term

regExFromText :: FilePath -> Text -> Either String (RegEx t)
regExFromText fname s =
  either (Left . errorBundlePretty) Right $ parse (pRegEx <* eof) fname s

data NFA t s = NFA
  { states' :: Set s,
    transitions' :: Map (s, Maybe Char) (Set s),
    initial' :: s,
    alphabet' :: Set Char,
    accepting' :: Set s,
    tokenMap' :: Map t (Set s, Set s)
  }
  deriving (Show)

initNFA :: (Ord s, Enum s) => s -> NFA t s
initNFA start_state =
  NFA
    { states' = Set.fromList [start_state, succ start_state],
      alphabet' = Set.empty,
      transitions' = Map.empty,
      initial' = start_state,
      accepting' = Set.singleton $ succ start_state,
      tokenMap' = Map.empty
    }

newState :: (Ord s, Enum s) => State (NFA t s) s
newState = do
  nfa <- get
  let max_state = Set.findMax $ states' nfa
  let new_max_state = succ max_state
  let new_states' = Set.insert new_max_state $ states' nfa
  put
    ( nfa
        { states' = new_states'
        }
    )
  return new_max_state

newTransition :: (Ord s) => s -> Maybe Char -> s -> State (NFA t s) ()
newTransition s c s' = do
  nfa <- get
  let trans = transitions' nfa
  let key = (s, c)
  let new_trans =
        if key `Map.member` trans
          then Map.adjust (Set.insert s') key trans
          else Map.insert key (Set.singleton s') trans
  let new_alph = Set.fromList (maybeToList c) `Set.union` alphabet' nfa
  put $ nfa {transitions' = new_trans, alphabet' = new_alph}

markToken :: Ord t => t -> s -> s -> State (NFA t s) ()
markToken t s s' = do
  nfa <- get
  let val = (Set.singleton s, Set.singleton s')
  let new_token_map = Map.insert t val $ tokenMap' nfa
  put (nfa {tokenMap' = new_token_map})

epsilon :: Maybe a
epsilon = Nothing

mkNFA' :: (Ord t, Ord s, Enum s) => s -> s -> RegEx t -> State (NFA t s) ()
mkNFA' s s' Epsilon = newTransition s epsilon s'
mkNFA' s s' (Literal c) = newTransition s (Just c) s'
mkNFA' s s'' (Concat a b) = do
  s' <- newState
  mkNFA' s s' a
  mkNFA' s' s'' b
mkNFA' s s' (Alter a b) = do
  mkNFA' s s' a
  mkNFA' s s' b
  -- s' <- newState
  -- s'' <- newState
  -- s''' <- newState
  -- newTransition s epsilon s'
  -- newTransition s epsilon s''
  -- mkNFA' s' s''' a
  -- mkNFA' s'' s''' b
  -- newTransition s''' epsilon s''''
mkNFA' s s'' (Star a) = do
  s' <- newState
  newTransition s epsilon s'
  newTransition s epsilon s''
  mkNFA' s' s a
mkNFA' s s' (Token t a) = do
  markToken t s s'
  mkNFA' s s' a

mkTokenizerRegEx :: Map t (RegEx t) -> RegEx t
mkTokenizerRegEx regex_map =
  if null regex_map
    then Epsilon
    else Star $ foldr1 Alter $ uncurry Token <$> Map.toList regex_map

mkNFA :: (Ord t, Show s, Ord s, Enum s) => RegEx t -> State (NFA t s) ()
mkNFA regex = do
  nfa <- get
  let (s, s') = (initial' nfa, accepting' nfa)
  let accept_list = toList s'
  mapM_ (\_s -> mkNFA' s _s regex) accept_list

stateTransitions :: (Show s, Ord s) => Maybe Char -> s -> State (NFA t s) (Set s)
stateTransitions c s = do
  nfa <- get
  let trans = transitions' nfa
  let eps_map = Map.filterWithKey (\k _ -> isSymbolTransition k) trans
  return . Set.unions $ toList eps_map
  where
    isSymbolTransition (s', c') = s == s' && c == c'

epsilonTransitions :: (Show s, Ord s) => s -> State (NFA t s) (Set s)
epsilonTransitions = stateTransitions Nothing

statesTransitions :: (Show s, Ord s) => Set s -> Maybe Char -> State (NFA t s) (Set s)
statesTransitions set c = Set.unions <$> mapM (stateTransitions c) (toList set)

epsilonClosure :: (Show s, Ord s) => Set s -> State (NFA t s) (Set s)
epsilonClosure set = do
  new_set <- Set.unions <$> mapM epsilonTransitions (toList set)
  let set' = new_set `Set.union` set
  if set == set'
    then return set'
    else epsilonClosure set'

nfaFromRegEx :: (Ord t, Show s, Ord s, Enum s) => s -> RegEx t -> NFA t s
nfaFromRegEx start_state regex = execState (mkNFA regex) init_nfa
  where
    init_nfa = initNFA start_state

mkDFATransitionEntry ::
  (Show s, Ord s, Enum s) =>
  Set s ->
  Char ->
  State (NFA t s) (Map (Set s, Char) (Set s))
mkDFATransitionEntry set c = do
  _states <- statesTransitions set $ Just c
  eps_states <- epsilonClosure _states
  return $ Map.singleton (set, c) eps_states

mkDFATransitionEntries ::
  (Show s, Ord s, Enum s) =>
  Set s ->
  State (NFA t s) (Map (Set s, Char) (Set s))
mkDFATransitionEntries set = do
  alph <- gets (toList . alphabet')
  new_table_entry <- mapM (mkDFATransitionEntry set) alph
  return $ Map.unionsWith Set.union new_table_entry

mkDFATransitions ::
  (Show s, Ord s, Enum s) =>
  Set (Set s) ->
  Map (Set s, Char) (Set s) ->
  [Set s] ->
  State (NFA t s) (Map (Set s, Char) (Set s))
mkDFATransitions _ table [] = return table
mkDFATransitions visited table (top : queue) = do
  entries <- mkDFATransitionEntries top
  let rest = toList $ Map.elems entries
  let new_queue = queue ++ rest
  let new_table = Map.unionWith Set.union entries table
  let new_visited = Set.insert top visited
  if top `Set.member` visited
    then mkDFATransitions visited table queue
    else mkDFATransitions new_visited new_table new_queue

data DFA t s = DFA
  { states :: Set s,
    alphabet :: Set Char,
    transitions :: Map (s, Char) s,
    initial :: s,
    accepting :: Set s,
    tokenMap :: Map t (Set s, Set s)
  }
  deriving (Eq, Show)

nfaMap :: (Ord s', Ord s) => (s' -> s) -> NFA t s' -> NFA t s
nfaMap f nfa =
  nfa
    { states' = Set.map f (states' nfa),
      transitions' = Set.map f <$> Map.mapKeys (first f) (transitions' nfa),
      initial' = f $ initial' nfa,
      accepting' = Set.map f $ accepting' nfa,
      tokenMap' = both (Set.map f) <$> tokenMap' nfa
    }

dfaMap :: (Ord s', Ord s) => (s' -> s) -> DFA t s' -> DFA t s
dfaMap f dfa =
  dfa
    { states = Set.map f (states dfa),
      transitions = f <$> Map.mapKeys (first f) (transitions dfa),
      initial = f $ initial dfa,
      accepting = f `Set.map` accepting dfa,
      tokenMap = both (Set.map f) <$> tokenMap dfa
    }

mkDFAFromNFA :: (Show s, Enum s, Ord s) => State (NFA t s) (DFA t (Set s))
mkDFAFromNFA = do
  nfa <- get
  let accept = accepting' nfa
  let token_map = tokenMap' nfa
  new_initial <- epsilonClosure . Set.singleton $ initial' nfa
  new_transitions <- mkDFATransitions Set.empty Map.empty [new_initial]
  let (new_states, new_alphabet) = bimap Set.fromList Set.fromList . unzip $ Map.keys new_transitions
  let newStates set = Set.filter (any (`Set.member` set)) new_states
  let new_accepting = newStates accept
  return $
    if null new_transitions
      then
        DFA
          { states = Set.singleton Set.empty,
            alphabet = Set.empty,
            transitions = new_transitions,
            initial = Set.empty,
            accepting = Set.singleton Set.empty,
            tokenMap = Map.empty
          }
      else
        DFA
          { states = new_states,
            alphabet = new_alphabet,
            transitions = new_transitions,
            initial = new_initial,
            accepting = new_accepting,
            tokenMap = both newStates <$> token_map
          }

mkDFAFromRegEx :: (Ord t, Show s, Enum s, Ord s) => RegEx t -> State (NFA t s) (DFA t (Set s))
mkDFAFromRegEx regex = do
  mkNFA regex
  mkDFAFromNFA

reenumerateDFA :: (Show s, Show s', Ord s, Enum s, Ord s') => s -> DFA t s' -> DFA t s
reenumerateDFA start_state dfa = dfaMap alphabetMap dfa
  where
    alphabet' = Map.fromList . flip zip [start_state ..] . toList $ states dfa
    alphabetMap = (alphabet' Map.!)

reenumerateNFA :: (Show s, Show s', Ord s, Enum s, Ord s') => s -> NFA t s' -> NFA t s
reenumerateNFA start_state nfa = nfaMap alphabetMap nfa
  where
    _alphabet = Map.fromList . flip zip [start_state ..] . toList $ states' nfa
    alphabetMap = (_alphabet Map.!)

dfaFromRegEx :: (Ord t, Show s, Ord s, Enum s) => s -> RegEx t -> DFA t s
dfaFromRegEx start_state regex = reenumerateDFA start_state dfa
  where
    dfa = evalState (mkDFAFromRegEx regex) init_nfa
    init_nfa = initNFA 0 :: NFA t Integer

isMatch :: Ord s => DFA t s -> Text -> Bool
isMatch dfa = runDFA' start_state
  where
    start_state = initial dfa
    trans = transitions dfa
    runDFA' s str' =
      if Text.null str'
        then s `Set.member` accepting dfa
        else case maybe_state of
          Just state' -> runDFA' state' xs
          Nothing -> False
      where
        x = Text.head str'
        xs = Text.tail str'
        maybe_state = Map.lookup (s, x) trans

parallelLexingTable :: Ord s => DFA t s -> Map Char [(s, s)]
parallelLexingTable dfa = table
  where
    _states = Set.toList $ states dfa
    _alphabet = Set.toList $ alphabet dfa
    tableLookUp = (transitions dfa Map.!)
    statesFromChar a = (a,) $ map (\b -> (b, tableLookUp (b, a))) _states
    table = Map.fromList $ map statesFromChar _alphabet

isMatchPar :: DFA t Int -> Text -> Bool
isMatchPar dfa str =
  all (`Set.member` set_alphabet) str'
    && last final_state `Set.member` accepting dfa
  where
    str' = Text.unpack str
    _initial = initial dfa
    set_alphabet = alphabet dfa
    table = parallelLexingTable dfa
    combineTransitions (a, _) (_, b) = (a, b)
    zipper = zipWith combineTransitions
    paths = map (map snd) $ scanl1 zipper $ map (table Map.!) str'
    final_state = debug $ scanl (flip (List.!!)) _initial paths