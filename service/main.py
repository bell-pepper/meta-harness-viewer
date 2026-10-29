"""Private Google Drive gateway. Start with: uvicorn service.main:app.

One instance with a persistent SQLite volume. Google tokens are encrypted at rest;
device credentials are hashed. No PDF bytes or raster images are written to disk.
"""
import base64
from collections import OrderedDict, defaultdict, deque
from contextlib import contextmanager, asynccontextmanager
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from urllib.parse import urlencode, urlsplit

from cryptography.fernet import Fernet
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response
import httpx
from PIL import ImageOps
from pydantic import BaseModel, Field

SCOPE = 'https://www.googleapis.com/auth/drive.readonly'
GOOGLE_API = 'https://www.googleapis.com/drive/v3/'
ID = re.compile(r'^[A-Za-z0-9_-]{1,200}$')
MAX_PDF = 25 * 1024 * 1024
WEB = Path(__file__).parent / 'web'

@dataclass
class Settings:
    public_url: str
    frontend_origin: str
    client_id: str
    client_secret: str
    encryption_key: str
    database: str

    @classmethod
    def environment(cls):
        return cls(os.getenv('HARNESS_PUBLIC_URL', 'http://127.0.0.1:8080').rstrip('/'),
                   os.getenv('HARNESS_FRONTEND_ORIGIN', 'https://bell-pepper.github.io'),
                   os.getenv('GOOGLE_CLIENT_ID', ''), os.getenv('GOOGLE_CLIENT_SECRET', ''),
                   os.getenv('HARNESS_ENCRYPTION_KEY', ''),
                   os.getenv('HARNESS_DATABASE', '/data/harness.sqlite3'))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def identifier(value):
    if not ID.fullmatch(value):
        raise HTTPException(400, 'Invalid Drive identifier.')
    return value


