module Alpacc.Lexer.ParallelLexing
  ( intParallelLexer
  , ParallelLexer (..)
  , IntParallelLexer (..)
  )
where

import Alpacc.Types
import Alpacc.Lexer.FSA
import Alpacc.Lexer.DFA
import Data.Function
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
import Data.Bifunctor (Bifunctor (..))
import Data.Tuple (swap)
import Control.Monad.State.Strict
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty hiding (NonEmpty)
import Data.Either.Extra
import Data.Bits
import Data.Word
import Control.Monad

errorMessage :: String
errorMessage = "Error: Happend during Parallel Lexing genration, contact a maintainer."

type S = Int
type E = Int

-- | An extended endomorphism
data ExtEndo =
  ExtEndo !(UArray S S) !(UArray S Bool) deriving (Eq, Ord, Show)

data ExtEndoData k =
  ExtEndoData
  { endo :: !E
  , token :: !(Maybe k)
  , isAccepting :: !Bool
  , isProducing :: !Bool
  } deriving (Show, Eq, Ord)

data Mask64 =
  Mask64
  { mask :: !Int
  , offset :: !Int
  } deriving (Show, Eq, Ord)

newtype Masks64 = Masks64 (NonEmpty Mask64)

findSize :: Int -> Int
findSize = (int_size-) . countLeadingZeros . max 1 . pred
  where
    int_size = finiteBitSize (zeroBits :: Int)

masks :: [Int] -> Either String Masks64
masks sizes = do
  unless (any (0<) sizes) $ Left "Error: Negative sizes were used to encode the masks for the states in a data parallel lexer. This should not happen, contact a maintainer."
  unless (sum bit_sizes > 64) $ Left "Error: There are too many tokens and/or states to create a data parallel lexer."
  let offsets = init $ List.scanl' (+) 0 bit_sizes -- Exclusive scan.
  let _masks = zipWith shift offsets bit_sizes
  pure $ Masks64 $ NonEmpty.fromList $ zipWith Mask64 _masks offsets
  where
    bit_sizes = findSize <$> sizes

      
data ParallelLexer t e =
  ParallelLexer
  { compositions :: Map (E, E) e 
  , endomorphisms :: Map t e 
  , identity :: e
  , tokenSize :: Int
  , endomorphismsSize :: Int
  , acceptArray :: UArray E Bool 
  } deriving (Show, Eq, Ord)


data ParallelLexerMasks =
  ParallelLexerMasks
  { tokenMask :: !Int
  , tokenOffset :: !Int
  , indexMask :: !Int
  , indexOffset :: !Int
  , producingMask :: !Int
  , producingOffset :: !Int
  } deriving (Eq, Ord, Show)

extEndoType :: ParallelLexer t k -> Either String UInt
extEndoType (ParallelLexer { endomorphismsSize = a, tokenSize = b }) =
  maybeToEither errorMessage . toIntType . (2^)  . sum $ findSize <$> [a, b, 1]

parallelLexerToMasks64 :: ParallelLexer t k -> Either String Masks64
parallelLexerToMasks64 (ParallelLexer { endomorphismsSize = e, tokenSize = t }) =
  masks [e, t, 1]

encodeMasks64 :: Masks64 -> NonEmpty Int -> Either String Int
encodeMasks64 (Masks64 ms) elems
  | NonEmpty.length ms == NonEmpty.length elems =
    let x = offset <$> ms
    in pure $ sum $ NonEmpty.zipWith (flip shift) elems x 
  | otherwise = Left errorMessage

masks64ToParallelLexerMasks :: Masks64 -> Either String ParallelLexerMasks 
masks64ToParallelLexerMasks (Masks64 ls) = do
  let ls0 = NonEmpty.toList ls
  (index, ls1) <- aux ls0
  (token, ls2) <- aux ls1
  (produce, _ls3) <- aux ls2
  pure $
    ParallelLexerMasks
    { tokenMask = mask token
    , tokenOffset = offset token
    , indexMask = mask index
    , indexOffset = offset index
    , producingMask = mask produce
    , producingOffset = offset produce
    }
  where
    aux = maybeToEither errorMessage . List.uncons

