{-# OPTIONS_GHC -Wall #-}

module Dyno.Casadi.SXFunction
       ( C.SXFunction, sxFunction
       ) where

import Data.Vector ( Vector )

import qualified Casadi.Wrappers.Classes.SXFunction as C
import Dyno.Casadi.SX ( SX )

sxFunction :: Vector SX -> Vector SX -> IO C.SXFunction
sxFunction inputs outputs = C.sxFunction''' inputs outputs