{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      :  Data.Solidity.Prim.Tuple.TH
-- Copyright   :  Alexander Krupenkin 2016-2018
-- License     :  BSD3
--
-- Maintainer  :  mail@akru.me
-- Stability   :  experimental
-- Portability :  noportable
--
-- This module is for internal usage only.
-- It contains tuple abi encoding template haskell generator.
--

module Data.Solidity.Prim.Tuple.TH (tupleDecs) where


import           Control.Monad       (replicateM)
import           Language.Haskell.TH (DecsQ, Type (VarT), appT, clause, conT,
                                      cxt, funD, instanceD, newName, normalB,
                                      tupleT)

import           Data.Solidity.Abi   (AbiGet, AbiPut, AbiType (..))

tupleDecs :: Int -> DecsQ
tupleDecs n = do
    vars <- replicateM n $ newName "a"
    let types = fmap (pure . VarT) vars
    sequence $
      [ instanceD (cxt $ map (appT $ conT ''AbiType) types) (appT (conT ''AbiType) (foldl appT (tupleT n) types))
          [funD 'isDynamic [clause [] (normalB [|const False|]) []]]
      , instanceD (cxt $ map (appT $ conT ''AbiGet) types) (appT (conT ''AbiGet) (foldl appT (tupleT n) types)) []
      , instanceD (cxt $ map (appT $ conT ''AbiPut) types) (appT (conT ''AbiPut) (foldl appT (tupleT n) types)) [] ]
