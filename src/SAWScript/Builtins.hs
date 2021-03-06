{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE DoAndIfThenElse #-}

{- |
Module           : $Header$
Description      :
License          : Free for non-commercial use. See LICENSE.
Stability        : provisional
Point-of-contact : atomb
-}
module SAWScript.Builtins where

import Data.Foldable (toList)
#if !MIN_VERSION_base(4,8,0)
import Data.Functor
import Control.Applicative
#endif
import Control.Lens
import Control.Monad.State
import qualified Data.ByteString.Lazy as BS
import Data.List (isPrefixOf)
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Vector as V
import System.CPUTime
import System.Directory
import qualified System.Exit as Exit
import System.IO
import System.IO.Temp (withSystemTempFile)
import System.Process
import Text.Printf (printf)
import Text.Read


import qualified Verifier.Java.Codebase as JSS
import qualified Verifier.SAW.Cryptol as Cryptol

import Verifier.SAW.Constant
import Verifier.SAW.ExternalFormat
import Verifier.SAW.FiniteValue ( FiniteType(..), FiniteValue(..)
                                , scFiniteValue, fvVec, readFiniteValues, readFiniteValue
                                , finiteTypeOf, asFiniteTypePure, sizeFiniteType
                                )
import Verifier.SAW.Prelude
import Verifier.SAW.PrettySExp
import Verifier.SAW.SCTypeCheck
import Verifier.SAW.SharedTerm
import qualified Verifier.SAW.Simulator.Concrete as Concrete
import Verifier.SAW.Recognizer
import Verifier.SAW.Rewriter
import Verifier.SAW.Testing.Random (scRunTestsTFIO, scTestableType)
import Verifier.SAW.TypedAST hiding (instantiateVarList)

import qualified SAWScript.SBVParser as SBV
import SAWScript.ImportAIG

import SAWScript.AST (getVal, pShow)
import SAWScript.Options
import SAWScript.Proof
import SAWScript.TopLevel
import SAWScript.TypedTerm
import SAWScript.Utils
import qualified SAWScript.Value as SV

import qualified Verifier.SAW.Cryptol.Prelude as CryptolSAW
import qualified Verifier.SAW.Simulator.BitBlast as BBSim
import qualified Verifier.SAW.Simulator.SBV as SBVSim

import qualified Data.ABC as ABC
import qualified Data.SBV.Dynamic as SBV

import qualified Data.ABC.GIA as GIA
import qualified Data.AIG as AIG

import qualified Cryptol.TypeCheck.AST as C
import qualified Cryptol.Eval.Value as C
import Cryptol.Utils.PP (pretty)

data BuiltinContext = BuiltinContext { biSharedContext :: SharedContext SAWCtx
                                     , biJavaCodebase  :: JSS.Codebase
                                     }

definePrim :: String -> TypedTerm SAWCtx -> TopLevel (TypedTerm SAWCtx)
definePrim name (TypedTerm schema rhs) = do
  sc <- getSharedContext
  t <- io $ scConstant sc name rhs
  return $ TypedTerm schema t

sbvUninterpreted :: String -> SharedTerm SAWCtx -> TopLevel (Uninterp SAWCtx)
sbvUninterpreted s t = return $ Uninterp (s, t)

readBytes :: FilePath -> TopLevel (TypedTerm SAWCtx)
readBytes path = do
  sc <- getSharedContext
  content <- io $ BS.readFile path
  let len = BS.length content
  let bytes = BS.unpack content
  e <- io $ scBitvector sc 8
  xs <- io $ mapM (scBvConst sc 8 . toInteger) bytes
  trm <- io $ scVector sc e xs
  let schema = C.Forall [] [] (C.tSeq (C.tNum len) (C.tSeq (C.tNum (8::Int)) C.tBit))
  return (TypedTerm schema trm)

readSBV :: FilePath -> [Uninterp SAWCtx] -> TopLevel (TypedTerm SAWCtx)
readSBV path unintlst =
    do sc <- getSharedContext
       opts <- getOptions
       pgm <- io $ SBV.loadSBV path
       let schema = C.Forall [] [] (toCType (SBV.typOf pgm))
       trm <- io $ SBV.parseSBVPgm sc (\s _ -> Map.lookup s unintmap) pgm
       when (extraChecks opts) $ do
         tcr <- io $ scTypeCheck sc trm
         case tcr of
           Left err ->
             io $ putStr $ unlines $
             ("Type error reading " ++ path ++ ":") : prettyTCError err
           Right _ -> return () -- TODO: check that it matches 'schema'?
       return (TypedTerm schema trm)
    where
      unintmap = Map.fromList $ map getUninterp unintlst

      toCType :: SBV.Typ -> C.Type
      toCType typ =
        case typ of
          SBV.TBool      -> C.tBit
          SBV.TFun t1 t2 -> C.tFun (toCType t1) (toCType t2)
          SBV.TVec n t   -> C.tSeq (C.tNum n) (toCType t)
          SBV.TTuple ts  -> C.tTuple (map toCType ts)
          SBV.TRecord bs -> C.tRec [ (C.Name n, toCType t) | (n, t) <- bs ]


-- | The 'AIG.Proxy' used by SAWScript.
sawProxy :: AIG.Proxy GIA.Lit GIA.GIA
sawProxy = GIA.proxy

-- | Use ABC's 'dsec' command to equivalence check to terms
-- representing SAIGs. Note that nothing is returned; you must read
-- the output to see what happened.
--
-- TODO: this is a first version. The interface can be improved later,
-- but I don't want too worry to much about generalization before I
-- have more examples. It might be an improvement to take SAIGs as
-- arguments, in the style of 'cecPrim' below. This would require
-- support for latches in the 'AIGNetwork' SAWScript type.
dsecPrint :: SharedContext s -> TypedTerm s -> TypedTerm s -> IO ()
dsecPrint sc t1 t2 = do
  withSystemTempFile ".aig" $ \path1 _handle1 -> do
  withSystemTempFile ".aig" $ \path2 _handle2 -> do
  writeSAIGInferLatches sc path1 t1
  writeSAIGInferLatches sc path2 t2
  callCommand (abcDsec path1 path2)
  where
    -- The '-w' here may be overkill ...
    abcDsec path1 path2 = printf "abc -c 'read %s; dsec -v -w %s;'" path1 path2

cecPrim :: AIGNetwork -> AIGNetwork -> TopLevel SV.ProofResult
cecPrim x y = do
  io $ verifyAIGCompatible x y
  res <- io $ ABC.cec x y
  case res of
    ABC.Valid -> return $ SV.Valid
    ABC.Invalid bs
      | Just ft <- readFiniteValue (FTVec (fromIntegral (length bs)) FTBit) bs ->
           return $ SV.Invalid ft
      | otherwise -> fail "cec: impossible, could not parse counterexample"
    ABC.VerifyUnknown -> fail "cec: unknown result "

loadAIGPrim :: FilePath -> TopLevel AIGNetwork
loadAIGPrim f = do
  exists <- io $ doesFileExist f
  unless exists $ fail $ "AIG file " ++ f ++ " not found."
  et <- io $ loadAIG f
  case et of
    Left err -> fail $ "Reading AIG failed: " ++ err
    Right ntk -> return ntk

-- | Tranlsate a SAWCore term into an AIG
bitblastPrim :: SharedContext s -> TypedTerm s -> IO AIGNetwork
bitblastPrim sc tt = do
  t' <- rewriteEqs sc tt
  let s = ttSchema t'
  case s of
    C.Forall [] [] _ -> return ()
    _ -> fail $ "Attempting to bitblast a term with a polymorphic type: " ++ pretty s
  BBSim.withBitBlastedTerm sawProxy sc (ttTerm t') $ \be ls -> do
    return (AIG.Network be (toList ls))

-- | Read an AIG file representing a theorem or an arbitrary function
-- and represent its contents as a @SharedTerm@ lambda term. This is
-- inefficient but semantically correct.
readAIGPrim :: FilePath -> TopLevel (TypedTerm SAWCtx)
readAIGPrim f = do
  sc <- getSharedContext
  exists <- io $ doesFileExist f
  unless exists $ fail $ "AIG file " ++ f ++ " not found."
  et <- io $ readAIG sc f
  case et of
    Left err -> fail $ "Reading AIG failed: " ++ err
    Right t -> io $ mkTypedTerm sc t

replacePrim :: TypedTerm SAWCtx
            -> TypedTerm SAWCtx
            -> TypedTerm SAWCtx
            -> TopLevel (TypedTerm SAWCtx)
replacePrim pat replace t = do
  sc <- getSharedContext

  let tpat  = ttTerm pat
  let trepl = ttTerm replace

  let fvpat = looseVars tpat
  let fvrepl = looseVars trepl

  unless (fvpat == 0) $ fail $ unlines
    [ "pattern term is not closed", show tpat ]

  unless (fvrepl == 0) $ fail $ unlines
    [ "replacement term is not closed", show trepl ]

  io $ do
    ty1 <- scTypeOf sc tpat
    ty2 <- scTypeOf sc trepl
    c <- scConvertable sc False ty1 ty2
    unless c $ fail $ unlines
      [ "terms do not have convertable types", show tpat, show ty1, show trepl, show ty2 ]

  let ss = emptySimpset
  t' <- io $ replaceTerm sc ss (tpat, trepl) (ttTerm t)

  io $ do
    ty  <- scTypeOf sc (ttTerm t)
    ty' <- scTypeOf sc t'
    c' <- scConvertable sc False ty ty'
    unless c' $ fail $ unlines
      [ "term does not have the same type after replacement", show ty, show ty' ]

  return t{ ttTerm = t' }


hoistIfsPrim :: TypedTerm SAWCtx
             -> TopLevel (TypedTerm SAWCtx)
hoistIfsPrim t = do
  sc <- getSharedContext
  t' <- io $ hoistIfs sc (ttTerm t)

  io $ do
    ty  <- scTypeOf sc (ttTerm t)
    ty' <- scTypeOf sc t'
    c' <- scConvertable sc False ty ty'
    unless c' $ fail $ unlines
      [ "term does not have the same type after hoisting ifs", show ty, show ty' ]

  return t{ ttTerm = t' }



checkConvertablePrim :: TypedTerm SAWCtx
                     -> TypedTerm SAWCtx
                     -> TopLevel ()
checkConvertablePrim x y = do
   sc <- getSharedContext
   io $ do
     c <- scConvertable sc False (ttTerm x) (ttTerm y)
     if c
       then putStrLn "Convertable"
       else putStrLn "Not convertable"

{-
-- | Apply some rewrite rules before exporting, to ensure that terms
-- are within the language subset supported by formats such as SMT-Lib
-- QF_AUFBV or AIG.
prepForExport :: SharedContext s -> SharedTerm s -> IO (SharedTerm s)
prepForExport sc t = do
  let eqs = map (mkIdent preludeName) [ "eq_Bool"
                                      , "at_single"
                                      , "bvNat_bvToNat"
                                      , "equalNat_bv"
                                      ]
      defs = map (mkIdent (moduleName javaModule))
                 [ "ecJoin", "ecJoin768", "ecSplit", "ecSplit768"
                 , "ecExtend", "longExtend"
                 ] ++
             map (mkIdent (moduleName llvmModule))
                 [ "trunc31" ] ++
             map (mkIdent preludeName)
                 [ "splitLittleEndian", "joinLittleEndian", "finEq" ]
  rs1 <- concat <$> traverse (defRewrites sc) defs
  rs2 <- scEqsRewriteRules sc eqs
  basics <- basic_ss sc
  let ss = addRules (rs1 ++ rs2) basics
  rewriteSharedTerm sc ss t
-}

-- | Write a @SharedTerm@ representing a theorem or an arbitrary
-- function to an AIG file.
writeAIG :: SharedContext s -> FilePath -> TypedTerm s -> IO ()
writeAIG sc f t = do
  aig <- bitblastPrim sc t
  ABC.writeAiger f aig

-- | Like @writeAIG@, but takes an additional 'Integer' argument
-- specifying the number of input and output bits to be interpreted as
-- latches. Used to implement more friendly SAIG writers
-- @writeSAIGInferLatches@ and @writeSAIGComputedLatches@.
writeSAIG :: SharedContext s -> FilePath -> TypedTerm s -> Int -> IO ()
writeSAIG sc file tt numLatches = do
  aig <- bitblastPrim sc tt
  GIA.writeAigerWithLatches file aig numLatches

-- | Given a term a type '(i, s) -> (o, s)', call @writeSAIG@ on term
-- with latch bits set to '|s|', the width of 's'.
writeSAIGInferLatches :: forall s.
  SharedContext s -> FilePath -> TypedTerm s -> IO ()
writeSAIGInferLatches sc file tt = do
  ty <- scTypeOf sc (ttTerm tt)
  s <- getStateType ty
  let numLatches = sizeFiniteType s
  writeSAIG sc file tt numLatches
  where
    die :: Monad m => String -> m a
    die why = fail $
      "writeSAIGInferLatches: " ++ why ++ ":\n" ++
      "term must have type of the form '(i, s) -> (o, s)',\n" ++
      "where 'i', 's', and 'o' are all fixed-width types,\n" ++
      "but type of term is:\n" ++ (pretty . ttSchema $ tt)

    -- Decompose type as '(i, s) -> (o, s)' and return 's'.
    getStateType :: SharedTerm s -> IO FiniteType
    getStateType ty = do
      ty' <- scWhnf sc ty
      case ty' of
        (asPi -> Just (_nm, tp, body)) ->
          -- NB: if we get unexpected "state types are different"
          -- failures here than we need to 'scWhnf sc' before calling
          -- 'asFiniteType'.
          case (asFiniteTypePure tp, asFiniteTypePure body) of
            (Just dom, Just rng) ->
              case (dom, rng) of
                (FTTuple [_i, s], FTTuple [_o, s']) ->
                  if s == s' then
                    return s
                  else
                    die "state types are different"
                _ -> die "domain or range not a tuple type"
            _ -> die "domain or range not finite width"
        _ -> die "not a function type"

-- | Like @writeAIGInferLatches@, but takes an additional argument
-- specifying the number of input and output bits to be interpreted as
-- latches.
writeAIGComputedLatches ::
  SharedContext s -> FilePath -> TypedTerm s -> TypedTerm s -> IO ()
writeAIGComputedLatches sc file term numLatches = do
  aig <- bitblastPrim sc term
  let numLatches' = SV.evaluateTypedTerm sc numLatches
  if isWord numLatches' then do
    let numLatches'' = fromInteger . C.fromWord $ numLatches'
    GIA.writeAigerWithLatches file aig numLatches''
  else do
    fail $ "writeAIGComputedLatches:\n" ++
      "non-integer or polymorphic number of latches;\n" ++
      "you may need a width annotation '_:[width]':\n" ++
      "value: " ++ ppCryptol numLatches' ++ "\n" ++
      "term: " ++ ppSharedTerm numLatches ++ "\n" ++
      "type: " ++ (pretty . ttSchema $ numLatches)
  where
    isWord :: C.Value -> Bool
    isWord (C.VWord _) = True
    isWord (C.VSeq isWord' _) = isWord'
    isWord _ = False

    ppCryptol :: C.Value -> String
    ppCryptol = show . C.ppValue C.defaultPPOpts

    ppSharedTerm :: TypedTerm s -> String
    ppSharedTerm = scPrettyTerm . ttTerm

writeCNF :: SharedContext s -> FilePath -> TypedTerm s -> IO ()
writeCNF sc f t = do
  AIG.Network be ls <- bitblastPrim sc t
  case ls of
    [l] -> do
      _ <- GIA.writeCNF be l f
      return ()
    _ -> fail "writeCNF: non-boolean term"

-- | Write a @SharedTerm@ representing a theorem to an SMT-Lib version
-- 1 file.
writeSMTLib1 :: SharedContext s -> FilePath -> TypedTerm s -> IO ()
writeSMTLib1 sc f t = writeUnintSMTLib1 sc f [] t

-- | Write a @SharedTerm@ representing a theorem to an SMT-Lib version
-- 1 file, treating some constants as uninterpreted.
writeUnintSMTLib1 :: SharedContext s -> FilePath -> [String] -> TypedTerm s -> IO ()
writeUnintSMTLib1 sc f unints t = do
  (_, _, l) <- prepSBV sc unints t
  txt <- SBV.compileToSMTLib False True l
  writeFile f txt

-- | Write a @SharedTerm@ representing a theorem to an SMT-Lib version
-- 2 file.
writeSMTLib2 :: SharedContext s -> FilePath -> TypedTerm s -> IO ()
writeSMTLib2 sc f t = writeUnintSMTLib2 sc f [] t

-- | Write a @SharedTerm@ representing a theorem to an SMT-Lib version
-- 2 file, treating some constants as uninterpreted.
writeUnintSMTLib2 :: SharedContext s -> FilePath -> [String] -> TypedTerm s -> IO ()
writeUnintSMTLib2 sc f unints t = do
  (_, _, l) <- prepSBV sc unints t
  txt <- SBV.compileToSMTLib True True l
  writeFile f txt

writeCore :: FilePath -> TypedTerm s -> IO ()
writeCore path t = writeFile path (scWriteExternal (ttTerm t))

readCore :: FilePath -> TopLevel (TypedTerm SAWCtx)
readCore path = do
  sc <- getSharedContext
  io (mkTypedTerm sc =<< scReadExternal sc =<< readFile path)

quickcheckGoal :: SharedContext s -> Integer -> ProofScript s SV.SatResult
quickcheckGoal sc n = StateT $ \goal -> do
  putStr $ "WARNING: using quickcheck to prove goal..."
  hFlush stdout
  let tm = ttTerm (goalTerm goal)
  ty <- scTypeOf sc tm
  maybeInputs <- scTestableType sc ty
  case maybeInputs of
    Just inputs -> do
      result <- scRunTestsTFIO sc n tm inputs
      case result of
        Nothing -> do
          putStrLn $ "checked " ++ show n ++ " cases."
          return (SV.Unsat, goal)
        Just (cex:_) -> return (SV.Sat cex, goal)
        Just [] -> fail "quickcheck: empty counterexample"
    Nothing -> fail $ "quickcheck:\n" ++
      "term has non-testable type:\n" ++
      pretty (ttSchema (goalTerm goal))

assumeValid :: ProofScript s SV.ProofResult
assumeValid = StateT $ \goal -> do
  putStrLn $ "WARNING: assuming goal " ++ goalName goal ++ " is valid"
  return (SV.Valid, goal)

assumeUnsat :: ProofScript s SV.SatResult
assumeUnsat = StateT $ \goal -> do
  putStrLn $ "WARNING: assuming goal " ++ goalName goal ++ " is unsat"
  return (SV.Unsat, goal)

printGoal :: ProofScript s ()
printGoal = StateT $ \goal -> do
  putStrLn (scPrettyTerm (ttTerm (goalTerm goal)))
  return ((), goal)

printGoalDepth :: Int -> ProofScript SAWCtx ()
printGoalDepth n = StateT $ \goal -> do
  print (ppTermDepth n (ttTerm (goalTerm goal)))
  return ((), goal)

printGoalSExp :: ProofScript SAWCtx ()
printGoalSExp = StateT $ \goal -> do
  print (ppSharedTermSExp (ttTerm (goalTerm goal)))
  return ((), goal)

printGoalSExp' :: Int -> ProofScript SAWCtx ()
printGoalSExp' n = StateT $ \goal -> do
  let cfg = defaultPPConfig { ppMaxDepth = Just n}
  print (ppSharedTermSExpWith cfg (ttTerm (goalTerm goal)))
  return ((), goal)

unfoldGoal :: SharedContext s -> [String] -> ProofScript s ()
unfoldGoal sc names = StateT $ \goal -> do
  let TypedTerm schema trm = goalTerm goal
  trm' <- scUnfoldConstants sc names trm
  return ((), goal { goalTerm = TypedTerm schema trm' })

simplifyGoal :: SharedContext s -> Simpset (SharedTerm s) -> ProofScript s ()
simplifyGoal sc ss = StateT $ \goal -> do
  let TypedTerm schema trm = goalTerm goal
  trm' <- rewriteSharedTerm sc ss trm
  return ((), goal { goalTerm = TypedTerm schema trm' })

-- | Bit-blast a @SharedTerm@ representing a theorem and check its
-- satisfiability using ABC.
{-
satABCold :: SharedContext s -> ProofScript s SV.SatResult
satABCold sc = StateT $ \g -> withBE $ \be -> do
  let t = goalTerm g
  t' <- prepForExport sc t
  let (args, _) = asLambdaList t'
      argNames = map fst args
      argTys = map snd args
  shapes <- mapM Old.parseShape argTys
  mbterm <- Old.bitBlast be t'
  case mbterm of
    Right bterm -> do
      case bterm of
        Old.BBool l -> do
          satRes <- ABC.checkSat be l
          case satRes of
            ABC.Unsat -> do
              ft <- scApplyPrelude_False sc
              return (SV.Unsat, g { goalTerm = ft })
            ABC.Sat cex -> do
              let r = liftCexBB shapes cex
              tt <- scApplyPrelude_True sc
              case r of
                Left err -> fail $ "Can't parse counterexample: " ++ err
                Right [v] ->
                  return (SV.Sat v, g { goalTerm = tt })
                Right vs -> do
                  return (SV.SatMulti (zip argNames vs), g { goalTerm = tt })
        _ -> fail "Can't prove non-boolean term."
    Left err -> fail $ "Can't bitblast: " ++ err
-}

returnsBool :: SharedTerm s -> Bool
returnsBool ((asBoolType . snd . asPiList) -> Just ()) = True
returnsBool _ = False

checkBoolean :: SharedContext s -> SharedTerm s -> IO ()
checkBoolean sc t = do
  ty <- scTypeCheckError sc t
  unless (returnsBool ty) $
    fail $ "Attempting to prove a term that returns a non-boolean type: " ++
           show ty

checkBooleanType :: C.Type -> IO ()
checkBooleanType (C.tIsBit -> True) = return ()
checkBooleanType (C.tIsFun -> Just (_, ty')) = checkBooleanType ty'
checkBooleanType ty =
  fail $ "Attempting to prove a term that returns a non-boolean type: " ++ pretty ty

checkBooleanSchema :: C.Schema -> IO ()
checkBooleanSchema (C.Forall [] [] t) = checkBooleanType t
checkBooleanSchema s =
  fail $ "Attempting to prove a term with polymorphic type: " ++ pretty s

-- | Bit-blast a @SharedTerm@ representing a theorem and check its
-- satisfiability using ABC.
satABC :: SharedContext s -> ProofScript s SV.SatResult
satABC sc = StateT $ \g -> do
  TypedTerm schema t <- rewriteEqs sc (goalTerm g)
  checkBooleanSchema schema
  tp <- scWhnf sc =<< scTypeOf sc t
  let (args, _) = asPiList tp
      argNames = map fst args
  -- putStrLn "Simulating..."
  BBSim.withBitBlastedPred sawProxy sc t $ \be lit0 shapes -> do
  let lit = case goalQuant g of
        Existential -> lit0
        Universal -> AIG.not lit0
  -- putStrLn "Checking..."
  satRes <- AIG.checkSat be lit
  case satRes of
    AIG.Unsat -> do
      -- putStrLn "UNSAT"
      ft <- scApplyPrelude_False sc
      return (SV.Unsat, g { goalTerm = TypedTerm schema ft })
    AIG.Sat cex -> do
      -- putStrLn "SAT"
      let r = liftCexBB shapes cex
      tt <- scApplyPrelude_True sc
      case r of
        Left err -> fail $ "Can't parse counterexample: " ++ err
        Right [v] ->
          return (SV.Sat v, g { goalTerm = TypedTerm schema tt })
        Right vs
          | length argNames == length vs -> do
              return (SV.SatMulti (zip argNames vs), g { goalTerm = TypedTerm schema tt })
          | otherwise -> fail $ unwords ["ABC SAT results do not match expected arguments", show argNames, show vs]
    AIG.SatUnknown -> fail "Unknown result from ABC"

parseDimacsSolution :: [Int]    -- ^ The list of CNF variables to return
                    -> [String] -- ^ The value lines from the solver
                    -> [Bool]
parseDimacsSolution vars ls = map lkup vars
  where
    vs :: [Int]
    vs = concatMap (filter (/= 0) . mapMaybe readMaybe . tail . words) ls
    varToPair n | n < 0 = (-n, False)
                | otherwise = (n, True)
    assgnMap = Map.fromList (map varToPair vs)
    lkup v = Map.findWithDefault False v assgnMap

satExternal :: Bool -> SharedContext s -> String -> [String]
            -> ProofScript s SV.SatResult
satExternal doCNF sc execName args = StateT $ \g -> do
  TypedTerm schema t <- rewriteEqs sc (goalTerm g)
  tp <- scWhnf sc =<< scTypeOf sc t
  let cnfName = goalName g ++ ".cnf"
      argNames = map fst (fst (asPiList tp))
  checkBoolean sc t
  (path, fh) <- openTempFile "." cnfName
  hClose fh -- Yuck. TODO: allow writeCNF et al. to work on handles.
  let args' = map replaceFileName args
      replaceFileName "%f" = path
      replaceFileName a = a
  BBSim.withBitBlastedPred sawProxy sc t $ \be l0 shapes -> do
  let l = case goalQuant g of
        Existential -> l0
        Universal -> AIG.not l0
  vars <- (if doCNF then GIA.writeCNF else writeAIGWithMapping) be l path
  (_ec, out, err) <- readProcessWithExitCode execName args' ""
  removeFile path
  unless (null err) $
    print $ unlines ["Standard error from SAT solver:", err]
  let ls = lines out
      sls = filter ("s " `isPrefixOf`) ls
      vls = filter ("v " `isPrefixOf`) ls
  case (sls, vls) of
    (["s SATISFIABLE"], _) -> do
      let bs = parseDimacsSolution vars vls
      let r = liftCexBB shapes bs
      tt <- scApplyPrelude_True sc
      case r of
        Left msg -> fail $ "Can't parse counterexample: " ++ msg
        Right [v] ->
          return (SV.Sat v, g { goalTerm = TypedTerm schema tt })
        Right vs
          | length argNames == length vs -> do
              return (SV.SatMulti (zip argNames vs), g { goalTerm = TypedTerm schema tt })
          | otherwise -> fail $ unwords ["external SAT results do not match expected arguments", show argNames, show vs]
    (["s UNSATISFIABLE"], []) -> do
      ft <- scApplyPrelude_False sc
      return (SV.Unsat, g { goalTerm = TypedTerm schema ft })
    _ -> fail $ "Unexpected result from SAT solver:\n" ++ out

writeAIGWithMapping :: GIA.GIA s -> GIA.Lit s -> FilePath -> IO [Int]
writeAIGWithMapping be l path = do
  nins <- GIA.inputCount be
  ABC.writeAiger path (ABC.Network be [l])
  return [1..nins]

unsatResult :: SharedContext s -> ProofGoal s
            -> IO (SV.SatResult, ProofGoal s)
unsatResult sc g = do
  let schema = C.Forall [] [] C.tBit
  ft <- scApplyPrelude_False sc
  return (SV.Unsat, g { goalTerm = TypedTerm schema ft })

rewriteEqs :: SharedContext s -> TypedTerm s -> IO (TypedTerm s)
rewriteEqs sc (TypedTerm schema t) = do
  let eqs = map (mkIdent preludeName)
            [ "eq_Bool", "eq_Nat", "eq_bitvector", "eq_VecBool"
            , "eq_VecVec" ]
  rs <- scEqsRewriteRules sc eqs
  ss <- addRules rs <$> basic_ss sc
  t' <- rewriteSharedTerm sc ss t
  return (TypedTerm schema t')

codegenSBV :: SharedContext s -> FilePath -> String -> TypedTerm s -> IO ()
codegenSBV sc path fname (TypedTerm _schema t) =
  SBVSim.sbvCodeGen sc [] mpath fname t
  where mpath = if null path then Nothing else Just path

prepSBV :: SharedContext s -> [String] -> TypedTerm s
        -> IO (SharedTerm s, [SBVSim.Labeler], SBV.Symbolic SBV.SVal)
prepSBV sc unints tt = do
  TypedTerm schema t' <- rewriteEqs sc tt
  checkBooleanSchema schema
  (labels, lit) <- SBVSim.sbvSolve sc unints t'
  return (t', labels, lit)

-- | Bit-blast a @SharedTerm@ representing a theorem and check its
-- satisfiability using SBV. (Currently ignores satisfying assignments.)
satSBV :: SBV.SMTConfig -> SharedContext s -> ProofScript s SV.SatResult
satSBV conf sc = satUnintSBV conf sc []

-- | Bit-blast a @SharedTerm@ representing a theorem and check its
-- satisfiability using SBV. (Currently ignores satisfying assignments.)
-- Constants with names in @unints@ are kept as uninterpreted functions.
satUnintSBV :: SBV.SMTConfig -> SharedContext s -> [String] -> ProofScript s SV.SatResult
satUnintSBV conf sc unints = StateT $ \g -> do
  (t', labels, lit0) <- prepSBV sc unints (goalTerm g)
  let lit = case goalQuant g of
        Existential -> lit0
        Universal -> liftM SBV.svNot lit0
  tp <- scWhnf sc =<< scTypeOf sc t'
  let (args, _) = asPiList tp
      argNames = map fst args
  SBV.SatResult r <- SBV.satWith conf lit
  case r of
    SBV.Satisfiable {} -> do
      let schema = C.Forall [] [] C.tBit
      tt <- scApplyPrelude_True sc
      return (getLabels labels (SBV.getModelDictionary r) argNames, g {goalTerm = TypedTerm schema tt})
    SBV.Unsatisfiable {} -> do
      let schema = C.Forall [] [] C.tBit
      ft <- scApplyPrelude_False sc
      return (SV.Unsat, g { goalTerm = TypedTerm schema ft })
    SBV.Unknown {} -> fail "Prover returned Unknown"
    SBV.ProofError _ ls -> fail . unlines $ "Prover returned error: " : ls
    SBV.TimeOut {} -> fail "Prover timed out"

getLabels :: [SBVSim.Labeler] -> Map.Map String SBV.CW -> [String] -> SV.SatResult
getLabels ls d argNames =
  case fmap getLabel ls of
    [x] -> SV.Sat x
    xs
     | length argNames == length xs -> SV.SatMulti (zip argNames xs)
     | otherwise -> error $ unwords ["SBV SAT results do not match expected arguments", show argNames, show xs]

  where
    getLabel :: SBVSim.Labeler -> FiniteValue
    getLabel (SBVSim.BoolLabel s) = FVBit (SBV.cwToBool (d Map.! s))
    getLabel (SBVSim.WordLabel s) = d Map.! s &
      (\(SBV.KBounded _ n)-> FVWord (fromIntegral n)) . SBV.cwKind <*> (\(SBV.CWInteger i)-> i) . SBV.cwVal
    getLabel (SBVSim.VecLabel xs)
      | V.null xs = error "getLabel of empty vector"
      | otherwise = fvVec t vs
      where vs = map getLabel (V.toList xs)
            t = finiteTypeOf (head vs)
    getLabel (SBVSim.TupleLabel xs) = FVTuple $ map getLabel (V.toList xs)
    getLabel (SBVSim.RecLabel xs) = FVRec $ fmap getLabel xs

satBoolector :: SharedContext s -> ProofScript s SV.SatResult
satBoolector = satSBV SBV.boolector

satZ3 :: SharedContext s -> ProofScript s SV.SatResult
satZ3 = satSBV SBV.z3

satCVC4 :: SharedContext s -> ProofScript s SV.SatResult
satCVC4 = satSBV SBV.cvc4

satMathSAT :: SharedContext s -> ProofScript s SV.SatResult
satMathSAT = satSBV SBV.mathSAT

satYices :: SharedContext s -> ProofScript s SV.SatResult
satYices = satSBV SBV.yices

satUnintBoolector :: SharedContext s -> [String] -> ProofScript s SV.SatResult
satUnintBoolector = satUnintSBV SBV.boolector

satUnintZ3 :: SharedContext s -> [String] -> ProofScript s SV.SatResult
satUnintZ3 = satUnintSBV SBV.z3

satUnintCVC4 :: SharedContext s -> [String] -> ProofScript s SV.SatResult
satUnintCVC4 = satUnintSBV SBV.cvc4

satUnintMathSAT :: SharedContext s -> [String] -> ProofScript s SV.SatResult
satUnintMathSAT = satUnintSBV SBV.mathSAT

satUnintYices :: SharedContext s -> [String] -> ProofScript s SV.SatResult
satUnintYices = satUnintSBV SBV.yices

negTypedTerm :: SharedContext s -> TypedTerm s -> IO (TypedTerm s)
negTypedTerm sc (TypedTerm schema t) = do
  checkBooleanSchema schema
  t' <- negTerm sc t
  return (TypedTerm schema t')

negTerm :: SharedContext s -> SharedTerm s -> IO (SharedTerm s)
negTerm sc (STApp _ (Lambda x ty tm)) = scLambda sc x ty =<< negTerm sc tm
negTerm sc tm = scNot sc tm

satWithExporter :: (SharedContext s -> FilePath -> TypedTerm s -> IO ())
                -> SharedContext s
                -> String
                -> String
                -> ProofScript s SV.SatResult
satWithExporter exporter sc path ext = StateT $ \g -> do
  t <- case goalQuant g of
         Existential -> return (goalTerm g)
         Universal -> negTypedTerm sc (goalTerm g)
  exporter sc ((path ++ goalName g) ++ ext) t
  unsatResult sc g

satAIG :: SharedContext s -> FilePath -> ProofScript s SV.SatResult
satAIG sc path = satWithExporter writeAIG sc path ".aig"

satCNF :: SharedContext s -> FilePath -> ProofScript s SV.SatResult
satCNF sc path = satWithExporter writeCNF sc path ".cnf"

satExtCore :: SharedContext s -> FilePath -> ProofScript s SV.SatResult
satExtCore sc path = satWithExporter (const writeCore) sc path ".extcore"

satSMTLib1 :: SharedContext s -> FilePath -> ProofScript s SV.SatResult
satSMTLib1 sc path = satWithExporter writeSMTLib1 sc path ".smt"

satSMTLib2 :: SharedContext s -> FilePath -> ProofScript s SV.SatResult
satSMTLib2 sc path = satWithExporter writeSMTLib2 sc path ".smt2"

liftCexBB :: [FiniteType] -> [Bool] -> Either String [FiniteValue]
liftCexBB tys bs =
  case readFiniteValues tys bs of
    Nothing -> Left "Failed to lift counterexample"
    Just fvs -> Right fvs

-- | Translate a @SharedTerm@ representing a theorem for input to the
-- given validity-checking script and attempt to prove it.
provePrim :: SharedContext s -> ProofScript s SV.SatResult
          -> TypedTerm s -> IO SV.ProofResult
provePrim _sc script t = do
  checkBooleanSchema (ttSchema t)
  r <- evalStateT script (ProofGoal Universal "prove" t)
  return (SV.flipSatResult r)

provePrintPrim :: SharedContext s -> ProofScript s SV.SatResult
               -> TypedTerm s -> IO (Theorem s)
provePrintPrim _sc script t = do
  r <- provePrim _sc script t
  case r of
    SV.Valid -> putStrLn "Valid" >> return (Theorem t)
    _ -> fail (show r)

satPrim :: SharedContext s -> ProofScript s SV.SatResult -> TypedTerm s
        -> IO SV.SatResult
satPrim _sc script t = do
  checkBooleanSchema (ttSchema t)
  evalStateT script (ProofGoal Existential "sat" t)

satPrintPrim :: SharedContext s -> ProofScript s SV.SatResult
             -> TypedTerm s -> IO ()
satPrintPrim _sc script t = print =<< satPrim _sc script t

-- | Quick check (random test) a term and print the result. The
-- 'Integer' parameter is the number of random tests to run.
quickCheckPrintPrim :: SharedContext s -> Integer -> TypedTerm s -> IO ()
quickCheckPrintPrim sc numTests tt = do
  let tm = ttTerm tt
  ty <- scTypeOf sc tm
  maybeInputs <- scTestableType sc ty
  case maybeInputs of
    Just inputs -> do
      result <- scRunTestsTFIO sc numTests tm inputs
      case result of
        Nothing -> putStrLn $ "All " ++ show numTests ++ " tests passed!"
        Just counterExample -> putStrLn $
          "At least one test failed! Counter example:\n" ++
          showList counterExample ""
    Nothing -> fail $ "quickCheckPrintPrim:\n" ++
      "term has non-testable type:\n" ++
      pretty (ttSchema tt)

cryptolSimpset :: SharedContext s -> IO (Simpset (SharedTerm s))
cryptolSimpset sc = scSimpset sc cryptolDefs [] []
  where cryptolDefs = filter (not . excluded) $
                      moduleDefs CryptolSAW.cryptolModule
        excluded d = defIdent d `elem` [ "Cryptol.fix" ]

addPreludeEqs :: SharedContext s -> [String] -> Simpset (SharedTerm s)
              -> IO (Simpset (SharedTerm s))
addPreludeEqs sc names ss = do
  eqRules <- mapM (scEqRewriteRule sc) (map qualify names)
  return (addRules eqRules ss)
    where qualify = mkIdent (mkModuleName ["Prelude"])

addCryptolEqs :: SharedContext s -> [String] -> Simpset (SharedTerm s)
              -> IO (Simpset (SharedTerm s))
addCryptolEqs sc names ss = do
  eqRules <- mapM (scEqRewriteRule sc) (map qualify names)
  return (addRules eqRules ss)
    where qualify = mkIdent (mkModuleName ["Cryptol"])

addPreludeDefs :: SharedContext s -> [String] -> Simpset (SharedTerm s)
              -> IO (Simpset (SharedTerm s))
addPreludeDefs sc names ss = do
  defs <- mapM getDef names -- FIXME: warn if not found
  defRules <- concat <$> (mapM (scDefRewriteRules sc) defs)
  return (addRules defRules ss)
    where qualify = mkIdent (mkModuleName ["Prelude"])
          getDef n =
            case findDef (scModule sc) (qualify n) of
              Just d -> return d
              Nothing -> fail $ "Prelude definition " ++ n ++ " not found"

rewritePrim :: SharedContext s -> Simpset (SharedTerm s) -> TypedTerm s -> IO (TypedTerm s)
rewritePrim sc ss (TypedTerm schema t) = do
  t' <- rewriteSharedTerm sc ss t
  return (TypedTerm schema t')

unfold_term :: SharedContext s -> [String] -> TypedTerm s -> IO (TypedTerm s)
unfold_term sc names (TypedTerm schema t) = do
  t' <- scUnfoldConstants sc names t
  return (TypedTerm schema t')

addsimp :: SharedContext s -> Theorem s -> Simpset (SharedTerm s)
        -> Simpset (SharedTerm s)
addsimp _sc (Theorem t) ss = addRule (ruleOfProp (ttTerm t)) ss

addsimp' :: SharedContext s -> SharedTerm s -> Simpset (SharedTerm s)
         -> Simpset (SharedTerm s)
addsimp' _sc t ss = addRule (ruleOfProp t) ss

addsimps :: SharedContext s -> [Theorem s] -> Simpset (SharedTerm s)
         -> Simpset (SharedTerm s)
addsimps _sc thms ss =
  foldr (\thm -> addRule (ruleOfProp (ttTerm (thmTerm thm)))) ss thms

addsimps' :: SharedContext s -> [SharedTerm s] -> Simpset (SharedTerm s)
          -> Simpset (SharedTerm s)
addsimps' _sc ts ss = foldr (\t -> addRule (ruleOfProp t)) ss ts

print_type :: SharedTerm SAWCtx -> TopLevel ()
print_type t = do
  sc <- getSharedContext
  io (scTypeOf sc t >>= print)

check_term :: SharedTerm SAWCtx -> TopLevel ()
check_term t = do
  sc <- getSharedContext
  io (scTypeCheckError sc t >>= print)

printTermSExp' :: Int -> SharedTerm SAWCtx -> TopLevel ()
printTermSExp' n =
  io . print . ppSharedTermSExpWith (defaultPPConfig { ppMaxDepth = Just n })

checkTypedTerm :: SharedContext s -> TypedTerm s -> IO ()
checkTypedTerm sc (TypedTerm _schema t) = scTypeCheckError sc t >>= print

fixPos :: Pos
fixPos = PosInternal "FIXME"

bindExts :: SharedContext s
         -> [SharedTerm s]
         -> SharedTerm s
         -> IO (SharedTerm s)
bindExts sc args body = do
  types <- mapM (scTypeOf sc) args
  let is = mapMaybe extIdx args
      names = mapMaybe extName args
  unless (length types == length is && length types == length names) $
    fail "argument isn't external input"
  locals <- mapM (scLocalVar sc . fst) ([0..] `zip` reverse types)
  body' <- scInstantiateExt sc (Map.fromList (is `zip` reverse locals)) body
  scLambdaList sc (names `zip` types) body'

freshSymbolicPrim :: String -> C.Schema -> TopLevel (TypedTerm SAWCtx)
freshSymbolicPrim x schema@(C.Forall [] [] ct) = do
  sc <- getSharedContext
  cty <- io $ Cryptol.importType sc Cryptol.emptyEnv ct
  tm <- io $ scFreshGlobal sc x cty
  return $ TypedTerm schema tm
freshSymbolicPrim _ _ =
  fail "Can't create fresh symbolic variable of non-ground type."

abstractSymbolicPrim :: TypedTerm SAWCtx -> TopLevel (TypedTerm SAWCtx)
abstractSymbolicPrim (TypedTerm _ t) = do
  sc <- getSharedContext
  io (mkTypedTerm sc =<< bindAllExts sc t)

bindAllExts :: SharedContext s
            -> SharedTerm s
            -> IO (SharedTerm s)
bindAllExts sc body = bindExts sc (getAllExts body) body

-- | Apply the given SharedTerm to the given values, and evaluate to a
-- final value.
cexEvalFn :: SharedContext s -> [FiniteValue] -> SharedTerm s
          -> IO Concrete.CValue
cexEvalFn sc args tm = do
  -- NB: there may be more args than exts, and this is ok. One side of
  -- an equality may have more free variables than the other,
  -- particularly in the case where there is a counter-example.
  let exts = getAllExts tm
  args' <- mapM (scFiniteValue sc) args
  let is = mapMaybe extIdx exts
      argMap = Map.fromList (zip is args')
  tm' <- scInstantiateExt sc argMap tm
  return $ Concrete.evalSharedTerm (scModule sc) tm'

toValueCase :: (SV.FromValue b) =>
               SharedContext SAWCtx
            -> (SharedContext SAWCtx -> b -> SV.Value -> SV.Value -> IO SV.Value)
            -> SV.Value
toValueCase sc prim =
  SV.VLambda $ \b -> return $
  SV.VLambda $ \v1 -> return $
  SV.VLambda $ \v2 ->
  prim sc (SV.fromValue b) v1 v2

caseProofResultPrim :: SharedContext SAWCtx -> SV.ProofResult
                    -> SV.Value -> SV.Value
                    -> IO SV.Value
caseProofResultPrim sc pr vValid vInvalid = do
  case pr of
    SV.Valid -> return vValid
    SV.Invalid v -> do t <- mkTypedTerm sc =<< scFiniteValue sc v
                       SV.applyValue vInvalid (SV.toValue t)
    SV.InvalidMulti pairs -> do
      let fvs = map snd pairs
      ts <- mapM (scFiniteValue sc) fvs
      t <- scTuple sc ts
      tt <- mkTypedTerm sc t
      SV.applyValue vInvalid (SV.toValue tt)

caseSatResultPrim :: SharedContext SAWCtx -> SV.SatResult
                  -> SV.Value -> SV.Value
                  -> IO SV.Value
caseSatResultPrim sc sr vUnsat vSat = do
  case sr of
    SV.Unsat -> return vUnsat
    SV.Sat v -> do t <- mkTypedTerm sc =<< scFiniteValue sc v
                   SV.applyValue vSat (SV.toValue t)
    SV.SatMulti pairs -> do
      let fvs = map snd pairs
      ts <- mapM (scFiniteValue sc) fvs
      t <- scTuple sc ts
      tt <- mkTypedTerm sc t
      SV.applyValue vUnsat (SV.toValue tt)

envCmd :: TopLevel ()
envCmd = do
  m <- rwTypes <$> getTopLevelRW
  let showLName = getVal
  io $ sequence_ [ putStrLn (showLName x ++ " : " ++ pShow v) | (x, v) <- Map.assocs m ]

exitPrim :: Integer -> IO ()
exitPrim code = Exit.exitWith exitCode
  where
    exitCode = if code /= 0
               then Exit.ExitFailure (fromInteger code)
               else Exit.ExitSuccess

timePrim :: TopLevel SV.Value -> TopLevel SV.Value
timePrim a = do
  t1 <- liftIO $ getCPUTime
  r <- a
  t2 <- liftIO $ getCPUTime
  let t :: Double
      t = fromIntegral (t2-t1) * 1e-12
  liftIO $ printf "Time: %9.3fs\n" t
  return r