class Store:
    def __init__(self, filename):
        Path(filename).parent.mkdir(parents=True, exist_ok=True)
        self.filename = filename
        with self.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS users (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, tokens TEXT NOT NULL,
              folder TEXT, folder_name TEXT);
            CREATE TABLE IF NOT EXISTS sessions (
              token TEXT PRIMARY KEY, csrf TEXT NOT NULL, user TEXT REFERENCES users(id) ON DELETE SET NULL,
              expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS oauth (
              state TEXT PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(token) ON DELETE CASCADE,
              verifier TEXT NOT NULL, expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS devices (
              token TEXT PRIMARY KEY, code TEXT UNIQUE, user TEXT REFERENCES users(id) ON DELETE CASCADE,
              expires REAL NOT NULL, created REAL NOT NULL);
            ''')
        os.chmod(filename, 0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.filename, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db:
                yield db
        finally:
            db.close()


class Drive:
    def __init__(self, settings, store, transport=None):
        self.settings, self.store = settings, store
        self.cipher = Fernet(settings.encryption_key.encode())
        self.http = httpx.Client(timeout=30, transport=transport, follow_redirects=False)
        self.lock = threading.RLock()
        self.cache = OrderedDict()
        self.cache_bytes = 0

    def encrypt(self, tokens):
        return self.cipher.encrypt(json.dumps(tokens).encode()).decode()

    def decrypt(self, text):
        return json.loads(self.cipher.decrypt(text.encode()))

    def exchange(self, fields):
        try:
            response = self.http.post('https://oauth2.googleapis.com/token', data={
                **fields, 'client_id': self.settings.client_id, 'client_secret': self.settings.client_secret})
        except httpx.HTTPError:
            raise HTTPException(502, 'Google could not be reached. Try again.')
        if response.status_code != 200:
            raise HTTPException(401, 'Google authorization expired or was denied. Reconnect on your phone.')
        return response.json()

    def token(self, user):
        # Serialize refreshes so a response cannot overwrite a rotated refresh token.
        with self.lock:
            with self.store.db() as db:
                row = db.execute('SELECT * FROM users WHERE id=?', (user,)).fetchone()
            if not row:
                raise HTTPException(401, 'Reconnect Google Drive on your phone.')
            tokens = self.decrypt(row['tokens'])
            if tokens.get('expires_at', 0) < time.time() + 60:
                if not tokens.get('refresh_token'):
                    raise HTTPException(401, 'Reconnect Google Drive on your phone.')
                update = self.exchange({'grant_type': 'refresh_token', 'refresh_token': tokens['refresh_token']})
                tokens.update(update)
                tokens['expires_at'] = time.time() + int(update.get('expires_in', 3600))
                with self.store.db() as db:
                    db.execute('UPDATE users SET tokens=? WHERE id=?', (self.encrypt(tokens), user))
            return tokens['access_token']

    def get(self, user, path, params=None):
        try:
            response = self.http.get(GOOGLE_API + path, params=params, headers={'Authorization': 'Bearer ' + self.token(user)})
        except httpx.HTTPError:
            raise HTTPException(502, 'Google Drive could not be reached. Try again.')
        if response.status_code == 401:
            raise HTTPException(401, 'Google authorization expired. Reconnect on your phone.')
        if response.status_code in (403, 404):
            raise HTTPException(403, 'This account no longer has access to the requested Drive file.')
        if response.status_code != 200:
            raise HTTPException(502, 'Google Drive request failed. Try again later.')
        return response.json()

    def metadata(self, user, file):
        return self.get(user, 'files/' + identifier(file), {'fields': 'id,name,mimeType,parents,trashed,size,modifiedTime,capabilities(canDownload)', 'supportsAllDrives': 'true'})

    def authorized_pdf(self, user, file):
        with self.store.db() as db:
            account = db.execute('SELECT folder FROM users WHERE id=?', (user,)).fetchone()
        if not account or not account['folder']:
            raise HTTPException(409, 'Choose a Drive folder on your phone first.')
        meta = self.metadata(user, file)
        if meta.get('trashed') or meta.get('mimeType') != 'application/pdf' or account['folder'] not in meta.get('parents', []):
            raise HTTPException(403, 'Only PDFs directly inside your selected folder can be opened.')
        if meta.get('capabilities', {}).get('canDownload') is not True:
            raise HTTPException(403, 'The file owner has disabled downloading.')
        if int(meta.get('size', 0)) > MAX_PDF:
            raise HTTPException(413, 'This PDF exceeds the 25 MB limit.')
        key = (user, file, meta.get('modifiedTime'))
        with self.lock:
            cached = self.cache.get(key)
            if cached and time.time() - cached[0] < 120:
                self.cache.move_to_end(key)
                return meta, cached[1]
        data = bytearray()
        try:
            with self.http.stream('GET', GOOGLE_API + 'files/' + identifier(file),
                                  params={'alt': 'media', 'supportsAllDrives': 'true'},
                                  headers={'Authorization': 'Bearer ' + self.token(user)}) as response:
                if response.status_code != 200:
                    raise HTTPException(403, 'PDF download was denied. Check Drive permissions.')
                for chunk in response.iter_bytes():
                    data.extend(chunk)
                    if len(data) > MAX_PDF:
                        raise HTTPException(413, 'This PDF exceeds the 25 MB limit.')
        except httpx.HTTPError:
            raise HTTPException(502, 'PDF download failed. Try again.')
        if not bytes(data[:1024]).lstrip().startswith(b'%PDF-'):
            raise HTTPException(422, 'Drive did not return a valid PDF.')
        content = bytes(data)
        with self.lock:
            old = self.cache.pop(key, None)
            if old:
                self.cache_bytes -= len(old[1])
            self.cache[key] = (time.time(), content)
            self.cache_bytes += len(content)
            while self.cache_bytes > 64 * 1024 * 1024:
                _, entry = self.cache.popitem(last=False)
                self.cache_bytes -= len(entry[1])
        return meta, content

    def clear_cache(self, user):
        with self.lock:
            for key in list(self.cache):
                if key[0] == user:
                    self.cache_bytes -= len(self.cache.pop(key)[1])


# Native PDF parsing is isolated in a short-lived child process with a deadline.
def pdf_job(data, index, pipe):
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (8, 8))
        resource.setrlimit(resource.RLIMIT_AS, (768 * 1024 * 1024,) * 2)
        import pypdfium2 as pdfium
        pdf = pdfium.PdfDocument(data)
        try:
            count = len(pdf)
            if count < 1 or count > 1000:
                raise ValueError('PDF page count must be between 1 and 1000.')
            if index is None:
                pipe.send(('ok', count))
            elif not 0 <= index < count:
                pipe.send(('range', None))
            else:
                page = pdf[index]
                try:
                    scale = min(1600 / max(page.get_size()), 3)
                    bitmap = page.render(scale=scale)
                    try:
                        image = ImageOps.invert(bitmap.to_pil().convert('RGB'))
                        output = io.BytesIO()
                        image.save(output, format='PNG', optimize=True)
                        pipe.send(('ok', output.getvalue()))
                    finally:
                        bitmap.close()
                finally:
                    page.close()
        finally:
            pdf.close()
    except Exception:
        pipe.send(('invalid', None))
    finally:
        pipe.close()


RENDER_LOCK = threading.Lock()
def render_pdf(data, index=None):
    import multiprocessing
    ctx = multiprocessing.get_context('spawn')
    with RENDER_LOCK:
        reader, writer = ctx.Pipe(duplex=False)
        process = ctx.Process(target=pdf_job, args=(data, index, writer), daemon=True)
        process.start()
        writer.close()
        try:
            if not reader.poll(12):
                raise HTTPException(422, 'PDF processing timed out. Try a smaller PDF.')
            try:
                status, result = reader.recv()
            except EOFError:
                raise HTTPException(422, 'This PDF could not be rendered.')
            if status == 'range':
                raise HTTPException(404, 'Page does not exist.')
            if status != 'ok':
                raise HTTPException(422, 'This PDF is encrypted, damaged, or unsupported.')
            return result
        finally:
            reader.close()
            if process.is_alive():
                process.terminate()
            process.join(2)


class PairCode(BaseModel):
    code: str = Field(min_length=8, max_length=12)

class FolderChoice(BaseModel):
    folder_id: str = Field(min_length=1, max_length=200)


def create_app(settings=None, transport=None):
    settings = settings or Settings.environment()
    # Fail closed, rather than silently generating a key that loses refresh tokens on restart.
    if not settings.encryption_key:
        raise RuntimeError('Set HARNESS_ENCRYPTION_KEY to a persistent Fernet key before starting.')
    origin = urlsplit(settings.public_url)
    if origin.scheme not in ('http', 'https') or not origin.netloc or origin.path or origin.query or origin.fragment:
        raise RuntimeError('HARNESS_PUBLIC_URL must be a bare origin.')
    if origin.scheme != 'https' and origin.hostname not in ('localhost', '127.0.0.1'):
        raise RuntimeError('Public deployments require HTTPS.')
    store = Store(settings.database)
    drive = Drive(settings, store, transport)
    @asynccontextmanager
    async def lifespan(app):
        yield
        drive.http.close()
        drive.cache.clear()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.store, app.state.drive = store, drive
    pdf_slots = threading.BoundedSemaphore(2)

    @contextmanager
    def pdf_access(user, file):
        if not pdf_slots.acquire(blocking=False):
            raise HTTPException(429, "PDF service is busy. Try again shortly.")
        try:
            yield drive.authorized_pdf(user, file)
        finally:
            pdf_slots.release()
    app.add_middleware(CORSMiddleware, allow_origins=[settings.frontend_origin],
                       allow_methods=['GET', 'POST', 'DELETE'], allow_headers=['Authorization', 'Content-Type'])
    buckets = defaultdict(deque)
    rate_lock = threading.Lock()

    @app.middleware('http')
    async def private_responses(request, call_next):
        # Reverse proxies should provide rate limiting as well. Do not trust forwarded IP headers here.
        if request.url.path.startswith('/api/') or request.url.path.startswith('/auth/'):
            key = (request.client.host if request.client else 'unknown',
                   'pair' if request.url.path == '/api/pair/start' else 'api')
            with rate_lock:
                now = time.time()
                queue = buckets[key]
                while queue and queue[0] < now - 60:
                    queue.popleft()
                if len(queue) >= (6 if key[1] == 'pair' else 180):
                    return JSONResponse({'detail': 'Too many requests. Wait a minute.'}, status_code=429, headers={'Retry-After': '60'})
                queue.append(now)
                if len(buckets) > 10000:
                    for old in list(buckets):
                        if not buckets[old] or buckets[old][-1] < now - 60:
                            buckets.pop(old, None)
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Referrer-Policy'] = 'no-referrer'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response

    def cookie(response, raw):
        response.set_cookie('harness_session', raw, httponly=True, secure=origin.scheme == 'https', samesite='lax', max_age=7*86400, path='/')

    def new_session(response, user=None):
        raw, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with store.db() as db:
            db.execute('DELETE FROM oauth WHERE expires<?', (time.time(),))
            db.execute('DELETE FROM sessions WHERE expires<?', (time.time(),))
            db.execute('INSERT INTO sessions VALUES (?,?,?,?)', (digest(raw), csrf, user, time.time()+7*86400))
        cookie(response, raw)
        return {'token': digest(raw), 'csrf': csrf, 'user': user}

    def session(request, required=True):
        raw = request.cookies.get('harness_session', '')
        with store.db() as db:
            row = db.execute('SELECT * FROM sessions WHERE token=? AND expires>?', (digest(raw), time.time())).fetchone()
        if not row or (required and not row['user']):
            raise HTTPException(401, 'Sign in with Google on this phone first.')
        return row

    def phone_write(request):
        row = session(request, required=False)
        if request.headers.get('origin') != settings.public_url or not secrets.compare_digest(request.headers.get('x-csrf-token', ''), row['csrf']):
            raise HTTPException(403, 'Refresh the setup page and try again.')
        return row

    def user_session(request):
        row = session(request)
        return row['user']

    def device(request, pending=False):
        auth = request.headers.get('authorization', '')
        if not auth.startswith('Bearer ') or len(auth) > 200:
            raise HTTPException(401, 'Pair these glasses on your phone.')
        with store.db() as db:
            row = db.execute('SELECT * FROM devices WHERE token=? AND expires>?', (digest(auth[7:]), time.time())).fetchone()
        if not row or (not pending and not row['user']):
            raise HTTPException(401, 'Pair these glasses on your phone.')
        return row

    @app.get('/healthz')
    def health():
        return {'status': 'ok', 'google_configured': bool(settings.client_id and settings.client_secret)}

    @app.get('/connect')
    def connect():
        return FileResponse(WEB / 'connect.html')

    @app.get('/connect.js')
    def connect_js():
        return FileResponse(WEB / 'connect.js', media_type='text/javascript')

    @app.get('/connect.css')
    def connect_css():
        return FileResponse(WEB / 'connect.css', media_type='text/css')

    @app.get('/api/setup')
    def setup(request: Request):
        response = JSONResponse({})
        try:
            row = session(request, required=False)
        except HTTPException:
            row = new_session(response)
        with store.db() as db:
            account = db.execute('SELECT name,folder,folder_name FROM users WHERE id=?', (row['user'],)).fetchone()
            devices = db.execute('SELECT token,created FROM devices WHERE user=? AND expires>?', (row['user'], time.time())).fetchall()
        response.body = json.dumps({'csrf': row['csrf'], 'configured': bool(settings.client_id and settings.client_secret),
                                    'account': dict(account) if account else None,
                                    'devices': [{'id': d['token'], 'created': d['created']} for d in devices]}).encode()
        response.headers['content-length'] = str(len(response.body))
        return response

    @app.post('/auth/start')
    def auth_start(request: Request):
        row = phone_write(request)
        if not settings.client_id or not settings.client_secret:
            raise HTTPException(503, 'The administrator must configure Google sign-in first.')
        state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        with store.db() as db:
            db.execute('DELETE FROM oauth WHERE expires<?', (time.time(),))
            db.execute('INSERT INTO oauth VALUES (?,?,?,?)', (digest(state), row['token'], verifier, time.time()+600))
        return {'url': 'https://accounts.google.com/o/oauth2/v2/auth?' + urlencode({
            'client_id': settings.client_id, 'redirect_uri': settings.public_url+'/auth/callback',
            'response_type': 'code', 'scope': SCOPE, 'access_type': 'offline', 'prompt': 'consent',
            'state': state, 'code_challenge': challenge, 'code_challenge_method': 'S256'})}

    @app.get('/auth/callback')
    def auth_callback(request: Request, state: str = '', code: str = '', error: str = ''):
        row = session(request, required=False)
        with store.db() as db:
            db.execute('BEGIN IMMEDIATE')
            flow = db.execute('SELECT * FROM oauth WHERE state=? AND session=? AND expires>?', (digest(state), row['token'], time.time())).fetchone()
            if not flow:
                raise HTTPException(400, 'Sign-in expired or belongs to another browser. Start again.')
            db.execute('DELETE FROM oauth WHERE state=?', (digest(state),))
        if error or not code:
            return RedirectResponse(settings.public_url+'/connect?error=google_denied', status_code=303)
        tokens = drive.exchange({'grant_type': 'authorization_code', 'code': code, 'code_verifier': flow['verifier'], 'redirect_uri': settings.public_url+'/auth/callback'})
        if SCOPE not in tokens.get('scope', '').split():
            raise HTTPException(403, 'Read-only Drive permission was not granted. Start sign-in again.')
        try:
            about = drive.http.get(GOOGLE_API+'about', params={'fields': 'user(permissionId,displayName)'}, headers={'Authorization': 'Bearer '+tokens['access_token']})
            about.raise_for_status()
            account = about.json()['user']
            user = account['permissionId']
        except (httpx.HTTPError, KeyError, ValueError):
            raise HTTPException(502, 'Could not verify the Google Drive account.')
        tokens['expires_at'] = time.time()+int(tokens.get('expires_in', 3600))
        with store.db() as db:
            old = db.execute('SELECT tokens FROM users WHERE id=?', (user,)).fetchone()
            if not tokens.get('refresh_token') and old:
                tokens['refresh_token'] = drive.decrypt(old['tokens']).get('refresh_token')
            if not tokens.get('refresh_token'):
                raise HTTPException(403, 'Google did not grant offline access. Reconnect with consent.')
            db.execute('INSERT INTO users(id,name,tokens) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,tokens=excluded.tokens',
                       (user, account.get('displayName', 'Google Drive user'), drive.encrypt(tokens)))
            db.execute('DELETE FROM sessions WHERE token=?', (row['token'],))
        response = RedirectResponse(settings.public_url+'/connect', status_code=303)
        new_session(response, user)
        return response

    @app.get('/api/folders')
    def folders(request: Request, parent: str = '', cursor: str = ''):
        user = user_session(request)
        if len(cursor) > 2048:
            raise HTTPException(400, 'Invalid pagination token.')
        query = "trashed=false and mimeType='application/vnd.google-apps.folder'"
        if parent:
            query += " and '"+identifier(parent)+"' in parents"
        return drive.get(user, 'files', {'q': query, 'fields': 'nextPageToken,files(id,name)', 'pageSize': 100, 'orderBy': 'name',
                                        'pageToken': cursor, 'supportsAllDrives': 'true', 'includeItemsFromAllDrives': 'true'})

    @app.post('/api/folder')
    def choose_folder(body: FolderChoice, request: Request):
        phone_write(request)
        user = user_session(request)
        meta = drive.metadata(user, body.folder_id)
        if meta.get('trashed') or meta.get('mimeType') != 'application/vnd.google-apps.folder':
            raise HTTPException(400, 'Choose a Google Drive folder.')
        with store.db() as db:
            db.execute('UPDATE users SET folder=?,folder_name=? WHERE id=?', (meta['id'], meta['name'], user))
        drive.clear_cache(user)
        return {'folder': meta['name']}

    @app.post('/api/pair/start')
    def pair_start():
        token = secrets.token_urlsafe(32)
        code = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(8))
        with store.db() as db:
            db.execute('DELETE FROM devices WHERE expires<?', (time.time(),))
            db.execute('INSERT INTO devices VALUES (?,?,NULL,?,?)', (digest(token), code, time.time()+600, time.time()))
        return {'token': token, 'code': code, 'expires_in': 600, 'setup_url': settings.public_url+'/connect'}

    @app.post('/api/pair/claim')
    def pair_claim(body: PairCode, request: Request):
        phone_write(request)
        user = user_session(request)
        with store.db() as db:
            folder = db.execute('SELECT folder FROM users WHERE id=?', (user,)).fetchone()
            if not folder or not folder['folder']:
                raise HTTPException(409, 'Choose a folder before pairing.')
            code = body.code.upper().replace('-', '').replace(' ', '')
            result = db.execute('UPDATE devices SET user=?,code=NULL,expires=? WHERE code=? AND user IS NULL AND expires>?',
                                (user, time.time()+90*86400, code, time.time()))
            if result.rowcount != 1:
                raise HTTPException(400, 'Pairing code is invalid, already used, or expired.')
        return {'paired': True}

    @app.get('/api/device/status')
    def device_status(request: Request):
        row = device(request, pending=True)
        return {'paired': bool(row['user']), 'expires_at': row['expires']}

    @app.delete('/api/device')
    def forget_device(request: Request):
        row = device(request, pending=True)
        with store.db() as db:
            db.execute('DELETE FROM devices WHERE token=?', (row['token'],))
        return {'disconnected': True}

    @app.get('/api/device/documents')
    def documents(request: Request, cursor: str = ''):
        row = device(request)
        if len(cursor) > 2048:
            raise HTTPException(400, 'Invalid pagination token.')
        with store.db() as db:
            account = db.execute('SELECT folder,folder_name FROM users WHERE id=?', (row['user'],)).fetchone()
        if not account or not account['folder']:
            raise HTTPException(409, 'Choose a folder on your phone.')
        result = drive.get(row['user'], 'files', {'q': "'"+identifier(account['folder'])+"' in parents and trashed=false and mimeType='application/pdf'",
            'fields': 'nextPageToken,files(id,name,modifiedTime)', 'pageSize': 100, 'orderBy': 'name', 'pageToken': cursor,
            'supportsAllDrives': 'true', 'includeItemsFromAllDrives': 'true'})
        return {'folder': account['folder_name'], 'documents': [{'id': f['id'], 'title': f['name'], 'revision': f.get('modifiedTime', ''), 'private': True} for f in result.get('files', [])], 'next': result.get('nextPageToken')}

    @app.get('/api/device/documents/{file}')
    def document_info(file: str, request: Request):
        row = device(request)
        with pdf_access(row['user'], file) as (meta, content):
            return {'id': file, 'title': meta['name'], 'page_count': render_pdf(content), 'revision': meta.get('modifiedTime', '')}

    @app.get('/api/device/documents/{file}/pages/{index}')
    def page_image(file: str, index: int, request: Request):
        row = device(request)
        with pdf_access(row['user'], file) as (_, content):
            return Response(render_pdf(content, index), media_type='image/png')

    @app.delete('/api/setup/devices/{token}')
    def revoke_device(token: str, request: Request):
        phone_write(request)
        user = user_session(request)
        with store.db() as db:
            db.execute('DELETE FROM devices WHERE token=? AND user=?', (token, user))
        return {'disconnected': True}

    @app.post('/api/disconnect')
    def disconnect(request: Request):
        phone_write(request)
        user = user_session(request)
        with store.db() as db:
            row = db.execute('SELECT tokens FROM users WHERE id=?', (user,)).fetchone()
            db.execute('DELETE FROM sessions WHERE user=?', (user,))
            db.execute('DELETE FROM users WHERE id=?', (user,))
        drive.clear_cache(user)
        revoked = False
        if row:
            tokens = drive.decrypt(row['tokens'])
            try:
                revoked = drive.http.post('https://oauth2.googleapis.com/revoke', data={'token': tokens.get('refresh_token', '')}).status_code == 200
            except httpx.HTTPError:
                pass
        response = JSONResponse({'disconnected': True, 'google_revoked': revoked})
        response.delete_cookie('harness_session', path='/')
        return response

    return app

# Use the factory flag to avoid loading production configuration while importing tests.
# uvicorn service.main:create_app --factory --host 0.0.0.0 --port 8080 --no-access-log
