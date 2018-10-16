{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent
import Control.Concurrent.Async (async)
import Control.Monad.Except
import Control.Monad.Reader
import Data.List (intercalate)
import Network
import System.IO

import Apocrypha.Network2
import Database
import Data.Aeson
import Data.ByteString.Char8 (ByteString)

import qualified Data.HashMap.Strict as HM
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T
import qualified Data.Text.IO as T


type WriteReq = MVar Bool
type Database = MVar Value
type ServerApp = ReaderT ThreadData IO

data ThreadData = ThreadData
        { threadHandle :: Handle
        , userTableMV  :: Database
        , writeRequest :: WriteReq
        }


main :: IO ()
main = do
        server <- listenOn $ PortNumber 9999
        putStrLn "Server started"
        db <- getDB Nothing
        case db of
            Null -> putStrLn "Could not parse database on disk"
            _    -> do
                dbMV <- newMVar db
                wrMV <- newMVar False
                void . async $ runReaderT diskWriter (ThreadData stdout dbMV wrMV)
                withSocketsDo $ clientForker server dbMV wrMV


clientForker :: Socket -> Database -> WriteReq -> IO b
clientForker socket db wr = do
        (h, _, _) <- accept socket
        hSetBuffering h NoBuffering
        void . async $ runReaderT clientLoop (ThreadData h db wr)
        clientForker socket db wr


diskWriter :: ServerApp ()
diskWriter = forever $ do
        write <- viewWrite >>= readMVarT
        db <- viewDatabase >>= readMVarT

        liftIO $ threadDelay oneSecond
        when write $ liftIO . saveDB Nothing $ db

    where oneSecond = 1000000


clientLoop :: ServerApp ()
clientLoop =
        flip catchError (\_ -> return ()) $ do
          query <- getQuery
          case query of
            Nothing  -> return ()
            (Just q) -> do serve q
                           clientLoop


getQuery :: ServerApp (Maybe ByteString)
getQuery = viewHandle >>= liftIO . protoRead


serve :: ByteString -> ServerApp ()
serve t = do
        dbMV <- viewDatabase
        db <- takeMVarT dbMV
        let (result, changed, newDB) = runAction db query
        putMVarT dbMV newDB

        showHeader changed query
        viewHandle >>= \h -> liftIO . protoSend h . B8.pack $ result

        wrMV <- viewWrite
        wr <- takeMVarT wrMV

        if changed
            then putMVarT wrMV True
            else putMVarT wrMV wr

    where
        query = filter (not . null)
              . map T.unpack
              . T.split (== '\n') $ text

        text = T.pack . B8.unpack $ t


runAction :: Value -> Operations -> (String, Bool, Value)
runAction db query =
        (result, changed, newDB)
    where
        (Action newDB changed output) =
            case db of
                (Object o) -> action baseAction query o
                _          -> action baseAction query $ HM.fromList []

        baseAction = Action db False []
        result = intercalate "\n" output ++ "\n"


showHeader c query =
        echoLocal . take 80 $ changed ++ unwords query
    where changed = (if c then '~' else ' ') : " "


putMVarT  = (liftIO . ) . putMVar
readMVarT = liftIO . readMVar
takeMVarT = liftIO . takeMVar

viewHandle   = threadHandle <$> ask
viewDatabase = userTableMV  <$> ask
viewWrite    = writeRequest <$> ask

echoLocal = liftIO . putStrLn
echoMessage msg =
        viewHandle >>= \h -> liftIO . T.hPutStrLn h $ msg
