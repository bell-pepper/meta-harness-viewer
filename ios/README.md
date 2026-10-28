# Harness HUD — native iPhone companion prototype

This is an optional native companion path to Meta Ray-Ban Display. A separate official on-glasses Web Apps platform has now been identified and is the preferred path to test for the glasses app-grid icon requirement; see [the corrected architecture review](../docs/SYSTEM-ARCHITECTURE.md). An iPhone Home Screen shortcut is separate from Meta Web Apps registration.

## Current implementation and validation status

- Import one or more unlocked PDFs using Apple's document picker, copy them into private app storage, and retain them across launches.
- Google Drive is available through the picker only if its iOS Files provider is installed, signed in, and enabled. Import downloads a local copy; it does not sync a Drive folder.
- Send a paginated list of saved document names to the glasses, three names per menu.
- Render PDFs using PDFKit on a worker task, send page images using MWDATDisplay, and offer Previous, Next, Zoom, Next section, Fit page, and Documents buttons.
- Zoom cycles through four corners at 2× fit scale. It is not continuous pan/zoom. Very small print may still be unreadable.
- Show the last rendered image and page controls on the phone. Phone rendering can work even if glasses connection fails; inspect the connection error separately.
- Retain Meta's original Samples and Settings screens for connection troubleshooting and sample simulator previews.

**Not yet built with Xcode or tested on glasses.** The cloud workspace is Linux and cannot compile Apple's frameworks. Device access, image sizing in the real display layout, input behavior, background operation, and PDF legibility remain acceptance checks. No claim of production readiness is made.

Direct Google Drive sign-in, live folder browsing, automatic sync, Google Docs export, and speech control are not implemented. V1 here is PDF import plus glasses selection. PDFs never need public sharing.

## Open on your Mac

Install Xcode 26.4 or later (the upstream sample requires Swift 6.3) and complete first launch. Use an iPhone running iOS 17.2 or newer.

```sh
git clone https://github.com/bell-pepper/meta-harness-viewer.git
cd meta-harness-viewer
open ios/DisplayAccess.xcodeproj
```

If you already cloned this repository, pull main in that checkout instead of cloning over existing files.

1. Let Xcode resolve Meta SDK **1.0.1**, pinned exactly in the project.
2. Select the **DisplayAccess** target, then **Signing & Capabilities**. Select your Apple development team and change `com.bellpepper.HarnessHUD` to a bundle identifier unique to you. Enable automatic signing. The installed app is named **Harness HUD**.
3. Connect and unlock your iPhone, trust the Mac, and enable **iPhone Developer Mode** if Xcode requests it. This is separate from Meta glasses Developer Mode.
4. Select the iPhone as the run destination and press **Cmd+R**.
5. Update Meta AI and the glasses firmware as needed. Enable Meta's **glasses Developer Mode**, which the upstream documentation places under Meta AI → Settings → your glasses → Developer Mode. If absent, this remains a prerequisite: check Meta's current developer setup/support guidance; do not guess hidden tap sequences or change unrelated settings.
6. In the app, use registration/Settings to connect through Meta AI and approve the requested connection. Allow Bluetooth and local-network access. The Developer Mode configuration intentionally has no Meta app ID or client token. Other release channels require your own Wearables Developer Center setup.
7. First use **Samples → Car maintenance guide → Try it**. Confirm it appears on the glasses and its buttons advance the tutorial. Resolve any firmware or glasses-app update prompt in Settings before testing PDFs.
8. Return to **PDF Library** and import a PDF. Tap **Show document menu on glasses**. Select the document on the glasses, then use its native controls.

The upstream project/target name stays DisplayAccess to keep the sample's build setup intact. No Google credentials or Apple signing credentials are included in this repository. Apple account signing availability and Meta device access must be verified on your Mac and phone.

## Google Drive import on the phone

Install Google Drive, sign in, then open Apple's Files app → Browse → menu → Edit and enable Drive if it is offered. In Harness HUD, tap **Import PDFs from Files / Google Drive**, browse to the desired folder, and select PDFs. If the provider is unavailable, download a PDF into Files first and import that local file. Google Docs documents must first be exported as PDFs.

Copies remain until deleted in this app or the app is uninstalled. Swipe a library row to delete its copy. This does not delete the original in Drive. Reimport after changing a source PDF; duplicates are allowed. Imported files use iOS app storage and its normal backup behavior.

## Mac build check

From the repository root:

```sh
xcodebuild -resolvePackageDependencies -project ios/DisplayAccess.xcodeproj -scheme DisplayAccess
xcodebuild -project ios/DisplayAccess.xcodeproj -scheme DisplayAccess \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/HarnessHUD-DerivedData CODE_SIGNING_ALLOWED=NO build
```

A simulator build checks compilation but does not validate the physical glasses. The original **Samples → Developer preview → In app** feature previews Meta's tutorial using MockDeviceKit; the custom PDF library is not wired to that preview surface yet.

## Device acceptance checklist

1. Import the included `fixtures/two-page-check.pdf` through Files. Verify both page labels and the four corner labels in zoom mode.
2. Import a real portrait datasheet, a landscape PDF, and a rotated PDF. Verify page orientation, no stretched text, readable enlarged corners, and all display controls visible.
3. Test first/last page boundaries, four zoom sections, Fit page, and Documents returning to the library.
4. Import at least four PDFs; verify More and Previous in the document menu and correct selection.
5. Force quit and reopen: imported filenames and files must remain. Delete a copy and reopen: it must stay deleted; Drive's original must remain.
6. Try a locked PDF and a non-PDF renamed to `.pdf`: show a useful import error rather than adding an unusable file.
7. Test with glasses disconnected and registration revoked: errors should be visible; reconnect through Settings. Test phone locking/background behavior on the actual device; do not assume live display continues.

Do not use the prototype as an approved engineering instruction source until the displayed data and readability have been reviewed on the target device.

## Upstream attribution and references

Connection lifecycle, registration, settings, tutorial assets, and project configuration are adapted from Meta's official DisplayAccess sample at commit `bbae597cd1c748cd29b9375a1624a8d75b1c9e14` (SDK 1.0.1). Original headers are retained. See `META-LICENSE` and `META-NOTICE`; use of the toolkit is subject to Meta's developer terms.

- https://github.com/facebook/meta-wearables-dat-ios/tree/main/samples/DisplayAccess
- https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md
- https://wearables.developer.meta.com/docs/develop/

This implementation uses Display buttons and their callbacks. It does not depend on the separate experimental raw Inputs capability or map browser keyboard events to glasses controls.
