import io
import json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
import time

from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
import httpx
from PIL import Image
import pytest

from service.main import create_app, Settings, digest, SCOPE

PDF = (Path(__file__).resolve().parents[2] / 'assets/demo/harness-test.pdf').read_bytes()
ORIGIN = 'http://localhost:8080'

@pytest.fixture
def system(tmp_path):
    calls = []
    def google(request):
        calls.append(request)
        if request.url.path.endswith('/token'):
            form = parse_qs(request.content.decode())
            user = form.get('code', [None])[0] or form['refresh_token'][0].removeprefix('refresh-')
            return httpx.Response(200, json={'access_token': 'access-'+user, 'refresh_token': 'refresh-'+user, 'expires_in': 3600, 'scope': SCOPE})
        if request.url.path.endswith('/revoke'):
            return httpx.Response(200, json={})
        user = request.headers.get('authorization', '').removeprefix('Bearer access-')
        if request.url.path.endswith('/about'):
            return httpx.Response(200, json={'user': {'permissionId': user, 'displayName': user.title()}})
        file = request.url.path.rsplit('/', 1)[-1]
        if file == 'files':
            query = request.url.params.get('q', '')
            if 'folder' in query and 'application/pdf' not in query:
                return httpx.Response(200, json={'files':[{'id':'folder-'+user,'name':user+' folder'}]})
            return httpx.Response(200, json={'files':[{'id':'pdf-'+user,'name':user+'.pdf','modifiedTime':'2026-10-28T00:00:00Z'}]})
        if file.startswith('folder-'):
            if file != 'folder-'+user:
                return httpx.Response(403, json={})
            return httpx.Response(200, json={'id':file,'name':user+' folder','mimeType':'application/vnd.google-apps.folder'})
        if request.url.params.get('alt') == 'media':
            return httpx.Response(200, content=PDF)
        if file == 'pdf-other':
            return httpx.Response(200, json={'id':file,'name':'Other.pdf','mimeType':'application/pdf','parents':['elsewhere']})
        if file != 'pdf-'+user:
            return httpx.Response(403, json={})
        return httpx.Response(200, json={'id':file,'name':user+'.pdf','mimeType':'application/pdf','parents':['folder-'+user],
                                        'size':str(len(PDF)),'modifiedTime':'version-1','capabilities':{'canDownload':True}})
    settings = Settings(ORIGIN, 'http://localhost:8090', 'test-client', 'test-secret', Fernet.generate_key().decode(), str(tmp_path/'data.sqlite'))
    app = create_app(settings, httpx.MockTransport(google))
    yield app, calls
    app.state.drive.http.close()


def phone(app, user='alice', choose=True):
    client = TestClient(app, base_url=ORIGIN)
    state = client.get('/api/setup').json()
    headers = {'origin':ORIGIN,'x-csrf-token':state['csrf']}
    response = client.post('/auth/start', headers=headers)
    assert response.status_code == 200, response.text
    flow = parse_qs(urlsplit(response.json()['url']).query)
    assert flow['code_challenge_method'] == ['S256']
    result = client.get('/auth/callback', params={'state':flow['state'][0],'code':user}, follow_redirects=False)
    assert result.status_code == 303, result.text
    headers['x-csrf-token'] = client.get('/api/setup').json()['csrf']
    if choose:
        result = client.post('/api/folder', headers=headers, json={'folder_id':'folder-'+user})
        assert result.status_code == 200, result.text
    return client, headers


def pair(app, phone_client, headers):
    viewer = TestClient(app, base_url=ORIGIN)
    created = viewer.post('/api/pair/start').json()
    viewer.headers['Authorization'] = 'Bearer '+created['token']
    assert not viewer.get('/api/device/status').json()['paired']
    assert phone_client.post('/api/pair/claim', headers=headers, json={'code':created['code']}).status_code == 200
    return viewer, created


