{-# LANGUAGE RecordWildCards #-}

module Unison.Auth.TransferServer where

import qualified Crypto.Hash as Crypto
import Crypto.Random (getRandomBytes)
import Data.Aeson ((.:), (.:?))
import qualified Data.Aeson as Aeson
import qualified Data.ByteArray.Encoding as BE
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromJust)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Network.HTTP.Client (urlEncodedBody)
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as HTTP
import Network.HTTP.Types
import Network.URI
import qualified Network.URI as URI
import Network.Wai
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Unison.Prelude
import qualified UnliftIO
import qualified Web.Browser as Web

ucmClient :: ByteString
ucmClient = "ucm"

userAgent :: ByteString
userAgent = "UCM"

type Code = Text

type OAuthState = ByteString

type PKCEVerifier = ByteString

type PKCEChallenge = ByteString

type AccessToken = Text

type RefreshToken = Text

type IDToken = Text

shareDiscoveryEndpoint :: URI
shareDiscoveryEndpoint =
  -- TODO: use the correct enlil host for the environment.
  fromJust $ URI.parseURI "http://localhost:5424/.well-known/openid-configuration"

-- | A server in the format expected for a Wai Application
authTransferServer :: (Code -> IO Response) -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
authTransferServer callback req respond =
  case (requestMethod req, pathInfo req, getCodeQuery req) of
    ("GET", ["redirect"], Just code) -> do
      callback code >>= respond
    -- respond (responseLBS status200 [] "Successfully authenticated. You may close this page and return to UCM.")
    _ -> respond (responseLBS status404 [] "Not Found")
  where
    getCodeQuery req = do
      code <- join $ Prelude.lookup "code" (queryString req)
      pure $ Text.decodeUtf8 code

openIDDiscovery :: HTTP.Manager -> IO DiscoveryDoc
openIDDiscovery httpClient = do
  req <- HTTP.requestFromURI shareDiscoveryEndpoint
  resp <- HTTP.httpLbs req httpClient
  either fail pure . Aeson.eitherDecode . HTTP.responseBody $ resp

initiateFlow :: IO (Either Text AccessToken)
initiateFlow = do
  httpClient <- HTTP.getGlobalManager
  -- (DiscoveryDoc {authorizationEndpoint, tokenEndpoint}) <- openIDDiscovery httpClient
  let (DiscoveryDoc {authorizationEndpoint, tokenEndpoint}) = testDiscovery
  authResult <- UnliftIO.newEmptyMVar
  -- Clean up this hack
  redirectURIVar <- UnliftIO.newEmptyMVar
  (verifier, challenge, state) <- generateParams
  let codeHandler code = do
        redirectURI <- UnliftIO.readMVar redirectURIVar
        result <- exchangeCode httpClient tokenEndpoint code verifier redirectURI
        traceShowM result
        UnliftIO.putMVar authResult result
        pure $ case result of
          Left _ -> Wai.responseLBS internalServerError500 [] "Something went wrong, please try again."
          Right _ -> Wai.responseLBS ok200 [] "Authorization successful. You may close this page and return to UCM."
  Warp.withApplication (pure $ authTransferServer codeHandler) $ \port -> do
    let redirectURI = "http://localhost:" <> show port <> "/redirect"
    UnliftIO.putMVar redirectURIVar redirectURI
    let authorizationKickoff = authURI authorizationEndpoint redirectURI state challenge
    void $ Web.openBrowser (show authorizationKickoff)
    putStrLn $ "Please navigate to " <> show authorizationKickoff <> " to initiate authorization."
    UnliftIO.readMVar authResult

authURI :: URI -> String -> OAuthState -> PKCEChallenge -> URI
authURI authEndpoint redirectURI state challenge =
  authEndpoint
    & addQueryParam "state" state
    & addQueryParam "redirect_uri" (BSC.pack redirectURI)
    & addQueryParam "response_type" "code"
    & addQueryParam "scope" "openid"
    & addQueryParam "client_id" ucmClient
    & addQueryParam "code_challenge" challenge
    & addQueryParam "code_challenge_method" "S256"

exchangeCode :: HTTP.Manager -> URI -> Code -> PKCEVerifier -> String -> IO (Either Text AccessToken)
exchangeCode httpClient tokenEndpoint code verifier redirectURI = do
  req <- HTTP.requestFromURI tokenEndpoint
  let addFormData =
        urlEncodedBody
          [ ("code", Text.encodeUtf8 code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", BSC.pack redirectURI),
            ("client_id", ucmClient)
          ]
  let fullReq = addFormData $ req {HTTP.method = "POST", HTTP.requestHeaders = [("Accept", "application/json")]}
  -- TODO: handle failure better
  resp <- HTTP.httpLbs fullReq httpClient
  traceShowM resp
  let respBytes = HTTP.responseBody resp
  pure . mapLeft Text.pack $ accessToken <$> Aeson.eitherDecode respBytes

addQueryParam :: ByteString -> ByteString -> URI -> URI
addQueryParam key val uri =
  let existingQuery = parseQuery $ BSC.pack (uriQuery uri)
      newParam = (key, Just val)
   in uri {uriQuery = BSC.unpack $ renderQuery True (existingQuery <> [newParam])}

generateParams :: IO (PKCEVerifier, PKCEChallenge, OAuthState)
generateParams = do
  verifier <- BE.convertToBase @ByteString BE.Base64URLUnpadded <$> getRandomBytes 50
  traceM $ BSC.unpack verifier
  let digest = Crypto.hashWith Crypto.SHA256 verifier
  let challenge = BE.convertToBase BE.Base64URLUnpadded digest
  state <- BE.convertToBase @ByteString BE.Base64URLUnpadded <$> getRandomBytes 12
  pure (verifier, challenge, state)

data TokenResponse = TokenResponse
  { accessToken :: AccessToken,
    idToken :: Maybe IDToken,
    refreshToken :: Maybe RefreshToken
  }

instance Aeson.FromJSON TokenResponse where
  parseJSON =
    Aeson.withObject "TokenResponse" $ \obj -> do
      accessToken <- obj .: "access_token"
      idToken <- obj .:? "id_token"
      refreshToken <- obj .:? "refresh_token"
      pure (TokenResponse {..})

data DiscoveryDoc = DiscoveryDoc
  { issuer :: URI,
    authorizationEndpoint :: URI,
    tokenEndpoint :: URI,
    userInfoEndpoint :: URI
  }

testDiscovery :: DiscoveryDoc
testDiscovery =
  DiscoveryDoc
    { issuer = undefined,
      authorizationEndpoint = fromJust $ URI.parseURI "http://localhost:5424/oauth/authorize",
      tokenEndpoint = fromJust $ URI.parseURI "http://localhost:5424/oauth/token",
      userInfoEndpoint = fromJust $ URI.parseURI "http://localhost:5424/oauth/user-info"
    }

newtype URIParam = URIParam URI

instance Aeson.FromJSON URIParam where
  parseJSON = Aeson.withText "URI" $ \txt ->
    maybe (fail "Invalid URI") (pure . URIParam) $ URI.parseURI (Text.unpack txt)

instance Aeson.FromJSON DiscoveryDoc where
  parseJSON = Aeson.withObject "Discovery Document" $ \obj -> do
    URIParam issuer <- obj .: "issuer"
    URIParam authorizationEndpoint <- obj .: "authorization_endpoint"
    URIParam tokenEndpoint <- obj .: "token_endpoint"
    URIParam userInfoEndpoint <- obj .: "userinfo_endpoint"
    pure (DiscoveryDoc {..})
