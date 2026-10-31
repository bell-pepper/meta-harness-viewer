# Direct Google Drive on iPhone

Harness HUD now has a native Google connection, separate from Apple's Files picker and the optional web backend. Sign in on the phone, choose folders once, then browse their subfolders/PDFs on the glasses using the existing gesture viewer. The Google Drive app does not need to be installed or enabled in Files for this route.

**Implementation and isolated API/model tests are complete; live Google authorization and the iOS build/device flow have not been tested here.** Google OAuth is not configured in this checkout. Until configured, the phone shows **Google setup required**, identifies missing/invalid client settings or a mismatched callback scheme, and offers a one-time setup checklist with the installed bundle identifier. This does not affect local Files or Meta registration.

## Configure Google once for the app

1. In your Google Cloud project, enable **Google Drive API**.
2. Configure Google Auth Platform branding, audience and contact details. For an external app in testing, add your Google account as a test user.
3. Add `https://www.googleapis.com/auth/drive.readonly` to the requested scopes. This grants read-only access across the account, not just the folders selected in Harness HUD. The app's selected-folder restriction is narrower than the Google permission. `drive.file` is not substituted: it does not support browsing arbitrary existing Drive folders in this workflow.
4. Create an OAuth client of type **iOS**, using the exact bundle identifier you sign in Xcode (**DisplayAccess → Signing & Capabilities**; the committed default is `com.bellpepper.HarnessHUD`). Follow Google's current iOS client requirements. Do not use the web backend's Web application client.
5. From the repository root, copy the configuration example:

   ```sh
   cp ios/GoogleDrive.local.xcconfig.example ios/GoogleDrive.local.xcconfig
   ```

6. Edit the local file to set your full iOS client ID and its reversed URL scheme. For example, a client ID `1234567890-abcdef.apps.googleusercontent.com` has reversed scheme `com.googleusercontent.apps.1234567890-abcdef`.

   ```xcconfig
   GOOGLE_IOS_CLIENT_ID = YOUR_FULL_CLIENT_ID.apps.googleusercontent.com
   GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.YOUR_FULL_CLIENT_ID
   ```

   Use the actual values from your iOS client. They are public identifiers; **no client secret, access token or refresh token belongs in this file**. The local file is ignored by Git. The checked-in `GoogleDrive.xcconfig` includes it optionally for both Debug and Release. `Info.plist` uses these settings for `GIDClientID` and the Google callback URL scheme. The existing `harnesshud` Meta callback is preserved.

7. Open `ios/DisplayAccess.xcodeproj`, resolve packages, and build/install. The app pins official **GoogleSignIn-iOS 9.2.0**, with `GoogleSignIn` and `GoogleSignInSwift` products. No Firebase project, server client secret, or hosted backend is required by this implementation.

`drive.readonly` is a restricted Google scope. Wider external distribution can require verification and other Google policy steps; testing-mode authorization can expire. Check current Google requirements before rollout. Meta's experimental Inputs release restrictions are separate from Google authorization.

## Use it

1. In **Library**, open the **Google Drive** card and tap **Sign in with Google** and allow read-only Drive access.
2. In Google Drive management, tap **Choose a Google Drive folder**, or use the Library’s **+ → Google Drive folder**. Browse My Drive's folders on the phone and tap **Use folder: …**. Repeat to save more folders. Selecting My Drive itself is also supported.
3. Keep the app active and connect registered glasses. The last saved folder reopens automatically; Back returns to all saved locations for that Google account and local Files. If the display is already connected, saving/removing a location refreshes its menu. Tap the glasses card, then **Open library on glasses**, after errors or a manual stop.
4. On the glasses, navigate/select folders and PDFs. Select cycles fit → 2× → 3× → fit; navigation changes pages at fit and pans at zoom; drag moves the zoomed page; Back returns to fit, then documents. No glasses viewer buttons are added.
5. Use **Reconnect / switch Google account** if authorization expires or you want another account. Saved Drive folders are bound to the account that selected them; another account does not inherit them. Disconnect/switch first stops the display and releases the current PDF/preview.
6. **Disconnect Google Drive** signs out locally and attempts Google-side revocation. If revocation cannot be confirmed, remove the connection in your Google Account settings. Saved folder IDs remain for reconnecting the same account but are hidden while signed out or using another account. Swipe an available saved location to forget it; this never deletes its source folder.

