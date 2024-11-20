module Alpacc.Lexer.ParallelLexing
  ( ParallelLexer (..)
  , parallelLexer
  , EndoData (..)
  , listCompositions
  )
where

import Alpacc.Lexer.FSA
import Alpacc.Lexer.DFA
import Data.Foldable
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map hiding (Map)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap hiding (IntMap)
import Data.IntSet (IntSet)
import Data.IntSet qualified as IntSet hiding (IntSet)
import Data.Set (Set)
import Data.Set qualified as Set hiding (Set)
import Data.Maybe
import Data.Array.Base (IArray (..))
import Data.Array.Unboxed (UArray)
import Data.Array.Unboxed qualified as UArray hiding (UArray)
import Data.Tuple (swap)
import Control.Monad.State.Strict
import Data.List qualified as List

errorMessage :: String
errorMessage = "Error: Happend during Parallel Lexing genration, contact a maintainer."

type S = Int
type E = Int

identityE :: E
identityE = 0

identityEndo :: EndoData k
identityEndo =
  EndoData
  { endo = identityE
  , token = Nothing
  , isAccepting = False
  , isProducing = False
  }

deadE :: E
deadE = 1

deadEndo :: EndoData k
deadEndo =
  EndoData
  { endo = deadE
  , token = Nothing
  , isAccepting = False
  , isProducing = False
  }

initE :: E
initE = 2

