{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}
-- | Jenkins REST API interface internals
module Jenkins.Rest.Internal where

import           Control.Applicative
import           Control.Concurrent.Async (concurrently)
import           Control.Exception (Exception, try, toException)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Free.Church (F, iterM, liftF)
import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Control (MonadTransControl(..))
import           Control.Monad.Trans.Reader (ReaderT, runReaderT, ask, local)
import           Control.Monad.Trans.Resource (ResourceT)
import           Control.Monad.Trans.Maybe (MaybeT(..), mapMaybeT)
import           Data.ByteString.Lazy (ByteString)
import           Data.Data (Data, Typeable)
import           Data.Text (Text)
import qualified Data.Text.Encoding as Text
import           GHC.Generics (Generic)
import           Network.HTTP.Conduit
import           Network.HTTP.Types (Status(..))

import           Jenkins.Rest.Method (Method, Type(..), render, slash)
import qualified Network.HTTP.Conduit.Lens as Lens


-- | Jenkins REST API query sequence description
newtype Jenkins a = Jenkins { unJenkins :: F JenkinsF a }
  deriving (Functor, Applicative, Monad)

instance MonadIO Jenkins where
  liftIO = liftJ . IO
  {-# INLINE liftIO #-}

-- | Jenkins REST API query
data JenkinsF a where
  Get  :: Method Complete f -> (ByteString -> a) -> JenkinsF a
  Post :: (forall f. Method Complete f) -> ByteString -> (ByteString -> a) -> JenkinsF a
  Conc :: Jenkins a -> Jenkins b -> (a -> b -> c) -> JenkinsF c
  IO   :: IO a -> JenkinsF a
  With :: (Request -> Request) -> Jenkins b -> (b -> a) -> JenkinsF a
  Dcon :: JenkinsF a

instance Functor JenkinsF where
  fmap f (Get  m g)      = Get  m      (f . g)
  fmap f (Post m body g) = Post m body (f . g)
  fmap f (Conc m n g)    = Conc m n    (\a b -> f (g a b))
  fmap f (IO a)          = IO (fmap f a)
  fmap f (With h j g)    = With h j    (f . g)
  fmap _ Dcon            = Dcon
  {-# INLINE fmap #-}

-- | Lift 'JenkinsF' to 'Jenkins'
liftJ :: JenkinsF a -> Jenkins a
liftJ = Jenkins . liftF
{-# INLINE liftJ #-}

-- | Jenkins connection settings
--
-- '_jenkinsApiToken' may be user's password, Jenkins
-- does not make any distinction between these concepts
data ConnectInfo = ConnectInfo
  { _jenkinsUrl      :: String -- ^ Jenkins URL, e.g. @http:\/\/example.com\/jenkins@
  , _jenkinsPort     :: Int    -- ^ Jenkins port, e.g. @8080@
  , _jenkinsUser     :: Text   -- ^ Jenkins user, e.g. @jenkins@
  , _jenkinsApiToken :: Text   -- ^ Jenkins user API token
  } deriving (Show, Eq, Typeable, Data, Generic)

-- | The result of Jenkins REST API queries
data Result e v =
    Error e    -- ^ Exception @e@ was thrown while querying
  | Disconnect -- ^ The client was explicitly disconnected
  | Result v   -- ^ Querying successfully finished the with value @v@
    deriving (Show, Eq, Ord, Typeable, Data, Generic)

-- | Query Jenkins API using 'Jenkins' description
--
-- Successful result is either 'Disconnect' or @ 'Result' v @
--
-- If 'HttpException' was thrown by @http-conduit@, 'runJenkins' catches it
-- and wraps in 'Error'. Other exceptions are /not/ catched
runJenkins :: HasConnectInfo t => t -> Jenkins a -> IO (Result HttpException a)
runJenkins conn jenk = either Error (maybe Disconnect Result) <$> try (runJenkinsInternal conn jenk)

-- | Query Jenkins API using 'Jenkins' description
--
-- Successful result is either 'Disconnect' or @ 'Result' v @
--
-- No exceptions are catched, i.e.
--
-- @
-- runJenkinsThrowing :: 'ConnectInfo' -> 'Jenkins' a -> 'IO' ('Result' 'Void' a)
-- @
--
-- is perfectly fine—'Result' won't ever be an 'Error'
runJenkinsThrowing :: HasConnectInfo t => t -> Jenkins a -> IO (Result e a)
runJenkinsThrowing conn jenk = maybe Disconnect Result <$> runJenkinsInternal conn jenk

runJenkinsInternal :: HasConnectInfo t => t -> Jenkins a -> IO (Maybe a)
runJenkinsInternal (view connectInfo -> ConnectInfo h p user token) jenk =
  withManager $ \manager -> do
    req <- liftIO $ parseUrl h
    let req' = req
          & Lens.port            .~ p
          & Lens.responseTimeout .~ Just (20 * 1000000)
          & applyBasicAuth (Text.encodeUtf8 user) (Text.encodeUtf8 token)
    runReaderT (runMaybeT (iterJenkinsIO manager jenk)) req'


-- | A prism into Jenkins error
_Error :: Prism (Result e a) (Result e' a) e e'
_Error = prism Error $ \case
  Error e    -> Right e
  Disconnect -> Left Disconnect
  Result a   -> Left (Result a)
{-# INLINE _Error #-}

-- | A prism into disconnect
_Disconnect :: Prism' (Result e a) ()
_Disconnect = prism' (\_ -> Disconnect) $ \case
  Disconnect -> Just ()
  _          -> Nothing
{-# INLINE _Disconnect #-}

-- | A prism into result
_Result :: Prism (Result e a) (Result e b) a b
_Result = prism Result $ \case
  Error e    -> Left (Error e)
  Disconnect -> Left Disconnect
  Result a   -> Right a
{-# INLINE _Result #-}

-- | Interpret 'JenkinsF' AST in 'IO'
iterJenkinsIO
  :: Manager
  -> Jenkins a
  -> MaybeT (ReaderT Request (ResourceT IO)) a
iterJenkinsIO manager = iterJenkins (interpreter manager)
{-# INLINE iterJenkinsIO #-}

-- | Tear down 'JenkinsF' AST with a 'JenkinsF'-algebra
iterJenkins :: Monad m => (JenkinsF (m a) -> m a) -> Jenkins a -> m a
iterJenkins go = iterM go . unJenkins
{-# INLINE iterJenkins #-}

-- | 'JenkinsF' AST interpreter
interpreter
  :: Manager
  -> JenkinsF (MaybeT (ReaderT Request (ResourceT IO)) a)
  -> MaybeT (ReaderT Request (ResourceT IO)) a
interpreter manager = go where
  go (Get m next) = do
    req <- lift ask
    let req' = req
          & Lens.path   %~ (`slash` render m)
          & Lens.method .~ "GET"
    bs <- lift . lift $ httpLbs req' manager
    next (responseBody bs)
  go (Post m body next) = do
    req <- lift ask
    let req' = req
          & Lens.path          %~ (`slash` render m)
          & Lens.method        .~ "POST"
          & Lens.requestBody   .~ RequestBodyLBS body
          & Lens.redirectCount .~ 0
          & Lens.checkStatus   .~ \s@(Status st _) hs cookie_jar ->
            if 200 <= st && st < 400
                then Nothing
                else Just . toException $ StatusCodeException s hs cookie_jar
    res <- lift . lift $ httpLbs req' manager
    next (responseBody res)
  go (Conc jenka jenkb next) = do
    (a, b) <- liftWith $ \run' -> liftWith $ \run'' -> liftWith $ \run''' ->
      let
        run :: Jenkins t -> IO (StT ResourceT (StT (ReaderT Request) (StT MaybeT t)))
        run = run''' . run'' . run' . iterJenkinsIO manager
      in
        concurrently (run jenka) (run jenkb)
    c <- restoreT . restoreT . restoreT $ return a
    d <- restoreT . restoreT . restoreT $ return b
    next c d
  go (IO action) = join (liftIO action)
  go (With f jenk next) = do
    res <- mapMaybeT (local f) (iterJenkinsIO manager jenk)
    next res
  go Dcon = mzero


-- | Default Jenkins connection settings
--
-- @
-- defaultConnectInfo = ConnectInfo
--   { _jenkinsUrl      = \"http:\/\/example.com\/jenkins\"
--   , _jenkinsPort     = 8080
--   , _jenkinsUser     = \"jenkins\"
--   , _jenkinsApiToken = \"\"
--   }
-- @
defaultConnectInfo :: ConnectInfo
defaultConnectInfo = ConnectInfo
  { _jenkinsUrl      = "http://example.com/jenkins"
  , _jenkinsPort     = 8080
  , _jenkinsUser     = "jenkins"
  , _jenkinsApiToken = ""
  }

-- | Convenience class aimed at elimination of long
-- chains of lenses to access jenkins connection configuration
--
-- For example, if you have a configuration record in your application:
--
-- @
-- data Config = Config
--   { ...
--   , _jenkinsConnectInfo :: ConnectInfo
--   , ...
--   }
-- @
--
-- you can make it an instance of 'HasConnectInfo':
--
-- @
-- instance HasConnectInfo Config where
--   connectInfo f x = (\p -> x { _jenkinsConnectInfo = p }) \<$\> f (_jenkinsConnectInfo x)
-- @
--
-- and then use e.g. @view jenkinsUrl config@ to get the url part of the jenkins connection
class HasConnectInfo t where
  connectInfo :: Lens' t ConnectInfo

instance HasConnectInfo ConnectInfo where
  connectInfo = id
  {-# INLINE connectInfo #-}

-- | A lens into Jenkins URL
jenkinsUrl :: HasConnectInfo t => Lens' t String
jenkinsUrl = connectInfo . \f x ->  f (_jenkinsUrl x) <&> \p -> x { _jenkinsUrl = p }
{-# INLINE jenkinsUrl #-}

-- | A lens into Jenkins port
jenkinsPort :: HasConnectInfo t => Lens' t Int
jenkinsPort = connectInfo . \f x -> f (_jenkinsPort x) <&> \p -> x { _jenkinsPort = p }
{-# INLINE jenkinsPort #-}

-- | A lens into Jenkins user
jenkinsUser :: HasConnectInfo t => Lens' t Text
jenkinsUser = connectInfo . \f x -> f (_jenkinsUser x) <&> \p -> x { _jenkinsUser = p }
{-# INLINE jenkinsUser #-}

-- | A lens into Jenkins user API token
jenkinsApiToken :: HasConnectInfo t => Lens' t Text
jenkinsApiToken = connectInfo . \f x -> f (_jenkinsApiToken x) <&> \p -> x { _jenkinsApiToken = p }
{-# INLINE jenkinsApiToken #-}

-- | A lens into Jenkins password
--
-- @
-- jenkinsPassword = jenkinsApiToken
-- @
jenkinsPassword :: HasConnectInfo t => Lens' t Text
jenkinsPassword = jenkinsApiToken
{-# INLINE jenkinsPassword #-}
