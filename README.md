# Harness HUD

An icon-launchable web-app prototype for Meta Ray-Ban Display. Includes Pinouts, Quick Reference, example assembly steps, and an internal two-page datasheet viewer. The user has confirmed launcher installation and full-screen demo reading on the glasses. Private Drive integration is implemented and locally tested; live Google login and deployment/device validation remain outstanding.

- **App:** https://bell-pepper.github.io/meta-harness-viewer/
- **Phone setup / installation QR:** https://bell-pepper.github.io/meta-harness-viewer/install.html

## Add to glasses

Open the installation page on your phone and tap **Add with Meta AI**, or scan its QR code from a computer. The link uses the installation scheme in Meta's official examples. Follow the Meta AI prompts and confirm on the glasses if requested.

Manual path documented by Meta: **Meta AI → Devices → Display Glasses settings → App connections → Web apps → Add a web app**. Enter **Harness HUD** and the app URL above. Menu names and developer-access requirements depend on the installed Meta software. If Web apps is unavailable, check updates and Meta's developer setup guidance. No hidden tap sequence is assumed here.

Look for Harness HUD in the glasses app grid. This is a web-app registration path, not APK sideloading or an iPhone Home Screen shortcut. Native iPhone development is not required to try this milestone.

## First device test

1. Launch the app from its glasses icon. Verify arrows/selection work on the main menu.
2. Choose **Documents → Harness test datasheet**. The example opens inside the app; no URL entry or external Google viewer is involved.
3. The document opens full screen with all app borders, headers, and controls hidden. Press **Enter / Select** (or tap the page) to show controls. Try both pages; page controls disable at the beginning/end.
4. Select **Zoom 2×** or **Zoom 3×**. Controls hide automatically; arrows or touch dragging move the enlarged page, stopping at its edges. **Enter / Select** shows controls again. **Read full screen** hides them.
5. **Fit page** returns to the full-page view and hides controls. While reading at fit size, Left/Right changes pages. Back from reading returns to the library; Back with controls open dismisses them first. The **Documents** action returns directly to the library.
6. Report any installation errors, clipped controls, unreadable labels, or unsupported input. Check phone locking and connection interruption separately; offline or phone-free operation is not promised.

## Viewer scope

The bundled [PDF](assets/demo/harness-test.pdf) is pre-rendered to two high-contrast PNG page images. This keeps the glasses runtime small and avoids loading a PDF engine for the initial hardware test. Images preserve the source page's layout; raster colors are inverted for white content on a black additive-display background. Fit page gives an overview; zoom is needed to read small text.

The public demo remains available. A separate private Drive service now supports per-user Google authorization, folder selection, glasses pairing, and on-demand PDF page rendering. It must be deployed and configured before the public app can connect Google accounts. Google Docs export, recursive subfolders, and offline reading are not implemented. Do not commit private engineering data to this public site.

All pinouts and assembly instructions are examples. Use approved engineering data and acceptance criteria for actual harness work.

## Document catalog foundation

The viewer now reads `assets/documents.json` instead of assuming one two-page document. Entries have an ID, title, optional revision, and a nonempty list of prepared page-image URLs. Paths resolve relative to that catalog. Different documents may have different page counts. Documents offers Refresh and handles empty libraries and connection failures.

This catalog is public on GitHub Pages. It is not a Google Drive connection, and it must not contain credentials or private document links. When paired to the configured private service, the viewer uses an authenticated per-user Drive library instead of this public catalog. Keep Drive sharing settings private; no single shared folder is hard-coded.

The additional browser test `tests/library.cjs` checks multiple documents, variable page counts, title escaping, empty libraries, failed refreshes, and invalid page addresses. Run it using the same Playwright setup as `tests/webapp.cjs`.

## Current direction: native iPhone companion

The [native companion](ios/README.md) supports direct Google sign-in, phone-side Drive folder selection and the same full-screen gesture viewer as local Files locations. Select folders once; saved locations appear when registered glasses connect with the app active. Direct Drive avoids reliance on Apple's Google Drive Files provider and requires no hosted backend. It does require a Google iOS OAuth client: see [Google Drive setup](ios/GOOGLE-DRIVE.md).

The user confirms the earlier native app builds, registers with Meta and displays documents on real glasses. Direct Drive, automatic library presentation and gesture changes still require an Xcode build/device validation. Nineteen isolated Drive API/model tests pass; live Google login has not been verified. The working web app is preserved.

The server-backed web integration below remains an alternative implementation, not a prerequisite for the native workflow.

## Per-user private Google Drive

Implementation: [private service setup and deployment](service/README.md).

