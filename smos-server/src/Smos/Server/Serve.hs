{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Server.Serve where

import Control.Monad.Logger
import Control.Monad.Reader
import Crypto.JOSE.JWK (JWK)
import Data.Aeson as JSON
import Data.Aeson.Encode.Pretty as JSON (encodePretty)
import qualified Data.ByteString.Lazy as LB
import Data.Function
import Data.Proxy
import qualified Data.Text as T
import Database.Persist.Sqlite as DB
import Lens.Micro
import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Middleware.RequestLogger as Wai
import Path
import Path.IO
import Servant.API.Generic
import Servant.Auth.Server as Auth
import Servant.Server as Servant
import Servant.Server.Generic
import Smos.API
import Smos.Server.Constants
import Smos.Server.Handler
import Smos.Server.OptParse
import System.Exit

serveSmosServer :: ServeSettings -> IO ()
serveSmosServer ss = do
  pPrint ss
  runSmosServer ss

runSmosServer :: ServeSettings -> IO ()
runSmosServer ServeSettings {..} =
  runStderrLoggingT
    $ filterLogger (\_ ll -> ll >= serveSetLogLevel)
    $ DB.withSqlitePoolInfo (DB.mkSqliteConnectionInfo (T.pack $ fromAbsFile serveSetDatabaseFile) & DB.fkEnabled .~ False) 1
    $ \pool ->
      liftIO $ do
        uuid <- readServerUUID serveSetUUIDFile
        flip DB.runSqlPool pool $ DB.runMigration migrateAll
        jwtKey <- loadSigningKey
        let env =
              ServerEnv
                { serverEnvServerUUID = uuid,
                  serverEnvConnection = pool,
                  serverEnvCookieSettings = defaultCookieSettings,
                  serverEnvJWTSettings = defaultJWTSettings jwtKey,
                  serverEnvPasswordDifficulty = if development then 4 else 14 -- Rather slower
                }
        let middles =
              if development
                then Wai.logStdoutDev
                else Wai.logStdout
        Warp.run serveSetPort $ middles $ makeSyncApp env

-- TODO put this file in settings
signingKeyFile :: IO (Path Abs File)
signingKeyFile = resolveFile' "signing-key.json"

storeSigningKey :: JWK -> IO ()
storeSigningKey key_ = do
  skf <- signingKeyFile
  LB.writeFile (toFilePath skf) (JSON.encodePretty key_)

loadSigningKey :: IO JWK
loadSigningKey = do
  skf <- signingKeyFile
  mErrOrKey <- forgivingAbsence $ JSON.eitherDecode <$> LB.readFile (toFilePath skf)
  case mErrOrKey of
    Nothing -> do
      key_ <- Auth.generateKey
      storeSigningKey key_
      pure key_
    Just (Left err) ->
      die $ unlines ["Failed to load signing key from file", fromAbsFile skf, "with error:", err]
    Just (Right r) -> pure r

makeSyncApp :: ServerEnv -> Wai.Application
makeSyncApp env =
  let cfg = serverEnvCookieSettings env :. serverEnvJWTSettings env :. EmptyContext
   in Servant.serveWithContext syncAPI cfg $
        hoistServerWithContext
          syncAPI
          (Proxy :: Proxy '[CookieSettings, JWTSettings])
          ((`runReaderT` env) :: SyncHandler a -> Handler a)
          syncServantServer

syncServantServer :: ServerT SyncAPI SyncHandler
syncServantServer = toServant syncServerRecord

syncServerRecord :: APIRoutes (AsServerT SyncHandler)
syncServerRecord =
  APIRoutes
    { unprotectedRoutes = toServant syncServerUnprotectedRoutes,
      protectedRoutes = toServant syncServerProtectedRoutes
    }

syncServerUnprotectedRoutes :: UnprotectedRoutes (AsServerT SyncHandler)
syncServerUnprotectedRoutes =
  UnprotectedRoutes {postRegister = servePostRegister, postLogin = servePostLogin}

syncServerProtectedRoutes :: ProtectedRoutes (AsServerT SyncHandler)
syncServerProtectedRoutes =
  ProtectedRoutes
    { postSync = withAuthResult servePostSync,
      getNextActionReport = withAuthResult serveGetNextActionReport
    }

readServerUUID :: Path Abs File -> IO ServerUUID
readServerUUID p = do
  mContents <- forgivingAbsence $ LB.readFile $ fromAbsFile p
  case mContents of
    Nothing -> do
      u <- nextRandomUUID
      writeServerUUID p u
      pure u
    Just contents ->
      case JSON.eitherDecode contents of
        Left err -> die err
        Right u -> pure u

writeServerUUID :: Path Abs File -> ServerUUID -> IO ()
writeServerUUID p u = do
  ensureDir (parent p)
  LB.writeFile (fromAbsFile p) $ JSON.encodePretty u

withAuthResult :: ThrowAll a => (AuthCookie -> a) -> (AuthResult AuthCookie -> a)
withAuthResult func ar =
  case ar of
    Authenticated ac -> func ac
    _ -> throwAll err401
