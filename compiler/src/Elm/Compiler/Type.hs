{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Elm.Compiler.Type
  ( Type(..)
  , Context(..)
  , toDoc
  , DebugMetadata(..)
  , Alias(..)
  , Union(..)
  , encode
  , decoder
  , encodeMetadata
  )
  where


import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import qualified AST.Source as Src
import qualified Elm.Name as N
import qualified Parse.Primitives as Parse
import qualified Parse.Type as Type
import qualified Reporting.Annotation as A
import qualified Reporting.Doc as D
import Reporting.Doc ((<>), (<+>))
import qualified Json.Decode as Decode
import qualified Json.Encode as Encode
import Json.Encode ((==>))



-- TYPES


data Type
    = Lambda Type Type
    | Var N.Name
    | Type N.Name [Type]
    | Record [(N.Name, Type)] (Maybe N.Name)
    | Unit
    | Tuple Type Type [Type]


data DebugMetadata =
  DebugMetadata
    { _message :: Type
    , _aliases :: [Alias]
    , _unions :: [Union]
    }


data Alias = Alias N.Name [N.Name] Type
data Union = Union N.Name [N.Name] [(N.Name, [Type])]



-- TO DOC


data Context = None | InType | InFunction


toDoc :: Context -> Type -> D.Doc
toDoc context tipe =
  case tipe of
    Lambda _ _ ->
        let t:ts =
              map (toDoc InFunction) (collectLambdas tipe)

            lambda =
              D.sep [ t, D.sep (map ("->" <+>) ts) ]
        in
            case context of
              None -> lambda
              _ -> "(" <> lambda <> ")"

    Var name ->
        D.fromName name

    Unit ->
        "()"

    Tuple a b cs ->
        D.sep
          [ D.cat $
              [ "(" <+> toDoc None a
              , "," <+> toDoc None b
              ]
              ++ map ("," <+>) (map (toDoc None) cs)
          , ")"
          ]

    Type name args ->
        case args of
          [] ->
            D.fromName name

          _ ->
            let
              docName =
                D.fromName name

              application =
                D.hang 2 $ D.sep (docName : map (toDoc InType) args)
            in
              case context of
                InType ->
                  "(" <> application <> ")"

                _ ->
                  application

    Record [] Nothing ->
      "{}"

    Record fields ext ->
      case ext of
        Nothing ->
          D.sep
            [ D.cat (zipWith (<+>) ("{" : repeat ",") (map entryToDoc fields))
            , "}"
            ]

        Just x ->
          D.sep
            [ D.hang 4 $ D.sep $
                [ "{" <+> D.fromName x
                , D.cat (zipWith (<+>) ("|" : repeat ",") (map entryToDoc fields))
                ]
            , "}"
            ]


entryToDoc :: (N.Name, Type) -> D.Doc
entryToDoc (field, fieldType) =
  D.fromName field <+> ":" <+> toDoc None fieldType


collectLambdas :: Type -> [Type]
collectLambdas tipe =
  case tipe of
    Lambda arg body -> arg : collectLambdas body
    _ -> [tipe]



-- JSON for TYPE


encode :: Type -> Encode.Value
encode tipe =
  Encode.text $ Text.pack $ D.toLine (toDoc None tipe)


decoder :: Decode.Decoder () Type
decoder =
  do  txt <- Decode.text
      case Parse.run Type.expression (Text.encodeUtf8 (Text.replace "'" "_" txt)) of
        Left _ ->
          Decode.fail ()

        Right (tipe, _, _) ->
          Decode.succeed (fromRawType tipe)


fromRawType :: Src.Type -> Type
fromRawType (A.At _ astType) =
  case astType of
    Src.TLambda t1 t2 ->
        Lambda (fromRawType t1) (fromRawType t2)

    Src.TVar x ->
        Var x

    Src.TUnit ->
        Unit

    Src.TTuple a b cs ->
        Tuple
          (fromRawType a)
          (fromRawType b)
          (map fromRawType cs)

    Src.TType _ name args ->
        Type name (map fromRawType args)

    Src.TTypeQual _ _ name args ->
        Type name (map fromRawType args)

    Src.TRecord fields ext ->
        let fromField (A.At _ field, tipe) = (field, fromRawType tipe) in
        Record
          (map fromField fields)
          (fmap A.toValue ext)



-- JSON for PROGRAM


encodeMetadata :: DebugMetadata -> Encode.Value
encodeMetadata (DebugMetadata msg aliases unions) =
  Encode.object
    [ "message" ==> encode msg
    , "aliases" ==> Encode.object (map toAliasField aliases)
    , "unions" ==> Encode.object (map toUnionField unions)
    ]


toAliasField :: Alias -> ( Text.Text, Encode.Value )
toAliasField (Alias name args tipe) =
  N.toText name ==>
    Encode.object
      [ "args" ==> Encode.list Encode.name args
      , "type" ==> encode tipe
      ]


toUnionField :: Union -> ( Text.Text, Encode.Value )
toUnionField (Union name args constructors) =
  N.toText name ==>
    Encode.object
      [ "args" ==> Encode.list Encode.name args
      , "tags" ==> Encode.object (map toCtorObject constructors)
      ]


toCtorObject :: (N.Name, [Type]) -> ( Text.Text, Encode.Value )
toCtorObject (name, args) =
  N.toText name ==> Encode.list encode args
