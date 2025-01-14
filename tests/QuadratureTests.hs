{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}

module QuadratureTests
       ( quadratureTests
       ) where

import GHC.Generics ( Generic, Generic1 )

import Data.Vector ( Vector )
import qualified Test.HUnit.Base as HUnit
import Test.Framework ( Test, testGroup )
import Test.Framework.Providers.HUnit ( testCase )
import Text.Printf ( printf )

import Dyno.Vectorize ( Vectorize(..), None(..), Id(..) )
import Dyno.View.View ( View(..), J, splitJV )
import Dyno.Solvers
import Dyno.Nlp ( NlpOut(..), Bounds )
import Dyno.NlpUtils
import Dyno.Ocp
import Dyno.DirectCollocation.Formulate
import Dyno.DirectCollocation.Types
--import Dyno.DirectCollocation.Types ( CollTraj(..) )
import Dyno.DirectCollocation.Quadratures ( QuadratureRoots(..) )




data QuadOcp
type instance X QuadOcp = QuadX
type instance Z QuadOcp = QuadZ
type instance U QuadOcp = QuadU
type instance P QuadOcp = QuadP
type instance R QuadOcp = QuadR
type instance O QuadOcp = QuadO
type instance C QuadOcp = QuadBc
type instance H QuadOcp = None
type instance Q QuadOcp = QuadQ
type instance QO QuadOcp = None
type instance FP QuadOcp = None
type instance PO QuadOcp = None

data QuadX a = QuadX { xP  :: a
                     , xV  :: a
                     } deriving (Functor, Generic, Generic1, Show)
data QuadZ a = QuadZ  deriving (Functor, Generic, Generic1, Show)
data QuadU a = QuadU deriving (Functor, Generic, Generic1, Show)
data QuadP a = QuadP deriving (Functor, Generic, Generic1, Show)
data QuadR a = QuadR (QuadX a) deriving (Functor, Generic, Generic1, Show)
data QuadO a = QuadO a deriving (Functor, Generic, Generic1, Show)
data QuadBc a = QuadBc (QuadX a) deriving (Functor, Generic, Generic1, Show)
data QuadQ a = QuadQ a deriving (Functor, Generic, Generic1, Show)

instance Vectorize QuadX
instance Vectorize QuadZ
instance Vectorize QuadU
instance Vectorize QuadP
instance Vectorize QuadR
instance Vectorize QuadO
instance Vectorize QuadBc
instance Vectorize QuadQ

mayer :: Num a => QuadOrLagrange -> a -> QuadX a -> QuadX a -> QuadQ a -> QuadP a -> None a -> a
mayer TestQuadratures _ _ _ (QuadQ qf) _ _ = qf
mayer TestLagrangeTerm _ _ _ _ _ _ = 0

data QuadOrLagrange = TestQuadratures | TestLagrangeTerm deriving Show
data StateOrOutput = TestState | TestOutput deriving Show

lagrange :: Num a => StateOrOutput -> QuadOrLagrange -> QuadX a -> QuadZ a -> QuadU a -> QuadP a -> None a -> QuadO a -> a -> a -> a
lagrange _ TestQuadratures _ _ _ _ _ _ _ _ = 0
lagrange TestState TestLagrangeTerm (QuadX _ v) _ _ _ _ _ _ _ = v
lagrange TestOutput TestLagrangeTerm _ _ _ _ _ (QuadO v) _ _ = v

quadratures :: Floating a =>
               StateOrOutput -> QuadX a -> QuadZ a -> QuadU a -> QuadP a -> None a -> QuadO a -> a -> a -> QuadQ a
quadratures TestState (QuadX _ v) _ _ _ _ _ _ _ = QuadQ v
quadratures TestOutput _ _ _ _ _ (QuadO v) _ _ = QuadQ v

dae :: Floating a => QuadX a -> QuadX a -> QuadZ a -> QuadU a -> QuadP a -> None a -> a -> (QuadR a, QuadO a)
dae (QuadX p' v') (QuadX _ v) _ _ _ _ _ = (residual, outputs)
  where
    residual =
      QuadR
      QuadX { xP = p' - v
            , xV = v' - alpha
            }
    outputs = QuadO v

alpha :: Fractional a => a
alpha = 7

tf :: Fractional a => a
tf = 4.4

