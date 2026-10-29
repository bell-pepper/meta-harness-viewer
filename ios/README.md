# Harness HUD — Files-based iPhone companion

This is the selected simpler path: choose PDFs or folders with Apple's Files picker on the iPhone, then browse folders/documents and read pages on Meta Ray-Ban Display through Meta's native Display SDK. No app-specific Google OAuth project, shared Drive folder, or private backend is required for this workflow. Google Drive must already be installed/signed in and available as a Files provider.

The existing icon-launched web app remains unchanged. This native companion starts from the phone; an icon that launches this native experience on the glasses has not been verified. Installing a web app is a different mechanism.

## Storage and access behavior

- The app saves only security-scoped location bookmarks, display names, and small location metadata in `Application Support/HarnessLocations.json`.
- It does not copy selected PDFs into app-managed storage. Selecting a PDF does not parse it; opening it for reading coordinates provider access and lets PDFKit read it.
- Google Drive/Files may download an entire selected PDF and retain a local cache. We cannot promise zero local storage or force another provider to delete its cache. Local phone PDFs work through the same picker.
- One 600×600 raster is retained for the current phone preview and sent to the glasses. No PDF bytes are sent to the glasses. Rendering buffers are temporary, and page images are not saved to disk by this app.
- Disconnect stops the display session and releases our preview. This does not clear Google's or iOS's cache.
- Swipe a saved location to forget its bookmark. This does not delete or modify the source file or folder.
- Existing imported copies from the older prototype, if any, are not automatically deleted or migrated. Their old `Application Support/HarnessPDFs` directory is no longer used; do not mistake those legacy copies for newly created files.

## Folder navigation

On the phone choose **Choose PDFs from Files / Drive** or **Choose a folder**, then **Browse on glasses**. Selected locations form the first menu. Folders have a `Folder:` label. Select one to list its immediate subfolders and PDFs, three entries per page. Use **More**, **Previous**, **Up**, and **Refresh**. Refresh re-reads the selected provider directory; it is not a background cloud sync.

File providers do not all offer folder selection, persistent folder permissions, or recursive descendant access. **Google Drive folder support and bookmark persistence must be tested on your iPhone.** If selecting a folder is unavailable or access fails, select individual PDFs instead. An expired/unavailable location may need to be selected again in the picker. A stale bookmark may resolve to a moved location, but automatic bookmark renewal is not implemented; reselect when necessary.

The app does not enumerate your whole Google Drive account, use pasted URLs, authenticate to Google directly, or bypass provider permissions. Google Docs must be exported to PDFs outside the app. External symlink entries are omitted from folder lists.

## Reading and controls

Selecting a PDF opens its current provider content, checks page count, and renders pages on a worker task using PDFKit. Source page geometry/rotation is respected. The raster is inverted for bright content on the additive display; verify color-coded technical data on the real device.

The native reading view sends a page image without app headings, borders, or persistent control buttons. Select/tap the view to request controls. Controls include Previous/Next, Zoom/Next section, Fit page, Documents, and Read. Actions return to the image-only view. Documents returns to the folder/menu page from which the document was opened.

Zoom is 2× fit with four corner sections, not arbitrary pan. Very small print may still need a larger zoom feature later. Meta's host may add its own focus/system UI; verify actual appearance and selection behavior on the glasses. Raw gesture streams are not used; navigation relies on Meta's supported Display button/tap callbacks. The phone also has reading controls as a fallback.

## Validation status

**Source implementation only: not built with Xcode or tested on physical glasses.** This Linux workspace cannot compile PDFKit, SwiftUI, or the Meta iOS frameworks. Folder-provider behavior, security-scoped bookmark restoration, native image-only selection, background/locked-phone operation, and PDF readability are pending Mac/iPhone/glasses tests. Existing successful web-app tests do not validate this native companion.

## Open on your Mac

Use Xcode 26.4 or later / Swift 6.3 (the upstream sample requirements), and an iPhone running iOS 17.2 or newer.

```sh
git clone https://github.com/bell-pepper/meta-harness-viewer.git
cd meta-harness-viewer
open ios/DisplayAccess.xcodeproj
```

For an existing checkout, pull `main` without overwriting local work instead of cloning again.

1. Let Xcode resolve Meta SDK **1.0.1**, pinned exactly in the project.
2. Select target **DisplayAccess → Signing & Capabilities**. Choose your Apple development team and a unique bundle identifier. Enable automatic signing. The installed app is named **Harness HUD**.
3. Connect/unlock your iPhone, trust the Mac, and enable iPhone Developer Mode if Xcode requests it. Select the iPhone and press **Cmd+R**.
4. Complete Meta's native developer setup and app registration through Meta AI. This is separate from adding the existing web app and separate from iPhone Developer Mode. If the Meta Developer Mode setting is missing, resolve that with Meta's current developer guidance; no hidden tap sequence is assumed here.
5. Approve Bluetooth/local-network access. First try Meta's retained **Samples → Car maintenance guide → Try it** to verify the native display connection. Resolve firmware or glasses-app update requirements in Settings.
6. In **PDF Library**, choose files/folders, then **Browse on glasses**.

App signing and Meta native device access remain prerequisites. No Google OAuth or hosting credentials are needed for this Files-based companion. Google Drive account restrictions may still prevent file-provider access.

## Enable Google Drive in Files

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
2. Select a local folder with at least four PDFs and a subfolder. Check folder/document labels, More/Previous, Up, Refresh, and returning to the correct folder from reading.
3. Repeat with Google Drive. If folder grants fail, verify individual PDF selection works and the error explains reselecting on the phone.
4. Force quit/reopen and use the saved references. Rename/move/delete a source and test refresh/reselection. Changing source content should be visible after reopening it; there is no app-managed PDF snapshot.
5. Choose a locked/damaged PDF or a non-PDF renamed to `.pdf`. Confirm a useful error on phone and glasses, with a route back to Locations.
6. Read a page and select it to show controls. Confirm Read/Next/Zoom returns to an image-only view and Documents returns to the originating folder. Check whether Meta's host adds system UI.
7. Forget a location and confirm the original remains in Files/Drive. Confirm no new PDF copies or raster files appear in app-managed storage; only bookmark metadata is written by this implementation.
8. Test slow downloads, offline cached files versus uncached files, disconnected glasses, locked phone/background suspension, and relaunch. Provider downloads cannot be cancelled by this prototype and there is no background-readiness guarantee.

Do not use sample pinouts as approved engineering instructions. Review source revision, content, color handling, and legibility before field use.

## Attribution

Native registration, session management, sample assets and project configuration are adapted from Meta's DisplayAccess sample at `bbae597cd1c748cd29b9375a1624a8d75b1c9e14`, SDK 1.0.1. Original headers are preserved; see `META-LICENSE` and `META-NOTICE`.

- https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/DisplayAccess
- https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md
- https://wearables.developer.meta.com/docs/develop/
