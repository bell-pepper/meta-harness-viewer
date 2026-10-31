# Harness HUD — iPhone companion

The native app supports **direct Google sign-in and Drive folder selection**, plus local/provider PDFs and folders through Apple's Files picker. Both feed the same full-screen, gesture-controlled viewer on Meta Ray-Ban Display. Select folders once on the phone; saved locations appear when glasses connect with the app active.

**For direct Google Drive, start with [Google Drive setup](GOOGLE-DRIVE.md).** It requires an iOS OAuth client in your Google Cloud project, but no backend or Google Drive app installation. This route does not depend on Drive appearing in Apple's picker. Direct authorization and the new iOS build still need Mac/iPhone validation.
The existing icon-launched web app remains unchanged. This native companion starts from the phone; an icon that launches this native experience on the glasses has not been verified. Installing a web app is a different mechanism.

## Phone interface

The Library uses the approved dark navy and mint design: a branded header, live glasses connection card, Google Drive management card, saved locations, and a current-document preview. Counts, connection labels and page details use actual app state; there are no sample documents or invented sync/battery indicators in the interface.

- Tap **Google Drive → Connect / Manage** to sign in, choose folders, switch accounts or disconnect.
- The **+** menu adds a Drive folder, Files PDFs or a Files folder. **Add from Files** opens the Files choices directly.
- Tap a saved location to open it on glasses. **Edit** reveals forget controls; touch-and-hold also offers Forget location. Originals are never deleted.
- **Reading now** appears only with a real rendered page. Tap it for a larger phone preview, Previous/Next and Show on glasses. These phone controls do not add buttons to the glasses viewer.
- Tap the glasses card for Open library, Disconnect display, connection settings and gesture diagnostics. When Inputs activation fails, the library shows the error and does not claim readiness.

The layout scrolls on smaller phones and uses native menus, sheets, tabs, accessibility labels and scalable text. The iOS build, small-screen layouts, large Dynamic Type, VoiceOver, sheet navigation and real connection/reading states still need an Xcode/device check. Linux syntax/project checks do not validate SwiftUI rendering.

## Storage and access behavior

- The app saves Files bookmarks or direct Drive account/folder IDs and names in `Application Support/HarnessLocations.json`. Google Sign-In manages authorization separately; tokens are not written into this metadata.
- Files PDFs are opened through coordinated provider access. Direct Drive PDFs are downloaded into memory only while the current document is open, with a 25 MiB / 1000-page limit. No permanent PDF copies or page images are saved.
- Google Drive/Files may download an entire selected PDF and retain a local cache. We cannot promise zero local storage or force another provider to delete its cache. Local phone PDFs work through the same picker.
- One 600×600 raster is retained for the current phone preview and sent to the glasses. No PDF bytes are sent to the glasses. Rendering buffers are temporary, and page images are not saved to disk by this app.
- Disconnect stops the display session and releases our preview. This does not clear Google's or iOS's cache.
- Swipe a saved location to forget its bookmark. This does not delete or modify the source file or folder.
- Existing imported copies from the older prototype, if any, are not automatically deleted or migrated. Their old `Application Support/HarnessPDFs` directory is no longer used; do not mistake those legacy copies for newly created files.

## Folder navigation

Choose folders or PDFs once on the phone. With the Library tab active, connecting glasses or returning to the foreground opens the last remembered available folder (or a single saved folder from older builds). Multiple locations remain available by going Back to the saved-locations screen. Tap the glasses card, then Open library on glasses, after an error or manual stop.

The glasses list uses native card backgrounds, clean folder/document symbols and a caret on the selected row. Up/Down moves between entries, scrolling through groups of three. Select or Right opens the entry. Left goes up one folder; at saved locations it remains at the root. The physical middle-finger Back gesture exits on current hardware. Reopening a folder re-reads its provider contents. With no saved locations, the app sends a Harness HUD welcome screen asking you to choose a folder on the phone; it no longer skips display startup and leaves previous content visible. Saved Drive folders while signed out prompt for reconnection rather than reselection.

Providers differ in folder selection, persistent bookmark permissions, and descendant access. Test Google Drive folder support on your iPhone; individual PDFs remain the fallback. Expired references require reselection. Files/Drive may download/cache PDFs; no app-managed PDF copy is made.

## Gesture reading controls

Reading remains full-screen and image-only, without tap handlers or viewer buttons:

