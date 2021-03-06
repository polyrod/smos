{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Smos.Docs.Site.Static.TH where

import CMarkGFM as MD
import qualified Conduit
import Conduit (ConduitT)
import Control.Monad
import Control.Monad.IO.Class
import Data.Data
import Data.List
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time
import GHC.Generics (Generic)
import Instances.TH.Lift ()
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import Path
import Path.IO
import Path.Internal
import qualified System.FilePath as FP

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}

deriving instance Data Rel

deriving instance Data File

deriving instance Lift Day

data DocPage
  = DocPage
      { docPagePath :: !(Path Rel File),
        docPageUrl :: !Text,
        docPageTitle :: !Text,
        docPageAttributes :: ![(Text, Text)],
        docPageContents :: !Text,
        docPageRendered :: !Text
      }
  deriving (Show, Eq, Generic, Data, Typeable, Lift)

walkSafe ::
  MonadIO m =>
  (Path Abs Dir -> [Path Abs Dir] -> [Path Abs File] -> m (WalkAction Abs)) ->
  Path Abs Dir ->
  m ()
walkSafe go dir = do
  e <- liftIO $ fmap (fromMaybe False) $ forgivingAbsence $ doesDirExist dir
  if e
    then walkDir go dir
    else pure ()

sourceFilesInNonHiddenDirsRecursively ::
  forall m i.
  MonadIO m =>
  Path Abs Dir ->
  ConduitT i (Path Abs File) m ()
sourceFilesInNonHiddenDirsRecursively = walkSafe go
  where
    go ::
      Path Abs Dir ->
      [Path Abs Dir] ->
      [Path Abs File] ->
      ConduitT i (Path Abs File) m (WalkAction Abs)
    go curdir subdirs files = do
      Conduit.yieldMany
        $ filter isMarkdown
        $ filter (not . isHiddenIn curdir) files
      pure $ WalkExclude $ filter (isHiddenIn curdir) subdirs

isMarkdown :: Path b File -> Bool
isMarkdown f = case fileExtension f of
  Just ".md" -> True
  Just ".markdown" -> True
  _ -> False

isHiddenIn :: Path b Dir -> Path b t -> Bool
isHiddenIn curdir ad =
  case stripProperPrefix curdir ad of
    Nothing -> False
    Just rd -> "." `isPrefixOf` toFilePath rd

hidden :: Path r File -> Bool
hidden f = ".swp" `isSuffixOf` toFilePath f

mkDocPages' :: FilePath -> Q [DocPage]
mkDocPages' fp = do
  cd <- runIO $ resolveDir' fp
  postFiles <-
    runIO $ Conduit.sourceToList $ sourceFilesInNonHiddenDirsRecursively cd
  mapM_ (addDependentFile . toFilePath) postFiles
  runIO
    $ fmap catMaybes
    $ forM (filter (not . hidden) postFiles)
    $ \pf ->
      case stripProperPrefix cd pf of
        Nothing -> pure Nothing
        Just rp ->
          Just <$> do
            rawContents <- T.readFile $ toFilePath pf
            let urlString = FP.dropExtension $ toFilePath rp
            let url = T.pack urlString
            let (attributes, contents) = splitContents rawContents
            let maybeAtt k =
                  case lookup k attributes of
                    Nothing ->
                      error $
                        unlines
                          [ "The post with url",
                            urlString,
                            "Does not have an attribute with key",
                            T.unpack k
                          ]
                    Just a -> pure a
            title <- maybeAtt "title"
            let rendered = MD.commonmarkToHtml [optUnsafe] [] contents
            pure
              DocPage
                { docPagePath = rp,
                  docPageUrl = url,
                  docPageTitle = title,
                  docPageAttributes = attributes,
                  docPageContents = contents,
                  docPageRendered = rendered
                }

splitContents :: Text -> ([(Text, Text)], Text)
splitContents cs =
  let threeDashes = "---"
      parts = T.splitOn threeDashes cs
   in case parts of
        "" : ts : rest ->
          let attLines = T.lines ts
              tags =
                flip mapMaybe attLines $ \l ->
                  let column = ":"
                   in case T.splitOn column l of
                        [] -> Nothing
                        (key : valParts) ->
                          Just (key, T.intercalate column valParts)
              contents = T.intercalate threeDashes rest
           in (tags, contents)
        [contents] -> ([], contents)
        _ -> error $ "Failed to parse attributes in" <> T.unpack cs

mkDocPages :: Q [Dec]
mkDocPages = do
  docPages <- mkDocPages' "content/pages"
  individuals <-
    fmap concat
      $ forM docPages
      $ \p -> do
        pb <- lift p
        let name = mkName $ docPageName $ T.unpack $ docPageUrl p
            typ = ConT ''DocPage
            body = NormalB pb
            pat = VarP name
        pure [SigD name typ, ValD pat body []]
  docPagesE <- lift docPages
  let name = mkName "docPages"
      typ = AppT ListT $ ConT ''DocPage
      body = NormalB docPagesE
      pat = VarP name
      allPages = [SigD name typ, ValD pat body []]
  pure $ allPages ++ individuals
  where
    docPageName = map go
      where
        go '-' = '_'
        go '/' = '_'
        go c = c
