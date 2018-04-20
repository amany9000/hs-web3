{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

-- |
-- Module      :  Network.Ethereum.Contract.Event
-- Copyright   :  Alexander Krupenkin 2016-2018
-- License     :  BSD3
--
-- Maintainer  :  mail@akru.me
-- Stability   :  experimental
-- Portability :  unportable
--
-- Ethereum contract event support.
--

module Network.Ethereum.Contract.Event (
    EventAction(..)
  , Event(..)
  , event
  , event'
  , eventMany'
  ) where

import           Control.Concurrent                (threadDelay)
import           Control.Monad                     (forM, void, when)
import           Control.Monad.IO.Class            (liftIO)
import           Control.Monad.Trans.Class         (lift)
import           Control.Monad.Trans.Reader        (ReaderT (..))
import           Data.Either                       (rights)
import           Data.Machine                      (MachineT, asParts, autoM,
                                                    await, construct, final,
                                                    mapping, repeatedly, runT,
                                                    unfoldPlan, (~>))
import           Data.Machine.Plan                 (PlanT, stop, yield)
import           Data.Maybe                        (listToMaybe)

import           Control.Concurrent.Async          (Async)
import           Network.Ethereum.ABI.Event        (DecodeEvent (..))
import           Network.Ethereum.ABI.Prim.Address (Address)
import qualified Network.Ethereum.Web3.Eth         as Eth
import           Network.Ethereum.Web3.Provider    (Web3, forkWeb3)
import           Network.Ethereum.Web3.Types       (BlockNumber (..),
                                                    Change (..),
                                                    DefaultBlock (..),
                                                    Filter (..), FilterId)

-- | Event callback control response
data EventAction = ContinueEvent
                 -- ^ Continue to listen events
                 | TerminateEvent
                 -- ^ Terminate event listener
  deriving (Show, Eq)

-- | Contract event listener
class Event e where
    -- | Event filter structure used by low-level subscription methods
    eventFilter :: Address -> Filter e

-- | Run 'event\'' one block at a time.
event :: (DecodeEvent i ni e, Event e)
      => Filter e
      -> (e -> ReaderT Change Web3 EventAction)
      -> Web3 (Async ())
event fltr handler = forkWeb3 $ event' fltr handler

-- | Same as 'event', but does not immediately spawn a new thread.
event' :: (DecodeEvent i ni e, Event e)
       => Filter e
       -> (e -> ReaderT Change Web3 EventAction)
       -> Web3 ()
event' fltr handler = eventMany' fltr 0 handler

-- | 'eventMany\'' take s a filter, a window size, and a handler.
--
-- It runs the handler over the results of 'eventLogs' results using
-- 'reduceEventStream'. If no 'TerminateEvent' action is thrown and
-- the toBlock is not yet reached, it then transitions to polling.
--
eventMany' :: (DecodeEvent i ni e, Event e)
           => Filter e
           -> Integer
           -> (e -> ReaderT Change Web3 EventAction)
           -> Web3 ()
eventMany' fltr window handler = do
    start <- mkBlockNumber $ filterFromBlock fltr
    let initState = FilterStreamState { fssCurrentBlock = start
                                      , fssInitialFilter = fltr
                                      , fssWindowSize = window
                                      }
    mLastProcessedFilterState <- reduceEventStream (playLogs initState) handler
    case mLastProcessedFilterState of
      Nothing -> startPolling fltr {filterFromBlock = BlockWithNumber start}
      Just (act, lastBlock) -> do
        end <- mkBlockNumber . filterToBlock $ fltr
        when (act /= TerminateEvent && lastBlock < end) $
          let pollingFromBlock = lastBlock + 1
          in startPolling fltr {filterFromBlock = BlockWithNumber pollingFromBlock}
  where
    startPolling fltr' = do
      filterId <- Eth.newFilter fltr'
      let pollTo = filterToBlock fltr'
      void $ reduceEventStream (pollFilter filterId pollTo) handler

-- | Effectively a mapM_ over the machine using the given handler.
reduceEventStream :: Monad m
                  => MachineT m k [FilterChange a]
                  -> (a -> ReaderT Change m EventAction)
                  -> m (Maybe (EventAction, BlockNumber))
reduceEventStream filterChanges handler = fmap listToMaybe . runT $
       filterChanges
    ~> autoM (processChanges handler)
    ~> asParts
    ~> runWhile (\(act, _) -> act /= TerminateEvent)
    ~> final
  where
    runWhile p = repeatedly $ do
      v <- await
      if p v
        then yield v
        else yield v >> stop
    processChanges :: Monad m
                   => (a -> ReaderT Change m EventAction)
                   -> [FilterChange a]
                   -> m [(EventAction, BlockNumber)]
    processChanges handler' changes =
        forM changes $ \FilterChange{..} -> do
            act <- flip runReaderT filterChangeRawChange $
                handler' filterChangeEvent
            return (act, changeBlockNumber filterChangeRawChange)

data FilterChange a = FilterChange { filterChangeRawChange :: Change
                                   , filterChangeEvent     :: a
                                   }

-- | 'playLogs' streams the 'filterStream' and calls eth_getLogs on these 'Filter' objects.
playLogs :: (DecodeEvent i ni e, Event e)
         => FilterStreamState e
         -> MachineT Web3 k [FilterChange e]
playLogs s = filterStream s
          ~> autoM Eth.getLogs
          ~> mapping mkFilterChanges

-- | Polls a filter from the given filterId until the target toBlock is reached.
pollFilter :: forall i ni e k .
              (DecodeEvent i ni e, Event e)
           => FilterId
           -> DefaultBlock
           -> MachineT Web3 k [FilterChange e]
pollFilter i = construct . pollPlan i
  where
    pollPlan :: FilterId -> DefaultBlock -> PlanT k [FilterChange e] Web3 ()
    pollPlan fid end = do
      bn <- lift $ Eth.blockNumber
      if BlockWithNumber bn > end
        then do
          _ <- lift $ Eth.uninstallFilter fid
          stop
        else do
          liftIO $ threadDelay 1000000
          changes <- lift $ Eth.getFilterChanges fid
          yield $ mkFilterChanges changes
          pollPlan fid end

mkFilterChanges :: (Event e, DecodeEvent i ni e)
                => [Change]
                -> [FilterChange e]
mkFilterChanges = rights
                . fmap (\c@Change{..} -> FilterChange c <$> decodeEvent c)

data FilterStreamState e =
  FilterStreamState { fssCurrentBlock  :: BlockNumber
                    , fssInitialFilter :: Filter e
                    , fssWindowSize    :: Integer
                    }


-- | 'filterStream' is a machine which represents taking an initial filter
-- over a range of blocks b1, ... bn (where bn is possibly `Latest` or `Pending`,
-- but b1 is an actual `BlockNumber`), and making a stream of filter objects
-- which cover this filter in intervals of size `windowSize`. The machine
-- halts whenever the `fromBlock` of a spanning filter either (1) excedes then
-- initial filter's `toBlock` or (2) is greater than the chain head's `BlockNumber`.
filterStream :: FilterStreamState e
             -> MachineT Web3 k (Filter e)
filterStream initialPlan = unfoldPlan initialPlan filterPlan
  where
    filterPlan :: FilterStreamState e -> PlanT k (Filter e) Web3 (FilterStreamState e)
    filterPlan initialState@FilterStreamState{..} = do
      end <- lift . mkBlockNumber $ filterToBlock fssInitialFilter
      if fssCurrentBlock > end
        then stop
        else do
          let to' = newTo end fssCurrentBlock fssWindowSize
              filter' = fssInitialFilter { filterFromBlock = BlockWithNumber fssCurrentBlock
                                         , filterToBlock = BlockWithNumber to'
                                         }
          yield filter'
          filterPlan $ initialState { fssCurrentBlock = succBn to' }
    succBn :: BlockNumber -> BlockNumber
    succBn (BlockNumber bn) = BlockNumber $ bn + 1
    newTo :: BlockNumber -> BlockNumber -> Integer -> BlockNumber
    newTo upper (BlockNumber current) window = min upper . BlockNumber $ current + window

-- | Coerce a 'DefaultBlock' into a numerical block number.
mkBlockNumber :: DefaultBlock -> Web3 BlockNumber
mkBlockNumber bm = case bm of
  BlockWithNumber bn -> return bn
  Earliest           -> return 0
  _                  -> Eth.blockNumber
