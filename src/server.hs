{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

import           Control.Concurrent
import           Control.Concurrent.Async (async)
import           Control.Monad.Except
import           Control.Monad.Reader
import           Data.Aeson               (Value (..))
import           Data.ByteString.Char8    (ByteString)
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Text.Encoding       (decodeUtf8, encodeUtf8)
import           Network
import           System.Directory         (doesFileExist, removeFile)
import           System.Environment       (getArgs)
import           System.Exit              (die)
import           System.IO

import           Apocrypha.Database       (Query, defaultDB, getDB, runAction,
                                           saveDB)
import           Apocrypha.Internal.Cache (Cache, emptyCache, get, put)
import           Apocrypha.Options
import           Apocrypha.Protocol       (defaultTCPPort, protoRead, protoSend,
                                           unixSocketPath)


type WriteNeeded = MVar Bool
type Database = MVar Value
type DbCache  = MVar Cache
type ClientCount = MVar Integer
type ServerApp = ReaderT ThreadData IO

data ThreadData = ThreadData
        { _threadHandle :: !Handle
        , _database     :: !Database
        , _writeNeeded  :: !WriteNeeded
        , _clientCount  :: !ClientCount
        , _cache        :: !DbCache
        , _options      :: !Options
        }


main :: IO ()
-- ^ set up the listening socket, read the database from disk and start
-- initial worker threads
main = do
        defaultPath <- defaultDB
        arguments <- getOptions defaultPath defaultTCPPort <$> getArgs

        case arguments of
            Nothing -> die usage

            Just options -> do
                db <- (getDB $ _databasePath options) :: IO Value
                case db of
                    Null -> die "Could not parse database on disk"
                    _    -> startup db options
    where
        startup :: Value -> Options -> IO ()
        startup db options = withSocketsDo $ do
            tcpSocket  <- listenOn $ PortNumber $ _tcpPort options

            putStrLn "Server started"
            dbMV <- newMVar db
            wrMV <- newMVar False
            chMV <- newMVar emptyCache
            ccMV <- newMVar 0

            when (_enablePersist options) $
                persistThread (ThreadData stdout dbMV wrMV ccMV chMV options)

#ifndef mingw32_HOST_OS
            unixSocket <- getUnixSocket
            -- listen on both sockets
            when (_enableUnix options) $
                void . async $
                    clientForker unixSocket dbMV wrMV ccMV chMV options
#endif

            clientForker tcpSocket dbMV wrMV ccMV chMV options

        persistThread :: ThreadData -> IO ()
        persistThread = void . async . runReaderT diskWriter

#ifndef mingw32_HOST_OS
        getUnixSocket :: IO Socket
        getUnixSocket = do
            unixPath <- unixSocketPath
            exists <- doesFileExist unixPath
            when exists $
                removeFile unixPath
            listenOn $ UnixSocket unixPath
#endif


clientForker :: Socket
    -> Database
    -> WriteNeeded
    -> ClientCount
    -> DbCache
    -> Options
    -> IO b
-- ^ listen for clients, fork off workers
clientForker socket d w n c o = forever $ do
        count <- readMVar n
        if count < maxClients
            then do
                (h, _, _) <- accept socket
                hSetBuffering h NoBuffering

                _count <- takeMVar n
                putMVar n (_count + 1)

                forkerThread (ThreadData h d w n c o)

            else threadDelay tenthSecond
    where
        cacheEnabled = _enableCache o
        logEnabled   = _enableLog o
        forkerThread = void . async . runReaderT (clientLoop cacheEnabled logEnabled)
        maxClients   = 500
        tenthSecond  = 100000


diskWriter :: ServerApp ()
-- ^ checks if a write to disk is necessary once per second
-- done in a separate thread so client threads can run faster
diskWriter = forever $ do
        write <- readMVarT =<< viewWrite
        db <- readMVarT =<< viewDatabase
        path <- _databasePath <$> viewOptions

        liftIO $ threadDelay oneSecond
        when write $ liftIO (saveDB path db)
    where
        oneSecond = 1000000


clientLoop :: Bool -> Bool -> ServerApp ()
-- ^ read queries from the client, serve them or quit
clientLoop cacheEnabled logEnabled =
        flip catchError (\_ -> cleanUp) $ do
              query <- getQuery
              case query of
                    Nothing  -> cleanUp

                    (Just q) -> do
                        handle q
                        clientLoop cacheEnabled logEnabled
    where
        handle = serve cacheEnabled logEnabled

        cleanUp = do
            count <- takeMVarT =<< viewCount
            putMVarT (count - 1) =<< viewCount
            pure ()


getQuery :: ServerApp (Maybe ByteString)
-- ^ Read a client query from our network handle
getQuery = viewHandle >>= liftIO . protoRead


serve :: Bool -> Bool -> ByteString -> ServerApp ()
-- ^ Run a user query through the database, and send them the result.
-- If the database reports that it changed, we set writeNeeded.
serve cacheEnabled logEnabled rawQuery = do

        cache <- readMVarT =<< viewCache

        case get cacheEnabled cache query of

            -- cache hit
            Just value -> do
                replyToClient value =<< viewHandle
                when logEnabled $
                    logToConsole cacheHit noChange query

            -- cache miss, or disabled
            Nothing -> do
                db <- takeMVarT =<< viewDatabase

                let (result, changed, newDB) = runAction db query
                    newCache = put cache query result

                putMVarT newDB    =<< viewDatabase
                _ <- takeMVarT =<< viewCache
                putMVarT newCache =<< viewCache

                replyToClient result =<< viewHandle
                when logEnabled $
                    logToConsole cacheMiss noChange query

                when changed $ do
                    setWriteNeeded
                    clearCache
    where
        query :: Query
        query = filter (not . T.null)
              . T.split (== '\n')
              $ decodeUtf8 rawQuery

        cacheHit = True
        cacheMiss = False
        noChange = False


setWriteNeeded :: ServerApp ()
setWriteNeeded = do
    _ <- takeMVarT =<< viewWrite
    putMVarT True =<< viewWrite


clearCache :: ServerApp ()
clearCache = do
    _ <- takeMVarT =<< viewCache
    putMVarT emptyCache =<< viewCache


replyToClient :: Text -> Handle -> ServerApp ()
replyToClient value h = liftIO . protoSend h . encodeUtf8 $ value


logToConsole :: Bool -> Bool -> Query -> ServerApp ()
-- ^ write a summary of the query to stdout
logToConsole hit write query = do
        count <- readMVarT =<< viewCount
        echoLocal . T.take 80 $
            clients count <> status <> T.unwords query
    where
        status
            | hit && write = "? "       -- this shouldn't happen
            | hit          = "  "
            | write        = "~ "
            | otherwise    = "* "       -- no hit, no write

        clients count
            | count < 10  = " "
            | count < 50  = "."
            | count < 100 = "o"
            | count < 250 = "O"
            | count < 450 = "0"
            | otherwise   = "!"


-- | MVar Utilities

putMVarT :: a -> MVar a -> ReaderT ThreadData IO ()
putMVarT thing place = liftIO $ putMVar place thing

readMVarT :: MVar a -> ReaderT ThreadData IO a
readMVarT = liftIO . readMVar

takeMVarT :: MVar a -> ReaderT ThreadData IO a
takeMVarT = liftIO . takeMVar


-- | ReaderT Utilities

viewHandle :: ReaderT ThreadData IO Handle
viewHandle = asks _threadHandle

viewDatabase :: ReaderT ThreadData IO Database
viewDatabase = asks _database

viewWrite :: ReaderT ThreadData IO WriteNeeded
viewWrite = asks _writeNeeded

viewCount :: ReaderT ThreadData IO ClientCount
viewCount = asks _clientCount

viewCache :: ReaderT ThreadData IO DbCache
viewCache = asks _cache

viewOptions :: ReaderT ThreadData IO Options
viewOptions = asks _options

echoLocal :: Text -> ReaderT ThreadData IO ()
echoLocal = liftIO . putStrLn . T.unpack
