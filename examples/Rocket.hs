{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}

module Main ( main ) where

import GHC.Generics ( Generic, Generic1 )

import Data.Vector ( Vector )

import Accessors ( Lookup )

import Dyno.View.View ( J, jfill, catJV )
import Dyno.Nlp ( NlpOut(..), Bounds )
import Dyno.Ocp
import Dyno.Vectorize ( Vectorize, None(..), fill )
import Dyno.Solvers ( Solver(..), GType(..), ipoptSolver )
import Dyno.NlpUtils ( solveNlp )
import Dyno.DirectCollocation.ActiveConstraints
import Dyno.DirectCollocation.Formulate
       ( CollProblem(..), DirCollOptions(..), MapStrategy(..), makeCollProblem, def )
import Dyno.DirectCollocation.Types ( CollTraj' )
import Dyno.DirectCollocation.Dynamic ( toMeta )
import Dyno.DirectCollocation.Quadratures ( QuadratureRoots(..) )
import Dynoplot.Callback ( withCallback )

rocketOcp :: OcpPhase' RocketOcp
rocketOcp =
  OcpPhase
  { ocpMayer = mayer
  , ocpLagrange = lagrange
  , ocpQuadratures = \_ _ _ _ _ _ _ _ -> None
  , ocpQuadratureOutputs = \_ _ _ _ _ _ _ _ -> None
  , ocpDae = dae
  , ocpBc = bc
  , ocpPathC = pathC
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

rocketOcpInputs :: OcpPhaseInputs' RocketOcp
rocketOcpInputs =
  OcpPhaseInputs
  { ocpBcBnds = bcBnds
  , ocpPathCBnds = pathCBnds
  , ocpXbnd = RocketX
              { xPos = (Just 0, Nothing)
              , xVel = (Just (-10), Just 0)
              , xMass = (Just 0.01, Nothing)
              , xThrust = (Just (-200), Just 200)
              }
  , ocpZbnd = fill (Nothing, Nothing)
  , ocpUbnd = RocketU
              { uThrustDot = (Just (-100), Just 100) }
  , ocpPbnd = fill (Nothing, Nothing)
  , ocpTbnd = (Just 4, Just 4)
  , ocpFixedP = None
  }

data RocketOcp
type instance X RocketOcp = RocketX
type instance O RocketOcp = RocketO
type instance R RocketOcp = RocketX
type instance U RocketOcp = RocketU
type instance C RocketOcp = RocketBc
type instance H RocketOcp = RocketPathC
type instance P RocketOcp = None
type instance Z RocketOcp = None
type instance Q RocketOcp = None
type instance QO RocketOcp = None
type instance FP RocketOcp = None
type instance PO RocketOcp = None

data RocketX a =
  RocketX
  { xPos :: a
  , xVel :: a
  , xMass :: a
  , xThrust :: a
  } deriving (Functor, Generic, Generic1)
data RocketU a =
  RocketU
  { uThrustDot :: a
  } deriving (Functor, Generic, Generic1)
data RocketO a =
  RocketO
  { oForce :: a
  } deriving (Functor, Generic, Generic1)
data RocketBc a =
  RocketBc
  { bcX0 :: RocketX a
  , bcXF :: RocketX a
  } deriving (Functor, Generic, Generic1)
data RocketPathC a = RocketPathC a deriving (Functor, Generic, Generic1)
instance Vectorize RocketX
instance Vectorize RocketU
instance Vectorize RocketO
instance Vectorize RocketBc
instance Vectorize RocketPathC
instance Lookup a => Lookup (RocketX a)
instance Lookup a => Lookup (RocketU a)
instance Lookup a => Lookup (RocketO a)
instance Lookup a => Lookup (RocketBc a)
instance Lookup a => Lookup (RocketPathC a)


dae :: Floating a
       => RocketX a -> RocketX a -> None a -> RocketU a -> None a -> None a -> a
       -> (RocketX a, RocketO a)
dae (RocketX p' v' m' thrust') (RocketX _ v m thrust) _ (RocketU uThrust') _ _ _ =
  (residual, outputs)
  where
    residual = RocketX
               { xPos = p' - v
               , xVel = v' - force/m
               , xMass = m' - (-1e-2*thrust**2)
               , xThrust = thrust' - uThrust'
               }
    outputs = RocketO { oForce = force
                      }
    g = 9.8
    force = thrust - m*g


bc :: RocketX a -> RocketX a -> None a -> None a -> None a -> a -> RocketBc a
bc x0 xf _ _ _ _ = RocketBc x0 xf

bcBnds :: RocketBc Bounds
bcBnds =
  RocketBc
  { bcX0 = RocketX (Just 1, Just 1) (Just 0, Just 0) (Just 10, Just 10) (Nothing, Nothing)
  , bcXF = RocketX (Just 0, Just 0) (Just 0, Just 0) (Nothing, Nothing) (Nothing, Nothing)
  }

mayer :: Floating a => a -> RocketX a -> RocketX a -> None a -> None a -> None a -> a
mayer _endTime _ (RocketX _ _ mf _) _ _ _ = -mf -- endTime


pathC :: Floating a => RocketX a -> None a -> RocketU a -> None a -> None a -> RocketO a -> a -> RocketPathC a
pathC _ _ _ _ _ _ = RocketPathC

pathCBnds :: RocketPathC Bounds
pathCBnds = RocketPathC (Nothing, Just 4)

lagrange :: Fractional a => RocketX a -> None a -> RocketU a -> None a -> None a -> RocketO a -> a -> a -> a
lagrange _ _ (RocketU u') _ _ _ _ _ = 1e-4*u'*u'
-- (1e-8*u*u + 1e-9*p*p + 1e-9*v*v + 1e-9*m*m)
-- (1e-6*u*u + 1e-6*p*p + 1e-6*v*v + 1e-6*m*m)

solver :: Solver
solver = ipoptSolver { options = [("expand", GBool True)] }

guess :: J (CollTraj' RocketOcp NCollStages CollDeg) (Vector Double)
guess = jfill 1

type NCollStages = 100
type CollDeg = 3

dirCollOpts :: DirCollOptions
dirCollOpts =
  def
  { collocationRoots = Legendre
  , mapStrategy = Unroll
  }

main :: IO ()
main =
  withCallback $ \send -> do

    cp  <- makeCollProblem dirCollOpts rocketOcp rocketOcpInputs guess
    let nlp = cpNlp cp
        meta = toMeta (cpMetaProxy cp)

        cb' traj _ _ = do
          plotPoints <- cpPlotPoints cp traj (catJV None)
          send (plotPoints, meta)

    (_, eopt) <- solveNlp solver nlp (Just cb')
    case eopt of
      Left msg -> putStrLn $ "\nsolve failed with " ++ show msg
      Right opt -> do
        activeConstraints <- getActiveConstraints (cpConstraints cp) rocketOcp 1e-3
                             (xOpt opt) (catJV None) rocketOcpInputs
        putStrLn "\nactive constriants:"
        putStr $ summarizeActiveConstraints activeConstraints