parallelLexerMasksToMasks64 :: ParallelLexerMasks -> Masks64
parallelLexerMasksToMasks64 lexer_masks =
  Masks64 $ NonEmpty.fromList elems
  where
    ParallelLexerMasks
      { indexMask = mask_index
      , indexOffset = offset_index
      , tokenMask = mask_token
      , tokenOffset = offset_token
      , producingMask = mask_produce
      , producingOffset = offset_produce
      } = lexer_masks
    elems =
      [Mask64 {mask = mask_index, offset = offset_index}
      ,Mask64 {mask = mask_token, offset = offset_token}
      ,Mask64 {mask = mask_produce, offset = offset_produce}]

lexerMasks :: ParallelLexer t k -> Either String ParallelLexerMasks
lexerMasks lexer = do
  ms <- parallelLexerToMasks64 lexer
  masks64ToParallelLexerMasks ms

encodeEndoData ::
  Ord k =>
  ParallelLexerMasks ->
  Map (Maybe k) Int ->
  ExtEndoData k ->
  Either String Int
encodeEndoData lexer_masks to_int endo_data = do
  t <- findInt maybe_token 
  encodeMasks64 ms (NonEmpty.fromList [e, t, p])
  where
    ms = parallelLexerMasksToMasks64 lexer_masks
    ExtEndoData
      { endo = e
      , token = maybe_token
      , isProducing = produce
      } = endo_data
    p = fromEnum produce
    findInt = maybeToEither errorMessage . flip Map.lookup to_int

toExtEndoData ::
  (Enum t, Bounded t, IsTransition t, Ord k) =>
  ParallelDFALexer t S k ->
  IntMap ExtEndo ->
  E ->
  Either String (ExtEndoData k)
