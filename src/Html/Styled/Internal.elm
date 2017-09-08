module Html.Styled.Internal exposing (Classname, InternalHtml(..), getClassname, unstyle, unstyleKeyed)

import Css exposing (Style)
import Dict exposing (Dict)
import Hex
import Json.Encode
import Murmur3
import VirtualDom exposing (Node, Property)


type alias Classname =
    String


type InternalHtml msg
    = Element (Maybe ( Classname, List Style )) String (List (VirtualDom.Property msg)) (List (InternalHtml msg))
    | KeyedElement (Maybe ( Classname, List Style )) String (List (VirtualDom.Property msg)) (List ( String, InternalHtml msg ))
    | Unstyled (VirtualDom.Node msg)


getClassname : List Style -> Maybe String
getClassname styles =
    if List.isEmpty styles then
        Nothing
    else
        -- TODO Replace this comically inefficient implementation
        -- with crawling these union types and building up a hash along the way.
        styles
            |> Css.everything
            |> List.singleton
            |> Css.stylesheet
            |> List.singleton
            |> Css.compile
            |> .css
            |> Murmur3.hashString murmurSeed
            |> Hex.toString
            |> String.cons '_'
            |> Just


murmurSeed : Int
murmurSeed =
    15739


unstyle :
    String
    -> Maybe ( Classname, List Style )
    -> List (Property msg)
    -> List (InternalHtml msg)
    -> Node msg
unstyle =
    unstyleWith
        resolve
        VirtualDom.node
        toStyleNode


unstyleKeyed :
    String
    -> Maybe ( Classname, List Style )
    -> List (Property msg)
    -> List ( String, InternalHtml msg )
    -> Node msg
unstyleKeyed =
    unstyleWith
        resolveKeyed
        VirtualDom.keyedNode
        toKeyedStyleNode



-- INTERNAL --


toStyleNode :
    String
    -> Dict Classname (List Style)
    -> a
    -> Node msg
toStyleNode classname allStyles _ =
    getStyleNode classname allStyles


toKeyedStyleNode :
    String
    -> Dict Classname (List Style)
    -> List ( String, a )
    -> ( String, Node msg )
toKeyedStyleNode classname allStyles finalChildNodes =
    let
        styleNodeKey =
            getUnusedKey "_" finalChildNodes

        finalNode =
            getStyleNode classname allStyles
    in
    ( styleNodeKey, finalNode )


getStyleNode : String -> Dict Classname (List Style) -> Node msg
getStyleNode classname styles =
    -- this <style> node will be the first child of the requested one
    toDeclaration styles
        |> VirtualDom.text
        |> List.singleton
        |> VirtualDom.node "style" []



-- INTERNAL --


unstyleWith :
    (keyedOrHtml2 -> ( List keyedOrHtml, Dict Classname (List Style) ) -> ( List keyedOrHtml, Dict Classname (List Style) ))
    -> (String -> List (Property msg) -> List keyedOrHtml -> keyedOrHtml3)
    -> (String -> Dict Classname (List Style) -> List keyedOrHtml -> keyedOrHtml)
    -> String
    -> Maybe ( Classname, List Style )
    -> List (Property msg)
    -> List keyedOrHtml2
    -> keyedOrHtml3
unstyleWith resolver toNode createStyleNode elemType maybePair attributes children =
    let
        ( styles, finalAttributes, classname ) =
            case maybePair of
                Just ( classnameFromPair, style ) ->
                    ( Dict.singleton classnameFromPair style
                    , class classnameFromPair :: attributes
                    , classnameFromPair
                    )

                Nothing ->
                    ( Dict.empty
                    , attributes
                    , ""
                    )

        ( childNodes, allStyles ) =
            List.foldl resolver ( [], styles ) children

        finalChildNodes =
            List.reverse childNodes
    in
    if Dict.isEmpty allStyles then
        -- If we have no styles to speak of, don't emit a <style>
        toNode elemType finalAttributes finalChildNodes
    else
        let
            styleNode =
                createStyleNode classname allStyles finalChildNodes
        in
        toNode
            elemType
            attributes
            (styleNode :: finalChildNodes)


