{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE ImpredicativeTypes    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeSynonymInstances  #-}

module Web.Offset.Internal where

import           Data.Monoid      ((<>))
import qualified Data.Set         as Set
import           Data.Text        (Text)

import           Web.Offset.HTTP
import           Web.Offset.Types
import           Web.Offset.Utils

wpRequestInt :: Requester -> Text -> WPKey -> IO (Either StatusCode WPResponse)
wpRequestInt runHTTP endpt key =
  case key of
   TaxDictKey resName ->          req (defaultEndpoint <> "/" <> resName) []
   PostByPermalinkKey _ _ slug -> req (defaultEndpoint <> "/posts") [("slug", slug)]
   PostsKey{} ->                  req (defaultEndpoint <> "/posts") (buildParams key)
   PostKey i ->                   req (defaultEndpoint <> "/posts/" <> tshow i) []
   PageKey s ->                   req (defaultEndpoint <> "/pages") [("slug", s)]
   AuthorKey i ->                 req (defaultEndpoint <> "/users/" <> tshow i) []
   TaxSlugKey tName tSlug ->      req (defaultEndpoint <> "/" <> tName) [("slug", tSlug)]
   EndpointKey endpoint ->        req ("/" <> endpoint) []
   PostRevisionKey i ->               req (defaultEndpoint <> "/posts/" <> tshow i <> "/revisions") []
  where req path = unRequester runHTTP (endpt <> path)
        defaultEndpoint = "/wp/v2"

buildParams :: WPKey -> [(Text, Text)]
buildParams (PostsKey filters) = params
  where params = Set.toList $ Set.map mkFilter filters
        mkFilter (TaxFilter taxonomyName (TaxPlusId i)) = (taxonomyName <> "[]", tshow i)
        mkFilter (TaxFilter taxonomyName (TaxMinusId i)) = (taxonomyName <> "_exclude[]", tshow i)
        mkFilter (NumFilter num) = ("per_page", tshow num)
        mkFilter (OffsetFilter offset) = ("offset", tshow offset)
        mkFilter (UserFilter user) = ("author[]", user)
buildParams _ = []

wpLogInt :: Maybe (Text -> IO ()) -> Text -> IO ()
wpLogInt logger msg = case logger of
                    Nothing -> return ()
                    Just f -> f msg
