{-# LANGUAGE OverloadedStrings #-}
module Main(main) where

import Spec.Contract qualified
import Spec.Emulator qualified
import Spec.ErrorChecking qualified
import Spec.Plutus.Contract.Wallet qualified
import Spec.Rows qualified
import Spec.Secrets qualified
import Spec.State qualified
import Spec.ThreadToken qualified
import Test.Tasty (TestTree, defaultMain, testGroup)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "plutus-contract" [
    Spec.Contract.tests,
    Spec.Emulator.tests,
    Spec.State.tests,
    Spec.Rows.tests,
    Spec.ThreadToken.tests,
    Spec.Secrets.tests,
    Spec.ErrorChecking.tests,
    Spec.Plutus.Contract.Wallet.tests
    ]