quadOcp :: StateOrOutput -> QuadOrLagrange -> OcpPhase' QuadOcp
quadOcp stateOrOutput quadOrLag =
  OcpPhase
  { ocpMayer = mayer quadOrLag
  , ocpLagrange = lagrange stateOrOutput quadOrLag
  , ocpQuadratures = quadratures stateOrOutput
  , ocpQuadratureOutputs = \_ _ _ _ _ _ _ _ -> None
  , ocpDae = dae
  , ocpBc = bc
  , ocpPathC = pathc
  , ocpPlotOutputs = \_ _ _ _ _ _ _ _ _ _ _ -> None
  , ocpObjScale      = Nothing
  , ocpTScale        = Nothing
  , ocpXScale        = Nothing
  , ocpZScale        = Nothing
  , ocpUScale        = Nothing
  , ocpPScale        = Nothing
  , ocpResidualScale = Nothing
  , ocpBcScale       = Nothing
  , ocpPathCScale    = Just None
  }

quadOcpInputs :: OcpPhaseInputs' QuadOcp
quadOcpInputs =
  OcpPhaseInputs
  { ocpPathCBnds = None
  , ocpBcBnds = bcBnds
  , ocpXbnd = xbnd
  , ocpUbnd = ubnd
  , ocpZbnd = QuadZ
  , ocpPbnd = QuadP
  , ocpTbnd = (Just tf, Just tf)
  , ocpFixedP = None
  }

pathc :: Floating a => QuadX a -> QuadZ a -> QuadU a -> QuadP a -> None a -> QuadO a -> a -> None a
pathc _ _ _ _ _ _ _ = None

xbnd :: QuadX Bounds
xbnd = QuadX { xP =  (Nothing, Nothing)
             , xV =  (Nothing, Nothing)
             }

ubnd :: QuadU Bounds
ubnd = QuadU

bc :: Floating a => QuadX a -> QuadX a -> QuadQ a -> QuadP a -> None a -> a -> QuadBc a
bc x0 _ _ _ _ _ = QuadBc x0

bcBnds :: QuadBc Bounds
bcBnds =
  QuadBc
  (QuadX
   { xP = (Just 0, Just 0)
   , xV = (Just 0, Just 0)
   })

type NCollStages = 120
type CollDeg = 3

guess :: QuadratureRoots -> J (CollTraj' QuadOcp NCollStages CollDeg) (Vector Double)
guess roots = cat $ makeGuess roots tf guessX guessZ guessU parm
  where
    guessX _ = QuadX { xP = 0
                     , xV = 0
                     }
    guessZ _ = QuadZ
    guessU _ = QuadU
    parm = QuadP



solver :: Solver
solver = ipoptSolver { options = [ ("expand", GBool True)
--                                 , ("ipopt.linear_solver", GString "ma86")
--                                 , ("ipopt.ma86_order", GString "metis")
                                 , ("ipopt.print_level", GInt 0)
                                 , ("print_time", GBool False)
                                 ]}

goodSolution :: NlpOut
                (CollTraj QuadX QuadZ QuadU QuadP NCollStages CollDeg)
                (CollOcpConstraints QuadX QuadP QuadR QuadBc None NCollStages CollDeg)
                (Vector Double)
                -> HUnit.Assertion
goodSolution out = HUnit.assertBool msg (abs (f - fExpected) < 1e-8 && abs (pF - fExpected) < 1e-8)
  where
    msg = printf "    objective: %.4f, final pos: %.4f, expected: %.4f" f pF fExpected
    fExpected = 0.5 * alpha * tf**2 :: Double
    QuadX pF _ = splitJV xf'
    CollTraj _ _ _ xf' = split (xOpt out)
    Id f = splitJV (fOpt out)

compareIntegration :: (MapStrategy, QuadratureRoots, StateOrOutput, QuadOrLagrange, Bool)
                      -> HUnit.Assertion
compareIntegration (mapStrat, roots, stateOrOutput, quadOrLag, unrollMapInHaskell') = HUnit.assert $ do
  let dirCollOpts =
        def
        { mapStrategy = mapStrat
        , collocationRoots = roots
        , unrollMapInHaskell = unrollMapInHaskell'
        }
  cp  <- makeCollProblem dirCollOpts (quadOcp stateOrOutput quadOrLag) quadOcpInputs (guess roots)
  let nlp = cpNlp cp
  (_, eopt) <- solveNlp solver nlp Nothing
  case eopt of
   Left msg -> return (HUnit.assertString msg)
   Right opt -> return (goodSolution opt) :: IO HUnit.Assertion


quadratureTests :: Test
quadratureTests =
  testGroup "quadrature tests"
  [ testCase (show input) (compareIntegration input)
  | root <- [Radau, Legendre]
  , stateOrOutput <- [TestState, TestOutput]
  , quadOrLagr <- [TestQuadratures, TestLagrangeTerm]
  , mapStrat <- [ Unroll
                , Serial
                , Parallel
                ]
  , unrollMapInHaskell' <- [True, False]
  , let input = (mapStrat, root, stateOrOutput, quadOrLagr, unrollMapInHaskell')
  ]