def test_complete_private_flow_renders_real_pdf(system):
    app, calls = system
    client, headers = phone(app)
    viewer, created = pair(app, client, headers)
    assert viewer.get('/api/device/status').json()['paired']
    docs = viewer.get('/api/device/documents').json()
    assert docs['documents'][0]['title'] == 'alice.pdf'
    assert all('token' not in item for item in docs['documents'])
    info = viewer.get('/api/device/documents/pdf-alice')
    assert info.status_code == 200, info.text
    assert info.json()['page_count'] == 2
    rendered = viewer.get('/api/device/documents/pdf-alice/pages/0')
    assert rendered.status_code == 200, rendered.text
    assert rendered.headers['cache-control'] == 'no-store'
    im = Image.open(io.BytesIO(rendered.content))
    assert max(im.size) <= 1600 and im.size[0] > 0
    assert im.getpixel((0,0)) == (0,0,0)
    assert viewer.get('/api/device/documents/pdf-alice/pages/2').status_code == 404
    with app.state.store.db() as db:
        tokens = db.execute('SELECT tokens FROM users').fetchone()[0]
        assert 'access-alice' not in tokens and 'refresh-alice' not in tokens
        stored = db.execute('SELECT token,code FROM devices').fetchone()
        assert stored['token'] != created['token'] and stored['code'] is None


def test_cross_user_and_outside_folder_access_denied(system):
    app, _ = system
    alice, ah = phone(app)
    bob, bh = phone(app, 'bob')
    av, _ = pair(app, alice, ah)
    bv, _ = pair(app, bob, bh)
    assert av.get('/api/device/documents').json()['documents'][0]['id'] == 'pdf-alice'
    assert bv.get('/api/device/documents').json()['documents'][0]['id'] == 'pdf-bob'
    assert av.get('/api/device/documents/pdf-bob').status_code == 403
    assert av.get('/api/device/documents/pdf-other/pages/0').status_code == 403
    assert bv.get('/api/device/documents/pdf-alice/pages/0').status_code == 403


def test_oauth_state_browser_binding_replay_and_csrf(system):
    app, _ = system
    a, b = TestClient(app,base_url=ORIGIN), TestClient(app,base_url=ORIGIN)
    csrf = a.get('/api/setup').json()['csrf']
    assert a.post('/auth/start').status_code == 403
    assert a.post('/auth/start',headers={'origin':'https://evil.example','x-csrf-token':csrf}).status_code == 403
    flow=a.post('/auth/start',headers={'origin':ORIGIN,'x-csrf-token':csrf}).json()
    state=parse_qs(urlsplit(flow['url']).query)['state'][0]
    b.get('/api/setup')
    assert b.get('/auth/callback',params={'state':state,'code':'alice'}).status_code == 400
    assert a.get('/auth/callback',params={'state':state,'code':'alice'},follow_redirects=False).status_code == 303
    assert a.get('/auth/callback',params={'state':state,'code':'alice'}).status_code == 400


def test_pair_code_single_use_expiry_and_unpaired_denied(system):
    app, _ = system
    client, headers = phone(app)
    viewer, created = pair(app, client, headers)
    assert client.post('/api/pair/claim',headers=headers,json={'code':created['code']}).status_code == 400
    pending = TestClient(app,base_url=ORIGIN)
    p=pending.post('/api/pair/start').json()
    pending.headers['authorization']='Bearer '+p['token']
    assert pending.get('/api/device/documents').status_code == 401
    with app.state.store.db() as db:
        db.execute('UPDATE devices SET expires=0 WHERE token=?',(digest(p['token']),))
    assert client.post('/api/pair/claim',headers=headers,json={'code':p['code']}).status_code == 400
    assert pending.get('/api/device/status').status_code == 401


def test_token_refresh_and_revocation(system):
    app, calls = system
    client, headers = phone(app)
    viewer, _ = pair(app, client, headers)
    with app.state.store.db() as db:
        row=db.execute('SELECT tokens FROM users WHERE id=?',('alice',)).fetchone()
        data=app.state.drive.decrypt(row['tokens']);data['expires_at']=0
        db.execute('UPDATE users SET tokens=?',(app.state.drive.encrypt(data),))
    assert viewer.get('/api/device/documents').status_code == 200
    assert any(b'grant_type=refresh_token' in request.content for request in calls)
    assert client.post('/api/disconnect',headers=headers).json()['google_revoked']
    assert viewer.get('/api/device/documents').status_code == 401
    with app.state.store.db() as db:
        assert db.execute('SELECT COUNT(*) FROM users').fetchone()[0] == 0
        assert db.execute('SELECT COUNT(*) FROM devices').fetchone()[0] == 0


