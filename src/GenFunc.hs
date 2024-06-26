module GenFunc where

import Common
import CommonGen
import Control.Applicative         ((<|>))
import Control.Monad
import Control.Monad.Trans.State
import Data.IntMap                 qualified as IntMap
import Data.Maybe                  (fromJust)
import Data.Traversable
import Data.Vector                 qualified as V
import GenVectorizable
import Language.C.Data.Ident
import Language.C.Data.Node        (undefNode)
import Language.C.Data.Position    (nopos)
import Language.C.Syntax.AST
import Language.C.Syntax.Constants

{-
Goal:
  - Create functions f1..fn based on #noOfFunctions
  - Each function defines:
  -      - Function parameters <=> Array Specification.
           - We can do it after constructing the block.
           - i.e. Keep a map for the function parameters and build over it.
           - Use it to create the function signature and clear it.
  -      - c Index Variables (stack allocated)
  -          c = arrays * dims[i]
  -      - b Scalars (stack allocated)
  -      - a Arrays (heap allocated) + initialization to random values
           - Multidimensional arrays must be allocated with nested for loops.
  - TODO:
    1. flattened arrays => Use 1D arrays with row major indexing.
-}


{-
   Generate a function call block as:
   ```
   {
      int p1, ..., pn;
      scanf("%d %d .. %d", &p1, ..., &pn);
      fm(p1, ..., pn);
   }
   ```
-}
genFuncCallBlock :: StdFunctions -> Ident -> Parameters -> GState CStat
genFuncCallBlock stdFunctionIdents fnIdent params = do
  let argumentIdents = IntMap.elems params
  decls :: [CBlockItem] <- ((CBlockDecl <$>) <$>) . for argumentIdents $ \pIdent -> do
    pure $ constructSingleton pIdent DInt Nothing
  let
    -- Call to scanf
    scanfCall :: CBlockItem = CBlockStmt  . flip CExpr undefNode . Just $ constructScanf stdFunctionIdents argumentIdents
    -- Function call
    fnCall :: CBlockItem = CBlockStmt . flip CExpr undefNode . Just $
      CCall (CVar fnIdent undefNode) (flip CVar undefNode <$> argumentIdents) undefNode
  -- reset singletons
  modify' (\s -> s { singletons = mempty })
  pure $ CCompound [] (decls ++ [scanfCall, fnCall]) undefNode

genFunc :: GState CFunDef
genFunc = do
    cNameId <- getId
    key <- gets (IntMap.size . functions)

    -- Generate the body
    body <- genFuncBody
    params <- gets parameters
    let
        name = "f" ++ show key
        ident = mkIdent nopos name cNameId
        funcDef = constructFunc ident params body

    -- Remove the local scope
    popFunctionScope key ident
    pure funcDef

constructFunc :: Ident -> Parameters -> CStat -> CFunDef
constructFunc ident params body =
    CFunDef
     -- Return type
     [CTypeSpec (CVoidType undefNode)] -- Void return type
     -- Declarator
     (CDeclr
        -- Identifier
        (Just ident)
        -- Function Declarator Specifier
        [ CFunDeclr
            ( Right
                (
                  -- Parameters
                  constructParams params
                  -- IsVariadic
                , False
                )
            ) []
            undefNode
        ]
        Nothing
        -- CAttributes: Not necessary for us
        []
        undefNode
     )
     []
     body
     undefNode

constructParams :: Parameters -> [CDecl]
constructParams params = (\ident -> constructSingleton ident DInt Nothing) <$> IntMap.elems params

