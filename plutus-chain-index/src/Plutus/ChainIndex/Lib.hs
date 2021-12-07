{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-| Using the chain index as a library.
-}
module Plutus.ChainIndex.Lib where

import Control.Concurrent.STM qualified as STM
import Control.Monad.Freer (Eff)
import Control.Monad.Freer.Extras.Beam (BeamEffect, BeamLog (SqlLog))
import Control.Monad.Freer.Extras.Log qualified as Log
import Data.Functor (void)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Database.Beam.Migrate.Simple (autoMigrate)
import Database.Beam.Sqlite qualified as Sqlite
import Database.Beam.Sqlite.Migrate qualified as Sqlite
import Database.SQLite.Simple qualified as Sqlite

import Cardano.Api qualified as C
import Cardano.BM.Configuration.Model qualified as CM
import Cardano.BM.Setup (setupTrace_)
import Cardano.BM.Trace (Trace, logDebug, logError, nullTracer)

import Cardano.Protocol.Socket.Client (ChainSyncEvent (..), runChainSync)
import Cardano.Protocol.Socket.Type (epochSlots)
import Plutus.ChainIndex (ChainIndexLog (BeamLogItem), RunRequirements (RunRequirements), getResumePoints,
                          runChainIndexEffects)
import Plutus.ChainIndex qualified as CI
import Plutus.ChainIndex.Compatibility (fromCardanoBlock, fromCardanoPoint, tipFromCardanoBlock)
import Plutus.ChainIndex.Config qualified as Config
import Plutus.ChainIndex.DbSchema (checkedSqliteDb)
import Plutus.ChainIndex.Effects (ChainIndexControlEffect (..), ChainIndexQueryEffect (..), appendBlock, resumeSync,
                                  rollback)
import Plutus.ChainIndex.Logging qualified as Logging
import Plutus.Monitoring.Util (runLogEffects)

withRunRequirements :: CM.Configuration -> Config.ChainIndexConfig -> (RunRequirements -> IO ()) -> IO ()
withRunRequirements logConfig config cont = do
  Sqlite.withConnection (Config.cicDbPath config) $ \conn -> do

    (trace :: Trace IO ChainIndexLog, _) <- setupTrace_ logConfig "chain-index"

    -- Optimize Sqlite for write performance, halves the sync time.
    -- https://sqlite.org/wal.html
    Sqlite.execute_ conn "PRAGMA journal_mode=WAL"
    Sqlite.runBeamSqliteDebug (logDebug trace . (BeamLogItem . SqlLog)) conn $ do
        autoMigrate Sqlite.migrationBackend checkedSqliteDb

    -- Automatically delete the input when an output from a matching input/output pair is deleted.
    -- See reduceOldUtxoDb in Plutus.ChainIndex.Handlers
    Sqlite.execute_ conn "DROP TRIGGER IF EXISTS delete_matching_input"
    Sqlite.execute_ conn
        "CREATE TRIGGER delete_matching_input AFTER DELETE ON unspent_outputs \
        \BEGIN \
        \  DELETE FROM unmatched_inputs WHERE input_row_tip__row_slot = old.output_row_tip__row_slot \
        \                                 AND input_row_out_ref = old.output_row_out_ref; \
        \END"

    stateTVar <- STM.newTVarIO mempty
    cont $ RunRequirements trace stateTVar conn (Config.cicSecurityParam config)

withDefaultRunRequirements :: (RunRequirements -> IO ()) -> IO ()
withDefaultRunRequirements cont = do
    logConfig <- Logging.defaultConfig
    withRunRequirements logConfig Config.defaultConfig cont

type ChainSyncHandler = ChainSyncEvent -> IO ()

defaultChainSynHandler :: RunRequirements -> ChainSyncHandler
defaultChainSynHandler runReq
    (RollForward block _ opt) = do
        let ciBlock = fromCardanoBlock block
        case ciBlock of
            Left err    ->
                logError (CI.trace runReq) (CI.ConversionFailed err)
            Right txs -> void $ runChainIndexDuringSync runReq $
                appendBlock (tipFromCardanoBlock block) txs opt
defaultChainSynHandler runReq
    (RollBackward point _) = do
        void $ runChainIndexDuringSync runReq $ rollback (fromCardanoPoint point)
defaultChainSynHandler runReq
    (Resume point) = do
        void $ runChainIndexDuringSync runReq $ resumeSync $ fromCardanoPoint point

storeFromBlockNo :: C.BlockNo -> ChainSyncHandler -> ChainSyncHandler
storeFromBlockNo storeFrom handler (RollForward block@(C.BlockInMode (C.Block (C.BlockHeader _ _ blockNo) _) _) tip opt) =
    handler (RollForward block tip opt{ CI.bpoStoreTxs = blockNo >= storeFrom })
storeFromBlockNo _ handler evt = handler evt

getTipSlot :: Config.ChainIndexConfig -> IO Integer
getTipSlot config = do
  C.ChainTip (C.SlotNo slotNo) _ _ <- C.getLocalChainTip $ C.LocalNodeConnectInfo
    { C.localConsensusModeParams = C.CardanoModeParams epochSlots
    , C.localNodeNetworkId = Config.cicNetworkId config
    , C.localNodeSocketPath = Config.cicSocketPath config
    }
  pure $ fromIntegral slotNo

showProgress :: Config.ChainIndexConfig -> IORef (Integer, Integer) -> C.SlotNo -> IO ()
showProgress config lastProgressRef (C.SlotNo blockSlot) = do
  (lastProgress, tipSlot) <- readIORef lastProgressRef
  let pct = (100 * fromIntegral blockSlot) `div` tipSlot
  if pct > lastProgress then do
    putStrLn $ "Syncing (" ++ show pct ++ "%)"
    newTipSlot <- getTipSlot config
    writeIORef lastProgressRef (pct, newTipSlot)
  else pure ()

showingProgress :: Config.ChainIndexConfig -> ChainSyncHandler -> IO ChainSyncHandler
showingProgress config handler = do
    -- The primary purpose of this query is to get the first response of the node for potential errors before opening the DB and starting the chain index.
    -- See #69.
    slotNo <- getTipSlot config
    lastProgressRef <- newIORef (0, slotNo)
    pure $ \case
        (RollForward block@(C.BlockInMode (C.Block (C.BlockHeader blockSlot _ _) _) _) tip opt) -> do
            showProgress config lastProgressRef blockSlot
            handler $ RollForward block tip opt
        evt -> handler evt

syncChainIndex :: Config.ChainIndexConfig -> RunRequirements -> ChainSyncHandler -> IO ()
syncChainIndex config runReq syncHandler = do
    Just resumePoints <- runChainIndexDuringSync runReq getResumePoints
    void $ runChainSync (Config.cicSocketPath config)
                        nullTracer
                        (Config.cicSlotConfig config)
                        (Config.cicNetworkId  config)
                        resumePoints
                        syncHandler


runChainIndexDuringSync
  :: RunRequirements
  -> Eff '[ChainIndexQueryEffect, ChainIndexControlEffect, BeamEffect] a
  -> IO (Maybe a)
runChainIndexDuringSync runReq effect = do
    errOrResult <- runChainIndexEffects runReq effect
    case errOrResult of
        Left err -> do
            runLogEffects (CI.trace runReq) $ Log.logError $ CI.Err err
            pure Nothing
        Right result -> do
            pure (Just result)