toExtEndoData lexer to_endo e = do
  (is_producing, s) <- maybeToEither errorMessage $ toState e
  let maybe_token = toToken s
  return $
    ExtEndoData
    { endo = e
    , token = maybe_token
    , isAccepting = s `Set.member` accept_states
    , isProducing = is_producing
    }
  where
    initial_state = initial $ fsa $ parDFALexer lexer
    toState e' = do
      ExtEndo endo' producing <- IntMap.lookup e' to_endo
      let (a, b) = bounds endo'
      unless (a <= initial_state && initial_state <= b) (fail errorMessage)
      pure (producing UArray.! initial_state
           ,endo' UArray.! initial_state)
    token_map = terminalMap $ parDFALexer lexer
    toToken s = Map.lookup s token_map
    accept_states = accepting $ fsa $ parDFALexer lexer

data IntParallelLexer t =
  IntParallelLexer
  { parLexer :: !(ParallelLexer t Int)
  , parMasks :: !ParallelLexerMasks
  } deriving (Show, Eq, Ord)

intParallelLexer ::
  (IsTransition t, Enum t, Bounded t, Ord k, Show k) =>
  Map (Maybe k) Int ->
  ParallelDFALexer t S k ->
  Either String (IntParallelLexer t)
intParallelLexer to_int lexer = do
  parallel_lexer <- parallelLexer lexer
  ms <- lexerMasks parallel_lexer
  let encode = encodeEndoData ms to_int
  new_compositions <- mapM encode $ compositions parallel_lexer
  new_endomorphims <- mapM encode $ endomorphisms parallel_lexer
  new_identity <- encode $ identity parallel_lexer
  let new_parallel_lexer =
        parallel_lexer
        { compositions = new_compositions
        , endomorphisms = new_endomorphims
        , identity = new_identity
        }
  return $
    IntParallelLexer
    { parLexer = new_parallel_lexer
    , parMasks = ms
    }
  
data EndoCtx t k =
  EndoCtx
  { comps :: !(Map (E, E) E)
  , endoMap :: !(Map t E)
  , inverseEndoMap :: !(IntMap t)
  , endoData :: !(IntMap (ExtEndoData k))
  , initialStateCtx :: !S
  , deadStateCtx :: !S
  , connectedMap :: !(IntMap IntSet)
  , inverseConnectedMap :: !(IntMap IntSet)
  , maxE :: !E
  , ecParallelLexer :: !(ParallelDFALexer t S k)
  } deriving (Show, Eq, Ord)

endoInsert ::
  (IsTransition t) =>
  E ->
  t ->
  State (EndoCtx t k) ()
endoInsert e endo = do
  new_inv_map <- IntMap.insert e endo <$> gets inverseEndoMap
  new_map <- Map.insert endo e <$> gets endoMap
  
  modify $
    \s ->
      s { inverseEndoMap = new_inv_map
        , endoMap = new_map }

eLookup :: E -> State (EndoCtx t k) (Maybe t)
eLookup e = IntMap.lookup e <$> gets inverseEndoMap

connectedLookup :: E -> State (EndoCtx t k) (Maybe IntSet)
connectedLookup e = IntMap.lookup e <$> gets connectedMap

connectedUpdate :: E -> IntSet -> State (EndoCtx t k) ()
connectedUpdate e e_set = do
  inv_map <- gets inverseConnectedMap
  new_map <- IntMap.insertWith IntSet.union e e_set <$> gets connectedMap
  let new_inverse_map =
        IntMap.unionWith IntSet.union inv_map
        $ IntMap.fromList
        $ (,IntSet.singleton e) <$> IntSet.toList e_set
  modify $ \s ->
    s { connectedMap = new_map
      , inverseConnectedMap = new_inverse_map }

connectedUpdateAll :: IntMap IntSet -> State (EndoCtx t k) ()
connectedUpdateAll =
  mapM_ (uncurry connectedUpdate) . IntMap.assocs

insertComposition :: E -> E -> E -> State (EndoCtx t k) ()
insertComposition e e' e'' = do
  modify $ \s -> s { comps = Map.insert (e, e') e'' $ comps s }

preSets :: E -> E -> State (EndoCtx t k) (IntMap IntSet)
preSets e'' e = do
  _map <- gets connectedMap
  inv_map <- gets inverseConnectedMap
  let set = IntSet.singleton e''
  return $
    case IntMap.lookup e inv_map of
      Nothing -> error errorMessage -- This should never happen.
      Just _set ->
        if e'' `IntSet.member` _set
        then IntMap.empty
        else  
          IntMap.fromList
          $ (,set) <$> IntSet.toList _set

postSets :: E -> E -> State (EndoCtx t k) (IntMap IntSet)
postSets e'' e' = do
  e_set' <- fromMaybe IntSet.empty <$> connectedLookup e'
  e_set'' <- fromMaybe IntSet.empty <$> connectedLookup e''
  return $ IntMap.singleton e'' (IntSet.difference e_set' e_set'')

endomorphismLookup ::
  (IsTransition t) =>
  t ->
  State (EndoCtx t k) (Maybe E)
endomorphismLookup endomorphism = do
  Map.lookup endomorphism <$> gets endoMap

instance Semigroup ExtEndo where
  (ExtEndo a a') <> (ExtEndo b b') = ExtEndo c c'
    where
      c = UArray.array (0, numElements a - 1)
        $ map auxiliary [0..(numElements a - 1)]
      c' = UArray.array (0, numElements a' - 1)
        $ map auxiliary' [0..(numElements a' - 1)]
      auxiliary i = (i, b UArray.! (a UArray.! i))
      auxiliary' i = (i, b' UArray.! (a UArray.! i))

endoNext :: State (EndoCtx t k) E
endoNext = do
  new_max_e <- succ <$> gets maxE
  modify $ \s -> s { maxE = new_max_e }
  pure new_max_e

endoCompose ::
  (IsTransition t, Semigroup t) =>
  E ->
  E ->
  State (EndoCtx t k) (IntMap IntSet)
