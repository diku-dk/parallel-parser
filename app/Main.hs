module Main where

import ParallelParser.Grammar
import ParallelParser.Generator
import Prelude hiding (last)
import Data.Maybe
import Options.Applicative
import Data.Semigroup ((<>))
import Data.String.Interpolate (i)
import System.FilePath.Posix (stripExtension, takeFileName)
import qualified Data.List as List
import Control.Monad
import Control.Exception
import System.Exit (exitFailure)
import Data.Foldable
import ParallelParser.LLP (rightNullableDoubleNT)
import ParallelParser.LL (isLeftRecursive, closureAlgorithm, leftFactorNonterminals, nullableOne)
import qualified Data.Set as Set
import Debug.Trace (traceShow)

debug x = traceShow x x

data Input
  = FileInput FilePath
  | StdInput

data Parameters = Parameters
  { input     :: Input
  , output    :: Maybe String
  , lookback  :: Int
  , lookahead :: Int}

lookbackParameter :: Parser Int
lookbackParameter =
    option auto
      ( long "lookback"
    <> short 'q'
    <> help "The amount of characters used for lookback."
    <> showDefault
    <> value 1
    <> metavar "INT" )

lookaheadParameter :: Parser Int
lookaheadParameter =
    option auto
      ( long "lookahead"
    <> short 'k'
    <> help "The amount of characters used for lookahead."
    <> showDefault
    <> value 1
    <> metavar "INT")

outputParameter :: Parser (Maybe String)
outputParameter =
    optional $ strOption
      ( long "output"
    <> short 'o'
    <> help "The name of the output file."
    <> metavar "FILE" )

fileInput :: Parser Input
fileInput = FileInput <$> argument str (metavar "FILE")

stdInput :: Parser Input
stdInput = flag' StdInput
      ( long "stdin"
    <> short 's'
    <> help "Read from stdin.")

inputParameter :: Parser Input
inputParameter = fileInput <|> stdInput

parameters :: Parser Parameters
parameters = Parameters
  <$> inputParameter
  <*> outputParameter
  <*> lookbackParameter
  <*> lookaheadParameter

opts :: ParserInfo Parameters
opts = info (parameters <**> helper)
  ( fullDesc
  <> progDesc "Creates a parallel parser in Futhark using FILE."
  <> header "ParallelParser" )


writeFutharkProgram :: String -> String -> IO ()
writeFutharkProgram program_path program = do
  writeFile program_path program
  putStrLn ("The parser " ++ program_path ++ " was created.")

isFileInput :: Input -> Bool
isFileInput StdInput = False
isFileInput (FileInput _) = True

grammarError :: Grammar String String -> Maybe String
grammarError grammar
  | not $ null nt_dups = Just [i|The given grammar contains duplicate nonterminals because of #{nt_dups_str}.|]
  | not $ null t_dups = Just [i|The given grammar contains duplicate terminals because of #{t_dups_str}.|]
  | not $ null p_dups = Just [i|The given grammar contains duplicate productions because of #{p_dups_str}.|]
  | isLeftRecursive grammar = Just [i|The given grammar contains left recursion.|]
  | not $ null  left_factors = Just [i|The given grammar contains productions that has common left factors due to the following nonterminals #{left_factors_str}.|]
  | any isHeadNullable start_symbols = Just [i|The given grammars start nonterminal must not have productions where the first symbol is nullable.|]
  | rightNullableDoubleNT grammar = Just [i|The given grammar is able to derive two consecutive nonterminals that are the same and nullable.|]
  | not $ null nonproductive = Just [i|The given grammar contains nonproductive productions due to the following nonterminals #{nonproductive_str}.|]
  | otherwise = Nothing
  where
    start' = start grammar
    nullableOne' = nullableOne grammar
    isHeadNullable [] = False
    isHeadNullable (x:_) = nullableOne' x 
    start_symbols = symbols <$> findProductions grammar start'
    nts = Set.fromList $ nonterminals grammar
    nonproductive = nts `Set.difference` closureAlgorithm grammar
    nonproductive_str = List.intercalate ", " $ Set.toList nonproductive
    left_factors = leftFactorNonterminals grammar
    left_factors_str = List.intercalate ", " left_factors
    (nt_dups, t_dups, p_dups) = grammarDuplicates grammar
    nt_dups_str = List.intercalate ", " nt_dups
    t_dups_str = List.intercalate ", " t_dups
    p_dups_str = List.intercalate ", " $ fmap showProd p_dups
    unwrapSym (Terminal a) = a
    unwrapSym (Nonterminal a) = a
    showProd (Production nt s) = nt ++ " -> " ++ unwords (fmap unwrapSym s)

main :: IO ()
main = do
  options <- execParser opts
  let input_method = input options
  let q = lookback options
  let k = lookahead options
  let outfile = output options
  let program_path = case outfile of
        Just path -> path
        Nothing -> case input_method of
          StdInput -> "parser.fut"
          FileInput path -> (++".fut") . fromJust . stripExtension "cg" $ takeFileName path
  contents <- case input_method of
        StdInput -> getContents
        FileInput path -> readFile path
  let grammar = unpackNTTGrammar (read contents :: Grammar NT T)
  let maybe_program = futharkKeyGeneration q k grammar
  case grammarError grammar of
    Just msg -> putStrLn msg *> exitFailure
    Nothing -> case maybe_program of
        Nothing -> putStrLn [i|The given Grammar is not a LLP(#{q}, #{k}).|] *> exitFailure
        Just program -> writeFutharkProgram program_path program