{-# OPTIONS_GHC -Wall -fno-warn-orphans #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveFunctor #-}

module Qps.Lp
       ( Lp(..), FLp(..), ILp(..), Coef(..)
       , matchesGlpk' , asNumber
       , glpkSolved, glpkUnsolved
       , ipoptSolved, ipoptUnsolved
       ) where

import Control.Monad ( unless )
import Test.QuickCheck.Arbitrary
import Test.QuickCheck hiding ( Result, reason )
import Test.QuickCheck.Property
import Test.QuickCheck.Monadic
--import Linear.Conjugate ( Conjugate(..) )

import qualified Numeric.LinearProgramming as GLPK
import qualified Data.Vector as V
import Data.List ( intersperse )
import Data.Maybe
import Linear hiding ( vector )

import qualified Data.Foldable as F

import Dyno.Vectorize
import Dyno.TypeVecs -- ( Vec(..), mkVec', tvlength )
import Dyno.Nlp
import Dyno.NlpSolver
import Dyno.Casadi.SXElement
--import Dyno.Nats

-- NOTES
-- chooseNonzero restricts the tests
-- x0 currently hardcoded to 0
-- constraint offset currently hardcoded to 0
-- lb strictly < ub (until ipopt segfault is fixed)
-- when ipopt fails but snopt succeeds, i reject the test, but this should be reported for this LP case
-- tighten the bounds from 0.4 to 1e-6 or so, 0.4 is just to get a smoking gun for Elizabeth

instance (Arbitrary a, Dim n) => Arbitrary (Vec n a) where
  arbitrary = do
    let n = tvlength (undefined :: Vec n a)
    contents <- vector n
    return $ devectorize (V.fromList contents)

data Coef a = Linear a
            | Nonlinear a
            | Zero
            deriving (Functor, Show, Eq)

instance Num a => Num (Coef a) where
  fromInteger 0 = Zero
  fromInteger x = Linear (fromInteger x)
  abs = fmap abs
  signum = fmap signum
  negate = fmap negate

  x + Zero = x
  Zero + y = y
  (Linear x) + (Linear y)
    -- | z == 0 = Zero
    | otherwise = Linear z
    where
      z = x + y
  (Nonlinear x) + (Nonlinear y)
    -- | z == 0 = Zero
    | otherwise = Nonlinear z
    where
      z = x + y
  (Linear x) + (Nonlinear y)
    -- | z == 0 = Zero
    | otherwise = Nonlinear z
    where
      z = x + y
  (Nonlinear x) + (Linear y)
    -- | z == 0 = Zero
    | otherwise = Nonlinear z
    where
      z = x + y

  _ * Zero = Zero
  Zero * _ = Zero
  (Linear x) * (Linear y)
    -- | z == 0 = Zero
    | otherwise = Linear z
    where
      z = x * y
  (Nonlinear x) * (Nonlinear y)
    -- | z == 0 = Zero
    | otherwise = Nonlinear z
    where
      z = x * y
  (Linear x) * (Nonlinear y)
    -- | z == 0 = Zero
    | otherwise = Nonlinear z
    where
      z = x * y
  (Nonlinear x) * (Linear y)
    -- | z == 0 = Zero
    | otherwise = Nonlinear z
    where
      z = x * y

instance Conjugate a => Conjugate (Coef a) where
  conjugate = fmap conjugate

data Lp nx ng = Lp { px0 :: Vec nx Double
                   , pbx :: Vec nx (Double, Double)
                   , pbg :: Vec ng (Double, Double)
                   , pgoffset:: Vec ng Double
                   , pobjCoeffs :: Vec nx (Coef Double)
                   , pjacCoeffs :: Vec ng (Vec nx (Coef Double))
                   } --deriving Show
data FLp nx ng = FLp (Lp nx ng) 
data ILp nx ng = ILp (Lp nx ng)

class IsLp a n m | a -> n, a -> m where
  getLp :: a -> Lp n m
instance IsLp (Lp n m) n m where
  getLp = id
instance IsLp (FLp n m) n m where
  getLp (FLp lp) = lp
instance IsLp (ILp n m) n m where
  getLp (ILp lp) = lp

--instance (Dim nx, Dim ng) => Show (Lp nx ng) where
-- show = prettyPrint

asNumber :: Num a => Coef a -> a
asNumber Zero = 0
asNumber (Linear x) = x
asNumber (Nonlinear x) = x

chooseNonzero :: (Int,Int) -> Gen Int
chooseNonzero range = do
  k <- choose range
  if k==0 then chooseNonzero range else return k

instance (Num a, Arbitrary a) => Arbitrary (Coef a) where
  arbitrary =
    oneof [ do x <- chooseNonzero (-9,9)
               return (Nonlinear (fromIntegral x))
          , do x <- chooseNonzero (-9,9) --- THIS RESTRICTS OUR TESTS
               return (Linear (fromIntegral x))
          , return Zero
          ]
instance Arbitrary SXElement where
  arbitrary = do
    x <- arbitrary :: Gen Double
    return (realToFrac x)

absnl :: Num a => Coef a -> Coef a
absnl (Nonlinear x) = Nonlinear (abs x)
absnl x = x

runSum :: (F.Foldable f, Fractional a) => f (a, Coef a) -> a
runSum = runSum' 0 . F.toList

runSum' :: Fractional a => a -> [(a, Coef a)] -> a
runSum' acc [] = acc
runSum' acc ((_,Zero):xs) = runSum' acc xs
runSum' acc ((x,Linear c):xs) = runSum' (acc + c*x) xs
runSum' acc ((x,Nonlinear c):xs) = runSum' (acc + c*(x + 1e-140*x*x)) xs

newtype Bnd = Bnd { unBound :: (Double,Double) }
instance Arbitrary Bnd where
  arbitrary = do
    let range = (-9,9::Int)
    k0 <- fmap fromIntegral (choose range)
    k1 <- fmap fromIntegral (choose range)
    return $ if k0 == k1
             then Bnd (k0, k1 + 1)
             else if k0 <= k1
                  then Bnd (k0,k1)
                  else Bnd (k1,k0)


data Valid = Valid { vfErr :: Double
                   , vxErr :: Double
                   , vgErr :: Double
                   } deriving Show
validSol :: forall nx ng . (Dim nx, Dim ng) =>
            Lp nx ng -> Vec nx Double -> Double -> Valid
validSol lp xopt fopt =
  Valid { vfErr = abs (fopt - fopt')
        , vxErr = maximum (F.toList satisfiesBnds)
        , vgErr = maximum (F.toList satisfiesConstraints)
        }
  where
    fopt' = sum (F.toList (vzipWith (*) (fmap asNumber (pobjCoeffs lp)) xopt))

    satisfiesBnds :: Vec nx Double
    satisfiesBnds = vzipWith satisfiesBnd (pbx lp) xopt

    satisfiesBnd :: (Double,Double) -> Double -> Double
    satisfiesBnd (lb,ub) x = max (max (lb - x) 0) (max (x - ub) 0)

    satisfiesConstraints :: Vec ng Double
    satisfiesConstraints = vzipWith3 satisfiesConstraint
                           (pbg lp) (pjacCoeffs lp) (pgoffset lp)

    satisfiesConstraint :: (Double, Double) -> Vec nx (Coef Double) -> Double -> Double
    satisfiesConstraint (lbg,ubg) coeffs goffset =
      max (max (lbg - f) 0) (max (f - ubg) 0)
      where
        f = sum (F.toList (vzipWith (*) xopt (fmap asNumber coeffs))) + goffset


solveWithGlpk :: (Dim nx, Dim ng) => Lp nx ng -> GLPK.Solution
solveWithGlpk lp = GLPK.simplex prob constraints bounds
  where
    -- unpack lp
    jacCoeffs :: [[Coef Double]]
    jacCoeffs = F.toList (fmap F.toList (pjacCoeffs lp))

    bgs :: [(Double,Double)]
    bgs = F.toList (pbg lp)

    bxs :: [(Double,Double)]
    bxs = F.toList (pbx lp)

    goffsets :: [Double]
    goffsets = F.toList (pgoffset lp)

    objCoeffs :: [Double]
    objCoeffs = map asNumber (F.toList (pobjCoeffs lp))

    -- set up problem
    prob = GLPK.Minimize objCoeffs

    constraints = GLPK.Dense $ zipWith3 f jacCoeffs bgs goffsets
      where
        f jcs (lb,ub) (goffset) = (map asNumber jcs) GLPK.:&: (lb-goffset,ub-goffset)

    bounds = zipWith (GLPK.:&:) [0..] bxs


instance (Dim nx, Dim ng) => Arbitrary (Lp nx ng) where
  arbitrary = do
    --x0 <- arbitrary :: Gen (Vec nx Double)
    let x0 = fill 0

    bx <- fmap (fmap unBound) arbitrary :: Gen (Vec nx (Double,Double))

    bg <- fmap (fmap unBound) arbitrary :: Gen (Vec ng (Double,Double))

    goffset <- fmap (devectorize . V.fromList . map fromIntegral) $
               vectorOf (tvlength bg) (choose (0,0::Int))
-- vectorOf (tvlength bg) (choose (-2,2::Int))

    objCoeffs'' <- arbitrary :: Gen (Vec nx (Coef Double))
    let objCoeffs' = fmap absnl objCoeffs''
        makeNonzero objCoeffs0
          | V.any (/= Zero) objCoeffs0 = return (devectorize objCoeffs0)
          | otherwise = do
            k <- choose (0, V.length objCoeffs0 - 1)
            newCoeff <- arbitrary
            makeNonzero (objCoeffs0 V.// [(k,newCoeff)])
    objCoeffs <- makeNonzero (vectorize objCoeffs')

    jacCoeffs <- arbitrary :: Gen (Vec ng (Vec nx (Coef Double)))

    return $ Lp { px0 = x0
                , pbx = bx
                , pbg = bg
                , pgoffset = goffset
                , pobjCoeffs = objCoeffs
                , pjacCoeffs = jacCoeffs
                }
  shrink lp
    | V.all (==0) (vectorize (pgoffset lp)) = []
    | otherwise = [lp { pgoffset = fill 0 }]

justs :: (a, a) -> (Maybe a, Maybe a)
justs (x,y) = (Just x, Just y)

instance (Dim nx, Dim ng) => Arbitrary (FLp nx ng) where
  arbitrary = do
    objCoeffs'' <- arbitrary :: Gen (Vec nx (Coef Double))
    let objCoeffs' = fmap absnl objCoeffs''
        makeNonzero objCoeffs0
          | V.any (/= Zero) objCoeffs0 = return (devectorize objCoeffs0)
          | otherwise = do
            k <- choose (0, V.length objCoeffs0 - 1)
            newCoeff <- arbitrary
            makeNonzero (objCoeffs0 V.// [(k,newCoeff)])
    objCoeffs <- makeNonzero (vectorize objCoeffs')
    
    jacCoeffs <- arbitrary :: Gen (Vec ng (Vec nx (Coef Double)))

    xsol <- arbitrary :: Gen (Vec nx Double)
    let axsol = (fmap (fmap asNumber) jacCoeffs) !*  xsol
        
    bx <- fmap (devectorize . V.fromList) $ createBounds (V.toList (vectorize xsol)) :: Gen (Vec nx (Double, Double))
    bg <- fmap (devectorize . V.fromList) $ createBounds (V.toList (vectorize axsol)) :: Gen (Vec ng (Double, Double))
    goffset <- fmap (devectorize . V.fromList . map fromIntegral) $
               vectorOf (tvlength bg) (choose (0,0::Int))
    x0 <- fmap (devectorize . V.fromList) $ extractGen $ V.toList (vectorize (fmap choose bx))
    return $ FLp $ Lp { px0 = x0
                , pbx = bx
                , pbg = bg
                , pgoffset = goffset
                , pobjCoeffs = objCoeffs
                , pjacCoeffs = jacCoeffs
                }

extractGen :: [Gen a] -> Gen [a]
extractGen [] = return []
extractGen (hd:tl) = do
  h <- hd
  t <- extractGen tl
  return (h:t)

createBounds :: forall t t1.
                      (Fractional t1,
                       Fractional t) =>
                      [Double] -> Gen [(t, t1)]
createBounds xb 
  | xb == [] = return []
  | otherwise = do
    let hxb:txb = xb
    high <- fmap ceiling $ choose (hxb, hxb + 10) :: Gen Int
    low <- fmap floor $ choose (hxb - 10, hxb) :: Gen Int
    end <- createBounds txb
    return $ (realToFrac low, realToFrac high):end

instance (Dim nx, Dim ng) => Arbitrary (ILp nx ng) where
  arbitrary = do
    objCoeffs'' <- arbitrary :: Gen (Vec nx (Coef Double))
    let objCoeffs' = fmap absnl objCoeffs''
        makeNonzero objCoeffs0
          | V.any (/= Zero) objCoeffs0 = return (devectorize objCoeffs0)
          | otherwise = do
            k <- choose (0, V.length objCoeffs0 - 1)
            newCoeff <- arbitrary
            makeNonzero (objCoeffs0 V.// [(k,newCoeff)])
    objCoeffs <- makeNonzero (vectorize objCoeffs')
    bx <- fmap (fmap unBound) arbitrary :: Gen (Vec nx (Double,Double))
    jacCoeffs <- arbitrary :: Gen (Vec ng (Vec nx (Coef Double)))
    x0 <- fmap (devectorize . V.fromList) $ extractGen $ V.toList (vectorize (fmap choose bx))
    gl <- fmap (fmap unBound) arbitrary :: Gen (Vec ng (Double,Double))
    let runMinMax f xs = map (\y -> sum $ zipWith f (zipWith (*) (map fst xs) y) (zipWith (*) (map snd xs) y))
        atoList = V.toList $ vectorize (fmap (V.toList . vectorize) (fmap (fmap asNumber) jacCoeffs))
        lBounds = runMinMax min (V.toList (vectorize bx)) atoList
        uBounds = runMinMax max (V.toList (vectorize bx)) atoList  
    j <- choose (0, V.length (vectorize gl) - 1)
    up <- arbitrary 
    let range = if up then (ceiling (uBounds!!j+1.0) ::Int, ceiling(uBounds!!j+10.0)::Int) 
                      else (floor(lBounds!!j-10.0), floor(lBounds!!j-1.0))
    [l,u] <- vectorOf 2 $ choose range 
    let bg = devectorize $ (vectorize gl) V.// ([(j,(realToFrac (min l u), realToFrac (max l u)))])
    goffset <- fmap (devectorize . V.fromList . map fromIntegral) $
               vectorOf (tvlength bg) (choose (0,0::Int))

    return $ ILp $ Lp { px0 = x0
                , pbx = bx
                , pbg = bg
                , pgoffset = goffset
                , pobjCoeffs = objCoeffs
                , pjacCoeffs = jacCoeffs
                }


newtype LpNlp nx ng = LpNlp (Nlp (Vec nx) None (Vec ng) SXElement)
instance (Dim nx, Dim ng) => Show (Lp nx ng) where
  show = prettyPrint
instance (Dim nx, Dim ng) => Show (FLp nx ng) where
  show (FLp flp) = prettyPrint flp
instance (Dim nx, Dim ng) => Show (ILp nx ng) where
  show (ILp ilp) = prettyPrint ilp

nlpOfLp :: forall nx ng . (Dim nx, Dim ng) => Lp nx ng -> LpNlp nx ng
nlpOfLp (Lp x0 bx bg goffset objCoeffs jacCoeffs) =
  LpNlp $
    Nlp { nlpFG = fg
        , nlpBX = fmap justs bx
        , nlpBG = fmap justs bg
        , nlpX0 = x0
        , nlpP = None
        }
  where
    fg :: Vec nx SXElement -> None SXElement -> (SXElement, Vec ng SXElement)
    fg xs _ = (f, g)
      where
        f = runSum (tvzip xs (fmap (fmap realToFrac) objCoeffs))
        g' = fmap (runSum . tvzip xs) (fmap (fmap (fmap realToFrac)) jacCoeffs)
        g = tvzipWith (+) g' (fmap realToFrac goffset)

glpkUnsolved :: (Dim nx, Dim ng) => ILp nx ng -> Property
glpkUnsolved lp = monadicIO $ do
  let nlp = (getLp lp)
  (_,_) <- case solveWithGlpk nlp of
    GLPK.Feasible _ -> stop (failed {reason = "glpk result Feasible, should not be"})
    GLPK.Optimal _ -> stop (failed {reason = "glpk result Optimal, should definitely not be"})
    _ -> stop (succeeded {reason = "Not solvable !"})
  return ()

glpkSolved :: (Dim nx, Dim ng) => FLp nx ng -> Property
glpkSolved lp = monadicIO $ do
  let nlp = (getLp lp)
  (_,_) <- case solveWithGlpk nlp of
    GLPK.Unbounded -> stop (rejected {reason = "unbounded"})
    GLPK.NoFeasible -> stop (rejected {reason = "NoFeasible"})
    GLPK.Infeasible _ -> stop (rejected {reason = "Infeasible"})
    GLPK.Undefined -> stop (failed {reason = "glpk result Undefined"})
    GLPK.Feasible _ -> stop (failed {reason = "glpk result Feasible, should be optimal"})
    GLPK.Optimal _ -> stop (succeeded {reason = "Optimal !"})
  return ()

ipoptSolved :: (Dim nx, Dim ng) => NlpSolverStuff -> FLp nx ng -> Property
ipoptSolved solver lp = monadicIO $ do
  let LpNlp nlp = nlpOfLp (getLp lp)
  (ret,_) <- run $ solveNlp solver nlp Nothing
  case ret of
    Left "3" -> stop $ rejected {reason = "nlp solver got code 3"}
    Left code -> do
      stop $ failed {reason = "====== nlp solver failed with code " ++ show code ++ " ====="}
    Right "Solve_Succeeded" -> stop (succeeded {reason = "Optimal !"})
    Right _ -> stop (failed {reason = "feasible but not optimal !"})

ipoptUnsolved :: (Dim nx, Dim ng) => NlpSolverStuff -> ILp nx ng -> Property
ipoptUnsolved solver lp = monadicIO $ do
  let LpNlp nlp = nlpOfLp (getLp lp)
  (ret,_) <- run $ solveNlp solver nlp Nothing
  case ret of
    Left "3" -> stop $ rejected {reason = "nlp solver got code 3"}
    Left code -> do
      stop $ succeeded {reason = "====== nlp solver failed with code " ++ show code ++ " ====="}
    Right "Solve_Succeeded" -> stop (failed {reason = "Optimal ?!"})
    Right _ -> stop (failed {reason = "feasible but not optimal ?!"})

matchesGlpk' :: (Dim nx, Dim ng) => NlpSolverStuff -> FLp nx ng -> Property
matchesGlpk' solver flp = matchesGlpk solver (getLp flp)


matchesGlpk :: (Dim nx, Dim ng) => NlpSolverStuff -> Lp nx ng -> Property
matchesGlpk solver lp = monadicIO $ do
  let LpNlp nlp = nlpOfLp lp
  (fopt,xopt) <- case solveWithGlpk lp of
    GLPK.Unbounded -> stop (rejected {reason = "unbounded"})
    GLPK.NoFeasible -> stop (rejected {reason = "NoFeasible"})
    GLPK.Infeasible _ -> stop (rejected {reason = "Infeasible"})
    GLPK.Undefined -> stop (failed {reason = "glpk result Undefined"})
    GLPK.Feasible _ -> stop (failed {reason = "glpk result Feasible, should be optimal"})
    GLPK.Optimal opt -> return opt
  let v@(Valid fe xe ge) = validSol lp (devectorize (V.fromList xopt)) fopt
  unless (and [fe <= 1e-6, xe <= 1e-10, ge <= 1e-10]) $
    stop (failed {reason = "glpk gave invalid solution: " ++ show v})

  (ret,nlpOut) <- run $ solveNlp solver nlp Nothing
  let xerr = maximum (map abs (zipWith (-) xopt (F.toList (xOpt nlpOut))))
      ferr = abs (fopt - fOpt nlpOut)
      v'@(Valid fe' xe' ge') = validSol lp (xOpt nlpOut) (fOpt nlpOut)

      summary = unlines
               [ "design vars"
               , " glpk: " ++ show xopt
               , " nlp: " ++ show (F.toList (xOpt nlpOut))
               , "objective"
               , " glpk: " ++ show fopt
               , " nlp: " ++ show (fOpt nlpOut)
               , ""
               ]
  case ret of
    Left "3" -> stop $ rejected {reason = "nlp solver got code 3"}
    Left code -> do
      --run $ writeFile "counterexample.py" (toPython params)
      stop $ failed {reason = "====== nlp solver failed with code " ++ show code ++ " =====\n"++summary}
    Right _ ->
      if | or [fe' > 1e-5, xe' > 1e-6, ge' > 1e-4] ->
            stop $ failed {reason = "returned invalid solution: " ++ show v'}
         | xerr <= 0.4 && ferr <= 0.4 -> stop $ succeeded {reason = "solutions match"}
         | ferr <= 1e-6 -> stop $ rejected {reason =
             "two valid solutions match objective, don't match decision vars"}
         | otherwise -> do
             --run $ writeFile "counterexample.py" (toPython params)
             stop $ failed { reason = "======== solution doesn't match glpk! ========\n" ++ summary }

prettyPrint :: (Dim nx, Dim ng) => Lp nx ng -> String
prettyPrint (Lp x0' bx' bg' goffset' objCoeffs' jacCoeffs') =
  init $ unlines $
  [ "minimize:"
  , " " ++ myShowList (zipWith showCoeff objCoeffs ks)
  , "subject to:"
  ] ++ (zipWith3 (\coeffs goff (lb,ub) -> " " ++ show lb ++ " <= " ++ myShowList (zipWith showCoeff coeffs ks) ++ " + " ++ show goff ++ " <= " ++ show ub) jacCoeffs goffset bg) ++
  ["subject to (bounds):"] ++
  zipWith (\k (lb,ub) -> " " ++ show lb ++ " <= " ++ xname k ++ " <= " ++ show ub) ks bx
  where
    --maybeOffset
    x0 = V.toList (vectorize x0')
    bx = V.toList (vectorize bx')
    bg = V.toList (vectorize bg')
    goffset = V.toList (vectorize goffset')
    objCoeffs = V.toList (vectorize objCoeffs')
    jacCoeffs = V.toList (vectorize (fmap (V.toList . vectorize) jacCoeffs'))

    n = length x0
    --m = length bg
    ks = take n [1..]
    showCoeff (Linear x) k = Just (show x ++ "*" ++ xname k)
    showCoeff (Nonlinear x) k = Just (show x ++ "*{" ++ xname k ++ "}")
    showCoeff Zero _ = Nothing

    fstIndex = 0 :: Int
    xname k = "x" ++ show (k + fstIndex)
    myShowList :: [Maybe String] -> String
    myShowList = concat . (intersperse " + ") . catMaybes