data Endomorphism =
  Endomorphism
  {-# UNPACK #-} !(UArray S S)
  {-# UNPACK #-} !(UArray S Bool) deriving (Eq, Ord, Show)

data EndoData k =
  EndoData
  { endo :: !E
  , token :: !(Maybe k)
  , isAccepting :: !Bool
  , isProducing :: !Bool
  } deriving (Show, Eq, Ord, Functor)

toEndoData ::
  (Ord k) =>
  S ->
  Map S k ->
  Set S ->
  E ->
  Endomorphism ->
  EndoData k
toEndoData initial_state token_map accept_states e endo =
    EndoData
    { endo = e
    , token = Map.lookup s token_map
    , isAccepting = s `Set.member` accept_states
    , isProducing = is_producing
    }
  where
    (is_producing, s) =
      let (Endomorphism endo' producing) = endo
          (a, b) = bounds endo'
      in if a <= initial_state && initial_state <= b then
           (producing UArray.! initial_state
           ,endo' UArray.! initial_state)
         else
           error errorMessage

data ParallelLexer t e =
  ParallelLexer
  { compositions :: !(IntMap (IntMap e)) 
  , endomorphisms :: !(Map t e)
  , identity :: !e
  , endomorphismsSize :: !Int
  , dead :: !e
  , tokenSize :: !Int
  , acceptArray :: !(UArray E Bool)
  } deriving (Show, Eq, Ord)

data EndoCtx k =
  EndoCtx
  { ecCompositions ::  !(IntMap (IntMap (EndoData k)))
  , ecEndoMap :: !(Map Endomorphism E)
  , ecEndoData :: !(IntMap (EndoData k))
  , ecInverseEndoMap :: !(IntMap Endomorphism)
  , ecConnectedMap :: !(IntMap IntSet)
  , ecInverseConnectedMap :: !(IntMap IntSet)
  , ecMaxE :: !E
  , ecInitialState :: !S
  , ecTokenMap :: !(Map S k)
  , ecAcceptStates :: !(Set S)
  } deriving (Show, Eq, Ord)

lookupComposition ::
  IntMap (IntMap e) ->
  E ->
  E ->
  Maybe e
lookupComposition comps e e' =
  IntMap.lookup e comps >>= IntMap.lookup e'

listCompositions :: ParallelLexer t e -> [e]
listCompositions parallel_lexer =
  [fromMaybe d $ lookupComposition cs e' e | e <- range, e' <- range]
  where
    range = [0..upper]
    cs = compositions parallel_lexer
    d = dead parallel_lexer
    upper = endomorphismsSize parallel_lexer - 1

endoInsert ::
  Ord k =>
  E ->
  Endomorphism ->
  State (EndoCtx k) (EndoData k)
endoInsert e endo = do
  inv_map <- gets ecInverseEndoMap
  initial_state <- gets ecInitialState
  token_map <- gets ecTokenMap
  accept_states <- gets ecAcceptStates
  endo_data <- gets ecEndoData
  let new_inv_map = IntMap.insert e endo inv_map

  _map <- gets ecEndoMap
  let d = toEndoData initial_state token_map accept_states e endo
  let new_endo_data = IntMap.insert e d endo_data
  let new_map = Map.insert endo e _map
  
  modify $
    \s ->
      s { ecInverseEndoMap = new_inv_map
        , ecEndoMap = new_map
        , ecEndoData = new_endo_data }
  pure d

eLookup :: E -> State (EndoCtx k) Endomorphism
eLookup e = do
  inv_map <- gets ecInverseEndoMap
  pure $ inv_map IntMap.! e

connectedUpdate :: IntMap IntSet -> IntMap IntSet -> State (EndoCtx k) ()
connectedUpdate add_map add_inv_map = do
  old_map <- gets ecConnectedMap
  old_inv_map <- gets ecInverseConnectedMap
  let new_map =
        IntMap.foldrWithKey' (IntMap.insertWith IntSet.union) old_map add_map
  let new_inv_map =
        IntMap.foldrWithKey' (IntMap.insertWith IntSet.union) old_inv_map add_inv_map
  modify $ \s ->
    s { ecConnectedMap = new_map
      , ecInverseConnectedMap = new_inv_map }

insertComposition :: E -> E -> EndoData k -> State (EndoCtx k) ()
insertComposition e e' e'' = do
  _map <- gets ecCompositions
  let new_map =
        if e `IntMap.member` _map then
          IntMap.adjust (IntMap.insert e' e'') e _map
        else
          IntMap.insert e (IntMap.singleton e' e'') _map
  modify $ \s -> s { ecCompositions = new_map }

preSets :: E -> E -> State (EndoCtx k) (IntMap IntSet, IntMap IntSet)
preSets e'' e = do
  m <- gets ecInverseConnectedMap
  let e_set = m IntMap.! e
  let e_set'' = fromMaybe IntSet.empty $ e'' `IntMap.lookup` m
  let new_set = IntSet.difference e_set e_set''
  let e_inv_m'' = IntMap.singleton e'' new_set
  let e_m'' = IntMap.fromList $ (, IntSet.singleton e'') <$> IntSet.elems new_set
  pure (e_m'', e_inv_m'')

postSets :: E -> E -> State (EndoCtx k) (IntMap IntSet, IntMap IntSet)
postSets e'' e' = do
  m <- gets ecConnectedMap
  let e_set' = m IntMap.! e'
  let e_set'' = fromMaybe IntSet.empty $ e'' `IntMap.lookup` m
  let new_set = IntSet.difference e_set' e_set''
  let e_m'' = IntMap.singleton e'' new_set
  let e_inv_m'' = IntMap.fromList $ (, IntSet.singleton e'') <$> IntSet.elems new_set
  pure (e_m'', e_inv_m'')

endomorphismLookup ::
  Endomorphism ->
  State (EndoCtx k) (Maybe E)
endomorphismLookup endomorphism = do
  _map <- gets ecEndoMap
  pure $ Map.lookup endomorphism _map

compose :: Endomorphism -> Endomorphism -> Endomorphism
compose (Endomorphism a a') (Endomorphism b b') = Endomorphism c c'
  where
    c = UArray.array (0, numElements a - 1)
      $ map auxiliary [0..(numElements a - 1)]
    c' = UArray.array (0, numElements a' - 1)
      $ map auxiliary' [0..(numElements a' - 1)]
    auxiliary i = (i, b UArray.! (a UArray.! i))
    auxiliary' i = (i, b' UArray.! (a UArray.! i))

endoNext :: Ord k => Endomorphism -> State (EndoCtx k) (EndoData k)
endoNext endo = do
  maybe_e <- endomorphismLookup endo
  case maybe_e of
    Just e -> gets ((IntMap.! e) . ecEndoData)
    Nothing -> do
      new_max_e <- gets (succ . ecMaxE)
      d <- endoInsert new_max_e endo
      insertComposition identityE new_max_e d
      insertComposition new_max_e identityE d
      modify $ \s -> s { ecMaxE = new_max_e }
      pure d

endoCompose ::
  Ord k =>
  E ->
  E ->
  State (EndoCtx k) (IntMap IntSet)
endoCompose e e' = do
  _comps <- gets ecCompositions
  case lookupComposition _comps e e' of
    Nothing -> do
      endo'' <- {-# SCC compose #-} compose <$> eLookup e <*> eLookup e'
      e'' <- endoNext endo''
      insertComposition e e' e''
      (pre_map, pre_inv_map) <- preSets (endo e'') e
      (post_map, post_inv_map) <- postSets (endo e'') e'
      let new_map = IntMap.unionWith IntSet.union pre_map post_map
      let new_inv_map = IntMap.unionWith IntSet.union pre_inv_map post_inv_map
      connectedUpdate new_map new_inv_map
      pure new_map
    _ -> pure IntMap.empty

popElement :: IntMap IntSet -> Maybe ((Int, Int), IntMap IntSet)
popElement _map =
  case IntMap.lookupMin _map of
    Just (key, set) ->
      if IntSet.null set
      then popElement (IntMap.delete key _map)
      else
        let e = IntSet.findMin set
            new_map = IntMap.adjust (IntSet.delete e) key _map
         in Just ((key, e), new_map) 
    Nothing -> Nothing

endoCompositionsTable ::
  Ord k =>
  IntMap IntSet ->
  State (EndoCtx k) ()
endoCompositionsTable _map =
  case popElement _map of
    Just ((e, e'), map') -> do
      map'' <- endoCompose e e'
      let !map''' = IntMap.foldrWithKey' (IntMap.insertWith IntSet.union) map' map''
      endoCompositionsTable map''' 
    Nothing -> pure ()

endomorphismTable ::
  (Enum t, Bounded t, Ord t, Ord k) =>
  ParallelDFALexer t S k ->
  Map t Endomorphism
endomorphismTable lexer =
  Map.fromList
  $ map statesFromChar
  $ Set.toList _alphabet
  where
    dfa = fsa $ parDFALexer lexer
    produces_set = producesToken lexer
    dead_state = deadState lexer
    _transitions = transitions' dfa
    _states = states dfa
    _alphabet = alphabet dfa
    first_index = minimum _states
    last_index = maximum _states
    tableLookUp key =
      fromMaybe dead_state
      $ Map.lookup key _transitions
    statesFromChar t = (t, Endomorphism ss bs)
      where
        ss =
          UArray.array (first_index, last_index)
          $ zip [first_index..last_index]
          $ map (tableLookUp . (, t))
          $ Set.toAscList _states
        bs =
          UArray.array (first_index, last_index)
          $ zip [first_index..last_index]
          $ map ((`Set.member` produces_set) . (, t))
          $ Set.toAscList _states

connectedTable :: Ord t => ParallelDFALexer t S k -> Map t (Set t)
connectedTable lexer =
  Map.fromList
  $ auxiliary <$> _alphabet
  where
    dfa = fsa $ parDFALexer lexer
    _alphabet = Set.toList $ alphabet dfa
    _states = Set.toAscList $ states dfa
    _transitions = transitions' dfa

    auxiliary t =
      (t, )
      $ Set.unions
      $ transitionsLookup
      <$> mapMaybe ((`Map.lookup` _transitions) . (, t)) _states

    transitionLookup s t =
      if (s, t) `Map.member` _transitions
      then Just t
      else Nothing
    
    transitionsLookup s =
      Set.fromList
      $ mapMaybe (transitionLookup s) _alphabet

toAcceptArray :: IntMap (EndoData k) -> UArray E Bool
toAcceptArray endo_map =
  UArray.array (fst $ IntMap.findMin endo_map
               ,fst $ IntMap.findMax endo_map)
  $ IntMap.assocs
  $ isAccepting <$> endo_map

enumerate :: (Foldable f, Ord a) => Int -> f a -> IntMap a
enumerate a = IntMap.fromList . zip [a ..] . toList

invertBijection :: (Ord a, Ord b) => Map a b -> Map b a
invertBijection = Map.fromList . fmap swap . Map.assocs

intMapToMap :: IntMap a -> Map Int a
intMapToMap = Map.fromList . IntMap.toList

mapToIntMap :: Map Int a -> IntMap a
mapToIntMap = IntMap.fromList . Map.toList

setToIntSet :: Set Int -> IntSet
setToIntSet = IntSet.fromList . Set.toList

toIntMapSet :: Map Int (Set Int) -> IntMap IntSet
toIntMapSet = mapToIntMap . fmap setToIntSet

invertIntSetMap :: IntMap IntSet -> IntMap IntSet 
invertIntSetMap =
  IntMap.unionsWith IntSet.union
  . IntMap.mapWithKey toMap
  where
    toMap k =
      IntMap.fromList
      . fmap (,IntSet.singleton k)
      . IntSet.toList

mapMapSet ::
  (Ord t, Ord t') =>
  (t -> t') ->
  Map t (Set t) ->
  Map t' (Set t')
mapMapSet f =
  Map.mapKeys f . fmap (Set.map f)

initEndoData :: Ord k => S -> Map S k -> Set S -> IntMap Endomorphism -> IntMap (EndoData k)
initEndoData initial_state token_map accept_states =
  IntMap.insert identityE identityEndo
  . IntMap.insert deadE deadEndo
  . IntMap.mapWithKey (toEndoData initial_state token_map accept_states)


initCompositions :: [EndoData k] -> IntMap (IntMap (EndoData k))
initCompositions ls =
  IntMap.unionsWith IntMap.union
  $ (IntMap.singleton identityE (IntMap.singleton identityE identityEndo):)
  $ [IntMap.singleton identityE (IntMap.singleton (endo e) e) | e <- ls]
  ++ [IntMap.singleton (endo e) (IntMap.singleton identityE e) | e <- ls]


initEndoCtx ::
  (Enum t, Bounded t, Ord t, Ord k) =>
  ParallelDFALexer t S k ->
  Map t Endomorphism ->
  EndoCtx k
initEndoCtx lexer endo_table =
  EndoCtx
  { ecCompositions = initCompositions $ IntMap.elems endo_data
  , ecEndoMap = endo_to_e
  , ecInverseEndoMap = e_to_endo
  , ecConnectedMap = connected_table
  , ecInverseConnectedMap = inverse_connected_table
  , ecMaxE = maximum $ IntMap.keys e_to_endo
  , ecInitialState = initial_state
  , ecTokenMap = token_map
  , ecAcceptStates = accept_states
  , ecEndoData = endo_data
  }
  where
    endo_data = initEndoData initial_state token_map accept_states e_to_endo
    initial_state = initial $ fsa $ parDFALexer lexer
    token_map = terminalMap $ parDFALexer lexer
    accept_states = accepting $ fsa $ parDFALexer lexer
    e_to_endo = enumerate initE $ List.nub $ Map.elems endo_table
    endo_to_e = invertBijection $ intMapToMap e_to_endo
    t_to_e = (endo_to_e Map.!) <$> endo_table
    connected_table = toIntMapSet $ mapMapSet (t_to_e Map.!) $ connectedTable lexer
    inverse_connected_table = invertIntSetMap connected_table

addDead ::
  (Ord t, Enum t, Bounded t) =>
  Map t (EndoData k) ->
  Map t (EndoData k)
addDead = (`Map.union` unknown_transitions)
  where
    unknown_transitions =
      Map.fromList
      $ map (,deadEndo) [minBound..maxBound]
  
parallelLexer ::
  (Ord t, Enum t, Bounded t, Ord s, Ord k) =>
  ParallelDFALexer t s k ->
  ParallelLexer t (EndoData k)
parallelLexer lexer' =
  ParallelLexer
  { compositions = _compositions
  , endomorphisms = transition_to_endo
  , identity = identityEndo
  , endomorphismsSize = IntMap.size endo_data
  , dead = deadEndo
  , tokenSize = Map.size $ terminalMap $ parDFALexer lexer
  , acceptArray = accept_array
  }
  where
    lexer = enumerateParLexer 0 lexer'
    accept_array = toAcceptArray endo_data
    ctx = initEndoCtx lexer endo_table
    connected_map = ecConnectedMap ctx
    (EndoCtx
      { ecCompositions = _compositions
      , ecEndoMap = endo_map
      , ecEndoData = endo_data
      }) = execState (endoCompositionsTable connected_map) ctx
    endo_table = endomorphismTable lexer
    transition_to_endo =
      addDead $ (endo_data IntMap.!) . (endo_map Map.!) <$> endo_table
  