endoCompose e e' = do
  maybe_endo <- eLookup e
  maybe_endo' <- eLookup e'
  case (maybe_endo, maybe_endo') of
    (Just endo, Just endo') -> do
      _comps <- gets comps
      case Map.lookup (e, e') _comps of
        Just _ -> return IntMap.empty
        Nothing -> do
          let endo'' = endo <> endo'
          maybe_e'' <- endomorphismLookup endo''
          e'' <- maybe endoNext return maybe_e''
          endoInsert e'' endo''
          insertComposition e e' e''
          pre_sets <- preSets e'' e
          post_sets <- postSets e'' e'
          let new_sets =
                IntMap.unionWith IntSet.union pre_sets post_sets
          connectedUpdateAll new_sets
          return new_sets
    _ -> error errorMessage -- This should never happen.

popElement :: IntMap IntSet -> Maybe ((E, E), IntMap IntSet)
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
  (Semigroup t, IsTransition t) =>
  IntMap IntSet ->
  State (EndoCtx t k) ()
endoCompositionsTable _map =
  case popElement _map of
    Just ((e, e'), map') -> do
      map'' <- endoCompose e e'
      let !map''' = IntMap.unionWith IntSet.union map' map''
      endoCompositionsTable map''' 
    Nothing -> return ()

compositionsTable ::
  (Enum t, Bounded t, IsTransition t, Ord k, Semigroup t) =>
  ParallelDFALexer t S k ->
  Either String (Map ExtEndo (ExtEndoData k)
                ,Map (E, E) (ExtEndoData k))
compositionsTable lexer = do
  a <- to_endo
  b <- _compositions
  return (a, b)
  where
    ctx = initEndoCtx lexer
    toExtEndoData' = toExtEndoData lexer inv_to_endo
    connected_map = connectedMap ctx
    (EndoCtx
      { comps = _compositions'
      , endoMap = to_endo'
      , inverseEndoMap = inv_to_endo'
      }) = execState (endoCompositionsTable connected_map) ctx
    vec_dead = deadExtEndo lexer
    vec_identity = identityExtEndo lexer
    to_endo =
      mapM toExtEndoData'
      $ Map.insert vec_dead _dead
      $ Map.insert vec_identity _identity to_endo'
    inv_to_endo =
      IntMap.insert _dead vec_dead
      $ IntMap.insert _identity vec_identity inv_to_endo'
    _identity =
      case Map.lookup vec_identity to_endo' of
        Nothing -> succ $ maximum to_endo'
        Just a -> a
    _dead =
      case Map.lookup vec_dead to_endo' of
        Nothing -> succ _identity
        Just a -> a
    _compositions =
      mapM toExtEndoData'
      $ addDead _dead
      $ addIdentity _identity _compositions'

endomorphismTable ::
  (Enum t, Bounded t, IsTransition t, IsState s, Ord k) =>
  ParallelDFALexer t s k ->
  Map t ExtEndo
endomorphismTable lexer =
  Map.fromList
  $ map statesFromChar
  $ Set.toList
  $ alphabet dfa
  where
    dfa = fsa $ parDFALexer lexer
    produces_set = producesToken lexer
    states_list = Set.toList $ states dfa
    states_size = Set.size $ states dfa
    state_to_int = Map.fromList $ zip states_list [0..states_size - 1]
    stateToInt = (state_to_int Map.!)
    statesFromChar t = (t, ExtEndo ss bs)
      where
        ss = auxiliary $ stateToInt . uncurry (transition lexer) . (, t)
        bs = auxiliary $ (`Set.member` produces_set) . (, t)
        auxiliary f =
          UArray.array (0, states_size - 1)
          $ zip [0..states_size - 1]
          $ f <$> states_list

connectedTable :: IsTransition t => ParallelDFALexer t S k -> Map t (Set t)
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

enumerate :: Ord a => Set a -> IntMap a
enumerate = IntMap.fromList . zip [0 ..] . Set.toList

invertBijection :: (Ord a, Ord b) => Map a b -> Map b a
invertBijection = Map.fromList . fmap swap . Map.assocs

enumerateByMap :: (Functor f, Ord a) => Map a Int -> f a -> f Int
enumerateByMap _map = fmap (_map Map.!)

enumerateKeysByMap :: Ord a => Map a Int -> Map a b -> Map Int b
enumerateKeysByMap _map = Map.mapKeys (_map Map.!)

intMapToMap :: IntMap a -> Map Int a
intMapToMap = Map.fromList . IntMap.toList

mapToIntMap :: Map Int a -> IntMap a
mapToIntMap = IntMap.fromList . Map.toList

setToIntSet :: Set Int -> IntSet
setToIntSet = IntSet.fromList . Set.toList

enumerateSetMapByMap :: Ord a => Map a Int -> Map a (Set a) -> IntMap IntSet
enumerateSetMapByMap _map =
  mapToIntMap
  . enumerateKeysByMap _map
  . fmap (setToIntSet . enumerateByMap _map)

invertIntSetMap :: IntMap IntSet -> IntMap IntSet 
invertIntSetMap =
  IntMap.unionsWith IntSet.union
  . IntMap.mapWithKey toMap
  where
    toMap k =
      IntMap.fromList
      . fmap (,IntSet.singleton k)
      . IntSet.toList

initEndoCtx ::
  (Enum t, Bounded t, IsTransition t, Ord k) =>
  ParallelDFALexer t S k ->
  (ParallelDFALexer t S k -> t -> ExtEndoData k) ->
  EndoCtx t k
initEndoCtx lexer toData =
  EndoCtx
  { comps = Map.empty
  , endoMap = endo_to_e
  , inverseEndoMap = e_to_endo
  , connectedMap = connected_table
  , inverseConnectedMap = inverse_connected_table
  , maxE = maximum endo_to_e
  , initialStateCtx = initial $ fsa $ parDFALexer lexer
  , deadStateCtx = deadState lexer
  , endoData = endo_data
  , ecParallelLexer = lexer
  }
  where
    alpha = alphabet $ fsa $ parDFALexer lexer
    endo_data =
      mapToIntMap
      $ enumerateKeysByMap endo_to_e
      $ Map.fromList
      $ (\t -> (t, toData lexer t)) <$> Set.toList alpha
    e_to_endo = enumerate alpha
    endo_to_e = invertBijection $ intMapToMap e_to_endo
    connected_table = enumerateSetMapByMap endo_to_e $ connectedTable lexer
    inverse_connected_table = invertIntSetMap connected_table

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
  Map.union table deads
  where
    deads =
      Map.fromList [((q, q'), dead_endo) | q <- endos, q' <- endos]
    endos =
      Set.toList
      $ Set.insert dead_endo
      $ endosInTable table

deadExtEndo ::
  (IsTransition t, Enum t, Bounded t, Ord k) =>
  ParallelDFALexer t S k ->
  ExtEndo
deadExtEndo lexer = ExtEndo s b
  where
    _states = states $ fsa $ parDFALexer lexer
    first_state = minimum _states
    last_state = maximum _states
    dead_state = deadState lexer
    s =
      UArray.array (first_state, last_state)
      $ (,dead_state) <$> [first_state..last_state]
    b =
      UArray.array (first_state, last_state)
      $ (,False) <$> [first_state..last_state]

identityExtEndo ::
  (IsTransition t, Enum t, Bounded t, Ord k) =>
  ParallelDFALexer t S k ->
  ExtEndo
identityExtEndo lexer = ExtEndo s b
  where
    _states = states $ fsa $ parDFALexer lexer
    first_state = minimum _states
    last_state = maximum _states
    s =
      UArray.array (first_state, last_state)
      $ zip [first_state..last_state] [first_state..last_state]
    b =
      UArray.array (first_state, last_state)
      $ (,False) <$> [first_state..last_state]
    
parallelLexer ::
  (IsTransition t, Enum t, Bounded t, Ord k, Show k) =>
  ParallelDFALexer t S k ->
  Either String (ParallelLexer t (ExtEndoData k))
parallelLexer lexer = do
  (to_endo, _compositions) <- compositionsTable lexer
  let endo_size = Map.size to_endo
  let toEndo x = maybeToEither errorMessage $ Map.lookup x to_endo
  dead_e <- toEndo $ deadExtEndo lexer
  identity_e <- toEndo $ identityExtEndo lexer
  let _unknown_transitions =
        Map.fromList
        $ map (,dead_e) [minBound..maxBound]
  _transitions_to_endo <-
        fmap (`Map.union` _unknown_transitions)
        $ mapM toEndo
        $ endomorphismTable lexer
  return
    $ ParallelLexer
    { compositions = _compositions
    , endomorphisms = _transitions_to_endo
    , identity = identity_e
    , endomorphismsSize = endo_size
    }
