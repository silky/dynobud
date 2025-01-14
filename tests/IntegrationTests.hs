{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}

module IntegrationTests
       ( integrationTests
       ) where

import GHC.Generics ( Generic, Generic1 )

import Data.Proxy ( Proxy(..) )
import Data.Vector ( Vector )
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import qualified Numeric.GSL.ODE as ODE
import qualified Numeric.LinearAlgebra.Data as D
import qualified Test.HUnit.Base as HUnit
import Test.Framework ( Test, testGroup )
import Test.Framework.Providers.HUnit ( testCase )
import Linear ( Additive )

import Dyno.Vectorize ( Vectorize(..), None(..), devectorize, fill )
import Dyno.View.View ( View(..), J, splitJV )
import Dyno.TypeVecs ( Dim )
import Dyno.Solvers
import Dyno.Nlp ( NlpOut(..) )
import Dyno.NlpUtils

import Dyno.Ocp
import Dyno.DirectCollocation.Formulate
import Dyno.DirectCollocation.Types ( CollTraj(..) )
import Dyno.DirectCollocation.Quadratures ( QuadratureRoots(..) )


data PendX a = PendX a a deriving (Functor, Generic, Generic1, Show)
data PendP a = PendP a deriving (Functor, Generic, Generic1, Show)

instance Vectorize PendX
instance Vectorize PendP

over :: Vectorize f => (a -> a -> a) -> f a -> f a -> f a
over f x y = devectorize $ V.zipWith f (vectorize x) (vectorize y)

minus :: (Vectorize f, Num a) => f a -> f a -> f a
minus = over (-)

--divv :: (Vectorize f, Fractional a) => f a -> f a -> f a
--divv = over (/)


data IntegrationOcp x p
type instance X (IntegrationOcp x p) = x
type instance Z (IntegrationOcp x p) = None
type instance U (IntegrationOcp x p) = None
type instance P (IntegrationOcp x p) = p
type instance R (IntegrationOcp x p) = x
type instance O (IntegrationOcp x p) = None
type instance C (IntegrationOcp x p) = x
type instance H (IntegrationOcp x p) = None
type instance Q (IntegrationOcp x p) = None
type instance QO (IntegrationOcp x p) = None
type instance FP (IntegrationOcp x p) = None
type instance PO (IntegrationOcp x p) = None

runIntegration ::
  forall x p deg n
  . ( Vectorize x, Vectorize p, Additive x, Dim deg, Dim n )
  => Proxy n -> Proxy deg
  -> DirCollOptions
  -> (forall a . Floating a => x a -> p a -> a -> x a)
  -> x Double -> p Double -> Double
  -> IO (Either String (x Double))
runIntegration _ _ dirCollOpts ode x0 p tf = do
  let ocp :: OcpPhase' (IntegrationOcp x p)
      ocp =
        OcpPhase
        { ocpMayer = \_ _ _ _ _ _ -> 0
        , ocpLagrange = \_ _ _ _ _ _ _ _ -> 0
        , ocpDae = \x' x _ _ pp _ t -> ((ode x pp t) `minus` x', None)
        , ocpQuadratures = \_ _ _ _ _ _ _ _ -> None
        , ocpQuadratureOutputs = \_ _ _ _ _ _ _ _ -> None
        , ocpBc = \x0' _ _ _ _ _ -> x0'
        , ocpPathC = \_ _ _ _ _ _ _ -> None
        , ocpPlotOutputs = \_ _ _ _ _ _ _ _ _ _ _ -> None
        , ocpObjScale      = Nothing
        , ocpTScale        = Nothing
        , ocpXScale        = Nothing
        , ocpZScale        = Nothing
        , ocpUScale        = Nothing
        , ocpPScale        = Nothing
        , ocpResidualScale = Nothing
        , ocpBcScale       = Nothing
        , ocpPathCScale    = Nothing
        }
      ocpInputs :: OcpPhaseInputs' (IntegrationOcp x p)
      ocpInputs =
        OcpPhaseInputs
        { ocpPathCBnds = None
        , ocpBcBnds =  fmap (\x -> (Just x, Just x)) x0
        , ocpXbnd = fill (Nothing, Nothing)
        , ocpUbnd = None
        , ocpZbnd = None
        , ocpPbnd = fmap (\x -> (Just x, Just x)) p
        , ocpTbnd = (Just tf, Just tf)
        , ocpFixedP = None
        }
  let guess :: J (CollTraj x None None p n deg) (Vector Double)
      guess = cat $ makeGuessSim (collocationRoots dirCollOpts) tf x0 (\_ x _ -> ode x p 0) (\_ _ -> None) p
  cp  <- makeCollProblem dirCollOpts ocp ocpInputs guess :: IO (CollProblem x None None p x None x None None None None None n deg)
  (_, eopt) <- solveNlp solver (cpNlp cp) Nothing
  return $ case eopt of
    Left m -> Left m
    Right opt -> Right (toXf (xOpt opt))