genFuncBody :: GState CStat
genFuncBody = do
  stdFunctionIdents <- gets stdFunctions
  -- Random seed: srand
  srandStat <- CBlockStmt <$> genSRand
  -- For each type:
  targetDTypeValues <- gets targetDTypes
  declAndInitStats :: [CBlockItem] <- fmap concat . for targetDTypeValues $ \dtype -> do
    -- Generate Singletons
    nSingletons <- gets noOfSingletonRange >>= execRandGen
    singletonDecls :: [CBlockItem] <- (CBlockDecl <$>) <$> genSingletons dtype nSingletons
    -- Generate Arrays
    nArrays <- gets noOfArrayRange >>= execRandGen
    dims <- gets maxDims >>= (\x -> replicateM nArrays $ execRandGen (1,x))
    (arrKeys, arrDecls) :: ([Int], [CBlockItem]) <- fmap (CBlockDecl <$>) . unzip <$> genHeapArrays dtype dims
    -- Generate Indexes
    --    = Number of dimensions of all the arrays
    let nIndexVars = sum dims
    indexDecls :: [CBlockItem] <- (CBlockDecl <$>) <$> genIndexVars nIndexVars
    -- Allocate memory for arrays
    allocAndInit ::  [CBlockItem] <- (concat <$>) . for arrKeys $ fmap (CBlockStmt <$>) . genAllocateAndInitialize dtype
    pure $ singletonDecls ++ arrDecls ++ indexDecls ++ allocAndInit
  nLoops <- gets noLoopRange >>= execRandGen
  nHVars <- gets ((2*) . snd . nestedLoopRange)
  hoistedVarDecls :: [CBlockItem] <- (CBlockDecl <$>) <$> genHoistedVars nHVars
  execTimeDecl :: CBlockItem <- do
    ident <- createIdent "exec_time"
    pure . CBlockDecl $ constructSingleton ident DDouble Nothing
  indexDecl :: CBlockItem <- do
    pure . CBlockDecl $ constructSingleton (stdFuncIdents V.! fromEnum Ii) DInt Nothing
  body :: [CBlockItem] <- fmap concat . replicateM nLoops $ do
    noNestedFor <- gets nestedLoopRange >>= execRandGen
    targetStat <- genFor noNestedFor
    wrappedTargetStatWithTime <- genWrappedTimeWithClock stdFunctionIdents [CBlockStmt targetStat]
    effectfulStats :: [CStat] <- do
      usedExpressions <- gets expressionBucket
      res :: [CStat] <- for usedExpressions $ \expr -> do
        pure . flip CExpr undefNode . Just $ constructPrintf stdFuncIdents "%d, " [expr]
      modify' $ \s -> s { expressionBucket = [] }
      pure res
    do repeatFactor' <- gets repeatFactor
       let indexExpr :: CExpr = CVar (stdFuncIdents V.! fromEnum Ii) undefNode
           printIndexOfTheRepeatLoop :: CStat =
             flip CExpr undefNode . Just $ constructPrintf stdFuncIdents "\n%d: " [indexExpr]
           -- printCurrentExecTime :: CStat =
           --   flip CExpr undefNode . Just $
           --     constructFprintf (stdFuncIdents V.! fromEnum CStderr)
           --     stdFunctionIdents "Execution Time of the loop: %lf\n"
           --     [CVar (stdFuncIdents V.! fromEnum IExecTime) undefNode]
           ifCond :: CExpr =
             CBinary
                CEqOp
                (CBinary
                  CRmdOp
                  (flip CVar undefNode $ stdFunctionIdents V.! fromEnum Ii)
                  (flip CVar undefNode $ stdFunctionIdents V.! fromEnum MEFFECT_MOD)
                  undefNode
                )
                (constructConstExpr 0)
                undefNode
           res =   printIndexOfTheRepeatLoop
                 : effectfulStats
           wrappedIf :: CStat = CIf ifCond (CCompound [] (CBlockStmt <$> res) undefNode) Nothing undefNode
       genRepeatedStatement repeatFactor' "Execution Time of the loop: %lf\n" $
         CCompound [] (wrappedTargetStatWithTime ++ [CBlockStmt wrappedIf]) undefNode

  -- timeWrappedDeclAndInitStats :: [CBlockItem] <-
  --   genWrappedTime stdFunctionIdents "Execution Time of declaration and initialization: %lf\n" declAndInitStats
  -- Define a hoisted Variable
  pure $ CCompound [] ([srandStat, execTimeDecl, indexDecl] ++ declAndInitStats ++ hoistedVarDecls ++ body) undefNode

