module Alpacc.Lexer.ParallelLexing
  ( Endomorphism
  , parallelLexer
  , ParallelLexer (..)
  )
where

import Alpacc.Util (fixedPointIterate)
import Alpacc.Lexer.FSA
import Alpacc.Lexer.DFA
import Data.Map (Map)
import Data.Map qualified as Map hiding (Map)
import Data.Set (Set)
import Data.Set qualified as Set hiding (Set)
import Data.Maybe
import Data.Array (Array)
import Data.Array qualified as Array hiding (Array)
import Data.Bifunctor (Bifunctor (..))
import Data.Tuple (swap)
import Data.Tuple.Extra (both)
import Alpacc.Debug (debug)

type State = Int
type Endo = Int
type Endomorphism = Array State State

data ParallelLexer t k =
  ParallelLexer
  { compositions :: Map (Endo, Endo) Endo
  , endomorphisms :: Map t Endo
  , tokenEndomorphism :: Set Endo 
  , endomorphismsToStates :: Map Endo State
  , tokenMap :: Map State k
  , identity :: Endo
  , stateSize :: Int
  , endomorphismsSize :: Int
  , acceptingStates :: Set State
  } deriving (Show, Eq, Ord)

statesToKeysMap :: Ord s => Set s -> Map s State
statesToKeysMap =
  Map.fromList
  . flip zip [(0 :: State)..]
  . Set.toAscList

compose :: Endomorphism -> Endomorphism -> Endomorphism
compose a b =
  Array.array (0, length a - 1)
  $ map auxiliary [0..(length a - 1)]
  where
    auxiliary i = (i, b Array.! (a Array.! i))

composeTrans ::
  (Endomorphism, t) ->
  (Endomorphism, t) ->
  (Endomorphism, t)
composeTrans (a, _) (b, t) = (a `compose` b, t)

endomorphismTable ::
  (Enum t, Bounded t, IsTransition t, Ord k) =>
  ParallelDFALexer t State k ->
  Map t Endomorphism
endomorphismTable lexer =
  Map.fromList
  $ map statesFromChar [minBound..maxBound]
  where
    dfa = fsa $ parDFALexer lexer
    dead_state = deadState lexer
    _transitions = transitions' dfa
    _states = states dfa
    _alphabet = alphabet dfa
    first_index = minimum _states
    last_index = maximum _states
    toArray =
      Array.array (first_index, last_index)
      . zip [first_index..last_index]
    tableLookUp key =
      fromMaybe dead_state
      $ Map.lookup key _transitions
    statesFromChar t =
      (t,)
      $ toArray
      $ map (tableLookUp . (, t))
      $ Set.toAscList _states

connectedTable :: IsTransition t => ParallelDFALexer t State k -> Map t (Set t)
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

initConnected ::
  (Enum t, Bounded t, IsTransition t, Ord k) =>
  ParallelDFALexer t State k ->
  Map (Endomorphism, t) (Set (Endomorphism, t))
initConnected lexer =
  Map.unionsWith Set.union
  $ mapMaybe auxiliary
  $ Map.toList connected_table
  where
    connected_table = connectedTable lexer
    endomorphism_table = endomorphismTable lexer

    auxiliary (t, t_set) = do
      e <- toEndo t
      let t_set' =
            Set.fromList
            $ mapMaybe toEndo
            $ Set.toList t_set
      return $ Map.singleton e t_set'

    toEndo t = do
      e <- Map.lookup t endomorphism_table
      return (e, t)

newEndoConn ::
  (IsTransition t) =>
  Map (Endomorphism, t) (Set (Endomorphism, t)) ->
  (Endomorphism, t) ->
  Set (Endomorphism, t) ->
  Map (Endomorphism, t) (Set (Endomorphism, t))
newEndoConn conn_endos endo endo_set =
  Map.unionsWith Set.union
  $ Set.map toMap endo_set
  where
    toConn = (conn_endos Map.!)
    toMap endo' =
      Map.singleton comp (toConn endo') `Map.union` new_map
      where
        comp = endo `composeTrans` endo'
        set = Set.singleton comp
        new_map =
          Map.unions
          $ fmap (`Map.singleton` set)
          $ Map.keys
          $ Map.filter (endo `Set.member`) conn_endos

newEndoConns ::
  (IsTransition t) =>
  Map (Endomorphism, t) (Set (Endomorphism, t)) ->
  Map (Endomorphism, t) (Set (Endomorphism, t))
newEndoConns conn_endos =
  Map.unionWith Set.union conn_endos
  $ Map.unionsWith Set.union
  $ Map.mapWithKey (newEndoConn conn_endos) conn_endos

connected ::
  (IsTransition t) =>
  Map (Endomorphism, t) (Set (Endomorphism, t)) ->
  Map (Endomorphism, t) (Set (Endomorphism, t))
connected = fixedPointIterate (/=) newEndoConns

compositionsTable ::
  Map Endomorphism (Set Endomorphism) ->
  Map (Endomorphism, Endomorphism) Endomorphism
compositionsTable _connected =
  Map.fromList
  $ concat
  $ Map.mapWithKey auxiliary _connected
  where
    toMap e e' = ((e, e'), e `compose` e')
    auxiliary e = Set.toList . Set.map (toMap e)

endomorphismSet ::
  Map Endomorphism (Set Endomorphism) ->
  Set Endomorphism
