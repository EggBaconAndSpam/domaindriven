{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TemplateHaskell #-}

module DomainDriven.Server.TH where

import Control.Monad

import Control.Monad.State
import Data.Function (on)
import Data.Generics.Product
import Data.List qualified as L
import Data.Map qualified as M
import Data.Maybe
import Data.Set qualified as S
import Data.Traversable (for)
import Debug.Trace
import DomainDriven.Server.Class
import DomainDriven.Server.Config
import DomainDriven.Server.Helpers
import DomainDriven.Server.Types
import GHC.Generics (Generic)
import Language.Haskell.TH
import Lens.Micro
import Servant
import UnliftIO (MonadUnliftIO (..))
import Prelude

-- import Data.Bifunctor

-- | Generate a server with granular configuration
--
-- Expects a Map of ApiOptions generated by `DomainDriven.Config.getApiOptionsMap`
-- Due to GHC stage restrictions this cannot be generated in the same module.
--
-- Using this require you to enable template haskell
-- {\-# LANGUAGE TemplateHaskell #-\}

-- $(mkServer  config ''MyAction)

mkServer :: ServerConfig -> Name -> Q [Dec]
mkServer cfg (GadtName -> gadtName) = do
    spec <- mkServerSpec cfg gadtName
    opts <- getApiOptions cfg gadtName
    let si :: ServerInfo
        si =
            ServerInfo
                { baseGadt = spec ^. typed
                , currentGadt = spec ^. typed
                , parentConstructors = []
                , prefixSegments = []
                , options = opts
                }
    runServerGenM
        ServerGenState{info = si, usedParamNames = mempty}
        (mkServerFromSpec spec)

getApiOptions :: ServerConfig -> GadtName -> Q ApiOptions
getApiOptions cfg (GadtName n) = case M.lookup (show n) (allApiOptions cfg) of
    Just o -> pure o
    Nothing ->
        fail $
            "Cannot find ApiOptions for "
                <> show n
                <> ". "
                <> "\nProbable reasons:"
                <> "\n - It does not implement `HasApiOptions`."
                <> "\n - The instance is not visible from where `mkServerConfig` is run."
                <> "\n - The `ServerConfig` instance was manually defined and not complete."

getActionDec :: GadtName -> Q (Dec, VarBindings)
getActionDec (GadtName n) = do
    cmdType <- reify n
    let errMsg = fail $ "Expected " <> show n <> "to be a GADT"
    case cmdType of
        TyConI dec@(DataD _ctx _name params _ _ _) ->
            case getVarBindings params of
                Right b -> pure (dec, b)
                Left err -> fail $ "getActionDec: " <> err
        TyConI{} -> errMsg
        ClassI{} -> errMsg
        ClassOpI{} -> errMsg
        FamilyI{} -> errMsg
        PrimTyConI{} -> errMsg
        DataConI{} -> errMsg
        PatSynI{} -> errMsg
        VarI{} -> errMsg
        TyVarI{} -> errMsg

guardMethodVar :: TyVarBndr flag -> Q ()
guardMethodVar = \case
    KindedTV _ _ k -> check k
    PlainTV _ _ -> check StarT
  where
    check :: Type -> Q ()
    check _ = pure ()

getActionType :: Type -> Q ActionType
getActionType = \case
    AppT (AppT (AppT _ (PromotedT verbName)) _) _ -> checkVerb verbName
    ConT n ->
        reify n >>= \case
            TyConI (TySynD _ [] (AppT (AppT (AppT _ (PromotedT verbName)) _) _)) ->
                checkVerb verbName
            info ->
                fail $
                    "Expected method to be a Verb of a type synonym for a Verb. Got:\n"
                        <> show info
    ty -> fail $ "Expected a Verb without return type applied, got: " <> show ty
  where
    checkVerb :: Name -> Q ActionType
    checkVerb n = case show n of
        "Network.HTTP.Types.Method.GET" -> pure Immutable
        _ -> pure Mutable

guardReturnVar :: Show flag => TyVarBndr flag -> Q ()
guardReturnVar = \case
    KindedTV _ _ StarT -> pure ()
    ty -> fail $ "Return type must be a concrete type. Got: " <> show ty

getConstructors :: Dec -> Q [Con]
getConstructors = \case
    DataD _ _ (last3 -> Just (_x, method, ret)) _ cs _ -> do
        guardMethodVar method
        guardReturnVar ret
        pure cs
    d@DataD{} -> fail $ "Unexpected Action data type: " <> show d
    d -> fail $ "Expected a GADT with two parameters but got: " <> show d

last3 :: [a] -> Maybe (a, a, a)
last3 = \case
    [a, b, c] -> Just (a, b, c)
    [_, _] -> Nothing
    [_] -> Nothing
    [] -> Nothing
    l -> last3 $ tail l

getVarBindings :: Show flag => [TyVarBndr flag] -> Either String VarBindings
getVarBindings varBinds = case varBinds of
    [KindedTV x _ kind, KindedTV method _ StarT, KindedTV ret _ StarT]
        | kind == ConT ''ParamPart ->
            Right
                VarBindings
                    { paramPart = x
                    , method = method
                    , return = ret
                    , extra = []
                    }
        | otherwise ->
            Left $
                "getVarBindings: Expected parameter of kind ParamPart, got: "
                    <> show varBinds
    [_, _] -> Left errMsg
    [_] -> Left errMsg
    [] -> Left errMsg
    p : l -> over (field @"extra") (noFlag p :) <$> getVarBindings l
  where
    noFlag :: TyVarBndr flag -> TyVarBndr ()
    noFlag = \case
        KindedTV x _ kind -> KindedTV x () kind
        PlainTV x _ -> PlainTV x ()

    errMsg =
        "getVarBindings: Expected parameters `(x :: ParamPart) method return`, got: "
            <> show varBinds

data Pmatch = Pmatch
    { paramPart :: Name
    , paramName :: String
    , paramType :: Type
    }
    deriving (Show, Generic)

data ConstructorMatch = ConstructorMatch
    { xParam :: Name
    -- ^ Of kind ParamPart
    , constructorName :: Name
    , parameters :: [Pmatch]
    , finalType :: FinalConstructorTypeMatch
    }
    deriving (Show, Generic)

data SubActionMatch = SubActionMatch
    { constructorName :: Name
    , parameters :: [Pmatch]
    , subActionName :: Name
    , subActionType :: Type
    }
    deriving (Show, Generic)

data SubActionTypeMatch = SubActionTypeMatch
    deriving (Show, Generic)

data FinalConstructorTypeMatch = FinalConstructorTypeMatch
    { requestType :: RequestTypeMatch
    , returnType :: Type
    }
    deriving (Show, Generic)

data RequestTypeMatch = RequestTypeMatch
    { accessType :: Type
    , contentTypes :: Type
    , verb :: Type
    }
    deriving (Show, Generic)

matchNormalConstructor :: Con -> Either String ConstructorMatch
matchNormalConstructor con = do
    (x, gadtCon) <- unconsForall con
    (conName, params, constructorType) <- unconsGadt gadtCon
    finalType <- matchFinalConstructorType constructorType
    pure
        ConstructorMatch
            { xParam = x
            , constructorName = conName
            , parameters = params
            , finalType = finalType
            }
  where
    getParamPartVar :: Show a => [TyVarBndr a] -> Either String Name
    getParamPartVar = \case
        KindedTV x _spec kind : _ | kind == ConT ''ParamPart -> Right x
        a : l -> case getParamPartVar l of
            r@Right{} -> r
            Left e -> Left $ e <> show a
        [] -> Left "Expected a constrctor parameterized by `(x :: ParamPart)`, got: "

    unconsForall :: Con -> Either String (Name, Con)
    unconsForall = \case
        ForallC bindings _ctx con' -> do
            x <- getParamPartVar bindings
            Right (x, con')
        con' ->
            Left $
                "Expected a constrctor parameterized by `(x :: ParamPart)`, got: "
                    <> show con'

    unconsGadt :: Con -> Either String (Name, [Pmatch], Type)
    unconsGadt = \case
        GadtC [conName] bangArgs ty -> do
            params <- traverse (matchP . snd) bangArgs
            pure (conName, params, ty)
        con' -> Left $ "Expected Gadt constrctor, got: " <> show con'

matchSubActionConstructor :: Con -> Either String SubActionMatch
matchSubActionConstructor con = do
    gadtCon <- unconsForall con
    -- Left $ show gadtCon
    (conName, normalParams, (subActionName, subActionType), _constructorType) <-
        unconsGadt gadtCon
    -- finalType <- matchSubActionConstructorType constructorType
    pure
        SubActionMatch
            { constructorName = conName
            , parameters = normalParams
            , subActionName = subActionName
            , subActionType = subActionType
            }
  where
    unconsForall :: Con -> Either String Con
    unconsForall = \case
        ForallC _params _ctx con' -> pure con'
        --  first (("unconsForall: " <> show params) <>) $
        --      (,con')
        --          <$> getVarBindings params
        con' ->
            Left $
                "Expected a higher order constrctor parameterized by `(x :: ParamPart)`, got: "
                    <> show con'

    unconsGadt :: Con -> Either String (Name, [Pmatch], (Name, Type), Type)
    unconsGadt = \case
        con'@(GadtC [actionName] bangArgs ty) -> do
            (normalArgs, subActionType) <- do
                let (normalArgs, subActions) =
                        L.splitAt (length bangArgs - 1) (snd <$> bangArgs)
                case subActions of
                    [] -> Left "No arguments"
                    a : _ -> Right (normalArgs, a)
            normalParams <- traverse matchP normalArgs
            let getActionName :: Type -> Either String Name
                getActionName = \case
                    ConT subAction -> Right subAction
                    (AppT a _) -> getActionName a
                    ty' ->
                        Left $
                            "getActionName: Expected `ConT [action name]` got: "
                                <> show ty'
                                <> " from constructor: "
                                <> show con'
            subActionName <- getActionName subActionType
            pure (actionName, normalParams, (subActionName, subActionType), ty)
        con' -> Left $ "Expected Gadt constrctor, got: " <> show con'

matchSubActionConstructorType :: Type -> Either String SubActionTypeMatch
matchSubActionConstructorType = \case
    (AppT (AppT (AppT (ConT _typeName) (VarT _x)) (VarT _method)) (VarT _a)) ->
        Right SubActionTypeMatch
    ty -> Left $ "Expected a sub subaction with polymorphic argumnets, got: " <> show ty

matchFinalConstructorType :: Type -> Either String FinalConstructorTypeMatch
matchFinalConstructorType = \case
    AppT (AppT _typeName a) retTy -> do
        reqTy <- matchRequestType a
        Right FinalConstructorTypeMatch{requestType = reqTy, returnType = retTy}
    ty -> Left $ "Expected constructor like `GetCount x Query Int`, got: " <> show ty

matchRequestType :: Type -> Either String RequestTypeMatch
matchRequestType = \case
    AppT (AppT (AppT (ConT _reqTy) accessType) ct) verb ->
        Right RequestTypeMatch{accessType = accessType, contentTypes = ct, verb = verb}
    ty -> Left $ "Expected `RequestType`, got: " <> show ty

-- | Tries to match a Type to a more easily readable Pmatch.
-- Successful match means the type is representing the type family `P`
matchP :: Type -> Either String Pmatch
matchP = \case
    AppT (AppT (AppT (ConT p) (VarT x)) (LitT (StrTyLit pName))) ty -> do
        unless
            (show p == show ''P) -- FIXME: Comparing them directly will not match? or is it just my test case with mkName?
            (Left $ "Expected " <> show ''P <> ", got: " <> show p)
        Right Pmatch{paramPart = x, paramName = pName, paramType = ty}
    ty -> Left $ "Expected type family `P`, got: " <> show ty

mkApiPiece :: ServerConfig -> VarBindings -> Con -> Q ApiPiece
mkApiPiece cfg varBindings con = do
    case (matchNormalConstructor con, matchSubActionConstructor con) of
        (Right c, _) -> do
            actionType <-
                getActionType $
                    c
                        ^. field @"finalType"
                            . field @"requestType"
                            . field @"verb"
            pure $
                Endpoint
                    (ConstructorName $ c ^. field @"constructorName")
                    ( ConstructorArgs $
                        c
                            ^.. field @"parameters"
                                . folded
                                . to
                                    (\p -> (p ^. field @"paramName", p ^. field @"paramType"))
                    )
                    HandlerSettings
                        { contentTypes =
                            c
                                ^. field @"finalType"
                                    . field @"requestType"
                                    . field @"contentTypes"
                        , verb =
                            c
                                ^. field @"finalType"
                                    . field @"requestType"
                                    . field @"verb"
                        }
                    actionType
                    (EpReturnType $ c ^. field @"finalType" . field @"returnType")
        (_, Right c) -> do
            subServerSpec <- mkSubServerSpec cfg varBindings c
            pure $
                SubApi
                    (c ^. field @"constructorName" . to ConstructorName)
                    ( ConstructorArgs $
                        c
                            ^.. field @"parameters"
                                . folded
                                . to
                                    (\p -> (p ^. field @"paramName", p ^. field @"paramType"))
                    )
                    subServerSpec
        (Left err1, Left err2) ->
            fail $
                "mkApiPiece - "
                    <> "\n---------------------mkApiPiece: Expected ------------------------"
                    <> show err1
                    <> "\n---------------------or-------------------------------------------"
                    <> "\n"
                    <> show err2
                    <> "\n------------------------------------------------------------------"

-- | Create a ApiSpec from a GADT
-- The GADT must have one parameter representing the return type
mkServerSpec :: ServerConfig -> GadtName -> Q ApiSpec
mkServerSpec cfg n = do
    (dec, varBindings) <- getActionDec n --- AHA, THis is the fucker fucking with me!
    traceM $ "mkServerSpec: " <> show dec
    eps <- traverse (mkApiPiece cfg varBindings) =<< getConstructors dec
    opts <- getApiOptions cfg n
    pure
        ApiSpec
            { gadtName = n
            , gadtType =
                GadtType $
                    L.foldl'
                        AppT
                        (ConT $ n ^. typed @Name)
                        ( varBindings
                            ^.. field @"extra"
                                . folded
                                . typed @Name
                                . to VarT
                        )
            , allVarBindings = varBindings
            , endpoints = eps
            , options = opts
            }

-- I cannot do reify more than once!
-- But I need to in order to get the types of the subactions....
-- So what I need to do is to keep the top level VarBindings around and then, when I reify
-- the child type I need to rename type variables in accordance to the top level bindings
-- and what variables are applied to this child type.

gadtToAction :: GadtType -> Either String Type
gadtToAction (GadtType ty) = case ty of
    AppT (AppT (AppT ty' (VarT _x)) (VarT _method)) (VarT _return) -> Right ty'
    _ -> Left $ "Expected `GADT` with final kind `Action`, got: " <> show ty

mkSubServerSpec :: ServerConfig -> VarBindings -> SubActionMatch -> Q ApiSpec
mkSubServerSpec cfg varBindings subAction = do
    (dec, bindings) <- getActionDec name -- We must not use the bindings or we'd end up with different names
    traceM $ "mkSubServerSpec-varBindings: " <> show varBindings
    traceM $ "mkSubServerSpec-bindings: " <> show bindings
    traceM $ "mkSubServerSpec-subaction: " <> show subAction
    eps <- traverse (mkApiPiece cfg varBindings) =<< getConstructors dec
    opts <- getApiOptions cfg name

    actionTy <- either fail pure $ gadtToAction $ subAction ^. field @"subActionType" . to GadtType
    pure
        ApiSpec
            { gadtName = name
            , gadtType = GadtType actionTy
            , -- GadtType $
              --     L.foldl'
              --         AppT
              --         (ConT $ name ^. typed @Name)
              --         ( fuckitUnifyVarBindings bindings varBindings
              --             ^.. field @"extra"
              --                 . folded
              --                 . typed @Name
              --                 . to VarT
              --         )
              allVarBindings = varBindings
            , endpoints = eps
            , options = opts
            }
  where
    name :: GadtName
    name = subAction ^. field @"subActionName" . to GadtName

------------------------------------------------------------------------------------------

-- | Create the API definition for the top level API
-- * For Endpoint this simply means referencing that API type
-- * For SubApi we add the path parameters before referencing the sub API.
--
-- Result will be something like
-- ```
-- type SomeApi = Endpoint1
--           :<|> Endpoint2
--           :<|> "CustomerKey" :> CustomerKey :> CustomerApi
mkApiTypeDecs :: ApiSpec -> ServerGenM [Dec]
mkApiTypeDecs spec = do
    apiTypeName <- askApiTypeName
    epTypes <- traverse mkEndpointApiType (spec ^. typed @[ApiPiece])
    topLevelDec <- case reverse epTypes of -- :<|> is right associative
        [] -> fail "Server contains no endpoints"
        t : ts -> do
            let fish :: Type -> Type -> Q Type
                fish b a = [t|$(pure a) :<|> $(pure b)|]
            TySynD apiTypeName [] <$> liftQ (foldM fish t ts)
    handlerDecs <- mconcat <$> traverse mkHandlerTypeDec (spec ^. typed @[ApiPiece])
    pure $ topLevelDec : handlerDecs

-- | Create endpoint types to be referenced in the API
-- * For Endpoint this is just a reference to the handler type
-- * For SubApi we apply the path parameters before referencing the SubApi
mkEndpointApiType :: ApiPiece -> ServerGenM Type
mkEndpointApiType p = enterApiPiece p $ case p of
    Endpoint{} -> ConT <$> askEndpointTypeName
    SubApi cName cArgs _ -> do
        urlSegment <- mkUrlSegment cName
        n <- askApiTypeName
        finalType <- liftQ $ prependServerEndpointName urlSegment (ConT n)

        params <- mkQueryParams cArgs
        bird <- liftQ [t|(:>)|]
        pure $ foldr (\a b -> bird `AppT` a `AppT` b) finalType params

-- | Defines the servant types for the endpoints
-- For SubApi it will trigger the full creating of the sub server with types and all
--
-- Result will be something like:
-- ```
-- type Customer_CreateEndpoint
--     = "Create"
--     :> ReqBody '[JSON] (NamedField1 "Customer_Create" Name Email)
--     :> Post '[JSON] CustomerKey
mkHandlerTypeDec :: ApiPiece -> ServerGenM [Dec]
mkHandlerTypeDec p = enterApiPiece p $ do
    case p of
        Endpoint name args hs Immutable retType -> do
            -- Get endpoint will use query parameters
            ty <- do
                queryParams <- mkQueryParams args
                let reqReturn = mkVerb hs $ mkReturnType retType
                bird <- liftQ [t|(:>)|]
                let stuff = foldr1 joinUrlParts $ queryParams <> [reqReturn]
                    joinUrlParts :: Type -> Type -> Type
                    joinUrlParts a b = AppT (AppT bird a) b
                urlSegment <- mkUrlSegment name
                liftQ $ prependServerEndpointName urlSegment stuff
            epTypeName <- askEndpointTypeName
            pure [TySynD epTypeName [] ty]
        Endpoint name args hs Mutable retType -> do
            -- Non-get endpoints use a request body
            ty <- do
                reqBody <- mkReqBody hs name args
                let reqReturn = mkReturnType retType
                middle <- case reqBody of
                    Nothing -> pure $ mkVerb hs reqReturn
                    Just b -> liftQ [t|$(pure b) :> $(pure $ mkVerb hs reqReturn)|]
                urlSegment <- mkUrlSegment name
                liftQ $ prependServerEndpointName urlSegment middle
            epTypeName <- askEndpointTypeName
            pure [TySynD epTypeName [] ty]
        SubApi _name args spec' -> enterApi spec' $ do
            _ <- mkQueryParams args
            -- Make sure we take into account what parameters have already been used.
            -- Skip this and we could end up generating APIs with multiple
            -- QueryParams with the same name, which servant will accept and use one
            -- one the values for both parameters.
            mkServerFromSpec spec'

guardUniqueParamName :: String -> ServerGenM ()
guardUniqueParamName paramName = do
    existingNames <- gets (^. field @"usedParamNames")
    when (paramName `elem` existingNames) $ do
        info <- gets (^. field @"info")
        let problematicConstructor = info ^. field @"currentGadt" . typed @Name . to show
            problematicParentConstructors =
                L.intercalate "->" $
                    info
                        ^.. field @"parentConstructors"
                            . folded
                            . typed @Name
                            . to show
        fail $
            "Duplicate query parameters with name "
                <> show paramName
                <> " in Action "
                <> show problematicConstructor
                <> " with constructor hierarcy "
                <> show problematicParentConstructors
    modify $ over (field @"usedParamNames") (S.insert paramName)

mkQueryParams :: ConstructorArgs -> ServerGenM [QueryParamType]
mkQueryParams (ConstructorArgs args) = do
    may <- liftQ [t|Maybe|] -- Maybe parameters are optional, others required
    for args $ \case
        (name, (AppT may' ty@(ConT _))) | may' == may -> do
            guardUniqueParamName name
            liftQ
                [t|
                    QueryParam'
                        '[Optional, Servant.Strict]
                        $(pure . LitT . StrTyLit $ name)
                        $(pure ty)
                    |]
        (name, ty@(ConT _)) -> do
            guardUniqueParamName name
            liftQ
                [t|
                    QueryParam'
                        '[Required, Servant.Strict]
                        $(pure . LitT . StrTyLit $ name)
                        $(pure ty)
                    |]
        crap -> fail $ "mkQueryParams - unexpected input: " <> show crap

type QueryParamType = Type

mkVerb :: HandlerSettings -> Type -> Type
mkVerb (HandlerSettings _ verb) ret = verb `AppT` ret

-- | Declare then handlers for the API
mkServerDec :: ApiSpec -> ServerGenM [Dec]
mkServerDec spec = do
    apiTypeName <- askApiTypeName
    serverName <- askServerName

    let runnerName :: Name
        runnerName = mkName "runner"

        actionRunner' :: Type
        actionRunner' =
            ConT ''ActionRunner
                `AppT` VarT runnerMonadName
                `AppT` ( spec
                            ^. field @"gadtType"
                                . typed
                       )

        server :: Type
        server =
            ConT ''ServerT
                `AppT` ConT apiTypeName
                `AppT` VarT runnerMonadName

        serverType :: Type
        serverType =
            withForall
                (spec ^. field' @"allVarBindings" . field @"extra")
                (ArrowT `AppT` actionRunner' `AppT` server)

    -- ret <- liftQ [t| Server $(pure $ ConT apiTypeName) |]
    let serverSigDec :: Dec
        serverSigDec = SigD serverName serverType

        mkHandlerExp :: ApiPiece -> ServerGenM Exp
        mkHandlerExp p = enterApiPiece p $ do
            n <- askHandlerName
            pure $ VarE n `AppE` VarE runnerName
    handlers <- traverse mkHandlerExp (spec ^. typed @[ApiPiece])
    body <- case reverse handlers of -- :<|> is right associative
        [] -> fail "Server contains no endpoints"
        e : es -> liftQ $ foldM (\b a -> [|$(pure a) :<|> $(pure b)|]) e es
    let serverFunDec :: Dec
        serverFunDec = FunD serverName [Clause [VarP runnerName] (NormalB body) []]
    serverHandlerDecs <-
        mconcat
            <$> traverse (mkApiPieceHandler (gadtType spec)) (spec ^. typed @[ApiPiece])

    pure $ serverSigDec : serverFunDec : serverHandlerDecs

-- | Get the subset of type varaibes used ty a type, in the roder they're applied
-- Used to avoid rendundant type variables in the forall statement of sub-servers
getUsedTyVars :: forall flag. [TyVarBndr flag] -> Type -> [TyVarBndr flag]
getUsedTyVars bindings = \case
    (AppT a b) -> on (<>) (getUsedTyVars bindings) a b
    (ConT _) -> []
    (VarT n) -> bindings ^.. folded . filtered ((== n) . getName)
    _ -> []
  where
    getName :: TyVarBndr flag -> Name
    getName = \case
        PlainTV n _ -> n
        KindedTV n _ _ -> n

withForall :: [TyVarBndr ()] -> Type -> Type
withForall extra ty =
    ForallT
        bindings
        varConstraints
        ty
  where
    bindings :: [TyVarBndr Specificity]
    bindings =
        KindedTV runnerMonadName SpecifiedSpec (ArrowT `AppT` StarT `AppT` StarT)
            : ( getUsedTyVars extra ty
                    & traversed %~ \case
                        PlainTV n _ -> PlainTV n SpecifiedSpec
                        KindedTV n _ k -> KindedTV n SpecifiedSpec k
              )

    varConstraints :: [Type]
    varConstraints = [ConT ''MonadUnliftIO `AppT` VarT runnerMonadName]

actionRunner :: Type -> Type
actionRunner runnerGADT =
    ConT ''ActionRunner
        `AppT` VarT runnerMonadName
        `AppT` runnerGADT

runnerMonadName :: Name
runnerMonadName = mkName "m"

mkNamedFieldsType :: ConstructorName -> ConstructorArgs -> ServerGenM (Maybe Type)
mkNamedFieldsType cName = \case
    ConstructorArgs [] -> pure Nothing
    ConstructorArgs args -> do
        bodyTag <- askBodyTag cName

        let nfType :: Type
            nfType = AppT (ConT nfName) (LitT bodyTag)

            nfName :: Name
            nfName = mkName $ "NF" <> show (length args)

            addNFxParam :: Type -> (String, Type) -> Type
            addNFxParam nfx (name, ty) = AppT (AppT nfx (LitT $ StrTyLit name)) ty
        pure . Just $ foldl addNFxParam nfType args

mkQueryHandlerSignature :: GadtType -> ConstructorArgs -> EpReturnType -> Type
mkQueryHandlerSignature
    gadt@(GadtType actionType)
    (ConstructorArgs args)
    (EpReturnType retType) =
        withForall (either (const []) id $ gadtTypeParams gadt) $
            mkFunction $
                actionRunner actionType : fmap snd args <> [ret]
      where
        ret :: Type
        ret = AppT (VarT runnerMonadName) retType

-- | Makes command handler, e.g.
--  counterCmd_AddToCounterHandler ::
--    ActionRunner m CounterCmd -> NamedFields1 "CounterCmd_AddToCounter" Int -> m Int
mkCmdHandlerSignature
    :: GadtType -> ConstructorName -> ConstructorArgs -> EpReturnType -> ServerGenM Type
mkCmdHandlerSignature gadt cName cArgs (EpReturnType retType) = do
    nfArgs <- mkNamedFieldsType cName cArgs
    pure $
        withForall (either (const []) id $ gadtTypeParams gadt) $
            mkFunction $
                [actionRunner (gadt ^. field @"getGadtType")]
                    <> maybe [] pure nfArgs
                    <> [ret]
  where
    ret :: Type
    ret = AppT (VarT runnerMonadName) $ case retType of
        TupleT 0 -> ConT ''NoContent
        ty -> ty

mkFunction :: [Type] -> Type
mkFunction = foldr1 (\a b -> AppT (AppT ArrowT a) b)

sortAndExcludeBindings :: [TyVarBndr Specificity] -> Type -> Either String [TyVarBndr Specificity]
sortAndExcludeBindings bindings ty = do
    varOrder <- varNameOrder ty
    let m :: M.Map Name Int
        m = M.fromList $ zip varOrder [1 ..]

    Right $ fmap fst . catMaybes $ bindings ^.. folded . to (\a -> (a,) <$> M.lookup (a ^. typed) m)

varNameOrder :: Type -> Either String [Name]
varNameOrder = \case
    ConT _ -> Right []
    VarT n -> Right [n]
    (AppT a b) -> (<>) <$> varNameOrder a <*> varNameOrder b
    crap -> Left $ "sortAndExcludeBindings: " <> show crap

gadtTypeParams :: GadtType -> Either String [TyVarBndr ()]
gadtTypeParams = fmap (fmap (`PlainTV` ())) . varNameOrder . getGadtType

-- | Define the servant handler for an enpoint or referens the subapi with path
-- parameters applied
mkApiPieceHandler :: GadtType -> ApiPiece -> ServerGenM [Dec]
mkApiPieceHandler gadt apiPiece =
    enterApiPiece apiPiece $ do
        case apiPiece of
            Endpoint _cName cArgs _hs Immutable ty -> do
                let nrArgs :: Int
                    nrArgs = length $ cArgs ^. typed @[(String, Type)]
                varNames <- liftQ $ replicateM nrArgs (newName "arg")
                handlerName <- askHandlerName
                runnerName <- liftQ $ newName "runner"

                let funSig :: Dec
                    funSig = SigD handlerName $ mkQueryHandlerSignature gadt cArgs ty

                    funBodyBase =
                        AppE (VarE runnerName) $
                            foldl
                                AppE
                                (ConE $ apiPiece ^. typed @ConstructorName . typed)
                                (fmap VarE varNames)

                    funBody = case ty ^. typed of
                        TupleT 0 -> [|fmap (const NoContent) $(pure funBodyBase)|]
                        _ -> pure $ funBodyBase
                funClause <-
                    liftQ $
                        clause
                            (fmap (pure . VarP) (runnerName : varNames))
                            (normalB [|$(funBody)|])
                            []
                pure [funSig, FunD handlerName [funClause]]
            Endpoint cName cArgs hs Mutable ty | hasJsonContentType hs -> do
                let nrArgs :: Int
                    nrArgs = length $ cArgs ^. typed @[(String, Type)]
                varNames <- liftQ $ replicateM nrArgs (newName "arg")
                handlerName <- askHandlerName
                runnerName <- liftQ $ newName "runner"
                let varPat :: Pat
                    varPat = ConP nfName [] (fmap VarP varNames)

                    nfName :: Name
                    nfName = mkName $ "NF" <> show nrArgs

                funSig <- SigD handlerName <$> mkCmdHandlerSignature gadt cName cArgs ty

                let funBodyBase =
                        AppE (VarE runnerName) $
                            foldl
                                AppE
                                (ConE $ apiPiece ^. typed @ConstructorName . typed)
                                (fmap VarE varNames)

                    funBody = case ty ^. typed of
                        TupleT 0 -> [|fmap (const NoContent) $(pure funBodyBase)|]
                        _ -> pure $ funBodyBase
                funClause <-
                    liftQ $
                        clause
                            (pure (VarP runnerName) : (if nrArgs > 0 then [pure $ varPat] else []))
                            (normalB [|$(funBody)|])
                            []
                pure [funSig, FunD handlerName [funClause]]
            Endpoint _cName cArgs _hs Mutable ty -> do
                -- FIXME: For non-JSON request bodies we support only one argument.
                -- Combining JSON with other content types do not work properly at this point.
                -- It could probably be fixed by adding MimeRender instances to NamedField1
                -- that just uses the underlying MimeRender.
                let nrArgs :: Int
                    nrArgs = length $ cArgs ^. typed @[(String, Type)]
                unless (nrArgs < 2) $
                    fail "Only one argument is supported for non-JSON request bodies"
                varName <- liftQ $ newName "arg"
                handlerName <- askHandlerName
                runnerName <- liftQ $ newName "runner"
                let varPat :: Pat
                    varPat = VarP varName

                let funSig :: Dec
                    funSig = SigD handlerName $ mkQueryHandlerSignature gadt cArgs ty

                    funBodyBase =
                        AppE (VarE runnerName) $
                            AppE
                                (ConE $ apiPiece ^. typed @ConstructorName . typed)
                                (VarE varName)

                    funBody = case ty ^. typed of
                        TupleT 0 -> [|fmap (const NoContent) $(pure funBodyBase)|]
                        _ -> pure $ funBodyBase
                funClause <-
                    liftQ $
                        clause
                            (pure (VarP runnerName) : (if nrArgs > 0 then [pure $ varPat] else []))
                            (normalB [|$(funBody)|])
                            []
                pure [funSig, FunD handlerName [funClause]]
            SubApi cName cArgs spec -> do
                -- Apply the arguments to the constructor before referencing the subserver
                varNames <- liftQ $ replicateM (length (cArgs ^. typed @[(String, Type)])) (newName "arg")
                handlerName <- askHandlerName
                targetApiTypeName <- enterApi spec askApiTypeName
                targetServer <- enterApi spec askServerName
                runnerName <- liftQ $ newName "runner"

                funSig <- liftQ $ do
                    let params =
                            withForall (spec ^. field @"allVarBindings" . field @"extra") $
                                mkFunction $
                                    [actionRunner (gadt ^. field @"getGadtType")]
                                        <> cArgs ^.. typed @[(String, Type)] . folded . _2
                                        <> [ ConT ''ServerT
                                                `AppT` (ConT targetApiTypeName)
                                                `AppT` (VarT runnerMonadName)
                                           ]
                    SigD handlerName <$> pure params

                funClause <- liftQ $ do
                    let cmd =
                            foldl
                                (\b a -> AppE b a)
                                (ConE $ cName ^. typed)
                                (fmap VarE varNames)
                     in clause
                            (varP <$> runnerName : varNames)
                            ( fmap
                                NormalB
                                [e|
                                    $(varE targetServer)
                                        ($(varE runnerName) . $(pure cmd))
                                    |]
                            )
                            []
                let funDef = FunD handlerName [funClause]
                pure [funSig, funDef]

---- | This is the only layer of the ReaderT stack where we do not use `local` to update the
---- url segments.
mkServerFromSpec :: ApiSpec -> ServerGenM [Dec]
mkServerFromSpec spec = enterApi spec $ do
    apiTypeDecs <- mkApiTypeDecs spec
    serverDecs <- mkServerDec spec
    pure $ apiTypeDecs <> serverDecs

-- | Handles the special case of `()` being transformed into `NoContent`
mkReturnType :: EpReturnType -> Type
mkReturnType (EpReturnType ty) = case ty of
    TupleT 0 -> ConT ''NoContent
    _ -> ty

prependServerEndpointName :: UrlSegment -> Type -> Q Type
prependServerEndpointName prefix rest =
    [t|$(pure $ LitT . StrTyLit $ prefix ^. typed) :> $(pure $ rest)|]

mkReqBody
    :: HandlerSettings -> ConstructorName -> ConstructorArgs -> ServerGenM (Maybe Type)
mkReqBody hs name args =
    if hasJsonContentType hs
        then do
            body <- mkNamedFieldsType name args
            case body of
                Nothing -> pure Nothing
                Just b -> Just <$> liftQ [t|ReqBody '[JSON] $(pure b)|]
        else do
            let body = case args of
                    ConstructorArgs [] -> Nothing
                    ConstructorArgs [(_, t)] -> Just t
                    ConstructorArgs _ ->
                        fail "Multiple arguments are only supported for JSON content"
            case body of
                Nothing -> pure Nothing
                Just b ->
                    Just
                        <$> liftQ
                            [t|ReqBody $(pure $ hs ^. field @"contentTypes") $(pure b)|]
