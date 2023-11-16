module Selectors where

import           Common
import           Control.Monad.Trans.State
import qualified Data.IntMap               as IntMap
import qualified Data.Vector               as V
import           Language.C.Data.Ident

{-
   Activates an index variable from the IndexVars list
    - Activates = assigns (start, end, stride)
    - The values of the parameter is either:
        - (1) Integer Literal (TODO)
              - start: [0, 10] -- Can be Uniform
              - end: [10, 10_000] -- TODO: Would want to use a skewed-left RV
              - stride: [1, 5] -- Can be Uniform
        - (2) Scalar Identifier (TODO)
              - start: [Index, ?]
              - end: [dimension sizes]
              - stride: [Index, ?]
-}
activateIndexVar :: GState (Int, ActiveIndexVar)
activateIndexVar = do
    (key, ident) <- gets indexVars >>= chooseKeyFromMap
    -- Remove index from index variable list
    modify' (\s -> s { indexVars = IntMap.delete key (indexVars s) } )
    -- TODO: Currently just doing (1)
    startVal <- execRandGen (0, 10)
    endVal <- execRandGen (10, 10_000)
    strideVal <- execRandGen (1, 5)
    let activeIndexVar = ActiveIndexVar ident (Left startVal) (Left endVal) (Left strideVal)
    -- Add it to the active index variable list
    modify' (\s -> s { activeIndexes = IntMap.insert key activeIndexVar (activeIndexes s) } )
    pure (key, activeIndexVar)


deactiveIndexVar :: Int -> GState ()
deactiveIndexVar key = do
    ident <- gets (activeIndexIdent . (IntMap.! key) . activeIndexes)
    -- Remove the active index variable from the active list
    modify' (\s -> s { activeIndexes = IntMap.delete key (activeIndexes s) } )
    -- Add it back to the index variable list
    updateIndexes key ident


chooseKeyFromMap :: IntMap.IntMap a -> GState (Int, a)
chooseKeyFromMap m = do
    let keys :: V.Vector Int = V.fromList $ IntMap.keys m
    i <- execRandGen (0, V.length keys - 1)
    let k = keys V.! i
    pure (k, m IntMap.! k)

chooseSingleton :: DType -> GState Ident
chooseSingleton dtype = do
    (_, ident) <- gets ((V.! fromEnum dtype) . singletons) >>= chooseKeyFromMap
    pure ident

chooseArray :: DType -> GState ArrSpec
chooseArray dtype = do
    (_, arrSpec) <- gets ((V.! fromEnum dtype) . mDimArrs) >>= chooseKeyFromMap
    pure arrSpec

chooseActiveIndex :: GState ActiveIndexVar
chooseActiveIndex = do
    (_, activeIndexVar) <- gets activeIndexes >>= chooseKeyFromMap
    pure activeIndexVar

chooseFromList :: [a] -> GState a
chooseFromList xs = (xs !!) <$> execRandGen(0, length xs - 1) -- TODO: distribution


-- chooseFromVMap :: (SProg -> Map.Map k (a,b)) -> GState a
-- chooseFromVMap f = do
--   mp <- f <$> get
--   let n = Map.size mp
--   i <- execRandGen (0, n-1)
--   pure . fst . snd $ Map.elemAt i mp
