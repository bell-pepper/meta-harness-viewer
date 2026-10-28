# Harness HUD

An icon-launchable web-app prototype for Meta Ray-Ban Display. Includes Pinouts, Quick Reference, example assembly steps, and an internal two-page datasheet viewer. Device installation and readability still need validation on the glasses.

- **App:** https://bell-pepper.github.io/meta-harness-viewer/
- **Phone setup / installation QR:** https://bell-pepper.github.io/meta-harness-viewer/install.html

## Add to glasses

Open the installation page on your phone and tap **Add with Meta AI**, or scan its QR code from a computer. The link uses the installation scheme in Meta's official examples. Follow the Meta AI prompts and confirm on the glasses if requested.

Manual path documented by Meta: **Meta AI → Devices → Display Glasses settings → App connections → Web apps → Add a web app**. Enter **Harness HUD** and the app URL above. Menu names and developer-access requirements depend on the installed Meta software. If Web apps is unavailable, check updates and Meta's developer setup guidance. No hidden tap sequence is assumed here.

Look for Harness HUD in the glasses app grid. This is a web-app registration path, not APK sideloading or an iPhone Home Screen shortcut. Native iPhone development is not required to try this milestone.

## First device test

1. Launch the app from its glasses icon. Verify arrows/selection work on the main menu.
2. Choose **Documents → Harness test datasheet**. The example opens inside the app; no URL entry or external Google viewer is involved.
3. Try both pages. Page controls disable at the beginning/end.
4. Select **Zoom 2×**, then **Zoom 3×**. Choose **Move** and use arrows to inspect the labeled corners. **Enter** or **Back** exits Move mode. On a phone, drag the page in Move mode and tap **Done**.
5. Use **Fit page**, then **Documents** to return to the library. Try system Back and confirm the expected screen/focus returns.
6. Report any installation errors, clipped controls, unreadable labels, or unsupported input. Check phone locking and connection interruption separately; offline or phone-free operation is not promised.

## Viewer scope

The bundled [PDF](assets/demo/harness-test.pdf) is pre-rendered to two high-contrast PNG page images. This keeps the glasses runtime small and avoids loading a PDF engine for the initial hardware test. Images preserve the source page's layout; raster colors are inverted for white content on a black additive-display background. Fit page gives an overview; zoom is needed to read small text.

This version does **not** load arbitrary PDFs, connect Google Drive, sync folders, or store private files. All bundled data is public and illustrative. A private document library and authorization design come after the launcher/display test. Do not commit private engineering data to this public site.

All pinouts and assembly instructions are examples. Use approved engineering data and acceptance criteria for actual harness work.

## Controls

- Arrow keys move focus. In the viewer's two-row toolbar, Up/Down move between rows and Left/Right move between actions, skipping disabled controls.
- Enter selects the focused action.
- Escape, Backspace, BrowserBack, or GoBack returns a screen. At home, Back is not intercepted; the host decides what it does.
- In Move mode, arrows move the page; Enter or Back exits that mode. Movement stops at page edges. Touch dragging also works in Move mode.
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

[Architecture review](docs/SYSTEM-ARCHITECTURE.md) records the discovery of the Web Apps platform. [ios/](ios/README.md) preserves an optional, unbuilt native companion prototype, not a prerequisite for this web app.

- [Meta Web Apps and deployment guide](https://github.com/facebook/meta-wearables-webapp#4-deploy-to-glasses)
- [Meta UI Toolkit, simulator, and samples](https://github.com/facebook/meta-ray-ban-display-ui-toolkit-web)

The current small static UI uses explicit focus handling. Toolkit adoption and arbitrary-document rendering are later work, subject to the initial device test.
