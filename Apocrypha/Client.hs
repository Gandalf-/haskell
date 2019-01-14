{-# LANGUAGE FlexibleInstances #-}

module Apocrypha.Client
    ( keys,  get,  set,  del , pop , append
    , keys', get', set', del', pop', append'
    , Context, getContext, defaultContext
    ) where

import           Apocrypha.Protocol

import           Control.Monad         (void)
import           Data.Aeson
import           Data.ByteString.Char8 (unpack)
import           Data.ByteString.Lazy  (toStrict)


-- | Keys

keys :: Context -> Query -> IO [String]
keys c items = do
        result <- client c $ items <> ["--keys"]
        pure $ maybe [] words result

keys' :: Query -> IO [String]
keys' items =
        defaultContext >>= (`keys` items)


-- | Del

del :: Context -> Query -> IO ()
del c items =
        void $ client c $ items <> ["--del"]

del' :: Query -> IO ()
del' items =
        defaultContext >>= (`del` items)


-- | Set

set :: (ToJSON a) => Context -> Query -> a -> IO ()
set context items value =
        void $ client context $ items <> ["--set", v]
    where
        v = unpack . toStrict $ encode value

set' :: (ToJSON a) => Query -> a -> IO ()
set' items value =
        defaultContext >>= (\ c -> set c items value)


-- | Get

get :: (FromJSON a) => Context -> Query -> IO (Maybe a)
get context items = do
        result <- jClient context $ items <> ["--edit"]
        pure $ case result of
            Just m  -> decode m :: (FromJSON a) => Maybe a
            Nothing -> Nothing

get' :: (FromJSON a) => Query -> IO (Maybe a)
get' items =
        defaultContext >>= (`get` items)


-- | Append

append :: Context -> Query -> String -> IO ()
append context items value =
        void $ client context $ items <> ["+", value]

append' :: Query -> String -> IO ()
append' items value =
        defaultContext >>= (\ c -> append c items value)


-- | Pop

pop :: Context -> Query -> IO (Maybe String)
pop context items =
        client context $ items <> ["--pop"]

pop' :: Query -> IO (Maybe String)
pop' items =
        defaultContext >>= (`pop` items)
