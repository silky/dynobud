-- | Turn a haskell function into a C function.

{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}

module Main ( Bar(..), Foo(..), main ) where

import GHC.Generics ( Generic, Generic1 )
import Accessors ( Lookup )

import Dyno.View.ExportCFunction ( CExportOptions(..), exportCFunction' )
import Dyno.View.ExportCStruct ( exportCData )
import Dyno.Vectorize ( Vectorize )

data Bar a =
  Bar
  { barHey :: a
  , barYo :: a
  } deriving (Functor, Generic, Generic1)
instance Lookup a => Lookup (Bar a)
instance Vectorize Bar

data Foo a =
  Foo
  { lol :: a
  , blah :: a
  , excellent :: Bar a
  } deriving (Functor, Generic, Generic1)
instance Lookup a => Lookup (Foo a)
instance Vectorize Foo

foo :: Foo Double
foo = Foo 1 2 (Bar 3 4)

myfun :: Floating a => Bar a -> Foo a
myfun (Bar x y) = Foo (x*y) (x/y) (Bar (x + y) (y ** sin x))

main :: IO ()
main = do
  let opts =
        CExportOptions
        { exportName = "my_awesome_function"
        , headerOverride = Nothing
        --, generateMain = False
        , generateMain = True
        }
  (source, header) <- exportCFunction' myfun opts

  putStrLn source
  putStrLn "=================================================================="
  putStrLn header
  putStrLn "=================================================================="
  putStrLn (exportCData (Just "some_data") foo)