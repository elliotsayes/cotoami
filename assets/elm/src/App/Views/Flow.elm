module App.Views.Flow
    exposing
        ( Model
        , defaultModel
        , setFilter
        , update
        , initScrollPos
        , post
        , view
        )

import Html exposing (..)
import Html.Keyed
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Decode
import List.Extra exposing (groupWhile)
import Util.UpdateUtil exposing (..)
import Util.StringUtil exposing (isBlank, isNotBlank)
import Util.HtmlUtil exposing (faIcon, materialIcon)
import Util.DateUtil exposing (sameDay, formatDay)
import Util.EventUtil exposing (onKeyDown, onClickWithoutPropagation, onLinkButtonClick)
import Util.Keyboard.Key
import Util.Keyboard.Event exposing (KeyboardEvent)
import App.Types.Coto exposing (CotoContent)
import App.Types.Post exposing (Post, toCoto)
import App.Types.Session exposing (Session)
import App.Types.Graph exposing (Direction(..), Graph, member)
import App.Types.Timeline exposing (Timeline)
import App.Types.TimelineFilter exposing (TimelineFilter)
import App.Submodels.Context exposing (Context)
import App.Submodels.Modals exposing (Modals)
import App.Submodels.LocalCotos exposing (LocalCotos)
import App.Messages as AppMsg exposing (..)
import App.Views.FlowMsg as FlowMsg exposing (Msg(..), TimelineView(..))
import App.Views.Post
import App.Modals.ConnectModal exposing (WithConnectModal)
import App.Commands
import App.Server.Post


type alias Model =
    { hidden : Bool
    , view : TimelineView
    , filter : TimelineFilter
    }


defaultModel : Model
defaultModel =
    { hidden = False
    , view = StreamView
    , filter = App.Types.TimelineFilter.defaultTimelineFilter
    }


toggle : Model -> Model
toggle model =
    { model | hidden = not model.hidden }


switchView : TimelineView -> Model -> Model
switchView view model =
    { model | view = view }


setFilter : TimelineFilter -> Model -> Model
setFilter filter model =
    { model | filter = filter }


type alias UpdateModel model =
    LocalCotos
        (Modals
            (WithConnectModal
                { model
                    | flowView : Model
                }
            )
        )


update : Context context -> FlowMsg.Msg -> UpdateModel model -> ( UpdateModel model, Cmd AppMsg.Msg )
update context msg ({ flowView, timeline } as model) =
    case msg of
        ToggleFlow ->
            { model | flowView = toggle flowView }
                |> withoutCmd

        TimelineScrollPosInitialized ->
            { model | timeline = App.Types.Timeline.setScrollPosInitialized timeline }
                |> withoutCmd

        ImageLoaded ->
            model
                |> withCmdIf
                    (\model -> model.timeline.pageIndex == 0)
                    (\_ -> App.Commands.scrollTimelineToBottom NoOp)

        SwitchView view ->
            { model | flowView = switchView view flowView }
                |> withoutCmd

        LoadMorePosts ->
            { model | timeline = App.Types.Timeline.setLoadingMore timeline }
                |> withCmd
                    (\model ->
                        App.Server.Post.fetchPostsByContext
                            (App.Types.Timeline.nextPageIndex timeline)
                            flowView.filter
                            context
                    )

        EditorFocus ->
            { model | timeline = App.Types.Timeline.openOrCloseEditor True timeline }
                |> withCmdIf
                    (\model -> timeline.editorOpen)
                    (\_ -> App.Commands.scrollTimelineByQuickEditorOpen NoOp)

        EditorInput content ->
            { model | timeline = App.Types.Timeline.setEditorContent content timeline }
                |> withoutCmd

        EditorKeyDown keyboardEvent ->
            handleEditorShortcut context keyboardEvent (CotoContent timeline.editorContent Nothing) model
                |> addCmd (\_ -> App.Commands.focus "quick-coto-input" NoOp)

        Post ->
            post context (CotoContent timeline.editorContent Nothing) timeline
                |> Tuple.mapFirst (\timeline -> { model | timeline = timeline })
                |> addCmd (\_ -> App.Commands.focus "quick-coto-input" NoOp)

        Posted postId (Ok response) ->
            { model | timeline = App.Types.Timeline.setCotoSaved postId response timeline }
                |> App.Submodels.LocalCotos.updateRecentCotonomas response.postedIn
                |> App.Submodels.Modals.clearModals
                |> withoutCmd

        Posted postId (Err _) ->
            model |> withoutCmd

        ConfirmPostAndConnect content ->
            App.Modals.ConnectModal.openWithPost content model


