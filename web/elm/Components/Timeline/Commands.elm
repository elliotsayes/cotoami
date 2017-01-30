module Components.Timeline.Commands exposing (..)

import Json.Decode as Decode
import Json.Encode as Encode
import Dom.Scroll
import Task
import Process
import Time
import Http
import App.Types exposing (Cotonoma)
import Components.Timeline.Model exposing (Coto, decodeCoto)
import Components.Timeline.Messages exposing (..)


scrollToBottom : msg -> Cmd msg
scrollToBottom msg =
    Process.sleep (1 * Time.millisecond)
    |> Task.andThen (\_ -> (Dom.Scroll.toBottom "timeline"))
    |> Task.attempt (\_ -> msg) 


fetchCotos : Cmd Msg
fetchCotos =
    Http.send CotosFetched (Http.get "/api/cotos" (Decode.list decodeCoto))


postCoto : Maybe Cotonoma -> Coto -> Cmd Msg
postCoto maybeCotonoma coto =
    Http.send CotoPosted 
        <| Http.post 
            "/api/cotos" 
            (Http.jsonBody (encodeCoto maybeCotonoma coto)) 
            decodeCoto
        

encodeCoto : Maybe Cotonoma -> Coto -> Encode.Value
encodeCoto maybeCotonoma coto =
    Encode.object 
        [ ("coto", 
            (Encode.object 
                [ ("cotonoma_id"
                  , case maybeCotonoma of
                        Nothing -> Encode.null 
                        Just cotonoma -> Encode.int cotonoma.id
                  )
                , ("postId"
                  , case coto.postId of
                        Nothing -> Encode.null 
                        Just postId -> Encode.int postId
                  )
                , ("content", Encode.string coto.content)
                ]
            )
          )
        ]