resolve :
    InternalHtml msg
    -> ( List (Node msg), Dict Classname (List Style) )
    -> ( List (Node msg), Dict Classname (List Style) )
resolve html ( nodes, styles ) =
    case html of
        Unstyled vdom ->
            ( vdom :: nodes, styles )

        Element maybePair elemType attributes children ->
            let
                ( combinedStyles, elemAttributes ) =
                    case maybePair of
                        Just ( classname, style ) ->
                            ( Dict.insert classname style styles
                            , class classname :: attributes
                            )

                        Nothing ->
                            ( styles
                            , attributes
                            )

                ( childNodes, finalStyles ) =
                    List.foldl resolve ( [], combinedStyles ) children

                vdom =
                    VirtualDom.node elemType
                        elemAttributes
                        (List.reverse childNodes)
            in
            ( vdom :: nodes, finalStyles )

        KeyedElement maybePair elemType attributes children ->
            let
                ( combinedStyles, elemAttributes ) =
                    case maybePair of
                        Just ( classname, style ) ->
                            ( Dict.insert classname style styles
                            , class classname :: attributes
                            )

                        Nothing ->
                            ( styles
                            , attributes
                            )

                ( childNodes, finalStyles ) =
                    List.foldl resolveKeyed ( [], combinedStyles ) children

                vdom =
                    VirtualDom.keyedNode elemType
                        elemAttributes
                        (List.reverse childNodes)
            in
            ( vdom :: nodes, finalStyles )


resolveKeyed :
    ( String, InternalHtml msg )
    -> ( List ( String, Node msg ), Dict Classname (List Style) )
    -> ( List ( String, Node msg ), Dict Classname (List Style) )
resolveKeyed ( key, html ) ( pairs, styles ) =
    case html of
        Unstyled vdom ->
            ( ( key, vdom ) :: pairs, styles )

        Element maybePair elemType attributes children ->
            let
                ( combinedStyles, elemAttributes ) =
                    case maybePair of
                        Just ( classname, style ) ->
                            ( Dict.insert classname style styles
                            , class classname :: attributes
                            )

                        Nothing ->
                            ( styles
                            , attributes
                            )

                ( childNodes, finalStyles ) =
                    List.foldl resolve ( [], combinedStyles ) children

                vdom =
                    VirtualDom.node elemType
                        elemAttributes
                        (List.reverse childNodes)
            in
            ( ( key, vdom ) :: pairs, finalStyles )

        KeyedElement maybePair elemType attributes children ->
            let
                ( combinedStyles, elemAttributes ) =
                    case maybePair of
                        Just ( classname, style ) ->
                            ( Dict.insert classname style styles
                            , class classname :: attributes
                            )

                        Nothing ->
                            ( styles
                            , attributes
                            )

                ( childNodes, finalStyles ) =
                    List.foldl resolveKeyed ( [], combinedStyles ) children

                vdom =
                    VirtualDom.keyedNode elemType
                        elemAttributes
                        (List.reverse childNodes)
            in
            ( ( key, vdom ) :: pairs, finalStyles )


class : Classname -> Property msg
class =
    Json.Encode.string >> VirtualDom.property "className"


toDeclaration : Dict Classname (List Style) -> String
toDeclaration dict =
    Dict.toList dict
        |> List.map snippetFromPair
        |> Css.stylesheet
        |> List.singleton
        |> Css.compile
        |> .css


snippetFromPair : ( Classname, List Style ) -> Css.Snippet
snippetFromPair ( classname, styles ) =
    Css.class classname styles


{-| returns a String key that is not already one of the keys in the list of
key-value pairs. We need this in order to prepend to a list of InternalHtml.Keyed
nodes with a guaranteed-unique key.
-}
getUnusedKey : String -> List ( String, a ) -> String
getUnusedKey default pairs =
    case pairs of
        [] ->
            default

        ( firstKey, _ ) :: rest ->
            let
                newKey =
                    "_" ++ firstKey
            in
            if containsKey newKey rest then
                getUnusedKey newKey rest
            else
                newKey


containsKey : String -> List ( String, a ) -> Bool
containsKey key pairs =
    case pairs of
        [] ->
            False

        ( str, _ ) :: rest ->
            if key == str then
                True
            else
                containsKey key rest