- On the phone: sign in with Google, select a folder, and enter the code from the glasses.
- On the glasses: Documents → Connect Google Drive → Open my datasheets.
- PDFs are rendered by the service and displayed using the existing full-screen viewer. No Google tokens, PDF copies, or private page URLs are published in GitHub Pages.
- Revoke paired devices or disconnect the Google account from the phone setup page.

**Not activated on the live site yet.** `drive-config.js` intentionally contains an empty service URL. Activation needs an HTTPS backend with persistent storage and Google OAuth credentials from the app owner's project. The optional [Render deployment template](render.yaml) and [Dockerfile](service/Dockerfile) are supplied for review. The container was built and tested locally, including persistence across container replacement. No external backend has been deployed.

Local validation includes twelve backend tests and a complete browser flow with **Google simulated**: real OAuth state/PKCE handling in our app, account/folder selection, pairing, actual PDF parsing/rendering, full-screen display, and revocation. Google consent and a real private Drive folder still need live verification. See the service README for exact limitations, scope requirements, and test commands.

## Controls

- Arrow keys move focus. In the viewer's two-row toolbar, Up/Down move between rows and Left/Right move between actions, skipping disabled controls.
- Enter selects the focused action in menus. While reading, Enter shows document controls.
- Escape, Backspace, BrowserBack, or GoBack returns a screen. At home, Back is not intercepted; the host decides what it does.
- While reading at fit size, Left/Right changes pages. While zoomed, arrows or dragging move the page. Enter opens controls without changing the viewing position. Back from reading returns to Documents.
- Tab, touch, and mouse work in a browser.

The application targets a 600×600 display and adapts to smaller viewports. Keyboard tests do not substitute for testing real glasses input.

## Run locally

No installation or build is needed to serve the committed app:

```sh
python3 -m http.server 8000 --bind 127.0.0.1
```

The server must serve dot-prefixed directories: Meta metadata is in `.well-known/`. Runtime files are `index.html`, `app.css`, `app.js`, the manifests, icons, and demo images. `install.html` is a separate phone/computer setup page.

## GitHub Pages

Serve **main / (root)** through **Settings → Pages → Deploy from a branch**. `.nojekyll` lets Pages publish `.well-known/meta-wearables-manifest.json`. All application asset paths support the `/meta-harness-viewer/` project prefix.

`manifest.webmanifest` supplies conventional PWA metadata. Meta's separate `.well-known/meta-wearables-manifest.json` supplies launcher identity and white-on-transparent icon artwork. `mrbd-web-app-capable=yes` enables the glasses web-app input path. No service worker or offline guarantee is included.

## Browser regression checks

The existing environment provides Playwright and Chromium. From this repository, start a server at the parent directory to exercise deployment-relative paths:

```sh
python3 -m http.server 8090 --bind 127.0.0.1 --directory ..
```

In a separate terminal, use an existing Playwright installation or install test tooling outside the checkout:

```sh
npm install --prefix /tmp/harness-browser-check playwright
node /tmp/harness-browser-check/node_modules/playwright/cli.js install chromium
PLAYWRIGHT_MODULE=/tmp/harness-browser-check/node_modules/playwright node tests/webapp.cjs
```

`HARNESS_TEST_URL` overrides the base URL; `CHROMIUM_PATH` selects a system Chromium/Chrome binary. Linux defaults to `/usr/bin/chromium`; other platforms use Playwright's browser unless overridden. Tests cover metadata paths, menus, reference screens, page boundaries, zoom, clamped pan, focus restoration, 600×600 and narrow layouts, installation links, and image error recovery. Screenshots are saved outside the checkout under `/tmp`.

## Rebuild the public demo assets

The original PDF and generated page images, icons, and QR are committed; end users need no Python packages. To regenerate:

```sh
python3 -m venv /tmp/harness-assets-venv
/tmp/harness-assets-venv/bin/pip install -r tools/requirements.txt
/tmp/harness-assets-venv/bin/python tools/generate_demo.py
```

The QR code encodes the public app name and launch URL only. Change the URL constant in the generator and installation page together if moving hosts. PDF preparation uses PyMuPDF; review its applicable licensing before adopting this pipeline for distribution beyond this prototype.

## Other architecture and sources

[Architecture review](docs/SYSTEM-ARCHITECTURE.md) records the discovery of the Web Apps platform. [ios/](ios/README.md) documents the native Drive/Files companion, not a prerequisite for this web app.

- [Meta Web Apps and deployment guide](https://github.com/facebook/meta-wearables-webapp#4-deploy-to-glasses)
- [Meta UI Toolkit, simulator, and samples](https://github.com/facebook/meta-ray-ban-display-ui-toolkit-web)

The current small static UI uses explicit focus handling. Toolkit adoption remains optional future work. Arbitrary PDF rendering is implemented in the private backend, subject to deployment and live device verification.
