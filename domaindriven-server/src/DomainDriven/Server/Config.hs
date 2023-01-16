{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module DomainDriven.Server.Config
    ( module DomainDriven.Server.Config
    , Name
    )
where

import Data.Char (isLower)
import qualified Data.List as L
import qualified Data.Map as M
import DomainDriven.Internal.Class
import GHC.Generics (Generic)
import Language.Haskell.TH
import Prelude

-- | Configuration used to generate server
-- This is expected to be generated by `mkServerConfig`. It is only explicit due to
-- the GHC stage restrictions.
data ServerConfig = ServerConfig
    { allApiOptions :: M.Map String ApiOptions
    -- ^ Map of API options for all action GADTs used in the API
    }
    deriving (Show, Generic)

------------------------------------------------------------------------------------------
-- Things to deal with the P type family
------------------------------------------------------------------------------------------
type PAction = ParamPart -> Type -> Type -> Type

-- | Used as a parameter to the `P` type family on order to determine the focus.
data ParamPart
    = ParamName
    | ParamType
    deriving (Show)

-- | P is used for specifying the parameters of the model.
-- The name will be used as the name in the JSON encoding or the query parameter of the
-- generated server.
type family P (b :: ParamPart) (name :: Symbol) (a :: Type) where
    P 'ParamName name ty = Proxy name
    P 'ParamType name ty = ty

runPAction
    :: (MonadUnliftIO m, WriteModel p, model ~ Model p, event ~ Event p)
    => p
    -> ActionHandler model event m cmd
    -> cmd 'ParamType method ret
    -> m ret
runPAction p handleCmd cmd = case handleCmd cmd of
    Query m -> m =<< liftIO (getModel p)
    CbQuery m -> m (liftIO (getModel p))
    Cmd m -> transactionalUpdate p m
    CbCmd withTrans -> withTrans $ \runTrans -> do
        transactionalUpdate p runTrans

type PActionHandler model event m c =
    forall method a. c 'ParamType method a -> HandlerType method model event m a

type PActionRunner m c =
    forall method a
     . MonadUnliftIO m
    => c 'ParamType method a
    -> m a

------------------------------------------------------------------------------------------
-- Done with the P type family things
------------------------------------------------------------------------------------------
--
class HasApiOptions (action :: ParamPart -> Type -> Type -> Type) where
    apiOptions :: ApiOptions
    apiOptions = defaultApiOptions

defaultServerConfig :: ServerConfig
defaultServerConfig = ServerConfig M.empty

-- | Generate a server configuration and give it the specified name
mkServerConfig :: String -> Q [Dec]
mkServerConfig (mkName -> cfgName) = do
    sig' <- sigD cfgName (conT ''ServerConfig)
    body' <-
        [d|$(varP cfgName) = ServerConfig $(getApiOptionsMap)|]
    pure $ sig' : body'

-- | Generates `Map String ApiOptions`
-- Containing the ApiOptions of all types with an ApiOpts instance
getApiOptionsMap :: Q Exp
getApiOptionsMap =
    reify ''HasApiOptions >>= \case
        ClassI _ instances -> do
            cfgs <- traverse nameAndCfg instances
            [e|M.fromList $(pure $ ListE cfgs)|]
        i -> fail $ "Expected ClassI but got: " <> show i
  where
    nameAndCfg :: Dec -> Q Exp
    nameAndCfg = \case
        InstanceD _ _ (AppT _ ty@(ConT n)) _ ->
            [e|($(stringE $ show n), apiOptions @($(pure ty)))|]
        d -> fail $ "Expected instance InstanceD but got: " <> show d

------------------------------------------------------------------------------------------
-- Some utility functions that can be useful when remapping names
------------------------------------------------------------------------------------------
dropPrefix :: String -> String -> String
dropPrefix pre s = if pre `L.isPrefixOf` s then drop (length pre) s else s

dropSuffix :: String -> String -> String
dropSuffix pre s = if pre `L.isSuffixOf` s then take (length s - length pre) s else s

dropFirstWord :: String -> String
dropFirstWord = L.dropWhile isLower . drop 1
