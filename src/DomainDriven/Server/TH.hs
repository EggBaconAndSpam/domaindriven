{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DuplicateRecordFields #-}

module DomainDriven.Server.TH where


import           Control.Monad
import           Control.Monad.Catch            ( MonadThrow(..) )
import           Control.Monad.State
import           Data.Generics.Product
import qualified Data.List                                    as L
import qualified Data.Map                                     as M
import qualified Data.Set                                     as S
import qualified Data.Text                                    as T
import           Data.Traversable               ( for )
import           Debug.Trace
import           DomainDriven.Config            ( ServerConfig(..) )
import           DomainDriven.Internal.Class
import           DomainDriven.Server.Helpers
import           DomainDriven.Server.Types
import           Language.Haskell.TH
import           Lens.Micro
import           Prelude
import           Servant
import           UnliftIO                       ( MonadUnliftIO(..) )

-- | Generate a server with granular configuration
--
-- Expects a Map of ApiOptions generated by `DomainDriven.Config.getApiOptionsMap`
-- Due to GHC stage restrictions this cannot be generated in the same module.
--
-- Using this require you to enable template haskell
-- {-# LANGUAGE TemplateHaskell #-}
-- $(mkServer  config ''MyAction)
mkServer :: ServerConfig -> Name -> Q [Dec]
mkServer cfg (GadtName -> gadtName) = do
    spec <- mkServerSpec cfg gadtName
    opts <- getApiOptions cfg gadtName
    let si :: ServerInfo
        si = ServerInfo { baseGadt           = spec ^. typed
                        , currentGadt        = spec ^. typed
                        , parentConstructors = []
                        , prefixSegments     = []
                        , options            = opts
                        }
    runServerGenM
        ServerGenState { info           = si
                       , usedParamNames = mempty
                       , allParamNames  = cfg ^. field @"allParamNames"
                       }
        (mkServerFromSpec spec)

getApiOptions :: ServerConfig -> GadtName -> Q ApiOptions
getApiOptions cfg (GadtName n) = case M.lookup (nameBase n) (allApiOptions cfg) of
    Just o  -> pure o
    Nothing -> fail $ "Missing HasApiOptions instance for " <> show n


getActionDec :: GadtName -> Q Dec
getActionDec (GadtName n) = do
    cmdType <- reify n
    let errMsg = fail "Must be GADT with two parameters, HandlerType and return type"
    case cmdType of
        TyConI dec   -> pure dec
        ClassI{}     -> errMsg
        ClassOpI{}   -> errMsg
        FamilyI{}    -> errMsg
        PrimTyConI{} -> errMsg
        DataConI{}   -> errMsg
        PatSynI{}    -> errMsg
        VarI{}       -> errMsg
        TyVarI{}     -> errMsg


guardMethodVar :: TyVarBndr flag -> Q ()
guardMethodVar = \case
    KindedTV _ _ k -> check k
    PlainTV _ _    -> check StarT
  where
    check :: Type -> Q ()
    check _ = pure ()

getActionType :: Type -> Q ActionType
getActionType = \case
    AppT (AppT (AppT _ (PromotedT verbName)) _) _ -> checkVerb verbName
    ConT n -> reify n >>= \case
        TyConI (TySynD _ [] (AppT (AppT (AppT _ (PromotedT verbName)) _) _)) ->
            checkVerb verbName
        info ->
            fail
                $  "Expected method to be a Verb of a type synonym for a Verb. Got:\n"
                <> show info
    ty -> fail $ "Expected a Verb without return type applied, got: " <> show ty
  where
    checkVerb :: Name -> Q ActionType
    checkVerb n = case show n of
        "Network.HTTP.Types.Method.GET" -> pure Immutable
        _                               -> pure Mutable

guardReturnVar :: Show flag => TyVarBndr flag -> Q ()
guardReturnVar = \case
    KindedTV _ _ StarT -> pure ()
    ty                 -> fail $ "Return type must be a concrete type. Got: " <> show ty

getConstructors :: Dec -> Q [Con]
getConstructors = \case
    DataD _ _ [method, ret] _ cs _ -> do
        guardMethodVar method
        guardReturnVar ret
        pure cs
    d@DataD{} -> fail $ "bad data type: " <> show d
    d         -> fail $ "Expected a GADT with two parameters but got: " <> show d

mkApiPiece :: ServerConfig -> Con -> Q ApiPiece
mkApiPiece cfg = \case
    -- The normal case
    GadtC [gadtName] bangArgs (AppT (AppT _ requestType) retType) -> do
        handlerSettings <- do
            expandedReqType <- case requestType of
                ConT n -> reify n >>= \case
                    TyConI (TySynD _ _ realType) -> pure realType
                    ty ->
                        fail
                            $  "Expected "
                            <> show n
                            <> " to be a type synonym, got: "
                            <> show ty
                (AppT _ _) -> pure requestType
                ty         -> fail $ "Expected RequestType, got: " <> show ty
            case expandedReqType of
                (AppT (AppT _RequesType contentTypes') verb') ->
                    pure $ HandlerSettings contentTypes' verb'
                ty -> fail $ "Expected RequestType, got: " <> show ty

        actionType <- getActionType $ handlerSettings ^. field @"verb"
        pure $ Endpoint (ConstructorName gadtName)
                        (ConstructorArgs $ fmap snd bangArgs)
                        handlerSettings
                        actionType
                        (EpReturnType retType)
    -- When the constructor contain references to other domain models
    ForallC [method@(KindedTV methodName _ _), ret@(KindedTV retName _ _)] [] (GadtC [gadtName] bangArgs (AppT (AppT _ _) _))
        -> do
            guardMethodVar method
            guardReturnVar ret
            (args, subCmd') <- case reverse $ fmap snd bangArgs of
                AppT (AppT (ConT subCmd') (VarT methodName')) (VarT retName') : rest ->
                    do
                        unless (retName == retName')
                            $  fail
                            $  "\nSubCmd must use the return type variable of the parent."
                            <> ("\n\tExpected: " <> show retName)
                            <> ("\n\tGot: " <> show retName')
                        unless (methodName == methodName')
                            $  fail
                            $  "\nSubCmd must use the method type variable of the parent."
                            <> ("\n\tExpected: " <> show methodName)
                            <> ("\n\tGot: " <> show methodName')
                        pure (reverse rest, subCmd')
                ty : _ ->
                    fail
                        $ "Last constructor argument must have form \
                          \`SubCmd method return`. Got: \n"
                        <> pprint ty
                [] -> fail "I thought this coulnd't happen!"

            subServerSpec <- mkServerSpec cfg (GadtName subCmd')
            pure $ SubApi (ConstructorName gadtName) (ConstructorArgs args) subServerSpec
    c ->
        fail
            $  "Expected a GADT constructor representing an endpoint but got:\n"
            <> pprint c
            <> show c -- FIXME: Remove once it works


-- | Create a ApiSpec from a GADT
-- The GADT must have one parameter representing the return type
mkServerSpec :: ServerConfig -> GadtName -> Q ApiSpec
mkServerSpec cfg n = do
    eps  <- traverse (mkApiPiece cfg) =<< getConstructors =<< getActionDec n
    opts <- getApiOptions cfg n
    pure ApiSpec { gadtName = n, endpoints = eps, apiOptions = opts }


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
    epTypes     <- traverse mkEndpointApiType (spec ^. typed @[ApiPiece])
    topLevelDec <- case reverse epTypes of -- :<|> is right associative
        []     -> fail "Server contains no endpoints"
        t : ts -> do
            let fish :: Type -> Type -> Q Type
                fish b a = [t| $(pure a) :<|> $(pure b) |]
            TySynD apiTypeName [] <$> liftQ (foldM fish t ts)
    handlerDecs <- mconcat <$> traverse mkHandlerTypeDec (spec ^. typed @[ApiPiece])
    pure $ topLevelDec : handlerDecs

-- | Create endpoint types to be referenced in the API
-- * For Endpoint this is just a reference to the handler type
-- * For SubApi we apply the path parameters before referencing the SubApi
mkEndpointApiType :: ApiPiece -> ServerGenM Type
mkEndpointApiType p = enterApiPiece p $ case p of
    Endpoint{}           -> ConT <$> askEndpointTypeName
    SubApi cName cArgs _ -> do
        urlSegments <- mkUrlSegments cName
        n           <- askApiTypeName
        finalType   <- liftQ $ prependServerEndpointName urlSegments (ConT n)

        params      <- mkQueryParams cArgs
        bird        <- liftQ [t| (:>) |]
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
                bird <- liftQ [t| (:>) |]
                let stuff = foldr1 joinUrlParts $ queryParams <> [reqReturn]
                    joinUrlParts :: Type -> Type -> Type
                    joinUrlParts a b = AppT (AppT bird a) b
                urlSegments <- mkUrlSegments name
                liftQ $ prependServerEndpointName urlSegments stuff
            epTypeName <- askEndpointTypeName
            pure [TySynD epTypeName [] ty]
        Endpoint name args hs Mutable retType -> do
            -- Non-get endpoints use a request body
            ty <- do
                reqBody <- mkReqBody hs name args
                let reqReturn = mkReturnType retType
                middle <- case reqBody of
                    Nothing -> pure $ mkVerb hs reqReturn
                    Just b  -> liftQ [t| $(pure b) :> $(pure $ mkVerb hs reqReturn) |]
                urlSegments <- mkUrlSegments name
                liftQ $ prependServerEndpointName urlSegments middle
            epTypeName <- askEndpointTypeName
            pure [TySynD epTypeName [] ty]
        SubApi _name args spec' -> enterApi spec' $ do
            _ <- mkQueryParams args
                -- Make sure we take into account what parameters have already been used.
                -- Skip this and we could end up generating APIs with multiple
                -- QueryParams with the same name, which servant will accept and use one
                -- one the values for both parameters.
            mkServerFromSpec spec'


uniqueParamName :: Name -> ServerGenM String
uniqueParamName tyName = do
    paramName <- do
        -- gets (^. field' @"allParamNames" . at (tyName ^. unqualifiedString)) >>= \case
        gets
                (\c -> M.lookup (tyName ^. unqualifiedString)
                    $ DomainDriven.Server.Types.allParamNames c
                )
            >>= \case
                    Nothing ->
                        fail
                            $  "No param name defined for "
                            <> show tyName
                            <> ". Make sure it implements `HasParamName` and that the "
                            <> " instance is imported where `mkServerConfig` is called."
                    Just n -> pure $ T.unpack n

    existingNames <- gets (^. field @"usedParamNames")
    when (paramName `elem` existingNames) $ do
        info <- gets (^. field @"info")
        let problematicConstructor = info ^. field @"currentGadt" . typed @Name . to show
            problematicParentConstructors =
                L.intercalate "->"
                    $   info
                    ^.. field @"parentConstructors"
                    .   folded
                    .   typed @Name
                    .   to show
        fail
            $  "Duplicate query parameters of type "
            <> show paramName
            <> " in Action "
            <> show problematicConstructor
            <> " with constructor hierarcy "
            <> show problematicParentConstructors
    info <- gets (^. field @"info")
    traceShowM
        ( S.toList existingNames
        , paramName
        , L.intercalate "->"
        $   info
        ^.. field @"parentConstructors"
        .   folded
        .   typed @Name
        .   to show
        )
    modify $ over (field @"usedParamNames") (S.insert paramName)
    pure paramName

mkQueryParams :: ConstructorArgs -> ServerGenM [QueryParamType]
mkQueryParams (ConstructorArgs args) = do
    may <- liftQ [t| Maybe |] -- Maybe parameters are optional, others required
    let mkUniqueTyName :: Name -> ServerGenM Type
        mkUniqueTyName n =
            LitT . StrTyLit <$> uniqueParamName n

    for args $ \case
        (AppT may'  ty@(ConT n')) | may' == may -> do
            n <- mkUniqueTyName n'
            liftQ
                [t| QueryParam' '[Optional, Servant.Strict] $(pure n) $(pure ty) |]
        ty@(ConT n') -> do

            n <- mkUniqueTyName n'
            liftQ
                [t| QueryParam' '[Required, Servant.Strict] $(pure n) $(pure ty) |]
        ty -> fail $ "Expected type ConT, got: " <> show ty

-- mkQueryParam :: Type -> ServerGenM QueryParamType
-- mkQueryParam ty = do
--     may <- liftQ [t| Maybe |] -- Maybe parameters are optional, others required
--     usedNames <- asks $ view (field @"usedParamNames")
--     let mkTyName :: Name -> Q Type
--         mkTyName n = case n ^. unqualifiedString of
--             name | name `elem` usedNames -> fail $ "Duplicate param names: " <> show name
--                  | otherwise -> pure . LitT $ StrTyLit name
--
--     case ty of
--         (AppT may'  ty@(ConT n)) | may' == may ->
--             liftQ
--                 [t| QueryParam' '[Optional, Servant.Strict] $(mkTyName n) $(pure ty) |]
--         ty@(ConT n) ->
--             liftQ
--                 [t| QueryParam' '[Required, Servant.Strict] $(mkTyName n) $(pure ty) |]
--         ty -> fail $ "Expected type ConT, got: " <> show ty

type QueryParamType = Type

--enterApiPieceWithParams
--    :: ApiPiece -> ([QueryParamType] -> ServerGenM a) -> ServerGenM a
--enterApiPieceWithParams p m = do
--    newSegments <- mkUrlSegments (p ^. typed)
--    let extendServerInfo :: ServerInfo -> ServerInfo
--        extendServerInfo i =
--            i
--                & (typed @[UrlSegment] <>~ newSegments)
--                & (typed @[ConstructorName] <>~ p ^. typed . to pure)
--    qParams <- mkQueryParams $ p ^. typed @ConstructorArgs
--
--    local extendServerInfo $ m qParams

mkVerb :: HandlerSettings -> Type -> Type
mkVerb (HandlerSettings _ verb) ret = verb `AppT` ret
-- | Declare then handlers for the API

mkServerDec :: ApiSpec -> ServerGenM [Dec]
mkServerDec spec = do
    apiTypeName <- askApiTypeName
    serverName  <- askServerName

    let runnerName = mkName "runner"

    let gadtType :: GadtType
        gadtType = GadtType $ spec ^. field @"gadtName" . typed @Name . to ConT
    serverType <- liftQ
        [t| forall m. (MonadThrow m, MonadUnliftIO m)
                  => ActionRunner m $(pure $ unGadtType gadtType)
                  -> ServerT $(pure $ ConT apiTypeName) m
          |]

    -- ret <- liftQ [t| Server $(pure $ ConT apiTypeName) |]
    let serverSigDec :: Dec
        serverSigDec = SigD serverName serverType

        mkHandlerExp :: ApiPiece -> ServerGenM Exp
        mkHandlerExp p = enterApiPiece p $ do
            n <- askHandlerName
            pure $ VarE n `AppE` VarE runnerName

    handlers <- traverse mkHandlerExp (spec ^. typed @[ApiPiece])
    body     <- case reverse handlers of -- :<|> is right associative
        []     -> fail "Server contains no endpoints"
        e : es -> liftQ $ foldM (\b a -> [| $(pure a) :<|> $(pure b) |]) e es
    let serverFunDec :: Dec
        serverFunDec = FunD serverName [Clause [VarP runnerName] (NormalB body) []]
    serverHandlerDecs <- mconcat
        <$> traverse (mkApiPieceHandler gadtType) (spec ^. typed @[ApiPiece])

    pure $ serverSigDec : serverFunDec : serverHandlerDecs




withForall :: Type -> Type
withForall = ForallT
    [PlainTV runnerMonadName SpecifiedSpec]
    [ ConT ''MonadUnliftIO `AppT` VarT runnerMonadName
    , ConT ''MonadThrow `AppT` VarT runnerMonadName
    ]

actionRunner :: Type -> Type
actionRunner runnerGADT =
    ConT ''ActionRunner `AppT` VarT runnerMonadName `AppT` runnerGADT

runnerMonadName :: Name
runnerMonadName = mkName "m"

mkNamedFieldsType :: ConstructorName -> ConstructorArgs -> ServerGenM (Maybe Type)
mkNamedFieldsType cName = \case
    ConstructorArgs []   -> pure Nothing
    ConstructorArgs args -> do
        bodyTag <- askBodyTag cName

        let nfType :: Type
            nfType = AppT (ConT nfName) (LitT bodyTag)

            nfName :: Name
            nfName = mkName $ "NamedFields" <> show (length args)
        pure . Just $ foldl AppT nfType args

mkQueryHandlerSignature :: GadtType -> ConstructorArgs -> EpReturnType -> Type
mkQueryHandlerSignature (GadtType actionType) (ConstructorArgs args) (EpReturnType retType)
    = withForall $ mkFunction $ actionRunner actionType : args <> [ret]
  where
    ret :: Type
    ret = AppT (VarT runnerMonadName) retType


-- | Makes command handler, e.g.
--  counterCmd_AddToCounterHandler ::
--    ActionRunner m CounterCmd -> NamedFields1 "CounterCmd_AddToCounter" Int -> m Int
mkCmdHandlerSignature
    :: Type -> ConstructorName -> ConstructorArgs -> EpReturnType -> ServerGenM Type
mkCmdHandlerSignature actionType cName cArgs (EpReturnType retType) = do
    nfArgs <- mkNamedFieldsType cName cArgs
    pure
        $  withForall
        $  mkFunction
        $  [actionRunner actionType]
        <> maybe [] pure nfArgs
        <> [ret]
  where
    ret :: Type
    ret = AppT (VarT runnerMonadName) $ case retType of
        TupleT 0 -> ConT ''NoContent
        ty       -> ty


mkFunction :: [Type] -> Type
mkFunction = foldr1 (\a b -> AppT (AppT ArrowT a) b)

-- | Define the servant handler for an enpoint or referens the subapi with path
-- parameters applied
mkApiPieceHandler :: GadtType -> ApiPiece -> ServerGenM [Dec]
mkApiPieceHandler gadtType@(GadtType actionType') apiPiece = enterApiPiece apiPiece $  do
    case apiPiece of
        Endpoint _cName cArgs _hs Immutable ty -> do
            let nrArgs :: Int
                nrArgs = length $ cArgs ^. typed @[Type]
            varNames       <- liftQ $ replicateM nrArgs (newName "arg")
            handlerName    <- askHandlerName
            runnerName     <- liftQ $ newName "runner"

            let funSig :: Dec
                funSig = SigD handlerName
                 $ mkQueryHandlerSignature gadtType cArgs ty

                funBodyBase = AppE (VarE runnerName) $ foldl
                    AppE
                    (ConE $ apiPiece ^. typed @ConstructorName . typed)
                    (fmap VarE varNames)

                funBody = case ty ^. typed of
                    TupleT 0 -> [| fmap (const NoContent) $(pure funBodyBase) |]
                    _        -> pure $ funBodyBase
            funClause <- liftQ $ clause
                (fmap (pure . VarP) (runnerName:varNames ))
                (normalB [|  $(funBody)  |])
                []
            pure [funSig, FunD handlerName [funClause]]
        Endpoint cName cArgs hs Mutable ty | hasJsonContentType hs -> do
            let nrArgs :: Int
                nrArgs = length $ cArgs ^. typed @[Type]
            varNames       <- liftQ $ replicateM nrArgs (newName "arg")
            handlerName    <- askHandlerName
            runnerName     <- liftQ $ newName "runner"
            let varPat :: Pat
                varPat = ConP nfName [] (fmap VarP varNames)

                nfName :: Name
                nfName = mkName $ "NamedFields" <> show nrArgs

            funSig <- SigD handlerName <$> mkCmdHandlerSignature actionType' cName cArgs ty

            let funBodyBase = AppE (VarE runnerName) $ foldl
                    AppE
                    (ConE $ apiPiece ^. typed @ConstructorName . typed)
                    (fmap VarE varNames)

                funBody = case ty ^. typed of
                    TupleT 0 -> [| fmap (const NoContent) $(pure funBodyBase) |]
                    _        -> pure $ funBodyBase
            funClause <- liftQ $ clause
                (pure (VarP runnerName) : (if nrArgs > 0 then [pure $ varPat] else []))
                (normalB [|  $(funBody)  |])
                []
            pure [funSig, FunD handlerName [funClause]]
        Endpoint _cName cArgs _hs Mutable ty -> do
            -- FIXME: For non-JSON request bodies we support only one argument.
            -- Combining JSON with other content types do not work properly at this point.
            -- It could probably be fixed by adding MimeRender instances to NamedField1
            -- that just uses the underlying MimeRender.
            let nrArgs :: Int
                nrArgs = length $ cArgs ^. typed @[Type]
            unless (nrArgs < 2) $
                fail "Only one argument is supported for non-JSON request bodies"
            varName       <- liftQ $ newName "arg"
            handlerName    <- askHandlerName
            runnerName     <- liftQ $ newName "runner"
            let varPat :: Pat
                varPat = VarP varName

            let funSig :: Dec
                funSig = SigD handlerName $ mkQueryHandlerSignature gadtType cArgs ty

                funBodyBase = AppE (VarE runnerName) $
                    AppE
                    (ConE $ apiPiece ^. typed @ConstructorName . typed)
                    (VarE varName)

                funBody = case ty ^. typed of
                    TupleT 0 -> [| fmap (const NoContent) $(pure funBodyBase) |]
                    _        -> pure $ funBodyBase
            funClause <- liftQ $ clause
                (pure (VarP runnerName) : (if nrArgs > 0 then [pure $ varPat] else []))
                (normalB [|  $(funBody)  |])
                []
            pure [funSig, FunD handlerName [funClause]]
        SubApi cName cArgs spec -> do
            -- Apply the arguments to the constructor before referencing the subserver
            varNames  <- liftQ $ replicateM (length (cArgs ^. typed @[Type])) (newName "arg")
            handlerName    <- askHandlerName
            targetApiTypeName <- enterApi spec askApiTypeName
            targetServer <- enterApi spec askServerName
            runnerName     <- liftQ $ newName "runner"

            funSig <- liftQ $ do
                let params = withForall $ mkFunction $
                        [ actionRunner actionType']
                        <> cArgs ^. typed @[Type]
                        <> [ConT ''ServerT
                            `AppT` (ConT targetApiTypeName)
                            `AppT` (VarT runnerMonadName)]
                SigD handlerName <$> pure params


            funClause <- liftQ $ do
                let cmd = foldl (\b a -> AppE b a)
                                (ConE $ cName ^. typed)
                                (fmap VarE varNames)
                 in clause
                      (varP <$>  runnerName : varNames)
                      (fmap NormalB [e| $(varE targetServer)
                                        ( $(varE runnerName). $(pure cmd))
                                        |])
                      []
            let funDef = FunD handlerName [funClause]
            pure [funSig, funDef]
---- | This is the only layer of the ReaderT stack where we do not use `local` to update the
---- url segments.
mkServerFromSpec :: ApiSpec -> ServerGenM [Dec]
mkServerFromSpec spec = enterApi spec $ do
    apiTypeDecs <- mkApiTypeDecs spec
    serverDecs  <- mkServerDec spec
    pure $ apiTypeDecs <> serverDecs


-- | Handles the special case of `()` being transformed into `NoContent`
mkReturnType :: EpReturnType -> Type
mkReturnType (EpReturnType ty) = case ty of
    TupleT 0 -> ConT ''NoContent
    _        -> ty

prependServerEndpointName :: [UrlSegment] -> Type -> Q Type
prependServerEndpointName prefix rest = do
    foldr (\a b -> [t| $(pure a) :> $b |])
          (pure rest)
          (fmap (LitT . StrTyLit . (^. typed)) prefix)

mkReqBody
    :: HandlerSettings -> ConstructorName -> ConstructorArgs -> ServerGenM (Maybe Type)
mkReqBody hs name args = if hasJsonContentType hs
    then do
        bodyTag <- askBodyTag name
        let
            body = case args of
                ConstructorArgs [] -> Nothing
                ConstructorArgs ts ->
                    let n           = length ts
                        constructor = AppT (ConT (mkName $ "NamedFields" <> show n))
                                           (LitT bodyTag)
                    in  Just $ foldl AppT constructor ts
        case body of
            Nothing -> pure Nothing
            Just b  -> Just <$> liftQ [t| ReqBody '[JSON] $(pure b) |]
    else do
        let
            body = case args of
                ConstructorArgs []  -> Nothing
                ConstructorArgs [t] -> Just t
                ConstructorArgs _ ->
                    fail "Multiple arguments are only supported for JSON content"
        case body of
            Nothing -> pure Nothing
            Just b ->
                Just <$> liftQ
                    [t| ReqBody $(pure $ hs ^. field @"contentTypes") $(pure b) |]
