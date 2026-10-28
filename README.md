# Harness HUD

A dependency-free static reference app designed for a 600×600 Meta Ray-Ban Display HUD. Includes Pinouts, Documents, Quick Reference, an example connector pinout, a three-step harness assembly example, and an inspection checklist.

## Run locally

From this checkout:

```sh
python3 -m http.server 8000 --bind 127.0.0.1
```

Open the server in your browser. No build, package installation, backend, API key, or database is required.

## Controls

- Arrow keys move focus through actions; Enter activates the focused action.
- Escape or Backspace goes back one screen. Backspace edits text normally inside the document URL field.
- Tab, touch, and mouse also work. In the URL field, arrows edit text; Tab moves to Open document.
- The layout is sized for 600×600 and adapts to smaller screens. Focused actions use inverted high-contrast colors.

## Public documents

In Documents, paste an HTTPS Google Docs document sharing URL (`https://docs.google.com/document/d/FILE_ID/edit`) or Google Drive file URL (`https://drive.google.com/file/d/FILE_ID/view` or `https://drive.google.com/open?id=FILE_ID`). For PDFs, upload a PDF to Drive and use its file sharing link. Set sharing to **Anyone with the link — Viewer**.

Opening uses Google's viewer in a new browser tab. Actual visibility depends on Google sharing permissions, browser pop-up settings, network access, and the device's browser support. The app cannot check file type or public permissions without a backend. It does not embed or download private documents.

## GitHub Pages

Push these files to `main`. In **Settings → Pages → Build and deployment**, choose **Deploy from a branch**, select **main** and **/ (root)**, then **Save**. No custom build workflow is required.

Expected URL after a successful Pages deployment:

https://bell-pepper.github.io/meta-harness-viewer/

The manifest uses relative paths so the project Pages URL works. It supplies standalone display metadata; there is no service worker or offline document support.

## Scope

All pinouts and assembly instructions are illustrative. Replace them with approved engineering data before field use. This is a browser app with keyboard input mapping, not a native Meta integration. Physical-device compatibility and navigation input mapping must be verified on the target glasses; this repository does not use a Meta SDK.
