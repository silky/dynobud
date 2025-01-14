{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PolyKinds #-}

-- todo(greg): rename to PlotPoints or something
module Dyno.DirectCollocation.Dynamic
       ( DynPlotPoints(..)
       , CollTrajMeta(..)
       , addCollocationChannel
       , MetaProxy(..)
       , toMeta
       , dynPlotPoints
       , catDynPlotPoints
       , NameTree(..)
       ) where

import GHC.Generics ( Generic )

import Casadi.Viewable ( Viewable )
import Data.Proxy ( Proxy(..) )
import Data.List ( mapAccumL )
import Data.Tree ( Tree(..) )
import Data.Vector.Cereal ()
import Data.Vector.Binary ()
import Data.Vector ( Vector )
import qualified Data.Vector as V
import qualified Data.Foldable as F
import qualified Data.Traversable as T
import qualified Data.Tree as Tree
import Data.Binary ( Binary )
import Data.Serialize ( Serialize )
import Linear.V

import Accessors ( AccessorTree, Lookup(..), GAData(..), GAConstructor(..), accessors )
import PlotHo ( Plotter, addChannel )

import Dyno.View.Unsafe ( unM, unM' )
import Dyno.Vectorize ( Vectorize(..), Id(..), fill )
import Dyno.View.View ( View(..), JV, splitJV )
import Dyno.View.M ( M )
import Dyno.View.JVec ( JVec(..) )
import qualified Dyno.TypeVecs as TV
import Dyno.TypeVecs ( Vec )
import Dyno.DirectCollocation.Types
import Dyno.DirectCollocation.Quadratures ( QuadratureRoots, mkTaus )

unM'' :: (View f, View g, Viewable a) => String -> M f g a -> a
unM'' msg x = case unM' x of
  Left msg' ->
    error $
    "Dyno.DirectCollocation.Dynamic: unM'' " ++ msg ++ ":\n" ++ msg'
  Right r -> r

addCollocationChannel ::
  String -> (((DynPlotPoints Double, CollTrajMeta) -> IO ()) -> IO ()) -> Plotter ()
addCollocationChannel name action = addChannel name sameMeta toSignalTree action
  where
    toSignalTree ::
      (DynPlotPoints Double, CollTrajMeta)
      -> [Tree ( [String]
               , Either String ((DynPlotPoints Double, CollTrajMeta) -> [[(Double, Double)]])
               )]
    toSignalTree = forestFromMeta . snd

sameMeta :: (DynPlotPoints Double, CollTrajMeta)
            -> (DynPlotPoints Double, CollTrajMeta)
            -> Bool
sameMeta (_,ctm0) (_,ctm1) = ctm0 == ctm1

data DynPlotPoints a = DynPlotPoints
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                       (Vector (Vector (a, Vector a)))
                     deriving Generic


--instance Binary a => Binary (DynPlotPoints a) -- binary is slower than serial by 2x on this
instance Serialize a => Serialize (DynPlotPoints a)

catDynPlotPoints :: V.Vector (DynPlotPoints a) -> DynPlotPoints a
catDynPlotPoints pps =
  DynPlotPoints
  (V.concatMap (\(DynPlotPoints x _ _ _ _ _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ x _ _ _ _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ x _ _ _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ x _ _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ x _ _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ _ x _ _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ _ _ x _ _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ _ _ _ x _) -> x) pps)
  (V.concatMap (\(DynPlotPoints _ _ _ _ _ _ _ _ x) -> x) pps)


dynPlotPoints ::
  forall x z u p h o q qo po n deg a .
  ( Dim n, Dim deg, Real a, Fractional a, Show a
  , Vectorize x, Vectorize z, Vectorize u, Vectorize o, Vectorize p, Vectorize h, Vectorize q
  , Vectorize po, Vectorize qo
  )
  => QuadratureRoots
  -> CollTraj x z u p n deg (Vector a)
  -> Vec n (StageOutputs x o h q qo po deg a)
  -> DynPlotPoints a
dynPlotPoints quadratureRoots (CollTraj tf' _ stages' xf) outputs
  -- if degree is one, each arc will be 1 point and won't get drawn
  -- see https://github.com/ghorn/dynobud/issues/72
  --     https://github.com/ghorn/Plot-ho-matic/issues/10
  --     https://github.com/timbod7/haskell-chart/issues/81
  | reflectDim (Proxy :: Proxy deg) == 1 =
                DynPlotPoints xss (singleArc zss) (singleArc uss) (singleArc oss) (singleArc xdss)
                              (singleArc hss) (singleArc poss) (singleArc qss) (singleArc qdss)
  | otherwise = DynPlotPoints xss zss uss oss xdss hss poss (singleArc qss) qdss
    -- draw quadrature states as a single line since they are differentiable
    -- and gaps are closed by construction
  where
    singleArc :: Vector (Vector b) -> Vector (Vector b)
    singleArc = V.singleton . V.concat . V.toList
    nStages = size (Proxy :: Proxy (JVec n (JV Id)))
    tf,h :: a
    Id tf = splitJV tf'
    h = tf / fromIntegral nStages

    taus :: Vec deg a
    taus = mkTaus quadratureRoots

    stages :: Vec n (CollStage (JV x) (JV z) (JV u) (JV p) deg (Vector a))
    stages = fmap split (unJVec (split stages'))

    xss = xss' `V.snoc` (V.singleton (tf, unM xf))
    -- assumes initial time is 0
    qss = V.singleton (0, vectorize (fill 0 :: Quadratures q qo a)) `V.cons` qss'

    xss',zss,uss,oss,poss,xdss,hss :: Vector (Vector (a, Vector a))
    (xss',zss,uss,oss,xdss,hss,poss,qss',qdss) = unzip9 xzuoxdhs

    -- todo: check this final time tf'' against expected tf
    (_tf'', xzuoxdhs) = T.mapAccumL f 0 $ V.zip (TV.unVec stages) (TV.unVec outputs)


    -- todo(greg): should take the times from toCallbacks, not recalculate
    f :: a
         -> ( CollStage (JV x) (JV z) (JV u) (JV p) deg (Vector a)
            , StageOutputs x o h q qo po deg a
            )
         -> ( a
            , ( V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              , V.Vector (a, V.Vector a)
              )
            )
    f t0 (CollStage x0 xzus' _ _, stageOutputs) = (tnext, (xs,zs,us,os,xds,hs,pos,qs,qds))
      where
        tnext = t0 + h
        xzus0 = fmap split (unJVec (split xzus')) :: Vec deg (CollPoint (JV x) (JV z) (JV u) (Vector a))

        xs :: V.Vector (a, V.Vector a)
        xs = (t0, unM x0) `V.cons` xs' `V.snoc` (tnext, unM (soXNext stageOutputs))

        qs :: V.Vector (a, V.Vector a)
        qs = qs' `V.snoc` (tnext, vectorize (soQNext stageOutputs))

        xs',zs,us,os,xds,hs,pos,qs',qds :: Vector (a, Vector a)
        (xs',zs,us,os,xds,hs,pos,qs',qds) =
          unzip9 $ TV.unVec $ TV.tvzipWith3 g xzus0 (soVec stageOutputs) taus

        g :: CollPoint (JV x) (JV z) (JV u) (Vector a)
             -> StageOutputsPoint x o h q qo po a
             -> a
             -> ( (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                , (a, V.Vector a)
                )
        g (CollPoint x z u) sop tau =
          ( (t,unM'' "x" x)
          , (t,unM'' "z" z)
          , (t,unM'' "u" u)
          , (t,unM'' "o" (sopO sop))
          , (t,unM'' "x'" (sopXDot sop))
          , (t,unM'' "h" (sopH sop))
          , (t,unM'' "po" (sopPo sop))
          , (t,vectorize (sopQs sop))
          , (t,vectorize (sopQDots sop))
          )
          where
            t = t0 + h*tau


data NameTree = NameTreeNode (String, String) [(String, NameTree)]
              | NameTreeLeaf Int
              deriving (Show, Eq, Generic)
instance Binary NameTree
instance Serialize NameTree

data CollTrajMeta = CollTrajMeta { ctmX :: NameTree
                                 , ctmZ :: NameTree
                                 , ctmU :: NameTree
                                 , ctmP :: NameTree
                                 , ctmO :: NameTree
                                 , ctmQ :: NameTree
                                 , ctmH :: NameTree
                                 , ctmPo :: NameTree
                                 } deriving (Eq, Generic, Show)
instance Binary CollTrajMeta
instance Serialize CollTrajMeta

namesFromAccTree :: AccessorTree a -> NameTree
namesFromAccTree x = (\(_,(_,y)) -> y) $ namesFromAccTree' 0 (Just "", x)

namesFromAccTree' :: Int -> (Maybe String, AccessorTree a) -> (Int, (String, NameTree))
namesFromAccTree' k (mname, Left _) = (k+1, (name, NameTreeLeaf k))
  where
    name = case mname of
      Nothing -> "()"
      Just r -> r
namesFromAccTree' k0 (mname, Right (GAData dname (GAConstructor cname ats))) =
  (k, (name, NameTreeNode (dname,cname) children))
  where
    name = case mname of
      Nothing -> "()"
      Just r -> r
    (k, children) = mapAccumL namesFromAccTree' k0 ats
namesFromAccTree' k (mname, Right (GAData dname (GASum _))) =
  (k + 1, (name ++ " (" ++ dname ++ ")", NameTreeLeaf k))
  where
    name = case mname of
      Nothing -> "()"
      Just r -> r


type MetaTree a = Tree.Forest ([String], Either String ((DynPlotPoints a, CollTrajMeta) -> [[(a,a)]]))

forestFromMeta :: CollTrajMeta -> MetaTree Double
forestFromMeta meta =
  [ blah (\(DynPlotPoints x _ _ _  _ _  _ _ _ ) ->  x) ["diff states"] (ctmX meta)
  , blah (\(DynPlotPoints _ z _ _  _ _  _ _ _ ) ->  z) ["alg vars"] (ctmZ meta)
  , blah (\(DynPlotPoints _ _ u _  _ _  _ _ _ ) ->  u) ["controls"] (ctmU meta)
  , blah (\(DynPlotPoints _ _ _ o  _ _  _ _ _ ) ->  o) ["outputs"] (ctmO meta)
  , blah (\(DynPlotPoints _ _ _ _ xd _  _ _ _ ) -> xd) ["ddt(diff states)"] (ctmX meta)
  , blah (\(DynPlotPoints _ _ _ _  _ h  _ _ _ ) ->  h) ["path constraints"] (ctmH meta)
  , blah (\(DynPlotPoints _ _ _ _  _ _ po _ _ ) -> po) ["plot outputs"] (ctmPo meta)
  , blah (\(DynPlotPoints _ _ _ _  _ _  _ q _ ) ->  q) ["quadrature states"] (ctmQ meta)
  , blah (\(DynPlotPoints _ _ _ _  _ _  _ _ qd) -> qd) ["ddt(quad states)"] (ctmQ meta)
  ]
  where
    blah :: forall f c t
            . (Functor f, F.Foldable f)
            => (c -> f (f (t, Vector t))) -> [String] -> NameTree
            -> Tree ([String], Either String ((c, CollTrajMeta) -> [[(t, t)]]))
    blah f myname (NameTreeNode (nm1,_) children) =
      Tree.Node (reverse myname, Left nm1) $ map g children
      where
        g :: (String, NameTree)
          -> Tree ([String], Either String ((c, CollTrajMeta) -> [[(t, t)]]))
        g (x, y) = blah f (x:myname) y
    blah f myname (NameTreeLeaf k) = Tree.Node (reverse myname, Right (woo . f . fst)) []
      where
        woo :: f (f (t, Vector t)) -> [[(t, t)]]
        woo = F.toList . fmap (F.toList . fmap (\(t,x) -> (t, x V.! k)))


data MetaProxy x z u p o q qo po h = MetaProxy

toMeta :: forall x z u p o q qo po h .
          ( Lookup (x ()), Lookup (z ()), Lookup (u ()), Lookup (p ()), Lookup (o ()), Lookup (q ())
          , Lookup (h ()), Lookup (po ()), Lookup (qo ())
          , Vectorize x, Vectorize z, Vectorize u, Vectorize p, Vectorize o, Vectorize q
          , Vectorize h, Vectorize po, Vectorize qo
          )
          => MetaProxy x z u p o q qo po h -> CollTrajMeta
toMeta _ =
  CollTrajMeta
  { ctmX  = namesFromAccTree (accessors :: AccessorTree (x ()))
  , ctmZ  = namesFromAccTree (accessors :: AccessorTree (z ()))
  , ctmU  = namesFromAccTree (accessors :: AccessorTree (u ()))
  , ctmP  = namesFromAccTree (accessors :: AccessorTree (p ()))
  , ctmO  = namesFromAccTree (accessors :: AccessorTree (o ()))
  , ctmQ  = namesFromAccTree (accessors :: AccessorTree (Quadratures q qo ()))
  , ctmH  = namesFromAccTree (accessors :: AccessorTree (h ()))
  , ctmPo = namesFromAccTree (accessors :: AccessorTree (po ()))
  }

--unzip8 :: Vector (a, b, c, d, e, f, g, h)
--          -> (Vector a, Vector b, Vector c, Vector d, Vector e, Vector f, Vector g, Vector h)
--{-# INLINE unzip8 #-}
--unzip8 xs = (V.map (\(a, _, _, _, _, _, _, _) -> a) xs,
--             V.map (\(_, b, _, _, _, _, _, _) -> b) xs,
--             V.map (\(_, _, c, _, _, _, _, _) -> c) xs,
--             V.map (\(_, _, _, d, _, _, _, _) -> d) xs,
--             V.map (\(_, _, _, _, e, _, _, _) -> e) xs,
--             V.map (\(_, _, _, _, _, f, _, _) -> f) xs,
--             V.map (\(_, _, _, _, _, _, g, _) -> g) xs,
--             V.map (\(_, _, _, _, _, _, _, h) -> h) xs)

unzip9 :: Vector (a, b, c, d, e, f, g, h, i)
          -> (Vector a, Vector b, Vector c, Vector d, Vector e, Vector f, Vector g, Vector h, Vector i)
{-# INLINE unzip9 #-}
unzip9 xs = (V.map (\(a, _, _, _, _, _, _, _, _) -> a) xs,
             V.map (\(_, b, _, _, _, _, _, _, _) -> b) xs,
             V.map (\(_, _, c, _, _, _, _, _, _) -> c) xs,
             V.map (\(_, _, _, d, _, _, _, _, _) -> d) xs,
             V.map (\(_, _, _, _, e, _, _, _, _) -> e) xs,
             V.map (\(_, _, _, _, _, f, _, _, _) -> f) xs,
             V.map (\(_, _, _, _, _, _, g, _, _) -> g) xs,
             V.map (\(_, _, _, _, _, _, _, h, _) -> h) xs,
             V.map (\(_, _, _, _, _, _, _, _, i) -> i) xs)
