# Private Drive service

This service gives each user a separate Google Drive connection and pairs it with their glasses. It does not use a shared administrator folder. Google tokens stay on the server. The glasses receive a revocable device credential and page images, not Google access or refresh tokens.

**Implemented and tested locally with a simulated Google OAuth/Drive API. Not deployed or verified against a live Google account yet.** No Google OAuth credentials or hosting account are available in the task environment. The public frontend intentionally has an empty `HARNESS_SERVICE_URL` until a real HTTPS backend is configured.

## User experience

1. On glasses: Documents → Connect Google Drive. An eight-character pairing code and phone setup URL appear. The code expires in ten minutes.
2. On phone: open the setup URL, sign in with Google, select a folder from the list or paste its Drive folder link, then enter the glasses code.
3. On glasses: select Open my datasheets. PDFs directly in the selected folder appear. Select a PDF and read full screen with the existing zoom/page controls.
4. The same Google account can pair more than one device. Another account gets its own folder and library. The selected folder applies to all devices paired to that account.
5. Revoke a device or disconnect Google from the phone page. Disconnecting the glasses themselves removes their device grant but does not disconnect the phone's Google account.

Folders can stay private. No public sharing or rehosting of document contents in GitHub is required. Nested folders can be selected as the folder, but the PDF list does not recurse into them. Google Docs must be exported to PDF separately. Drive shortcuts, scanned-document OCR, offline reading, annotations, and continuous folder synchronization are not implemented. Refresh fetches the current folder contents; each PDF access rechecks Drive metadata and permissions.

## Deployment contract

Use a **single Linux service instance with a persistent volume**, a stable HTTPS origin, and at least 2 GB memory. SQLite is used deliberately for a small single-instance deployment. Do not use ephemeral storage, multiple replicas, multiple Uvicorn workers, or a scale-to-zero filesystem that discards `/data`. Horizontal scaling requires replacing SQLite and the in-process limits/cache first.

The repository includes a Dockerfile and an optional root `render.yaml` example selecting Render's Standard plan and a 1 GB persistent disk. Review the provider's plan/cost before deployment. The configuration has not been deployed. A managed PostgreSQL/object-storage deployment is not included. Back up the persistent database and encryption key separately with restricted access.

Docker build from the repository root:

```sh
docker build -f service/Dockerfile -t harness-drive .
```

The optional BuildKit secret `proxy_ca` supports build-time environments with a required custom CA; it is never copied into the image. Standard hosting does not need it. TLS verification is never disabled.

Set these environment values through your hosting provider's settings:

| Variable | Value |
| --- | --- |
| `HARNESS_PUBLIC_URL` | The service origin, e.g. `https://your-service.example`, without a path or trailing slash |
| `HARNESS_FRONTEND_ORIGIN` | `https://bell-pepper.github.io` (origin only, no project path) |
| `HARNESS_DATABASE` | `/data/harness.sqlite3` on the persistent disk |
| `HARNESS_ENCRYPTION_KEY` | A persistent Fernet key, generated locally once |
| `GOOGLE_CLIENT_ID` | Your Google OAuth Web application client ID |
| `GOOGLE_CLIENT_SECRET` | Its client secret, entered securely on the server |

To generate the key locally after installing the dependencies, use Python's `Fernet.generate_key()` from `cryptography.fernet`. Store the result in your provider's secret settings. Do not send credentials in chat, commit a populated `.env`, or replace the encryption key on restart. Losing the key requires users to reconnect; changing it without migrating existing encrypted tokens makes them unreadable.

The image runs as UID 10001. Ensure an externally mounted `/data` is writable by that user. The container command uses one Uvicorn worker and disables access logs so OAuth authorization codes are not recorded in URLs. Configure your reverse proxy/host not to retain query strings or Authorization headers for auth/device requests. Do not expose untrusted proxy headers as client identity. The service includes rate limits; add provider-level rate limiting for internet deployment.

`/healthz` checks startup and reports whether OAuth values are configured; it does not prove they are valid. `/connect` is the phone setup page.

## Google Cloud setup

1. Create/select your own Google Cloud project and enable **Google Drive API**.
2. Configure Google Auth Platform / OAuth consent branding, audience, and contact details. Use testing mode and explicitly add initial test users before rollout.
3. Add the read-only scope `https://www.googleapis.com/auth/drive.readonly`.
4. Create an OAuth client of type **Web application**. Set the exact authorized redirect URI to `https://YOUR-SERVICE/auth/callback`.
5. Enter its client ID and client secret in server settings. Do not put either token/secret in `drive-config.js`; only the client ID is public by nature, and this implementation keeps it on the server too.
6. Open `/connect`, complete sign-in with a test user, choose a private folder, and pair the glasses.

**Permission scope:** Google does not grant a folder-specific OAuth scope for arbitrary existing folder enumeration here. Google's `drive.readonly` permission is broader than the folder chosen in our UI; the server limits what paired glasses can request. The phone consent screen explains this distinction. A narrower selected-file workflow using Google Picker/`drive.file` would be a different product flow and is not substituted silently.