initScrollPos : LocalCotos a -> Cmd AppMsg.Msg
initScrollPos localCotos =
    if App.Submodels.LocalCotos.areTimelineAndGraphLoaded localCotos then
        App.Commands.scrollTimelineToBottom (AppMsg.FlowMsg TimelineScrollPosInitialized)
    else
        Cmd.none


handleEditorShortcut :
    Context context
    -> KeyboardEvent
    -> CotoContent
    -> UpdateModel model
    -> ( UpdateModel model, Cmd AppMsg.Msg )
handleEditorShortcut context keyboardEvent content model =
    if
        (keyboardEvent.keyCode == Util.Keyboard.Key.Enter)
            && isNotBlank content.content
    then
        if keyboardEvent.ctrlKey || keyboardEvent.metaKey then
            post context content model.timeline
                |> Tuple.mapFirst (\timeline -> { model | timeline = timeline })
        else if
            keyboardEvent.altKey
                && App.Submodels.Context.anySelection context
        then
            App.Modals.ConnectModal.openWithPost content model
        else
            ( model, Cmd.none )
    else
        ( model, Cmd.none )


post : Context context -> CotoContent -> Timeline -> ( Timeline, Cmd AppMsg.Msg )
post context content timeline =
    let
        ( newTimeline, newPost ) =
            App.Types.Timeline.post context False content timeline
    in
        ( newTimeline
        , Cmd.batch
            [ App.Commands.scrollTimelineToBottom NoOp
            , App.Server.Post.post
                context.clientId
                context.cotonoma
                (AppMsg.FlowMsg << (Posted newTimeline.postIdCounter))
                newPost
            ]
        )


type alias ViewModel model =
    LocalCotos
        { model
            | flowView : Model
        }


view : Context context -> Session -> ViewModel model -> Html AppMsg.Msg
view context session model =
    div
        [ id "flow"
        , classList
            [ ( "editing", model.timeline.editorOpen )
            ]
        ]
        [ if not (App.Submodels.LocalCotos.isTimelineReady model) then
            div [ class "loading-overlay" ] []
          else
            div [] []
        , toolbarDiv context model.flowView
        , timelineDiv context model
        , postEditor context session model.timeline
        , newCotoButton model.timeline
        ]


toolbarDiv : Context context -> Model -> Html AppMsg.Msg
toolbarDiv context model =
    div [ class "flow-toolbar" ]
        [ a
            [ class "tool-button flow-toggle"
            , title "Hide flow view"
            , onLinkButtonClick (AppMsg.FlowMsg ToggleFlow)
            ]
            [ materialIcon "arrow_left" Nothing ]
        , div [ class "tools" ]
            [ a
                [ classList
                    [ ( "tool-button", True )
                    , ( "open-filter", True )
                    ]
                , title "Filter"
                , onClick OpenTimelineFilterModal
                ]
                [ materialIcon "filter_list" Nothing ]
            , span [ class "view-switch" ]
                [ a
                    [ classList
                        [ ( "tool-button", True )
                        , ( "stream-view", True )
                        , ( "disabled", model.view == StreamView )
                        ]
                    , title "Stream View"
                    , onClick (AppMsg.FlowMsg (SwitchView StreamView))
                    ]
                    [ materialIcon "view_stream" Nothing ]
                , a
                    [ classList
                        [ ( "tool-button", True )
                        , ( "tile-view", True )
                        , ( "disabled", model.view == TileView )
                        ]
                    , title "Tile View"
                    , onClick (AppMsg.FlowMsg (SwitchView TileView))
                    ]
                    [ materialIcon "view_module" Nothing ]
                ]
            ]
        ]