| Input event | Fit view | Zoomed view |
| --- | --- | --- |
| Select | Zoom to 2× | 2× → 3× → fit |
| Left / Right | Previous / next page | Pan toward left / right |
| Up | Return to documents | Pan toward top |
| Down | No action | Pan toward bottom |
| Drag move | No action | Move the page using reported deltas |
| Semantic Back (mock / future hardware support) | Return to documents | Return to fit |

Zoom changes and page turns reset pan. Pan stops at page edges; axes that fit remain centered. Middle-finger Back currently exits on real glasses; see the hardware limitation below. Cycle Select to fit before changing pages while zoomed. Phone Previous/Next remain available as a fallback. Gesture-only return uses Up at fit and Left in folders, avoiding the hardware Back gesture. These are semantic navigation events; verify the corresponding physical inputs on the device.

This uses **experimental MWDATInputs**, included in pinned SDK 1.0.1. Enable Inputs for this app in Wearables Developer Center; it is not an iOS runtime permission. The phone shows activation state and errors. Only captouch, neuralBand, and neuralBandDrag sources are requested; hardware capture/action buttons are not mapped.

Inputs attaches after DeviceSession starts, and is removed on stop/teardown or when switching to Meta's retained sample. It currently supports development/beta, not production release channels. Actual physical gesture mappings, drag units/orientation/sensitivity, event latency, and interaction with the display must be tested on hardware. The SDK provides semantic events; it does not establish a universal physical gesture mapping. Drag rendering currently processes events serially and may lag during rapid movement.

## Validation status

**The user confirms the earlier native app builds, registers with Meta, and displays documents on real glasses.** Direct Google Drive, automatic library presentation and the revised zoom/pan controls are new changes and still need an Xcode build and device validation. This Linux workspace cannot compile PDFKit, SwiftUI, or the Meta iOS frameworks. Folder-provider behavior, security-scoped bookmark restoration, native image-only selection, background/locked-phone operation, and PDF readability are pending Mac/iPhone/glasses tests. Existing successful web-app tests do not validate this native companion.

## Open on your Mac

Use Xcode 26.4 or later / Swift 6.3 (the upstream sample requirements), and an iPhone running iOS 17.2 or newer.

```sh
git clone https://github.com/bell-pepper/meta-harness-viewer.git
cd meta-harness-viewer
open ios/DisplayAccess.xcodeproj
```

For an existing checkout, pull `main` without overwriting local work instead of cloning again.

1. Let Xcode resolve Meta SDK **1.0.1** and Google Sign-In **9.2.0**, pinned exactly in the project. For direct Drive, configure [the Google iOS client](GOOGLE-DRIVE.md) first.
2. Select target **DisplayAccess → Signing & Capabilities**. Choose your Apple development team and a unique bundle identifier. Enable automatic signing. The installed app is named **Harness HUD**.
3. Connect/unlock your iPhone, trust the Mac, and enable iPhone Developer Mode if Xcode requests it. Select the iPhone and press **Cmd+R**.
4. Complete Meta's native developer setup and app registration through Meta AI. This is separate from adding the existing web app and separate from iPhone Developer Mode. If the Meta Developer Mode setting is missing, resolve that with Meta's current developer guidance; no hidden tap sequence is assumed here.
5. Approve Bluetooth/local-network access. First try Meta's retained **Samples → Car maintenance guide → Try it** to verify the native display connection. Resolve firmware or glasses-app update requirements in Settings.
6. In **Library**, connect Google and choose Drive folders, or choose Files locations once. Saved locations open automatically when a registered physical display connects while the app is active (and when returning to the foreground). Tap the glasses card, then **Open library on glasses**, after a stopped session or error.

App signing and Meta native device access remain prerequisites. Local Files needs no Google configuration. Direct Drive requires the iOS client settings in [GOOGLE-DRIVE.md](GOOGLE-DRIVE.md). Google account restrictions can still prevent either route.

## Optional Google Drive provider in Files

Install Google Drive and sign in on the phone. In Apple's Files app, go to Browse, open the menu, choose Edit, and enable Drive if offered. Verify you can open a PDF there first. Use the same provider in Harness HUD's picker. If that provider offers only file selection, choose the desired PDFs individually; do not change their sharing to public.

## Mac build check

From the repository root:

```sh
xcodebuild -resolvePackageDependencies -project ios/DisplayAccess.xcodeproj -scheme DisplayAccess
xcodebuild -project ios/DisplayAccess.xcodeproj -scheme DisplayAccess \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/HarnessHUD-DerivedData CODE_SIGNING_ALLOWED=NO build
```

A simulator build checks compilation, not Drive provider or physical-glasses behavior. The original Samples → Developer preview → In app screen previews Meta's tutorial; the new file browser is not wired to that mock surface.