def test_csrf_for_folder_and_pair_and_device_owner(system):
    app, _ = system
    alice, ah = phone(app)
    bob, bh = phone(app,'bob')
    viewer, created = pair(app,alice,ah)
    assert alice.post('/api/folder',json={'folder_id':'folder-alice'}).status_code == 403
    assert alice.post('/api/pair/claim',json={'code':created['code']}).status_code == 403
    device_id=alice.get('/api/setup').json()['devices'][0]['id']
    assert bob.delete('/api/setup/devices/'+device_id,headers=bh).status_code == 200
    assert viewer.get('/api/device/documents').status_code == 200
    assert alice.delete('/api/setup/devices/'+device_id,headers=ah).status_code == 200
    assert viewer.get('/api/device/documents').status_code == 401


def test_folder_required_cors_and_bad_identifier(system):
    app, _ = system
    client, headers = phone(app,choose=False)
    pending=client.post('/api/pair/start').json()
    assert client.post('/api/pair/claim',headers=headers,json={'code':pending['code']}).status_code == 409
    assert client.post('/api/folder',headers=headers,json={'folder_id':"bad' or 1=1"}).status_code == 400
    assert client.get('/api/folders',headers={'Origin':'http://localhost:8090'}).headers['access-control-allow-origin']=='http://localhost:8090'
    assert 'access-control-allow-origin' not in client.get('/api/folders',headers={'Origin':'https://evil.example'}).headers


def test_missing_config_fails_closed(tmp_path):
    with pytest.raises(RuntimeError):
        create_app(Settings(ORIGIN,'https://site.example','','','',str(tmp_path/'db')))


def test_cached_pdf_still_checks_current_drive_permissions(system):
    app, _ = system
    client, headers = phone(app)
    viewer, _ = pair(app, client, headers)
    assert viewer.get('/api/device/documents/pdf-alice').status_code == 200
    original = app.state.drive.http
    def deny(request):
        if request.url.path.endswith('/files/pdf-alice'):
            return httpx.Response(403,json={})
        return original._transport.handle_request(request)
    app.state.drive.http = httpx.Client(transport=httpx.MockTransport(deny))
    assert viewer.get('/api/device/documents/pdf-alice/pages/0').status_code == 403
    original.close()


def test_bad_pdf_and_oversize_are_rejected(system):
    app, _ = system
    client, headers = phone(app)
    viewer, _ = pair(app, client, headers)
    original = app.state.drive.http
    oversized = False
    def bad_content(request):
        if request.url.params.get('alt') == 'media':
            return httpx.Response(200, content=b'%PDF-1.7\nnot a valid PDF')
        if oversized and request.url.path.endswith('/files/pdf-alice'):
            return httpx.Response(200,json={'id':'pdf-alice','name':'Big.pdf','mimeType':'application/pdf','parents':['folder-alice'],'size':str(26*1024*1024),'capabilities':{'canDownload':True}})
        return original._transport.handle_request(request)
    app.state.drive.http=httpx.Client(transport=httpx.MockTransport(bad_content))
    assert viewer.get('/api/device/documents/pdf-alice').status_code == 422
    oversized=True
    assert viewer.get('/api/device/documents/pdf-alice').status_code == 413
    original.close()


@pytest.mark.parametrize('allowed', [False, None])
def test_download_permission_must_be_explicit(system, allowed):
    app, _ = system
    client, headers = phone(app)
    viewer, _ = pair(app, client, headers)
    original = app.state.drive.http
    def without_download_permission(request):
        if request.url.path.endswith('/files/pdf-alice'):
            return httpx.Response(200,json={'id':'pdf-alice','name':'Restricted.pdf','mimeType':'application/pdf',
                'parents':['folder-alice'],'capabilities':{} if allowed is None else {'canDownload':allowed}})
        return original._transport.handle_request(request)
    app.state.drive.http=httpx.Client(transport=httpx.MockTransport(without_download_permission))
    assert viewer.get('/api/device/documents/pdf-alice').status_code == 403
    original.close()
