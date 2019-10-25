{-# LANGUAGE NumericUnderscores, TypeApplications #-}

import qualified Network.Socket as S
import Network.Socket.ByteString (recv, sendAll)

import Control.Applicative ((<|>))
import Control.Monad (forever, when)
import Data.Foldable (for_, find)
import Data.Maybe (mapMaybe)

import System.Environment

import Control.Exception.Safe

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8

import qualified Data.Sequence as Seq

import Data.Ratio

-- An event report represents the result of a single action.
data EventReport = Success | Failure
  deriving Eq

-- The system status is an overview of whether, in general, actions tend to be succeeding or failing.
data SystemStatus = Okay | Alarm
  deriving Eq

main =
  do
    args <- getArgs

    case args of
        ["aggregate-reports"] -> runAggregationService
        ["send-demo-reports"] -> runReportingDemo
        _                     -> putStrLn "Invalid args"

runAggregationService =
  do
    reportQueue <- atomically newTQueue
    alarmQueue <- atomically newTQueue

    foldr1 race_
      [ receiveReports reportQueue
      , analyzeReports reportQueue alarmQueue
      , sendAlarms alarmQueue
      ]


---  Message format  ---

encodeReport r = case r of Failure -> '0'; Success -> '1'

decodeReport c = find (\r -> encodeReport r == c) [Failure, Success]


---  Receiving event reports  ---

serverAddress = S.SockAddrUnix "monitoring-socket"

openServerSocket =
  do
    serverSocket <- S.socket S.AF_UNIX S.Stream S.defaultProtocol
    S.bind serverSocket serverAddress
    S.listen serverSocket S.maxListenQueue
    return serverSocket

receiveReports reportQueue =
    bracket openServerSocket S.close $ \serverSocket -> forever $
      do
        (clientSocket, _clientAddr) <- S.accept serverSocket

        _threadId <-
            forkFinally
                (receiveReports' clientSocket reportQueue)
                (\_ -> S.close clientSocket)

        return ()

receiveReports' clientSocket reportQueue = continue
  where
    continue =
      do
        receivedBytes <- recv clientSocket 1024

        case BS.length receivedBytes of
            0 -> return ()
            _ ->
              do
                receiveReports'' receivedBytes reportQueue
                continue

receiveReports'' receivedBytes reportQueue =
    for_ @[] (Data.ByteString.Char8.unpack receivedBytes) $ \c ->
        for_ @Maybe (decodeReport c) $ \r ->
            atomically (writeTQueue reportQueue r)


---  Analysis of system status changes using event reports  ---

reportsNeeded = 10
okayThreshold = 80 % 100
alarmThreshold = 50 % 100

analyzeReports reportQueue alarmQueue = continue Nothing Seq.empty
  where
    continue status reports =
      do
        newReport <- atomically (readTQueue reportQueue)

        let reports' = Seq.take reportsNeeded (newReport Seq.<| reports)
            status' = analysis reports' <|> status

        for_ @Maybe status' $ \s ->
            when (status /= status') $
                atomically (writeTQueue alarmQueue s)

        continue status' reports'

analysis reports
    | Seq.length reports < reportsNeeded  = Nothing
    | successRate <= alarmThreshold       = Just Alarm
    | successRate >= okayThreshold        = Just Okay
    | otherwise                           = Nothing
  where
    successes = Seq.filter (== Success) reports
    successRate = Seq.length successes % Seq.length reports


---  Sending alerts about system status changes  ---

sendAlarms alarmQueue =
  forever $
    do
      a <- atomically (readTQueue alarmQueue)
      case a of
          Alarm -> putStrLn "Alarm! System is in a degraded state."
          Okay -> putStrLn "System status is normal."


---  Client that sends event reports to an aggregation service  ---

runReportingDemo =
  do
    reportQueue <- atomically newTQueue

    foldr1 race_
      [ generateReports reportQueue
      , sendReports reportQueue
      ]


---  A fixed schedule of event reports for demonstration purposes  ---

demoReports = mapMaybe decodeReport
    "1111111111111010011000001000000100011101111110111111"
    -- successes --     -- failures --    -- successes --

generateReports reportQueue =
    for_ demoReports $ \r ->
      do
        atomically (writeTQueue reportQueue r)
        threadDelay 100_000


---  Sending reports to the server  ---

openClientSocket =
  do
    clientSocket <- S.socket S.AF_UNIX S.Stream S.defaultProtocol
    S.connect clientSocket serverAddress
    return clientSocket

sendReports reportQueue =
  do
    clientSocket <- openClientSocket

    forever $
      do
        r <- atomically (readTQueue reportQueue)
        putStr [encodeReport r]
        sendAll clientSocket (Data.ByteString.Char8.pack [encodeReport r])