-- Description: Allocates memory and initializes the ith array with the given dtype.
-- Effectful: Update parameters and array dims if applicable (Nothing -> Just <ident>)
genAllocateAndInitialize :: DType -> Int -> GState [CStat]
genAllocateAndInitialize dtype key = do
  -- We know if an array as d non-constant size dimensions, then
  -- we will need to have d parameters that map to those dimensions
  arrSpec@(arrIdent, dims) <- gets ((IntMap.! key) . (V.! fromEnum dtype) . mDimArrs)
  paramIdents :: [Maybe Ident] <- for dims $ \d -> do
    -- Effectful: Updates parameters
    case d of
      Left _ -> pure Nothing
      Right Nothing -> do
          cNameId <- getId
          nParam <- gets (length . parameters)
          let name = "p" ++ show nParam
              pIdent = mkIdent nopos name cNameId
          updateParams nParam pIdent
          pure $ Just pIdent
      Right (Just _) -> error "Partially defined Array." -- should not be the case, since at this point any heap allocated does not have param ids
  let dims' = zipWith (\pIdent dim -> fmap (pIdent <|>) dim) paramIdents dims
  -- Update the dimensions of the array
  updateArrs dtype key (dims' <$ arrSpec)
  -- Choose indexes
  indexes <- gets (take (length dims') . IntMap.elems . indexVars)
  stdFunctionIdents <- gets stdFunctions
  pure $ constructAllocateAndInitialize stdFunctionIdents dtype (CVar arrIdent undefNode) (zip indexes dims')

-- Arguments:
--  (1) DType
--  (2) partialArrExpr => <id>[.]..[.] with (k < d) index ops
--  (3) [(Index identifiers, dimension specification)]
constructAllocateAndInitialize :: StdFunctions -> DType -> CExpr -> [(Ident, DimSpec)] -> [CStat]
-- This case should never occur, since an array must have at least 1 dimension
constructAllocateAndInitialize _ _ _ [] = error "Dimension-less array."
-- This case can't happen either, since each dimension should have an associated size at this point
constructAllocateAndInitialize _ _ _ ((_, Right Nothing):_) = error "A dimension of the array does not have an associated size."
constructAllocateAndInitialize stdFunctionIdents dtype partialArrExpr [(indexIdent, dimSpec)] =
  let
    -- 1. Allocate space for the type:
    --    - i.e. <id>((d-1)-dimensional access) = malloc(sizeof (<type>) * <dim-size>);
    allocLhs = partialArrExpr
    -- Here fromJust is safe
    allocRhs = constructMalloc stdFunctionIdents (Just dtype) (fromJust <$> dimSpec)
    allocStat :: CStat = flip CExpr undefNode . Just $ CAssign CAssignOp allocLhs allocRhs undefNode
    -- 2. Assign values to the array
    --    i.e. construct a for loop with `indexIdent` and assign values
    -- initExpr: <index-ident> = 0
    indexExpr = CVar indexIdent undefNode
    initExpr :: CExpr = CAssign CAssignOp indexExpr (constructConstExpr 0) undefNode
    conditionExpr :: CExpr =
      let
        condLhs = indexExpr
        condRhs =
          case dimSpec of
            Left intLiteral    -> constructConstExpr $ fromIntegral intLiteral
            Right (Just ident) -> CVar ident undefNode
      in CBinary CLeOp condLhs condRhs undefNode
    updateExpr :: CExpr = CUnary CPostIncOp indexExpr undefNode
    assignStat =
      let
        assignLhs :: CExpr = CIndex partialArrExpr indexExpr undefNode
        assignRhs :: CExpr = constructRandomValue stdFunctionIdents dtype
      in flip CExpr undefNode . Just $ CAssign CAssignOp assignLhs assignRhs undefNode
    assignFor :: CStat =
      CFor (Left (Just initExpr)) -- init
        (Just conditionExpr) -- condition
        (Just updateExpr) -- update
        assignStat -- Assign
        undefNode
  in [allocStat, assignFor]

constructAllocateAndInitialize stdFunctionIdents dtype partialArrExpr ((indexIdent, dimSpec):rest) =
  let
    -- 1. Allocate space for the pointer to array:
    --    - i.e. <id>((d-1)-dimensional access) = malloc(sizeof (<type>) * <dim-size>);
    allocLhs = partialArrExpr
    -- Here fromJust is safe
    allocRhs = constructMalloc stdFunctionIdents Nothing (fromJust <$> dimSpec)
    allocStat :: CStat = flip CExpr undefNode . Just $ CAssign CAssignOp allocLhs allocRhs undefNode
    -- 2. Loop over the next dimension
    --    - i.e. construct a for loop with `indexIdent` and recurse with updated partialArrExpr
    indexExpr = CVar indexIdent undefNode
    initExpr :: CExpr = CAssign CAssignOp indexExpr (constructConstExpr 0) undefNode
    conditionExpr :: CExpr =
      let
        condLhs = indexExpr
        condRhs =
          case dimSpec of
            Left intLiteral    -> constructConstExpr $ fromIntegral intLiteral
            Right (Just ident) -> CVar ident undefNode
      in CBinary CLeOp condLhs condRhs undefNode
    updateExpr :: CExpr = CUnary CPostIncOp indexExpr undefNode
    partialArrExpr' = CIndex partialArrExpr indexExpr undefNode
    blockStat :: CStat =
      CCompound []
      (CBlockStmt <$> constructAllocateAndInitialize stdFunctionIdents dtype partialArrExpr' rest)
      undefNode
    assignFor :: CStat =
      CFor (Left (Just initExpr)) -- init
        (Just conditionExpr) -- condition
        (Just updateExpr) -- update
        blockStat -- block
        undefNode
  in [allocStat, assignFor]


-- Construct a malloc call
-- If mDtype is Nothing then it allocates with the size of of a void pointer
constructMalloc :: StdFunctions -> Maybe DType -> Either Int Ident -> CExpr
constructMalloc stdFunctionIdents mDtype eSize =
  let mallocIdent = stdFunctionIdents V.! fromEnum CMalloc
      lhs = constructSizeOf mDtype
      rhs =
        case eSize of
          Left intLiteral -> constructConstExpr $ fromIntegral intLiteral
          Right ident     -> CVar ident undefNode
      expr = CBinary CMulOp lhs rhs undefNode
  in CCall (CVar mallocIdent undefNode) [expr] undefNode

constructScanf :: StdFunctions -> [Ident] -> CExpr
constructScanf stdFunctionIdents varIdents =
  let scanfIdent :: Ident = stdFunctionIdents V.! fromEnum CScanf
      formatStringExpr :: CExpr = CConst . flip CStrConst undefNode . cString . unwords $ replicate (length varIdents) "%d"
      arguments :: [CExpr] = flip (CUnary CAdrOp) undefNode . flip CVar undefNode <$> varIdents
  in CCall (CVar scanfIdent undefNode) (formatStringExpr:arguments) undefNode


-- Well it is not guaranteed by the C standard that all pointer sizes are equal,
-- but in most modern system all pointer sizes are usually equal. So, for
-- simplicity we consider all pointer size to be equal to sizeof (void *)
constructSizeOf :: Maybe DType -> CExpr
constructSizeOf mDtype = CSizeofType (mDtypeToCTypeDecl mDtype) undefNode

{-
   Generates the code equivalent to the following:
   {
      struct timeval start, end;
      gettimeofday(&start, 0);
      <stmt>
      gettimeofday(&end, 0);
      double elapsed = ((end.tv_sec*1e6 + end.tv_usec) - (start.tv_sec*1e6 + start.tv_usec)) / 1e6;
      printf("Time: %lf\n", elapsed);
   }
   // or
   {
      clock_t start, end;
      start = clock()
      <stmt>
      end = clock()
      double elapsed = ((double) (end - start)) / CLOCKS_PER_SEC;
      printf("Time: %lf\n", elapsed);
   }
-}


genWrappedTime :: StdFunctions -> String -> [CBlockItem] -> GState [CBlockItem]
genWrappedTime stdFunctionIdents formatString targetItems = do
  -- C: struct timeval start<n>, end<n>;
  startIdent <- gets nId >>= \n -> createIdent ("start" ++ show n)
  endIdent <- gets nId >>= \n -> createIdent ("end" ++ show n)
  tvSecIdent <- createIdent "tv_sec"
  tvUsecIdent <- createIdent "tv_usec"
  let
    startDecl :: CDecl = constructTimeValDecl stdFunctionIdents startIdent
    endDecl :: CDecl = constructTimeValDecl stdFunctionIdents endIdent
    -- C: gettimeofday(&start, 0);
    gettimeofdayStartExpr :: CExpr = constructGetTimeOfDay stdFunctionIdents startIdent
    -- C: gettimeofday(&end, 0);
    gettimeofdayEndExpr :: CExpr = constructGetTimeOfDay stdFunctionIdents endIdent
    -- C: ((end.tv_sec*1e6 + end.tv_usec) - (start.tv_sec*1e6 + start.tv_usec)) / 1e6;
    --      --- expr1 ----                   ---- expr2 -----
    --      ----------- expr3 ----------     ------------- expr4 ------------
    --      ----------------------------- expr5 -------------------------------
    --      --------------------------------- expr6 ---------------------------------
    computeElapsedTimeExpr :: CExpr =
      let
        const1MExpr :: CExpr = CConst (CFloatConst (cFloat 1e6) undefNode)
        accessEndTvSecExpr :: CExpr =
          CMember (CVar endIdent undefNode) tvSecIdent False undefNode
        accessEndTvUsecExpr :: CExpr =
          CMember (CVar endIdent undefNode) tvUsecIdent False undefNode
        accessStartTvSecExpr :: CExpr =
          CMember (CVar startIdent undefNode) tvSecIdent False undefNode
        accessStartTvUsecExpr :: CExpr =
          CMember (CVar startIdent undefNode) tvUsecIdent False undefNode
        expr1 :: CExpr = CBinary CMulOp accessEndTvSecExpr const1MExpr undefNode
        expr3 :: CExpr = CBinary CAddOp expr1 accessEndTvUsecExpr undefNode
        expr2 :: CExpr = CBinary CMulOp accessStartTvSecExpr const1MExpr undefNode
        expr4 :: CExpr = CBinary CAddOp expr2 accessStartTvUsecExpr undefNode
        expr5 :: CExpr = CBinary CSubOp expr3 expr4 undefNode
        expr6 :: CExpr = CBinary CDivOp expr5 const1MExpr undefNode
       in expr6
  pure $
      [ -- start decl
        CBlockDecl startDecl
        -- end decl
      , CBlockDecl endDecl
        -- populate start
      , CBlockStmt $ CExpr (Just gettimeofdayStartExpr) undefNode
        -- evaluate statement that's being measured
      ]
      ++ targetItems ++
      [ -- populate end
        CBlockStmt $ CExpr (Just gettimeofdayEndExpr) undefNode
        -- printf elapsed time
      , CBlockStmt $ CExpr (Just $ constructFprintf (stdFuncIdents V.! fromEnum CStderr) stdFunctionIdents formatString [computeElapsedTimeExpr]) undefNode
      ]

genWrappedTimeWithClock :: StdFunctions -> [CBlockItem] -> GState [CBlockItem]
genWrappedTimeWithClock stdFunctionIdents targetItems = do
  startIdent <- gets nId >>= \n -> createIdent ("start" ++ show n)
  endIdent <- gets nId >>= \n -> createIdent ("end" ++ show n)
  let
    startDecl :: CDecl = constructClockTDecl stdFunctionIdents startIdent
    endDecl :: CDecl = constructClockTDecl stdFunctionIdents endIdent
    clockStartAssign :: CStat = constructClockCallStat stdFunctionIdents startIdent
    clockEndAssign :: CStat = constructClockCallStat stdFunctionIdents endIdent
    -- ((double) (end - start)) / CLOCKS_PER_SEC
    --            -- expr1 --     --- expr2 ----
    --  ------- expr3 --------
    computeElapsedTimeExpr :: CExpr =
      let expr1 :: CExpr =
            CBinary CSubOp
              (CVar endIdent undefNode)
              (CVar startIdent undefNode)
              undefNode
          expr2 :: CExpr = CVar (stdFunctionIdents V.! fromEnum CCLOCKS_PER_SEC) undefNode
          expr3 :: CExpr = CCast (mDtypeToCTypeDecl (Just DDouble)) expr1 undefNode
      in CBinary CDivOp expr3 expr2 undefNode
    execTimeIdentExpr :: CExpr = CVar (stdFuncIdents V.! fromEnum IExecTime) undefNode
    addToExecTime :: CExpr =
      CAssign CAddAssOp execTimeIdentExpr computeElapsedTimeExpr undefNode
  pure $
    [
      CBlockDecl startDecl
    , CBlockDecl endDecl
    , CBlockStmt clockStartAssign
    ]
    ++ targetItems ++
    [
      CBlockStmt clockEndAssign
    , CBlockStmt . flip CExpr undefNode . Just $ addToExecTime
    ]