`drive.readonly` is a restricted scope. Broad external distribution may require Google's verification/security-assessment process depending on the app's use and policy requirements. Testing-mode refresh tokens can expire after seven days for these scopes. Confirm current Google Auth Platform requirements before inviting general users. The service handles refresh and asks for reconnection when authorization expires, but it cannot bypass Google consent or verification.

Service outbound HTTPS destinations are `accounts.google.com` (browser authorization), `oauth2.googleapis.com` (token exchange/revocation), and `www.googleapis.com` (Drive API and media). No Drive credential injection from the Codex environment is assumed.

Official references:

- https://developers.google.com/identity/protocols/oauth2/web-server
- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://developers.google.com/workspace/drive/api/guides/search-files
- https://developers.google.com/workspace/drive/api/guides/manage-downloads

## Activate the existing glasses app

After verifying the backend and OAuth callback:

1. Set `window.HARNESS_SERVICE_URL = 'https://YOUR-SERVICE';` in the public `drive-config.js` and push it. This is a public origin, not a secret.
2. Keep `HARNESS_FRONTEND_ORIGIN` matched to the frontend origin. Device API calls use an Authorization header, not third-party cookies.
3. Reopen the existing glasses app, then use Documents → Connect Google Drive. The launcher URL does not change; no native companion app is required.

Without a backend URL, demo documents still work and the connection screen explains that the private service is not configured. Do not describe the live website as connected until these steps and an actual user login have passed.

## Security and limits

- OAuth uses state bound to an HttpOnly, SameSite=Lax phone session and a PKCE verifier. Phone mutations require a same-origin request and a CSRF token. Sessions rotate after login.
- Refresh/access tokens are encrypted in SQLite with Fernet; session/device credentials are stored as hashes. Never place credentials in page URLs.
- Pairing codes are single-use, expire in ten minutes, and require an authenticated phone with a selected folder. Paired devices expire after 90 days. Device secrets persist in the glasses web app's local storage; anyone possessing one has its delegated access until revocation or expiry. An XSS-free frontend and HTTPS remain essential.
- The device can list only its user's selected folder. Every PDF info/page request rechecks that the requested PDF is directly inside that folder, not trashed, and downloadable under the Google account's current permissions. Cached bytes do not skip that check.
- PDF bytes are held only in a bounded 64 MB process cache for up to two minutes and reused only after permission checks. No PDF or page image is written to disk; private responses are `no-store`. Disconnect clears that user's cached bytes. Cached entries are never served after their TTL, although unused entries may remain in memory until eviction/process exit.
- Downloads are capped at 25 MB and PDF page counts at 1000. At most two PDF requests enter the download/render stage at once. Rendering is serialized, isolated in a child process with CPU/memory limits, bounded to 1600 pixels on the longest side, and terminated after a deadline. Damaged/encrypted PDFs fail with a user-visible error.
- Source colors are inverted for the additive display. Color-coded technical information needs review on the device; rendering does not certify a datasheet or its revision.
- All users share the host's rendering capacity and IP rate limits. This is a small-deployment implementation, not a multi-tenant scale/performance certification.
- Google account disconnect removes local tokens and device grants first, then attempts provider-side revocation. If Google does not confirm revocation, the phone tells the user to remove the connection in Google Account settings as well.

## Local development and tests

From the repository root:

```sh
python3 -m venv /tmp/harness-service-venv
/tmp/harness-service-venv/bin/pip install -r service/requirements.lock
/tmp/harness-service-venv/bin/pip install pytest==8.3.5
/tmp/harness-service-venv/bin/python -m pytest -q service/tests
```

For a real local service, set environment variables yourself (see `.env.example`); they are not auto-loaded. Use `http://127.0.0.1:8080` as the public URL and the exact corresponding localhost callback in Google Cloud. Then run:

```sh
/tmp/harness-service-venv/bin/uvicorn service.main:create_app --factory --host 127.0.0.1 --port 8080 --no-access-log
```

Local HTTP is allowed only for loopback hosts. Production requires HTTPS. Native PDF resource limits target Linux; use the container on macOS if the host's resource-limit behavior differs.

Tests simulate Google OAuth and the Drive API, while downloading the actual bundled fixture PDF bytes into the real parser/renderer. They cover OAuth browser binding/replay/CSRF, separate user libraries, selected-folder enforcement, expired/single-use pairing, refresh/revocation, metadata permission rechecks despite cached PDFs, invalid and oversized PDFs, and device ownership.

The complete browser test `tests/drive.cjs` uses a test service on `http://localhost:8080` and the static app on `http://localhost:8090/meta-harness-viewer/`. A test-only server factory is provided below; it cannot be used unless explicitly enabled:

```sh
HARNESS_ENABLE_TEST_GOOGLE=1 /tmp/harness-service-venv/bin/uvicorn service.tests.browser_fixture:create --factory --host 127.0.0.1 --port 8080 --no-access-log
```

Start the static server from the repo parent (as in the root README), then run with your Playwright installation:

```sh
PLAYWRIGHT_MODULE=/tmp/harness-browser-check/node_modules/playwright node tests/drive.cjs
```

The browser intercepts Google authorization navigation and the test service simulates Google responses. This proves our local flow and PDF rendering; it does not validate Google's real consent UI, actual Drive permissions, internet deployment, or the glasses' cross-origin API/Blob support. Those are the remaining deployment/device acceptance checks.