timelineDiv : Context context -> ViewModel model -> Html AppMsg.Msg
timelineDiv context model =
    div
        [ id "timeline"
        , classList
            [ ( "timeline", True )
            , ( "stream", model.flowView.view == StreamView )
            , ( "tile", model.flowView.view == TileView )
            , ( "exclude-pinned-graph", model.flowView.filter.excludePinnedGraph )
            ]
        ]
        [ moreButton model.timeline
        , model.timeline.posts
            |> List.reverse
            |> groupWhile (\p1 p2 -> sameDay p1.postedAt p2.postedAt)
            |> List.map
                (\postsOnDay ->
                    let
                        lang =
                            context.session
                                |> Maybe.map (\session -> session.lang)
                                |> Maybe.withDefault ""

                        postDateString =
                            List.head postsOnDay
                                |> Maybe.andThen (\post -> post.postedAt)
                                |> Maybe.map (formatDay lang)
                                |> Maybe.withDefault ""
                    in
                        ( postDateString
                        , div
                            [ class "posts-on-day" ]
                            [ div
                                [ class "date-header" ]
                                [ span [ class "date" ] [ text postDateString ] ]
                            , postsDiv context model.graph postsOnDay
                            ]
                        )
                )
            |> Html.Keyed.node "div" [ class "posts" ]
        ]


moreButton : Timeline -> Html AppMsg.Msg
moreButton timeline =
    if timeline.more then
        div [ class "more-button-div" ]
            [ if timeline.loadingMore then
                button
                    [ class "button more-button loading", disabled True ]
                    [ img [ src "/images/loading-horizontal.gif" ] [] ]
              else
                button
                    [ class "button more-button"
                    , onClick (AppMsg.FlowMsg LoadMorePosts)
                    ]
                    [ materialIcon "arrow_drop_up" Nothing ]
            ]
    else
        Util.HtmlUtil.none


postsDiv : Context context -> Graph -> List Post -> Html AppMsg.Msg
postsDiv context graph posts =
    Html.Keyed.node
        "div"
        [ class "posts" ]
        (List.map
            (\post ->
                ( getKey post
                , App.Views.Post.view context graph post
                )
            )
            posts
        )


getKey : Post -> String
getKey post =
    post.cotoId
        |> Maybe.map toString
        |> Maybe.withDefault
            (post.postId
                |> Maybe.map toString
                |> Maybe.withDefault ""
            )


postEditor : Context context -> Session -> Timeline -> Html AppMsg.Msg
postEditor context session model =
    div [ class "quick-coto-editor" ]
        [ div [ class "toolbar", hidden (not model.editorOpen) ]
            [ span [ class "user session" ]
                [ img [ class "avatar", src session.avatarUrl ] []
                , span [ class "name" ] [ text session.displayName ]
                ]
            , div [ class "tool-buttons" ]
                [ if List.isEmpty context.selection then
                    Util.HtmlUtil.none
                  else
                    span [ class "connect-buttons" ]
                        [ button
                            [ class "button connect"
                            , disabled (isBlank model.editorContent)
                            , onMouseDown
                                (AppMsg.FlowMsg
                                    (ConfirmPostAndConnect
                                        (CotoContent model.editorContent Nothing)
                                    )
                                )
                            ]
                            [ faIcon "link" Nothing
                            , span [ class "shortcut-help" ] [ text "(Alt + Enter)" ]
                            ]
                        ]
                , button
                    [ class "button-primary post"
                    , disabled (isBlank model.editorContent)
                    , onMouseDown (AppMsg.FlowMsg FlowMsg.Post)
                    ]
                    [ text "Post"
                    , span [ class "shortcut-help" ] [ text "(Ctrl + Enter)" ]
                    ]
                ]
            ]
        , Html.Keyed.node
            "div"
            []
            [ ( toString model.editorCounter
              , textarea
                    [ class "coto"
                    , id "quick-coto-input"
                    , placeholder "Write your Coto in Markdown"
                    , defaultValue model.editorContent
                    , onFocus (AppMsg.FlowMsg EditorFocus)
                    , onInput (AppMsg.FlowMsg << EditorInput)
                    , on "keydown" <|
                        Decode.map
                            (AppMsg.FlowMsg << EditorKeyDown)
                            Util.Keyboard.Event.decodeKeyboardEvent
                    , onClickWithoutPropagation NoOp
                    ]
                    []
              )
            ]
        ]


newCotoButton : Timeline -> Html AppMsg.Msg
newCotoButton timeline =
    a
        [ class "tool-button new-coto-button"
        , title "New Coto"
        , hidden (timeline.editorOpen)
        , onClick OpenNewEditorModal
        ]
        [ materialIcon "create" Nothing
        , span [ class "shortcut" ] [ text "(Press N key)" ]
        ]
