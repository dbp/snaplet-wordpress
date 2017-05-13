{-# LANGUAGE OverloadedStrings #-}

module Web.Offset.Link where

import           Control.Monad.State
import           Data.Aeson              hiding (decode, encode, json, object)
import           Data.Aeson.Types (parseMaybe)
import           Data.Maybe              (fromMaybe)
import           Data.Monoid
import           Text.XML.Light
import           Data.Time.Clock
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Debug.Trace
import qualified Data.Text               as T
import           Data.Text (Text)

import           Web.Offset.Utils
import           Web.Offset.Field
import           Web.Offset.Splices
import           Web.Offset.Types
import           Web.Offset.Date

data Link = Link { feedLinkHref :: T.Text
                 , feedLinkTitle :: T.Text } deriving (Eq, Show)

data Permalink =
  Permalink { pYear :: T.Text
            , pMonth :: T.Text
            , pSlug :: T.Text
            , pTitle :: T.Text }

instance FromJSON Permalink where
  parseJSON (Object v) =
    Permalink <$> (toPermalinkPart "%0Y" v) <*>
                  (toPermalinkPart "%m" v) <*>
                   v .: "slug"  <*>
                  (do t <- v .: "title"
                      t .: "rendered")
    where toPermalinkPart formatStr v =
            T.pack <$>
              Data.Time.Format.formatTime defaultTimeLocale formatStr <$>
              jsonParseDate <$> (v .: "date")
  parseJSON _ = error "bad post"

toFeedLink :: T.Text -> Permalink -> Link
toFeedLink baseurl (Permalink y m s t) =
  Link (baseurl </> y </> m </> s) t
  where a </> b = a <> "/" <> b

permalinkBuilder :: T.Text -> Object -> Maybe Link
permalinkBuilder baseurl o =
  let permalink = parseMaybe parseJSON (Object o) :: Maybe Permalink in
  (toFeedLink baseurl) <$> permalink