endomorphismSet _connected =
  Set.union (Map.keysSet _connected)
  $ Set.unions _connected

enumerateEndomorphisms ::
  Map Endomorphism (Set Endomorphism) ->
  Map Endomorphism Endo
enumerateEndomorphisms =
  Map.fromList
  . flip zip [0..]
  . Set.toList
  . endomorphismSet

toStateMap :: State -> Map Endomorphism Endo -> Map Endo State
toStateMap initial_state =
  Map.fromList
  . fmap (swap . first (Array.! initial_state))
  . Map.toList

endoCompositions ::
  (Endomorphism -> Endo) ->
  Map (Endomorphism, Endomorphism) Endomorphism ->
  Map (Endo, Endo) Endo
endoCompositions toEndo comps =
  Map.mapKeys (both toEndo)
  $ toEndo <$> comps

endosInTable :: Ord t => Map (t, t) t -> Set t
endosInTable table = endos
  where
    endos =
      Set.union (Set.fromList right)
      $ Set.union (Set.fromList left)
      $ Set.fromList
      $ Map.elems table
    (left, right) =
      unzip
      $ Map.keys table

addIdentity :: Ord t => t -> Map (t, t) t -> Map (t, t) t
addIdentity identity_endo table =
  Map.union right_endos
  $ Map.union table left_endos
  where
    left_endos =
      Map.fromList $ (\q -> ((identity_endo, q), q)) <$> endos
    right_endos =
      Map.fromList $ (\q -> ((q, identity_endo), q)) <$> endos
    endos =
      Set.toList
      $ Set.insert identity_endo
      $ endosInTable table

addDead :: Ord t => t -> Map (t, t) t -> Map (t, t) t
addDead dead_endo table =
  Map.union right_endos
  $ Map.union table left_endos
  where
    left_endos =
      Map.fromList $ (\q -> ((dead_endo, q), dead_endo)) <$> endos
    right_endos =
      Map.fromList $ (\q -> ((q, dead_endo), dead_endo)) <$> endos
    endos =
      Set.toList
      $ Set.insert dead_endo
      $ endosInTable table

createIdentity ::
  (IsTransition t, Enum t, Bounded t, Ord k) =>
  ParallelDFALexer t State k ->
  Endomorphism
createIdentity lexer =
  Array.array (first_index, last_index)
  $ zip lst lst
  where
    _states = states $ fsa $ parDFALexer lexer
    first_index = minimum _states
    last_index = maximum _states
    lst = [first_index..last_index]

createDead ::
  (IsTransition t, Enum t, Bounded t, Ord k) =>
  ParallelDFALexer t State k ->
  Endomorphism
createDead lexer =
  Array.array (first_index, last_index)
  $ map (,_dead) lst
  where
    _states = states $ fsa $ parDFALexer lexer
    first_index = minimum _states
    last_index = maximum _states
    _dead = deadState lexer
    lst = [first_index..last_index]

producesTokenEndo :: 
  (IsTransition t, Enum t, Bounded t, Ord k) =>
  ParallelDFALexer t State k ->
  Map (Endomorphism, t) (Set (Endomorphism, t)) ->
  Set Endomorphism
producesTokenEndo lexer connected_set =
  Set.map fst
  $ Set.filter (
    \(e, t) ->
      let s = e Array.! _initial
      in (s, t) `Set.member` produces
  ) set
  where
    produces = producesToken lexer
    _initial = initial $ fsa $ parDFALexer lexer
    set =
      Set.union (Map.keysSet connected_set)
      $ Set.unions connected_set
  
parallelLexer ::
  (IsTransition t, Enum t, Bounded t, Ord k) =>
  ParallelDFALexer t State k ->
  ParallelLexer t k
parallelLexer lexer = 
  ParallelLexer
  { compositions = _compositions
  , endomorphisms = _transitions_to_endo
  , identity = _identity
  , tokenMap = token_map
  , endomorphismsToStates = to_state
  , stateSize = state_size
  , endomorphismsSize = endo_size
  , acceptingStates = accept_states
  , tokenEndomorphism = produces_token
  }
  where
    accept_states = accepting $ fsa $ parDFALexer lexer
    endo_size = Map.size to_endo
    state_size = Set.size $ states $ fsa $ parDFALexer lexer
    trans_connected = connected $ initConnected lexer
    _connected = Map.mapKeys fst $ Set.map fst <$> trans_connected
    to_endo' = enumerateEndomorphisms _connected
    to_endo =
      Map.insert vec_identity _identity
      $ Map.insert vec_dead _dead to_endo'
    _identity = succ $ maximum to_endo'
    _dead = succ $ succ $ maximum to_endo'
    vec_dead = createDead lexer
    vec_identity = createIdentity lexer
    toEndo = (to_endo Map.!)
    _endomorphisms = endomorphismTable lexer
    _compositions =
      addDead _dead
      $ addIdentity _identity
      $ endoCompositions toEndo
      $ compositionsTable _connected
    token_map = terminalMap $ parDFALexer lexer
    _alphabet = Set.toList $ alphabet $ fsa $ parDFALexer lexer
    _transitions_to_endo =
      Map.fromList
      $ (\t -> (t, toEndo $ _endomorphisms Map.! t))
      <$> [minBound..maxBound]
    initial_state = initial $ fsa $ parDFALexer lexer
    to_state = toStateMap initial_state to_endo
    produces_token =
      Set.map toEndo
      $ producesTokenEndo lexer trans_connected
