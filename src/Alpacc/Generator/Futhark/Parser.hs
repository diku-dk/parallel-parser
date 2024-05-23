module Alpacc.Generator.Futhark.Parser
  ( generateParser,
  )
where

import Control.DeepSeq
import Alpacc.Grammar
import Alpacc.LLP
  ( Bracket (..),
    llpParserTableWithStartsHomomorphisms,
  )
import Data.Bifunctor qualified as BI
import Data.Either.Extra (maybeToEither)
import Data.FileEmbed
import Data.List qualified as List
import Data.Map (Map)
import Data.Map qualified as Map
import Data.String.Interpolate (i)
import Data.Tuple.Extra
import Alpacc.Generator.Futhark.Util
<<<<<<< Updated upstream
import Alpacc.HashTable
import Alpacc.Debug
=======
import Alpacc.Generator.Futhark.FutPrinter
import Data.Composition
import Alpacc.HashTable
import Alpacc.Debug
import Data.Word
import Data.Array.Base as ABase
>>>>>>> Stashed changes

futharkParser :: String
futharkParser = $(embedStringFile "futhark/parser.fut")

-- | Given the table keys for a LLP parser create the keys which will be used
-- in the Futhark language for pattern matching.
futharkParserTableKey ::
  Int ->
  Int ->
  Int ->
  ([Int], [Int]) ->
  String
futharkParserTableKey empty_terminal q k =
  tupleToStr
  . both toTuple
  . BI.bimap backPad frontPad
  . both (map show)
  where
    backPad = lpad (show empty_terminal) q
    frontPad = rpad (show empty_terminal) k

-- | Creates a string that is a array in the Futhark language which corresponds
-- to the resulting productions list. This is used in the pattern matching.
futharkProductions :: Int -> Int -> ([Bracket Int], [Int]) -> String
futharkProductions max_alpha_omega max_pi = ("#some " ++) . toTuple . toArr . snd' . fst'
  where
    toArr (a, b) = [a, b]
    snd' = BI.second (toTuple . rpad "empty_production" max_pi . map show)
    fst' = BI.first (toTuple . rpad "epsilon" max_alpha_omega . map auxiliary)
    auxiliary (LBracket a) = "left " ++ show a
    auxiliary (RBracket a) = "right " ++ show a

