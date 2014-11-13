{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Main where

import           Prelude                     hiding ((++))

import           Blaze.ByteString.Builder
import           Control.Lens                hiding ((.=))
import           Control.Monad               (join)
import           Control.Monad.Trans         (liftIO)
import           Control.Monad.Trans.Either
import           Control.Concurrent.MVar
import           Data.Aeson                  hiding (Success)
import           Data.Default
import qualified Data.HashMap.Strict         as M
import           Data.List                   (intersect)
import           Data.Maybe
import           Data.Monoid
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T
import qualified Data.Text.Lazy              as TL
import qualified Data.Text.Lazy.Encoding     as TL
import qualified Database.Redis              as R
import           Heist
import           Heist.Compiled
import qualified Misc
import           Snap                        hiding (get)
import           Snap.Snaplet.Heist.Compiled
import           Snap.Snaplet.RedisDB
import           Snap.Snaplet.Wordpress
import           Test.Hspec
import           Test.Hspec.Core             (Result (..))
import           Test.Hspec.Snap
import qualified Text.XmlHtml                as X

(++) :: Monoid a => a -> a -> a
(++) = mappend

----------------------------------------------------------
-- Section 1: Example application used for testing.     --
----------------------------------------------------------

data App = App { _heist     :: Snaplet (Heist App)
               , _redis     :: Snaplet RedisDB
               , _wordpress :: Snaplet (Wordpress App) }

makeLenses ''App

instance HasHeist App where
    heistLens = subSnaplet heist

enc a = TL.toStrict . TL.decodeUtf8 . encode $ a

article2 = object [ "ID" .= (2 :: Int)
                  , "title" .= ("The post" :: Text)
                  , "excerpt" .= ("summary" :: Text)
                  ]

fakeRequester "/posts" ps | length (ps `intersect` [ ("filter[year]", "2009")
                                                   , ("filter[monthnum]", "10")
                                                   , ("filter[name]", "the-post")]) == 3 =
  return $ enc [article2]
fakeRequester "/posts" _ = return $ enc [article1]
fakeRequester a b = error $ show a ++ show b

jacobinFields = [N "featured_image" [N "attachment_meta" [N "sizes" [N "mag-featured" [F "width"
                                                                                      ,F "height"
                                                                                      ,F "url"]
                                                                    ,N "single-featured" [F "width"
                                                                                         ,F "height"
                                                                                         ,F "url"]]]]]

renderingApp :: [(Text, Text)] -> Text -> SnapletInit App App
renderingApp tmpls response = makeSnaplet "app" "App." Nothing $ do
                     h <- nestSnaplet "" heist $ heistInit ""
                     addConfig h $ set scTemplateLocations (return templates) mempty
                     r <- nestSnaplet "" redis redisDBInitConf
                     w <- nestSnaplet "" wordpress $ initWordpress' config h redis wordpress
                     return $ App h r w
  where mkTmpl (name, html) = let (Right doc) = X.parseHTML "" (T.encodeUtf8 html)
                               in ([T.encodeUtf8 name], DocumentFile doc Nothing)
        templates = return $ M.fromList (map mkTmpl tmpls)
        config = (def { endpoint = ""
                      , requester = Just (\_ _-> return response)
                      , cachePeriod = NoCache
                      , extraFields = jacobinFields})

queryingApp :: [(Text, Text)] -> MVar Text -> SnapletInit App App
queryingApp tmpls record = makeSnaplet "app" "An snaplet example application." Nothing $ do
                     h <- nestSnaplet "" heist $ heistInit "templates"
                     addConfig h $ set scTemplateLocations (return templates) mempty
                     r <- nestSnaplet "" redis redisDBInitConf
                     w <- nestSnaplet "" wordpress $ initWordpress' config h redis wordpress
                     return $ App h r w
  where mkTmpl (name, html) = let (Right doc) = X.parseHTML "" (T.encodeUtf8 html)
                               in ([T.encodeUtf8 name], DocumentFile doc Nothing)
        templates = return $ M.fromList (map mkTmpl tmpls)
        config = (def { endpoint = ""
                      , requester = Just recordingRequester
                      , cachePeriod = NoCache})
        recordingRequester url params = do
          tryPutMVar record $ mkUrlUnescape url params
          return ""
        mkUrlUnescape url params = (url <> "?" <> (T.intercalate "&" $ map (\(k, v) -> k <> "=" <> v) params))

cachingApp :: SnapletInit App App
cachingApp = makeSnaplet "app" "An snaplet example application." Nothing $ do
                     h <- nestSnaplet "" heist $ heistInit "templates"
                     r <- nestSnaplet "" redis redisDBInitConf
                     w <- nestSnaplet "" wordpress $ initWordpress' config h redis wordpress
                     return $ App h r w
  where config = (def { endpoint = ""
                    , requester = Just (\_ _-> return "")
                    , cachePeriod = CacheSeconds 1})

----------------------------------------------------------
-- Section 2: Test suite against application.           --
----------------------------------------------------------

shouldRenderTo :: (Text, Text) -> Text -> Spec
shouldRenderTo (tags, response) match =
  snap (route []) (renderingApp [("test", tags)] response) $
    it (T.unpack $ tags ++ " should render to match " ++ match) $
      do t <- eval (do st <- getHeistState
                       builder <- (fst.fromJust) $ renderTemplate st "test"
                       return $ T.decodeUtf8 $ toByteString builder)
         setResult $
           if match == t
             then Success
             else Fail (show t <> " didn't match " <> show match)

clearRedisCache :: Handler App App (Either R.Reply Integer)
clearRedisCache = runRedisDB redis (R.eval "return redis.call('del', unpack(redis.call('keys', ARGV[1])))" [] ["wordpress:*"])

article1 :: Value
article1 = object [ "ID" .= ("1" :: Text)
                  , "title" .= ("Foo bar" :: Text)
                  , "excerpt" .= ("summary" :: Text)
                  ]

main :: IO ()
main = hspec $ do
  Misc.tests
  describe "<wpPosts>" $ do
    ("<wpPosts><wpTitle/></wpPosts>", enc [article1]) `shouldRenderTo` "Foo bar"
    ("<wpPosts><wpID/></wpPosts>", enc [article1]) `shouldRenderTo` "1"
    ("<wpPosts><wpExcerpt/></wpPosts>", enc [article1]) `shouldRenderTo` "summary"
  describe "<wpNoPostDuplicates/>" $ do
    ("<wpNoPostDuplicates/><wpPosts><wpTitle/></wpPosts><wpPosts><wpTitle/></wpPosts>", enc [article1])
      `shouldRenderTo` "Foo bar"
    ("<wpPosts><wpTitle/></wpPosts><wpNoPostDuplicates/><wpPosts><wpTitle/></wpPosts>", enc [article1])
      `shouldRenderTo` "Foo barFoo bar"
    ("<wpPosts><wpTitle/></wpPosts><wpNoPostDuplicates/><wpPosts><wpTitle/></wpPosts><wpPosts><wpTitle/></wpPosts>", enc [article1])
      `shouldRenderTo` "Foo barFoo bar"
    ("<wpPosts><wpTitle/></wpPosts><wpPosts><wpTitle/></wpPosts><wpNoPostDuplicates/>", enc [article1])
      `shouldRenderTo` "Foo barFoo bar"
{-  describe "<wpPostByPermalink>" $ do
    shouldRenderAtUrl "/2009/10/the-post/"
                      "<wpPostByPermalink><wpTitle/></wpPostByPermalink>"
                      "The post"
    shouldRenderAtUrl "/posts/2009/10/the-post/"
                      "<wpPostByPermalink><wpTitle/></wpPostByPermalink>"
                      "The post"
    shouldRenderAtUrl "/posts/2009/10/the-post"
                      "<wpPostByPermalink><wpTitle/></wpPostByPermalink>"
                      "The post"
    shouldRenderAtUrl "/2009/10/the-post/"
                      "<wpPostByPermalink><wpTitle/>: <wpExcerpt/></wpPostByPermalink>"
                      "The post: summary" -}
{-    describe "should grab post from cache if it's there" $
      let (Object a2) = article2 in
      shouldRenderAtUrlPreCache
        (void $ with wordpress $ cacheSet (Just 10) (PostByPermalinkKey "2001" "10" "the-post")
                                            (enc a2))
        "/2001/10/the-post/"
        "<wpPostByPermalink><wpTitle/></wpPostByPermalink>"
        "The post" -}
  describe "caching" $ snap (route []) cachingApp $ afterEval (void clearRedisCache) $ do
    it "should find nothing for a non-existent post" $ do
      p <- eval (with wordpress $ cacheLookup (PostByPermalinkKey "2000" "1" "the-article"))
      p `shouldEqual` Nothing
    it "should find something if there is a post in cache" $ do
      eval (with wordpress $ cacheSet (Just 10) (PostByPermalinkKey "2000" "1" "the-article")
                                         (enc article1))
      p <- eval (with wordpress $ cacheLookup (PostByPermalinkKey "2000" "1" "the-article"))
      p `shouldEqual` (Just $ enc article1)
    it "should not find single post after expire handler is called" $
      do eval (with wordpress $ cacheSet (Just 10) (PostByPermalinkKey "2000" "1" "the-article")
                                            (enc article1))
         eval (with wordpress $ expirePost 1)
         eval (with wordpress $ cacheLookup (PostByPermalinkKey "2000" "1" "the-article"))
           >>= shouldEqual Nothing
    it "should not find post aggregates after expire handler is called" $
      do let key = PostsKey (Set.fromList [NumFilter 20, OffsetFilter 0, PageFilter 1, LimitFilter 20])
         eval (with wordpress $ cacheSet (Just 10) key ("[" ++ enc article1 ++ "]"))
         eval (with wordpress $ expirePost 1)
         eval (with wordpress $ cacheLookup key)
           >>= shouldEqual Nothing
    it "should find single post after expiring aggregates" $
      do eval (with wordpress $ cacheSet (Just 10) (PostByPermalinkKey "2000" "1" "the-article")
                                           (enc article1))
         eval (with wordpress expireAggregates)
         eval (with wordpress $ cacheLookup (PostByPermalinkKey "2000" "1" "the-article"))
           >>= shouldNotEqual Nothing
    it "should find a different single post after expiring another" $
      do let key1 = (PostByPermalinkKey "2000" "1" "the-article")
             key2 = (PostByPermalinkKey "2001" "2" "another-article")
         eval (with wordpress $ cacheSet (Just 10) key1 (enc article1))
         eval (with wordpress $ cacheSet (Just 10) key2 (enc article2))
         eval (with wordpress $ expirePost 1)
         eval (with wordpress $ cacheLookup key2) >>= shouldEqual (Just (enc article2))

  describe "generate queries from <wpPosts>" $ do
    shouldQueryTo
      "<wpPosts></wpPosts>"
      "/posts?filter[posts_per_page]=20&filter[offset]=0"
    shouldQueryTo
      "<wpPosts limit=2></wpPosts>"
      "/posts?filter[posts_per_page]=20&filter[offset]=0"
    shouldQueryTo
      "<wpPosts offset=1 limit=1></wpPosts>"
      "/posts?filter[posts_per_page]=20&filter[offset]=1"
    shouldQueryTo
      "<wpPosts offset=0 limit=1></wpPosts>"
      "/posts?filter[posts_per_page]=20&filter[offset]=0"
    shouldQueryTo
      "<wpPosts limit=10 page=1></wpPosts>"
      "/posts?filter[posts_per_page]=20&filter[offset]=0"
    shouldQueryTo
      "<wpPosts limit=10 page=2></wpPosts>"
      "/posts?filter[posts_per_page]=20&filter[offset]=20"
    shouldQueryTo
      "<wpPosts num=2></wpPosts>"
      "/posts?filter[posts_per_page]=2&filter[offset]=0"
    shouldQueryTo
      "<wpPosts num=2 page=2 limit=1></wpPosts>"
      "/posts?filter[posts_per_page]=2&filter[offset]=2"
    shouldQueryTo
      "<wpPosts num=1 page=3></wpPosts>"
      "/posts?filter[posts_per_page]=1&filter[offset]=2"

shouldQueryTo :: Text -> Text -> Spec
shouldQueryTo hQuery wpQuery = do
  record <- runIO newEmptyMVar
  snap (route []) (queryingApp [("x", hQuery)] record) $
    it ("query from " <> T.unpack hQuery) $ do
      eval $ render "x"
      x <- liftIO $ tryTakeMVar record
      x `shouldEqual` Just wpQuery




{-     ,("tag1", "<wpPosts tags=\"home-featured\" limit=10><wpTitle/></wpPosts>")
              ,("tag2", "<wpPosts limit=10><wpTitle/></wpPosts>")
              ,("tag3", "<wpPosts tags=\"+home-featured\" limit=10><wpTitle/></wpPosts>")
              ,("tag4", "<wpPosts tags=\"-home-featured\" limit=1><wpTitle/></wpPosts>")
              ,("tag5", "<wpPosts tags=\"+home-featured\" limit=1><wpTitle/></wpPosts>")
              ,("tag6", "<wpPosts tags=\"+home-featured,-featured-global\" limit=1><wpTitle/></wpPosts>")
              ,("tag7", "<wpPosts tags=\"+home-featured,+featured-global\" limit=1><wpTitle/></wpPosts>")
              ,("cat1", "<wpPosts categories=\"bookmarx\" limit=10><wpTitle/></wpPosts>")
              ,("cat2", "<wpPosts limit=10><wpTitle/></wpPosts>")
              ,("cat3", "<wpPosts categories=\"-bookmarx\" limit=10><wpTitle/></wpPosts>")
              ,("author-date", "<wpPostByPermalink><wpAuthor><wpName/></wpAuthor><wpDate><wpYear/>/<wpMonth/></wpDate></wpPostByPermalink>")
              ,("fields", "<wpPosts limit=1 categories=\"-bookmarx\"><wpFeaturedImage><wpAttachmentMeta><wpSizes><wpThumbnail><wpUrl/></wpThumbnail></wpSizes></wpAttachmentMeta></wpFeaturedImage></wpPosts>")
              ,("extra-fields", "<wpPosts limit=1 categories=\"-bookmarx\"><wpFeaturedImage><wpAttachmentMeta><wpSizes><wpMagFeatured><wpUrl/></wpMagFeatured></wpSizes></wpAttachmentMeta></wpFeaturedImage></wpPosts>")

  describe "live tests (which require config file w/ user and pass to sandbox.jacobinmag.com)" $
    snap (route [("/2014/10/a-war-for-power", render "single")
                ,("/2014/10/the-assassination-of-detroit/", render "author-date")
                ])
         (queryingApp [("single", "<wpPostByPermalink><wpTitle/></wpPostByPermalink>")
              ,("many", "<wpPosts limit=2><wpTitle/></wpPosts>")
              ,("many1", "<wpPosts><wpTitle/></wpPosts>")
              ,("many2", "<wpPosts offset=1 limit=1><wpTitle/></wpPosts>")
              ,("many3", "<wpPosts offset=0 limit=1><wpTitle/></wpPosts>")
              ,("page1", "<wpPosts limit=10 page=1><wpTitle/></wpPosts>")
              ,("page2", "<wpPosts limit=10 page=2><wpTitle/></wpPosts>")
              ,("num1", "<wpPosts num=2><wpTitle/></wpPosts>")
              ,("num2", "<wpPosts num=2 page=2 limit=1><wpTitle/></wpPosts>")
              ,("num3", "<wpPosts num=1 page=3><wpTitle/></wpPosts>")
              ,("tag1", "<wpPosts tags=\"home-featured\" limit=10><wpTitle/></wpPosts>")
              ,("tag2", "<wpPosts limit=10><wpTitle/></wpPosts>")
              ,("tag3", "<wpPosts tags=\"+home-featured\" limit=10><wpTitle/></wpPosts>")
              ,("tag4", "<wpPosts tags=\"-home-featured\" limit=1><wpTitle/></wpPosts>")
              ,("tag5", "<wpPosts tags=\"+home-featured\" limit=1><wpTitle/></wpPosts>")
              ,("tag6", "<wpPosts tags=\"+home-featured,-featured-global\" limit=1><wpTitle/></wpPosts>")
              ,("tag7", "<wpPosts tags=\"+home-featured,+featured-global\" limit=1><wpTitle/></wpPosts>")
              ,("cat1", "<wpPosts categories=\"bookmarx\" limit=10><wpTitle/></wpPosts>")
              ,("cat2", "<wpPosts limit=10><wpTitle/></wpPosts>")
              ,("cat3", "<wpPosts categories=\"-bookmarx\" limit=10><wpTitle/></wpPosts>")
              ,("author-date", "<wpPostByPermalink><wpAuthor><wpName/></wpAuthor><wpDate><wpYear/>/<wpMonth/></wpDate></wpPostByPermalink>")
              ,("fields", "<wpPosts limit=1 categories=\"-bookmarx\"><wpFeaturedImage><wpAttachmentMeta><wpSizes><wpThumbnail><wpUrl/></wpThumbnail></wpSizes></wpAttachmentMeta></wpFeaturedImage></wpPosts>")
              ,("extra-fields", "<wpPosts limit=1 categories=\"-bookmarx\"><wpFeaturedImage><wpAttachmentMeta><wpSizes><wpMagFeatured><wpUrl/></wpMagFeatured></wpSizes></wpAttachmentMeta></wpFeaturedImage></wpPosts>")
              ]
              def { cachePeriod = NoCache
                          , endpoint = "https://sandbox.jacobinmag.com/wp-json"
                          , extraFields = jacobinFields }) $
      do it "should have title on page" $
           get "/2014/10/a-war-for-power" >>= shouldHaveText "A War for Power"
         it "should not have most recent post's title" $
           do p1 <- get "/many"
              get "/many1" >>= shouldNotEqual p1
         it "should be able to offset" $
           do res <- get "/many2"
              res2 <- get "/many3"
              res `shouldNotEqual` res2
         it "should be able to get page 2" $
           do p1 <- get "/page1"
              get "/page2" >>= shouldNotEqual p1
         it "should be able to use page, num, and limit" $
           do p1 <- get "/num1"
              p2 <- get "/num2"
              p3 <- get "/num3"
              p1 `shouldNotEqual` p2
              p2 `shouldEqual` p3
         it "should be able to restrict based on tags" $
           do p1 <- get "/tag1"
              get "/tag2" >>= shouldNotEqual p1
         it "should be able to say +tag instead of tag" $
           do p1 <- get "/tag1"
              get "/tag3" >>= shouldEqual p1
         it "should be able to say -tag to NOT match a tag" $
           do p1 <- get "/tag4"
              get "/tag5" >>= shouldNotEqual p1
         it "should be able to have multiple tag queries" $
           do p1 <- get "/tag6"
              get "/tag7" >>= shouldNotEqual p1
         it "should be able to get nested attribute author name" $
           get "/2014/10/the-assassination-of-detroit/" >>= shouldHaveText "Carlos Salazar"
         it "should be able to get customly parsed attribute date" $
           get "/2014/10/the-assassination-of-detroit/" >>= shouldHaveText "2014/10"
         it "should be able to restrict based on category" $
           do c1 <- get "/cat1"
              c2 <- get "/cat2"
              c1 `shouldNotEqual` c2
         it "should be able to make negative category queries" $
           do c1 <- get "/cat1"
              c2 <- get "/cat3"
              c1 `shouldNotEqual` c2
         it "should be able to use extra fields set in application" $
           do get "/fields" >>= shouldHaveText "https://"
              get "/extra-fields" >>= shouldHaveText "https://"
-}