## Device acceptance checklist

1. Choose the included `fixtures/two-page-check.pdf` from Files. Verify both pages and all four corner labels. Check portrait, landscape, and rotated PDFs.
2. Select a local folder with at least four PDFs and a subfolder. Check gesture navigation across list pages, Left to go up, reopening to refresh, and returning to the originating folder.
3. Follow the direct Google Drive acceptance checks in [GOOGLE-DRIVE.md](GOOGLE-DRIVE.md). For the optional Files provider, verify individual PDFs if folder grants fail.
4. Force quit/reopen and use the saved references. Rename/move/delete a source and test refresh/reselection. Changing source content should be visible after reopening it; there is no app-managed PDF snapshot.
5. Choose a locked/damaged PDF or a non-PDF renamed to `.pdf`. Confirm a useful error on phone and glasses, with a route back to Locations.
6. Verify the gesture table above; confirm the page remains image-only throughout and Up at fit returns to the originating folder.
7. Forget a location and confirm the original remains in Files/Drive. Confirm no new PDF copies or raster files appear in app-managed storage; only location metadata is written by this implementation (Google Sign-In manages its own authorization storage).
8. Test slow downloads, offline cached files versus uncached files, disconnected glasses, locked phone/background suspension, and relaunch. Provider downloads cannot be cancelled by this prototype and there is no background-readiness guarantee.

Do not use sample pinouts as approved engineering instructions. Review source revision, content, color handling, and legibility before field use.

## Attribution

Native registration, session management, sample assets and project configuration are adapted from Meta's DisplayAccess sample at `bbae597cd1c748cd29b9375a1624a8d75b1c9e14`, SDK 1.0.1. Original headers are preserved; see `META-LICENSE` and `META-NOTICE`.

- https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/DisplayAccess
- https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md
- https://wearables.developer.meta.com/docs/develop/

## Input API evidence for this revision

Verified directly against the public Swift interface in Meta SDK tag `1.0.1`, commit `0bd369298eef6a980ad0bdb6c8a5502f2c02a08c`: `MWDATInputs.xcframework/ios-arm64/MWDATInputs.framework/Modules/MWDATInputs.swiftmodule/arm64-apple-ios.swiftinterface`. It defines `InputEvent`, `NavDirection`, `DragAction`, `InputsConfiguration`, `DeviceSession.addInputs(configuration:)`, and `removeInputs()`.

[Meta Inputs guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/inputs/SKILL.md).

Retest on Mac/iPhone/glasses: build with Inputs linked; verify active state or an actionable denial; choose saved folders after relaunch/reconnect; navigate more than three entries and nested folders; test each gesture at fit/2×/3×, all edges and page boundaries, drag orientation, repeated Select (one zoom step per event), Back, interruptions, and reconnect. Test suspended/locked/terminated phone states separately; automatic launch there is not promised.

## Hardware Back limitation (SDK 1.0.x)

The user's hardware trace receives Neural Band Select/Drag and then ends the display session with no Back event. A matching [public Meta issue and response](https://github.com/meta/meta-wearables-dat-ios/issues/349#issuecomment-6300429308) reports that real glasses in SDK 1.0.0/1.0.1 handle Back by closing the app; `consumeBack` only affects MockDeviceKit. The latest public tag checked during diagnosis is still 1.0.1. Changing registration, source filters or attachment order is not a verified remedy.

The production DeviceSession bridge explicitly calls Meta's `addInputs` / `removeInputs`, with Inputs added before Display and `consumeBack: true`. Keep semantic `.back` handling for MockDeviceKit and future hardware support, but do not promise that it intercepts the middle-finger/thumb gesture on current glasses. Do not infer a Back event from arbitrary session termination or automatically reopen the app after every shutdown.

On the phone, the glasses card → Gesture input shows a bounded event history and current state. **Gestures not attached** after **Display ended** describes teardown, not proof that gesture activation failed initially. **Restart gesture input** can retry an inactive capability while the session is running; it cannot override the system Back gesture.

Core validation has 23 passing tests, including remembered-folder restoration and missing/mismatched Google settings. Physical gestures still require device testing; successful mock Back handling does not establish hardware support.

The gesture-only fallback maps **Up while reading at fit** to the containing folder, **Left in a folder list** to its parent, and **Up/Down** to focus movement. **Select or Right** opens the focused entry. Directions still pan while zoomed; cycle Select to fit before using Up to leave the document. The native `.back` handler is retained for mocks/future SDKs, but middle-finger Back remains system exit on current hardware.
