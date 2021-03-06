{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE Arrows #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE Strict, StrictData #-}

module
    Main
where

import Prelude hiding ((.), id)
import Control.Category
import Control.Arrow
import Control.Lens hiding (set)
import Data.Void
import Data.Tree
import Data.Maybe (fromMaybe, isNothing)
import Control.Monad (forever, guard, forM_, mplus)
import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Resource
import qualified Data.Text as Text
import Control.Concurrent (forkIO, threadDelay)

import Graphics.UI.Gtk hiding (on, onClicked)
import Graphics.UI.Gtk.WebKit.WebFrame
import Graphics.UI.Gtk.WebKit.WebView
import Graphics.UI.Gtk.ModelView.TreeStore
import Graphics.UI.Gtk.ModelView.TreeView
import qualified Graphics.UI.Gtk.WebKit.DOM.Document as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.Element as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.Node as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.CSSStyleDeclaration as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.EventM as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.Event as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.MouseEvent as DOM
import qualified Graphics.UI.Gtk.WebKit.DOM.UIEvent as DOM
import qualified Graphics.UI.Gtk.WebKit.WebView as DOM

import Control.Arrow.Machine
import Graphics.UI.McGtk
import qualified Graphics.UI.McWebkit as McWeb
import Control.Arrow.Machine.World
import Control.Arrow.Machine.IORefRunner

import qualified Web.Hastodon as Hdon

import BasicModel
import qualified Content
import qualified DataModel
import qualified Async
import qualified MainForm
import qualified AuthDialog
import qualified ClassyDOM

import Debug.Trace

type TheWorld = World IO IO GtkRunner
type TheModel = DataModel.T GtkRunner

--
-- Utility
--
wrSwitchDiff ::
    Eq a =>
    (a -> ProcessT IO TheWorld b) ->
    a ->
    ProcessT IO (TheWorld, Event a) b
wrSwitchDiff f x0 = evolve $
  do
    x <- wSwitchAfter $ f x0 *** filterEvent (/= x0)
    finishWith $ wrSwitchDiff f x



main :: IO ()
main = gtkReactimate $ evolve $
  do
    model <- DataModel.init

    switchAfter $
        muted &&& onActivation

    mf <- lift $ MainForm.setup Content.initialHtml
    _ <- wSwitchAfter $
        muted &&& (mf ^. MainForm.statusView `on` DOM.loadFinished)

    finishWith $ driveMainForm model mf


authNew :: TheModel -> ProcessT IO (TheWorld, Event ()) (Event Void)
authNew model = evolve $ forever $
  do
    wSwitchAfter $ muted *** id
    liftIO $ postGUIAsync $ runMaybeT doAuth >> return ()

  where
    doAuth =
      do
        (hostname, appname) <- MaybeT AuthDialog.getHostname

        hst <- MaybeT $ DataModel.getClientInfo hostname appname
        let cid = Text.unpack $ hst ^. clientId
            csecret = Text.unpack $ hst ^. clientSecret

        reg <- MaybeT $ AuthDialog.authPasswd hostname cid csecret
        liftIO $ DataModel.addRegistration model reg


driveMainForm :: TheModel -> MainForm.T -> ProcessT IO TheWorld (Event Void)
driveMainForm model mf = proc world ->
  do
    fire0 (DataModel.loadSetting model) <<< onActivation -< world

    -- Instance Pane
    addClick <-
        onClicked $ mf ^. MainForm.instAddBtn
            -< world

    authNew model -< (world, addClick)

    modelReg <- DataModel.onAddReg model -< world
    fire $ MainForm.addRegistration mf -< modelReg

    treeSelected <-
        mf ^. MainForm.instSel `on` treeSelectionSelectionChanged
            -< world
    newDs <-
        filterJust <<< fire0 (MainForm.getDataSource mf)
            -< treeSelected
    fire $ DataModel.selDS model -< newDs

    -- Status pane
    doc <-
        filterJust
        <<< fire0 (webViewGetDomDocument $ mf ^. MainForm.statusView)
        <<< onActivation
            -< world
    wrSwitch0 -< (world, driveDocument model <$> doc)

    -- Post Box
    tootClick <-
        onClicked $ mf ^. MainForm.postButton
            -< world
    wrSwitch0 -< (world, toot <$ tootClick)

    -- Termination
    del <-
        mf ^. MainForm.win `on` deleteEvent `Replying` False
            -< world
    construct (await >> stop) -< del
  where
    toot = proc world ->
      do
        fire0 (postToot $ mf ^. MainForm.postBox) <<< onActivation -< world

-- Handle DOM event here.
driveDocument ::
    TheModel -> DOM.Document -> ProcessT IO TheWorld (Event Void)
driveDocument model doc = proc world ->
  do
    -- Data source handling
    ds <- DataModel.onSelDS model -< world
    wrSwitch0 -< (world, driveDs <$> ds)

    muted -< world
  where
    driveDs ds = proc world ->
      do
        -- Clear current web view on activation.
        fire0 (clearWebView doc) <<< onActivation -< world

        -- Show up toots (it depends on scroll state)
        scr <- fire0 (isScrollTop doc) <<<
            McWeb.on doc
                (DOM.EventName "scroll" :: DOM.EventName DOM.Document DOM.UIEvent)
                (return ())
                    -< world
        wrSwitchDiff (driveDsSub ds) True -< (world, scr)

        -- Handle placeholder click.
        clRPH <- onSelectorClick doc "div.hdon_rph a.waiting" -< world
        fire (runMaybeT . requireRangeByElem ds) -< clRPH

        -- Handle user name click.
        clUsername <- onSelectorClick doc "div.hdon_username a" -< world
        fire $ selUsernameDs (ds ^. dsreg) -< clUsername

        -- Handle fav.
        clFav <- onSelectorClick doc "div.hdon_favbox" -< world
        fire $ favByElem ds -< clFav

        -- Handle fav.
        clFav <- onSelectorClick doc "div.hdon_rebbox" -< world
        fire $ rebByElem ds -< clFav

        -- Handle placeholder substitution by the model.
        fire (\(placeId, sts, noLeft) -> replaceWithStatus doc sts placeId noLeft)
            <<< DataModel.onUpdateRange model
                -< world

        fire (\(placeId, ntfs, noLeft) -> replaceWithNotification doc ntfs placeId noLeft)
            <<< DataModel.onUpdateNRange model
                -< world

        -- Handle status update by the model
        fire (Content.replaceStatus doc)
            <<< DataModel.onUpdateStatus model
                -< world

    driveDsSub ds@(DSSSource dss) True = proc world ->
      do
        fire0 (runMaybeT $ setRPH ds) <<< onActivation -< world
        streamStatuses doc dss -< world

    driveDsSub ds@(DSNSource _) True = proc world ->
      do
        fire0 (runMaybeT $ setRPH ds) <<< onActivation -< world
        -- streamNotifications doc dsn -< world
        muted -< world

    driveDsSub ds False = proc world ->
      do
        muted -< world

    setRPH ds =
      do
        rphId <- MaybeT $ Content.pushRPH doc
        requireRangeById ds rphId

    requireRangeByElem ds elem =
      do
        pr <- MaybeT $ DOM.getParentNode elem
        rphId <- DOM.getId $ DOM.castToElement pr
        requireRangeById ds rphId

    requireRangeById ds rphId =
      do
        rph <- MaybeT $ Content.extractRPH doc rphId
        liftIO $ DataModel.requireRange model ds rph

    selUsernameDs reg elem = runMaybeT $
      do
        usernameDiv <- MaybeT $ DOM.getParentNode elem
        mainDiv <- MaybeT $ DOM.getParentNode usernameDiv
        statusDiv <- MaybeT $ DOM.getParentNode mainDiv

        domId <- DOM.getId (DOM.castToElement statusDiv)
        statusId <- MaybeT $ return $ domIdToStatusId domId

        liftIO $ DataModel.selUserDSByStatusId model reg statusId

    favByElem ds favboxElem = runMaybeT $
      do
        stInfoNode <- MaybeT $ DOM.getParentNode favboxElem
        stMainNode <- MaybeT $ DOM.getParentNode stInfoNode
        statusNode <- MaybeT $ DOM.getParentNode stMainNode
        domId <- DOM.getId $ DOM.castToElement statusNode
        stId <- MaybeT $ return $ domIdToStatusId domId
        liftIO $ DataModel.sendFav model (ds ^. hastodonClient) stId

    rebByElem ds rebboxElem = runMaybeT $
      do
        stInfoNode <- MaybeT $ DOM.getParentNode rebboxElem
        stMainNode <- MaybeT $ DOM.getParentNode stInfoNode
        statusNode <- MaybeT $ DOM.getParentNode stMainNode
        domId <- DOM.getId $ DOM.castToElement statusNode
        stId <- MaybeT $ return $ domIdToStatusId domId
        liftIO $ DataModel.sendReblog model (ds ^. hastodonClient) stId

    onSelectorClick doc selector =
        McWeb.onSelector doc
            (DOM.EventName "click" :: DOM.EventName DOM.Document DOM.MouseEvent)
            (selector :: BMText)
            (\self -> DOM.returnValue False >> return self)

isScrollTop :: DOM.Document -> IO Bool
isScrollTop doc = fmap (fromMaybe True) $ runMaybeT $
  do
    body <- MaybeT $ DOM.getBody doc
    pos <- DOM.getScrollTop body
    return $ pos == 0

runResourceWithMailbox ::
    ProcessT (ResourceT IO) (Event ()) (Event a) ->
    ProcessT IO TheWorld (Event a)
runResourceWithMailbox p = evolve $
  do
    box <- mailboxNew
    liftIO $ forkIO $ runResourceT $
      do
        runT_ (p >>> fire (liftIO . mailboxPost box)) (repeat ())
    wFinishWith $ onMailboxPost box

streamStatuses ::
    DOM.Document ->
    DataSource' DSSKind ->
    ProcessT IO TheWorld (Event Void)
streamStatuses doc dss = proc world ->
  do
    sts <- runResourceWithMailbox (DataModel.readDSS dss) -< world
    muted <<< fire (prependStatus doc) -< sts

streamNotifications ::
    DOM.Document ->
    DataSource' DSNKind ->
    ProcessT IO TheWorld (Event Void)
streamNotifications doc dsn = proc world ->
  do
    sts <- runResourceWithMailbox (DataModel.readDSN dsn) -< world
    muted <<< fire (prependNotification doc) -< sts

clearWebView doc = runMaybeT go >> return ()
  where
    go =
      do
        body <- MaybeT $ Content.getTimelineParent doc

        forever $ -- Until getFirstChild fails
          do
            ch <- MaybeT $ DOM.getFirstChild body
            DOM.removeChild body (Just ch)

checkExist :: DOM.Document -> BMText -> MaybeT IO ()
checkExist doc tId =
  do
    pre <- DOM.getElementById doc tId
    guard $ isNothing pre

prependStatus doc st = runMaybeT go >> return ()
  where
    go =
      do
        body <- MaybeT $ Content.getTimelineParent doc
        checkExist doc (statusIdToDomId $ Hdon.statusId st)

        -- Prepend
        ch <- MaybeT $ Content.domifyStatus doc st

        mfc <- lift $ DOM.getFirstChild body
        DOM.insertBefore body (Just ch) mfc

prependNotification = undefined

replaceWithStatus doc sts placeId del = fmap (const ()) $ runMaybeT $
  do
    body <- MaybeT $ Content.getTimelineParent doc
    frag <- MaybeT $ DOM.createDocumentFragment doc

    forM_ sts $ \st ->
      do
        checkExist doc (statusIdToDomId $ Hdon.statusId st)

        -- Prepend
        ch <- MaybeT $ Content.domifyStatus doc st
        DOM.appendChild frag (Just ch)
        return ()
      `mplus`
        return ()

    placeElem <- DOM.getElementById doc placeId
    DOM.insertBefore body (Just frag) placeElem

    if del then DOM.removeChild body placeElem >> return () else return ()

replaceWithNotification doc ntfs placeId del = fmap (const ()) $ runMaybeT $
  do
    body <- MaybeT $ Content.getTimelineParent doc
    frag <- MaybeT $ DOM.createDocumentFragment doc

    forM_ ntfs $ \st ->
      do
        checkExist doc (notificationIdToDomId $ Hdon.notificationId st)

        -- Prepend
        ch <- MaybeT $ Content.domifyNotification doc st
        DOM.appendChild frag (Just ch)
        return ()
      `mplus`
        return ()

    placeElem <- DOM.getElementById doc placeId
    DOM.insertBefore body (Just frag) placeElem

    if del then DOM.removeChild body placeElem >> return () else return ()

postToot form =
  do
    -- Get text
    let postText = form ^. MainForm.postText
    (beginPos, endPos) <- textBufferGetBounds postText
    content <- textBufferGetText postText beginPos endPos False

    runMaybeT $
      do
        -- Get destination
        postItr <- MaybeT $ comboBoxGetActiveIter $ form ^. MainForm.postDstCombo
        reg <- lift $ listStoreGetValue (form ^. MainForm.postDst) (listStoreIterToIndex postItr)

        -- Post it
        lift $ forkIO $
          do
            r <- Hdon.postStatusWithOption (reg ^. hastodonClient) Hdon.sensitive content
            print r
            return ()

        -- Clear text area
        lift $ textBufferDelete postText beginPos endPos

    return ()