pendOde :: Floating a => PendX a -> PendP a -> a -> PendX a
pendOde (PendX theta omega) (PendP mass) t = PendX omega ((9.8 * sin theta + force) / mass)
  where
    force = 0.3 * sin t

solver :: Solver
solver = ipoptSolver { options = [ ("expand", GBool True)
                                 --, ("ipopt.linear_solver", GString "ma86")
                                 --, ("ipopt.ma86_order", GString "metis")
                                 , ("ipopt.tol", GDouble 1e-11)
                                 ] }

pendX0 :: PendX Double
pendX0 = PendX 0 0.2

pendP :: PendP Double
pendP = PendP 2.3


rk45 :: (Vectorize x, Vectorize p)
        => (x Double -> p Double -> Double -> x Double)
        -> Double -> p Double -> x Double -> x Double
rk45 f h p x0 = devectorize $ sv $ last sol
  where
    vs :: V.Vector Double -> SV.Vector Double
    vs = SV.fromList .  V.toList
    sv :: SV.Vector Double -> V.Vector Double
    sv =  V.fromList . SV.toList

    sol = D.toRows $
          ODE.odeSolveV
          ODE.RKf45
          h 1e-10 1e-8 f'
          (vs (vectorize x0))
          (SV.fromList [0.0, h])
    f' :: Double -> SV.Vector Double -> SV.Vector Double
    f' t x = vs $ vectorize $ f (devectorize (sv x)) p t

toXf :: ( Vectorize x, Vectorize z, Vectorize u, Vectorize p
        , Dim n, Dim deg
        ) => J (CollTraj x z u p n deg) (Vector Double)-> x Double
toXf traj = splitJV xf
  where
    CollTraj _ _ _ xf = split traj


integrationTests :: Test
integrationTests =
  testGroup "integration tests"
  [ testGroup (show roots)
    [ testGroup (show mapStrat)
      [ testGroup ("unroll in haskell: " ++ show unrollInHaskell)
        [ testCase "pendulum" $ compareIntegration (Proxy :: Proxy 80) (Proxy :: Proxy 3) dirCollOpts pendOde pendX0 pendP tf
        ]
      | unrollInHaskell <- [True, False]
      , let dirCollOpts =
              def
              { mapStrategy = mapStrat
              , collocationRoots = roots
              , unrollMapInHaskell = unrollInHaskell
              }
      ]
    | mapStrat <- [Unroll, Serial, Parallel]
    ]
  | roots <- [Radau, Legendre]
  ]
  where
    tf = 3.0


compareIntegration ::
  forall x p n deg
  . (Vectorize x, Vectorize p, Additive x, Dim n, Dim deg)
  => Proxy n -> Proxy deg
  -> DirCollOptions
  -> (forall a . Floating a => x a -> p a -> a -> x a)
  -> x Double -> p Double -> Double -> HUnit.Assertion
compareIntegration pn pdeg dirCollOpts ode x0 p tf = HUnit.assert $ do
  x' <- runIntegration pn pdeg dirCollOpts ode x0 p tf
  let xGsl = rk45 ode tf p x0

      ret :: HUnit.Assertion
      ret = case x' of
        Left err -> HUnit.assertString $ "failed with: " ++ show err
        Right x
          | worstErr <= 1e-6 -> HUnit.assert True
          | otherwise -> HUnit.assertString $ "insufficient accuracy: " ++ show worstErr
          where
            worstErr :: Double
            worstErr = V.maximum $ V.map abs $ vectorize $ x `minus` xGsl

  return ret :: IO HUnit.Assertion
