{-# OPTIONS_GHC -Wall #-}
{-# Language FlexibleContexts #-}
{-# Language PolyKinds #-}

module DvdaCasadi ( toCallSXFun, runAlgorithmV, toCallAlgorithmV ) where

import Data.Vector.Generic ( (!) )
--import Data.Vector ( (!) )
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as GM
--import Control.Monad.ST ( ST, runST )
import Control.Monad.Primitive ( PrimState, PrimMonad )
import GHC.Prim ( RealWorld )
import Data.TypeLevel.Num.Sets ( Nat )
import Data.TypeLevel.Num.Reps

import Casadi.Wrappers.Classes.SX
import Casadi.Wrappers.Classes.DMatrix
import Casadi.Wrappers.Classes.SXMatrix
import Casadi.Wrappers.Classes.SXFunction
import Casadi.Wrappers.Classes.SharedObject
import Casadi.Wrappers.Classes.IOInterfaceFX
import Casadi.Wrappers.Classes.FX
import Casadi.Wrappers.Tools ( densify'' )

import Dvda.Algorithm.Construct (
  Node(..), AlgOp(..), Algorithm(..), InputIdx(..), OutputIdx(..),
  constructAlgorithm
  )
import Dvda.Algorithm.Eval ( runAlgorithm )
import Dvda.Expr
import Vectorize
import TypeVecs ( Vec(..) )
import qualified TypeVecs as TV

newtype AlgorithmV f g a = AlgorithmV (Algorithm a)

main :: IO ()
main = do
  let fun :: Num a => Vec D2 a -> Vec D1 a
      fun xs' = TV.unsafeVec (V.fromList [z])
        where
          xs = unVec xs'
          x = xs V.! 0
          y = xs V.! 1
          z = x*x + y
  f <- toCallSXFun fun
  out <- f (TV.unsafeVec (V.fromList [1,2]))
  print out


constructAlgorithmV :: (Vectorize f n, Vectorize g m) =>
                       (f (Expr a) -> g (Expr a)) -> IO (AlgorithmV f g a)
constructAlgorithmV f = fmap AlgorithmV (constructAlgorithm vf vg)
  where
    inputs = ssymsV "x"
    outputs = f (devectorize inputs)

    vf = unVec inputs
    vg = unVec (vectorize outputs)

ssymsV :: Nat n => String -> Vec n (Expr a)
ssymsV name = ret
  where
    ret = TV.unsafeVec $ V.fromList $ take n allSyms
    n = TV.vlength ret
    allSyms = map (sym . ((name ++ "_") ++) . show) [(0::Int)..]

runAlgorithmV :: (Vectorize f n, Vectorize g m) => AlgorithmV f g a -> f a -> g a
runAlgorithmV (AlgorithmV alg) inputs = devectorize (TV.unsafeVec outputVec)
  where
    inputVec = unVec $ vectorize inputs
    outputVec = runAlgorithm alg inputVec

toCallAlgorithmV :: (Vectorize f n, Vectorize g m) => (f (Expr a) -> g (Expr a)) -> IO (f a -> g a)
toCallAlgorithmV f = do
  alg <- constructAlgorithmV f
  return (runAlgorithmV alg)

toCallSXFun :: (Vectorize f n, Vectorize g m) =>
               (f (Expr Double) -> g (Expr Double)) -> IO (f Double -> IO (g Double))
toCallSXFun userFun = do
  alg <- constructAlgorithmV userFun
  f <- toSXFun alg
  sharedObject_init' f

  return $ \x -> do
    let vec = unVec $ vectorize x
    ioInterfaceFX_setInput''' f vec 0
    fx_evaluate'' f
    dmat <- ioInterfaceFX_output f 0
    dmatData <- dmatrix_data dmat
    return (devectorize (TV.unsafeVec dmatData))

casadiSsyms :: String -> Int -> IO (V.Vector SX)
casadiSsyms name k = fmap V.fromList $ mapM (sx'' . (name ++) . show) (take k [(0::Int)..])

toSXFun :: (Vectorize f n, Vectorize g m) => AlgorithmV f g Double -> IO SXFunction
toSXFun alg = do
  (f,g) <- toSX alg
  let inputsSX = unVec (vectorize f)
      outputsSX = unVec (vectorize g)

  outputVec <- sxMatrix''''''''''' outputsSX >>= densify''

  -- input SXMatrix
  sxmat <- sxMatrix''''''''''' inputsSX
  sxFunction''' (V.fromList [sxmat]) (V.fromList [outputVec])

toSX :: (Vectorize f n, Vectorize g m) => AlgorithmV f g Double -> IO (f SX, g SX)
toSX (AlgorithmV alg) = do
  -- work vector
  workVec <- VM.new (algWorkSize alg)

  -- outputs vector
  outputMVec <- VM.new (algOutDims alg)

  -- inputs vector
  inputsSX <- casadiSsyms "x" (algInDims alg)

  mapM_ (op workVec inputsSX outputMVec) (algOps alg)

  outputVec <- V.freeze outputMVec

  return (devectorize (TV.unsafeVec inputsSX), devectorize (TV.unsafeVec outputVec))

op :: (G.Vector v1 SX, GM.MVector v SX, GM.MVector v2 SX) =>
      v RealWorld SX -> v1 SX -> v2 RealWorld SX -> AlgOp Double -> IO ()
op work input _ (InputOp (Node k) (InputIdx i)) = GM.write work k (input ! i)
op work _ output (OutputOp (Node k) (OutputIdx i)) =
  GM.read work k >>= GM.write output i
op work _ _ (NormalOp (Node k) (GConst c)) =
  sx' c >>= GM.write work k
op work input output (NormalOp node (GNum (FromInteger x))) =
  op work input output (NormalOp node (GConst (fromIntegral x)))
op work input output (NormalOp node (GFractional (FromRational x))) =
  op work input output (NormalOp node (GConst (fromRational x)))

op work _ _ (NormalOp k (GNum (Mul x y)))  = bin work k x y sx___mul__
op work _ _ (NormalOp k (GNum (Add x y)))  = bin work k x y sx___add__
op work _ _ (NormalOp k (GNum (Sub x y)))  = bin work k x y sx___sub__
op work _ _ (NormalOp (Node k) (GNum (Negate (Node kx)))) = do
  x <- GM.read work kx
  zero <- sx' (0 :: Double)
  z <- sx___sub__ zero x
  GM.write work k z
op work _ _ (NormalOp k (GFractional (Div x y)))   = bin work k x y sx___truediv__
op work _ _ (NormalOp k (GNum (Abs x)))            = un work k x sx_fabs
op work _ _ (NormalOp k (GNum (Signum x)))         = un work k x sx_sign
op work _ _ (NormalOp k (GFloating (Pow x y)))     = bin work k x y sx___pow__
op work _ _ (NormalOp (Node k) (GFloating (LogBase (Node kx) (Node ky)))) = do
  logx <- GM.read work kx >>= sx_log
  logy <- GM.read work ky >>= sx_log
  z <- sx___truediv__ logy logx
  GM.write work k z

op work _ _ (NormalOp k (GFloating (Exp x)))       = un work k x sx_exp
op work _ _ (NormalOp k (GFloating (Log x)))       = un work k x sx_log
op work _ _ (NormalOp k (GFloating (Sin x)))       = un work k x sx_sin
op work _ _ (NormalOp k (GFloating (Cos x)))       = un work k x sx_cos
op work _ _ (NormalOp k (GFloating (Tan x)))       = un work k x sx_tan
op work _ _ (NormalOp k (GFloating (ASin x)))      = un work k x sx_arcsin
op work _ _ (NormalOp k (GFloating (ATan x)))      = un work k x sx_arctan
op work _ _ (NormalOp k (GFloating (ACos x)))      = un work k x sx_arccos
op work _ _ (NormalOp k (GFloating (Sinh x)))      = un work k x sx_sinh
op work _ _ (NormalOp k (GFloating (Cosh x)))      = un work k x sx_cosh
op work _ _ (NormalOp k (GFloating (Tanh x)))      = un work k x sx_tanh
op work _ _ (NormalOp k (GFloating (ASinh x)))     = un work k x sx_arcsinh
op work _ _ (NormalOp k (GFloating (ATanh x)))     = un work k x sx_arctanh
op work _ _ (NormalOp k (GFloating (ACosh x)))     = un work k x sx_arccosh
op _ _ _ (NormalOp _ (GSym _)) = error "runAlg: there's symbol in my algorithm"

bin :: (PrimMonad m, GM.MVector v t) => v (PrimState m) t -> Node -> Node -> Node -> (t -> t -> m t) -> m ()
bin work (Node k) (Node kx) (Node ky) f = do
  x <- GM.read work kx
  y <- GM.read work ky
  z <- f x y
  GM.write work k z

un :: (PrimMonad m, GM.MVector v a) => v (PrimState m) a -> Node -> Node -> (a -> m a) -> m ()
un work (Node k) (Node kx) f = GM.read work kx >>= f >>= GM.write work k
