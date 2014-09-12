{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Snap.Snaplet.Wordpress (
   Wordpress(..)
 , WordpressConfig(..)
 , CachePeriod(..)
 , initWordpress
 , initWordpress'
 , PostCacheKey(..)
 , cacheLookup
 , transformName
 ) where

import           Prelude                  hiding ((++))

import           Blaze.ByteString.Builder
import           Control.Applicative
import           Control.Lens
import           Data.Aeson
import qualified Data.Attoparsec.Text     as A
import           Data.ByteString          (ByteString)
import           Data.Char                (toUpper)
import           Data.Default
import qualified Data.HashMap.Strict      as M
import           Data.Monoid
import           Data.Set                 (Set)
import           Data.Text                (Text)
import qualified Data.Text                as T
import qualified Data.Text.Encoding       as T
import           Database.Redis           (Redis)
import qualified Database.Redis           as R
import           Heist
import           Heist.Compiled
import           Heist.Compiled.LowLevel
import           Snap
import           Snap.Snaplet.Heist       (Heist, addConfig)
import           Snap.Snaplet.RedisDB     (RedisDB)
import qualified Snap.Snaplet.RedisDB     as R

(++) :: Monoid a => a -> a -> a
(++) = mappend

data CachePeriod = NoCache | CacheSeconds Int

data WordpressConfig = WordpressConfig { endpoint    :: Text
                                       , requester   :: Maybe (Text -> IO (Maybe Text))
                                       , cachePeriod :: CachePeriod
                                       }

instance Default WordpressConfig where
  def = WordpressConfig "http://127.0.0.1/wp-json" Nothing (CacheSeconds 600)

data Wordpress b = Wordpress { runRedis :: forall a. Redis a -> Handler b (Wordpress b) a}

initWordpress = initWordpress' def

initWordpress' :: WordpressConfig
               -> Snaplet (Heist b)
               -> Simple Lens b (Snaplet RedisDB)
               -> SnapletInit b (Wordpress b)
initWordpress' wpconf heist redis =
  makeSnaplet "wordpress" "" Nothing $
    do conf <- getSnapletUserConfig
       addConfig heist mempty { hcCompiledSplices = wordpressSplices wpconf }
       return $ Wordpress $ withTop' id . R.runRedisDB redis

wordpressSplices :: WordpressConfig -> Splices (Splice (Handler b b))
wordpressSplices conf = do "wpPosts" ## wpPostsSplice conf
                           "wpPostByPermalink" ## wpPostByPermalinkSplice conf


wpPostsSplice :: WordpressConfig -> Splice (Handler b b)
wpPostsSplice conf =
  case requester conf of
    Just r -> do res <- liftIO $ r (endpoint conf ++ "/posts")
                 case (T.encodeUtf8 <$> res) >>= decodeStrict of
                   Just posts -> manyWithSplices runChildren postSplices (return posts)
                   Nothing -> return (yieldPureText "")


wpPostByPermalinkSplice :: WordpressConfig -> Splice (Handler b b)
wpPostByPermalinkSplice conf =
  case requester conf of
    Just r ->
      do promise <- newEmptyPromise
         outputChildren <- withSplices runChildren postSplices (getPromise promise)
         return $ yieldRuntime $
           do mperma <- (parsePermalink . T.decodeUtf8 . rqURI) <$> lift getRequest
              case mperma of
                Nothing -> codeGen (yieldPureText "")
                Just (year, month, slug) ->
                  do res <- liftIO $ r (endpoint conf ++ "/posts?filter[year]=" ++ year
                                                      ++ "&filter[monthnum]=" ++ month
                                                      ++ "&filter[name]=" ++ slug)
                     case (T.encodeUtf8 <$> res) >>= decodeStrict of
                       Just (post:_) -> do putPromise promise post
                                           codeGen outputChildren
                       _ -> codeGen (yieldPureText "")

parsePermalink = either (const Nothing) Just . A.parseOnly parser
  where parser = do A.char '/'
                    year <- A.count 4 A.digit
                    A.char '/'
                    month <- A.count 2 A.digit
                    A.char '/'
                    slug <- A.many1 (A.letter <|> A.char '-')
                    return (T.pack year, T.pack month, T.pack slug)

postSplices :: Monad m => Splices (RuntimeSplice m Object -> Splice m)
postSplices = mapS (pureSplice . textSplice) $ mconcat (map buildSplice ["ID", "title", "type", "content", "excerpt", "date"])
  where buildSplice n = transformName n ## \o -> case M.lookup n o of
                                                   Just (String t) -> t
                                                   Just (Number i) -> T.pack $ show i
                                                   _ -> ""


transformName :: Text -> Text
transformName = T.append "wp" . snd . T.foldl f (True, "")
  where f (True, rest) next = (False, T.snoc rest (toUpper next))
        f (False, rest) '_' = (True, rest)
        f (False, rest) next = (False, T.snoc rest next)


type Year = Text
type Month = Text
type Slug = Text
type Filter = Text
data PostCacheKey = PostByPermalinkKey Year Month Slug
class FormatKey a where
  formatKey :: a -> ByteString

instance FormatKey PostCacheKey where
  formatKey (PostByPermalinkKey y m s) =
    T.encodeUtf8 $ "wordpress:post_perma:" ++ y ++ "_" ++ m ++ "_" ++ s

data PostsCacheKey = PostsKey (Set Filter)

cacheLookup :: PostCacheKey -> Handler b (Wordpress b) (Maybe Object)
cacheLookup key = do (Wordpress run) <- view snapletValue <$> getSnapletState
                     res <- run $ R.get (formatKey key)
                     case res of
                       Left err -> return Nothing
                       Right val -> return $ val >>= decodeStrict