tupleToStr :: (Show a, Show b) => (a, b) -> String
tupleToStr (a, b) = [i|(#{a}, #{b})|]

-- | Creates a string that is the resulting LLP table which is done by using
-- pattern matching in Futhark.
futharkParserTable ::
  Int ->
  Int ->
  Int ->
  Map ([Int], [Int]) ([Bracket Int], [Int]) ->
  (Int, Int, String, String)
futharkParserTable empty_terminal q k table =
  (max_alpha_omega, max_pi, ne, )
    . (++ last_case_str)
    . cases
    . prods
    $ keys table
  where
    cases = futharkTableCases . Map.toList
    values = Map.elems table
    max_alpha_omega = maximum $ length . fst <$> values
    max_pi = maximum $ length . snd <$> values
    stacks = toArray $ replicate max_alpha_omega "epsilon"
    rules = toArray $ replicate max_pi "empty_production"
    ne = toTuple [stacks, rules]
    last_case_str = [i|\n  case _ -> #none|]
    prods = fmap (futharkProductions max_alpha_omega max_pi)
    keys = Map.mapKeys (futharkParserTableKey empty_terminal q k)

toIntegerLLPTable ::
  (Ord nt, Ord t) =>
  Map (Symbol (AugmentedNonterminal nt) (AugmentedTerminal t)) Int ->
  Map ([AugmentedTerminal t], [AugmentedTerminal t]) ([Bracket (Symbol (AugmentedNonterminal nt) (AugmentedTerminal t))], [Int]) ->
  Map ([Int], [Int]) ([Bracket Int], [Int])
toIntegerLLPTable symbol_index_map table = table'
  where
    table_index_keys = Map.mapKeys (both (fmap ((symbol_index_map Map.!) . Terminal))) table
    table' = first (fmap (fmap (symbol_index_map Map.!))) <$> table_index_keys
<<<<<<< Updated upstream
    -- _table = Map.mapKeys (\(a, b) -> fromIntegral <$> a ++ b) table'
    -- !hash_table = debug $ initHashTable 13 _table
=======

llpTableToStrings ::
  Int ->
  Int ->
  Map ([t], [t]) ([Bracket Int], [Int]) ->
  Map ([t], [t]) RawString
llpTableToStrings max_ao max_pi =
  fmap (RawString . tupleToStr . BI.bimap f g)
  where
    auxiliary (LBracket a) = "left " ++ show a
    auxiliary (RBracket a) = "right " ++ show a
    aoPad = rpad "epsilon" max_ao
    piPad = rpad "empty_terminal" max_pi
    f = toArray . aoPad . fmap auxiliary
    g = toArray . piPad . fmap show

padAndStringifyTable ::
  (Ord nt, Ord t) =>
  Int ->
  Int ->
  Int ->
  Int ->
  Int ->
  Map (Symbol (AugmentedNonterminal nt) (AugmentedTerminal t)) Int ->
  Map ([AugmentedTerminal t]
      ,[AugmentedTerminal t])
      ([Bracket (Symbol (AugmentedNonterminal nt) (AugmentedTerminal t))]
      ,[Int]) ->
  Map [Int] RawString
padAndStringifyTable empty_terminal q k max_ao max_pi =
  Map.mapKeys (uncurry (++))
  . llpTableToStrings max_ao max_pi
  . padLLPTableKeys empty_terminal q k
  .: toIntLLPTable
>>>>>>> Stashed changes

declarations :: String
declarations = [i|
type terminal = terminal_module.t
type production = production_module.t
type bracket = bracket_module.t

def empty_terminal : terminal = terminal_module.highest
def empty_production : production = production_module.highest
def epsilon : bracket = bracket_module.highest

def left (s : bracket) : bracket =
  bracket_module.set_bit (bracket_module.num_bits - 1) s 1

def right (s : bracket) : bracket =
  bracket_module.set_bit (bracket_module.num_bits - 1) s 0
|] 

findBracketIntegral ::
  Map (Symbol (AugmentedNonterminal nt) (AugmentedTerminal t)) Int ->
  Either String FutUInt
findBracketIntegral index_map = findSize _max
  where
    _max = maximum index_map
    findSize max_size
      | max_size < 0 = Left "Max size may not be negative."
      | max_size < 2 ^ (8 - 1 :: Integer) - 1 = Right U8
      | max_size < 2 ^ (16 - 1 :: Integer) - 1 = Right U16
      | max_size < 2 ^ (32 - 1 :: Integer) - 1 = Right U32
      | max_size < 2 ^ (64 - 1 :: Integer) - 1 = Right U64
      | otherwise = Left "There are too many symbols to find a Futhark integral type."

findProductionIntegral ::
  [Production nt t] ->
  Either String FutUInt
findProductionIntegral ps = findSize _max
  where
    _max = toInteger $ length ps
    findSize max_size
      | max_size < 0 = Left "Max size may not be negative."
      | max_size < maxFutUInt U8 = Right U8
      | max_size < maxFutUInt U16 = Right U16
      | max_size < maxFutUInt U32 = Right U32
      | max_size < maxFutUInt U64 = Right U64
      | otherwise = Left "There are too many productions to find a Futhark integral type."

productionToTerminal ::
  (Ord nt, Ord t) =>
  Map (Symbol (AugmentedNonterminal (Either nt t)) (AugmentedTerminal t)) Int ->
  [Production (AugmentedNonterminal (Either nt t)) (AugmentedTerminal t)] ->
  String
productionToTerminal symbol_to_index prods =
  ([i|sized number_of_productions [|]++)
  $ (++"]")
  $ List.intercalate "\n,"
  $ p
  . nonterminal <$> prods
  where
    p (AugmentedNonterminal (Right t)) =
      [i|#some #{x}|]
        where
          x = symbol_to_index Map.! Terminal (AugmentedTerminal t)
    p _ = "#none"    

productionToArity ::
  [Production (AugmentedNonterminal (Either nt t)) (AugmentedTerminal t)] ->
  Either String String
productionToArity prods =
  if 32767 < max_arity
  then Left "A production contains a right-hand side too many nonterminals"
  else Right arities_str
  where
    isNt (Nonterminal _) = 1 :: Integer
    isNt _ = 0
    arity = sum . fmap isNt . symbols
    arities = arity <$> prods
    max_arity = maximum arities
    arities_str =
      ([i|def production_to_arity: [number_of_productions]i16 = sized number_of_productions [|]++)
      $ (++"]")
      $ List.intercalate "\n,"
      $ show <$> arities
    

-- | Creates Futhark source code which contains a parallel parser that can
-- create the productions list for a input which is indexes of terminals.
generateParser ::
  (NFData t, NFData nt, Ord nt, Show nt, Show t, Ord t) =>
  Int ->
  Int ->
  Grammar (Either nt t) t ->
  Map (Symbol (AugmentedNonterminal (Either nt t)) (AugmentedTerminal t)) Int ->
  FutUInt ->
  Either String String
generateParser q k grammar symbol_index_map terminal_type = do
  start_terminal <- maybeToEither "The left turnstile \"⊢\" terminal could not be found, you should complain to a developer." maybe_start_terminal
  end_terminal <- maybeToEither "The right turnstile \"⊣\" terminal could not be found, you should complain to a developer." maybe_end_terminal
  table <- llpParserTableWithStartsHomomorphisms q k grammar
  bracket_type <- findBracketIntegral symbol_index_map
  production_type <- findProductionIntegral $ productions grammar
<<<<<<< Updated upstream
  arities <- productionToArity prods 
  let integer_table = toIntegerLLPTable symbol_index_map table
  let (max_ao, max_pi, ne, futhark_table) =
        futharkParserTable (fromInteger $ maxFutUInt terminal_type) q k integer_table
      brackets = List.intercalate "," $ zipWith (<>) (replicate max_ao "b") $ map show [(0 :: Int) ..]
      productions = List.intercalate "," $ zipWith (<>) (replicate max_pi "p") $ map show [(0 :: Int) ..]
=======
  arities <- productionToArity prods
  let empty_terminal = fromInteger $ maxFutUInt terminal_type :: Int
  let (max_ao, max_pi) = maxAoPi table
  let ne = createNe max_ao max_pi
  let integer_table =
        padAndStringifyTable empty_terminal q k max_ao max_pi symbol_index_map table
  hash_table <- initHashTable 13 integer_table
  hash_table_mem <- hashTableMem hash_table
  let hash_table_size = ABase.numElements $ elementArray hash_table_mem
  let hash_table_str = futPrint $ elementArray hash_table_mem
>>>>>>> Stashed changes
  return $
    futharkParser
      <> [i|
module parser = mk_parser {

module terminal_module = #{terminal_type}
module production_module = #{production_type}
module bracket_module = #{bracket_type}

#{declarations}

type look_type = #{look_type}

def number_of_terminals: i64 = #{number_of_terminals}
def number_of_productions: i64 = #{number_of_productions} 
def q: i64 = #{q}
def k: i64 = #{k}
def hash_table_size: i64 = #{hash_table_size}
def max_ao: i64 = #{max_ao}
def max_pi: i64 = #{max_pi}
def start_terminal: terminal = #{start_terminal}
def end_terminal: terminal = #{end_terminal}
def production_to_terminal: [number_of_productions](opt terminal) =
  #{prods_to_ters}
#{arities}

def key_to_config (_: look_type):
                  opt ([max_ao]bracket, [max_pi]production) =
    map_opt (
      \\((a),(b)) ->
        (sized max_ao [a], sized max_pi [b])
    ) <| #none

def array_to_look_type [n] (arr: [n]terminal): look_type =
  #{toTupleIndexArray "arr" (q+k)}

<<<<<<< Updated upstream
def key_to_config (key: (lookback_type, lookahead_type)):
                  opt ([max_ao]bracket, [max_pi]production) =
  map_opt (\\((#{brackets}),(#{productions})) ->
    (sized max_ao [#{brackets}], sized max_pi [#{productions}])
  ) <|
  match key
  #{futhark_table}
=======
def hash_table =
  #{hash_table_str} :> [hash_table_size](opt ([q + k]i64, ([max_ao]bracket, [max_pi]production)))
>>>>>>> Stashed changes

def ne: ([max_ao]bracket, [max_pi]production) =
  let (a,b) = #{ne}
  in (sized max_ao a, sized max_pi b)
}
|]
  where
    prods = productions augmented_grammar
    number_of_productions = length prods
    prods_to_ters = productionToTerminal symbol_index_map prods
    number_of_terminals = length terminals'
    maybe_start_terminal = Map.lookup (Terminal RightTurnstile) symbol_index_map
    maybe_end_terminal = Map.lookup (Terminal LeftTurnstile) symbol_index_map
    augmented_grammar = augmentGrammar grammar
    terminals' = terminals augmented_grammar
    look_type = toTuple $ replicate (q + k) "terminal"