## Data and limitations

- Google Sign-In manages its persisted authorization using the SDK's platform storage. The app does not write Google tokens into folder metadata, logs, page URLs or the repository. Tokens are used only on the phone; glasses receive a raster image and UI text.
- `Application Support/HarnessLocations.json` stores folder/account IDs and names for direct Drive locations, plus the existing bookmarks for Files locations. Existing bookmark-only metadata remains readable.
- The app downloads one current PDF into phone memory, capped at **25 MiB** and **1000 pages**. It does not create a permanent PDF copy or disk page cache. Leaving the document, opening another one, releasing the preview, or disconnecting Drive releases this retained PDF. The OS still manages process memory; this is not a secure-memory-erasure guarantee.
- Metadata, download permission, the saved root and every intermediate ancestor are checked when listing/opening. Permissions are not continuously polled while reading the already-open PDF. Reopen a document to get current contents; there is no offline library or background synchronization.
- Folder listing follows pagination, with a 10,000-entry limit. Moving focus uses the loaded list; entering/reopening a folder fetches it again. Moved/deleted/revoked items produce an error with Back to return to saved locations.
- The phone chooser currently starts at **My Drive**. Dedicated Shared with me/shared-drive discovery, Drive shortcuts, Google Docs export, OCR and annotations are not implemented. Use Files as an alternative for sources available there.
- Direct API traffic uses HTTPS with default TLS verification, an ephemeral non-caching URL session, bounded streaming downloads and no redirects. A download that requires a redirect currently fails rather than forwarding authorization to another host.
- Phone suspension, lock/termination, Google consent, SDK token restoration and physical gestures still require device testing. Automatic operation from a terminated iOS app is not promised.

## Validation

The Foundation-only API and document models are built from the same source files used by the iOS target:

```sh
swift test --package-path ios/DriveCore
```

23 tests pass on Swift 6.0.3/Linux: pagination/filtering, query/path validation, repeated cursors, incomplete results, nested-folder membership, moved/deleted/restricted PDFs, download limits, response validation, HTTP errors, stable references, old Files metadata compatibility, saved-folder restoration and Google client/callback configuration. These tests use simulated Drive responses, not a live Google account.

From the repository root on a Mac:

```sh
xcodebuild -resolvePackageDependencies -project ios/DisplayAccess.xcodeproj -scheme DisplayAccess
xcodebuild -project ios/DisplayAccess.xcodeproj -scheme DisplayAccess \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/HarnessHUD-DerivedData CODE_SIGNING_ALLOWED=NO build
```

Then test on the iPhone/glasses: consent/cancellation/denial; multiple folders and more than one list page; nested PDFs; cold app relaunch and account restore; switch accounts; revoke Google authorization; move/delete/change a PDF; oversize/locked PDFs; disconnect/reconnect; full-screen zoom/pan/pages; lock/background behavior. Verify that disconnect clears glasses content and the phone preview, and that no new PDFs/page images are written to app storage.

## Official references

- [Google Sign-In iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google Sign-In iOS SDK 9.2.0](https://github.com/google/GoogleSignIn-iOS/tree/9.2.0), inspected at `08d8dcecafb575f98879ffdbb8302c1b9ad65d19` for sign-in, URL handling, restore, refresh and disconnect APIs
- [Drive authorization scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [Search for files and folders](https://developers.google.com/workspace/drive/api/guides/search-files)
- [Download files](https://developers.google.com/workspace/drive/api/guides/manage-downloads)
