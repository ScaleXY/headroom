"""Offline contract tests: no App Store Connect credentials or network required."""
import base64
from email.message import Message
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
from urllib.request import HTTPSHandler
from urllib.response import addinfourl

spec = importlib.util.spec_from_file_location('listing', Path(__file__).resolve().parents[1] / 'appstore_listing.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def resource(kind, identity, **attributes):
    return {'type': kind, 'id': identity, 'attributes': attributes}


def screenshot(identity, checksum, state='COMPLETE'):
    delivery = {'assetDeliveryState': {'state': state}} if state is not None else {}
    return resource('appScreenshots', identity, sourceFileChecksum=checksum, **delivery)


CREDS = {'ASC_KEY': '-----BEGIN PRIVATE KEY-----', 'ASC_KEY_ID': 'id', 'ASC_ISSUER_ID': 'issuer'}


class FakeTransport:
    def __init__(self, responses):
        self.responses, self.calls = responses, []

    def __call__(self, method, url, headers, data):
        path = a.urllib.parse.urlsplit(url).path
        self.calls.append((method, path, json.loads(data) if data else None))
        status, payload = self.responses[method, path]
        return status, {}, json.dumps(payload).encode() if payload is not None else b''

    def client(self):
        return a.Client('https://asc.invalid', mock.Mock(get=mock.Mock(return_value='token')), self, lambda _: None)


def fixture():
    desired = {'config': {'bundleId': 'example.app', 'platform': 'IOS'},
               'locales': {'en-US': {'fields': {}, 'screenshots': {}}}}
    live = {'app': 'app', 'info': resource('appInfos', 'info'),
            'version': resource('appStoreVersions', 'version', versionString='1.0'),
            'editable': True, 'info_editable': True, 'creating': False, 'first': False,
            'locales': {'en-US': {'info': resource('appInfoLocalizations', 'il', locale='en-US', name='Old'),
                       'version': resource('appStoreVersionLocalizations', 'vl', locale='en-US', description='Old'),
                       'screenshots': {}}}}
    return desired, live


class RecordingClient:
    def __init__(self):
        self.calls = []
        self.sleep = lambda seconds: None

    def request(self, method, path, body=None, *args, **kwargs):
        self.calls.append((method, path, body, args, kwargs))
        if method == 'GET':
            return {'data': resource('appScreenshots', 'new', assetDeliveryState={'state': 'COMPLETE'})}
        if method == 'POST':
            return {'data': resource(body['data']['type'], 'new', **body['data']['attributes'])}
        return {}

    def all(self, path):
        raise AssertionError('Unexpected collection read: ' + path)


class ListingTests(unittest.TestCase):
    def test_der_short_and_padding(self):
        self.assertEqual(a.der_to_raw(bytes.fromhex('3006020101020102')), b'\0'*31+b'\1'+b'\0'*31+b'\2')
        integer = b'\0' + b'\x80' + b'\x11'*31
        signature = b'\x30\x46\x02\x21'+integer+b'\x02\x21'+integer
        self.assertEqual(a.der_to_raw(signature), integer[1:]*2)
        with self.assertRaises(ValueError):
            a.der_to_raw(b'bad')

    def test_jwt_signature_and_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            key, public = Path(directory)/'key.pem', Path(directory)/'public.pem'
            subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(key)], check=True, capture_output=True)
            subprocess.run(['openssl', 'ec', '-in', str(key), '-pubout', '-out', str(public)], check=True, capture_output=True)
            now = [1000]
            token = a.Token(base64.encodebytes(key.read_bytes()).decode(), 'KEY', 'ISSUER', lambda: now[0])
            encoded = token.get()
            decode = lambda text: base64.urlsafe_b64decode(text + '='*(-len(text)%4))
            h, c, s = encoded.split('.')
            self.assertEqual(json.loads(decode(h)), {'alg':'ES256','kid':'KEY','typ':'JWT'})
            self.assertEqual(json.loads(decode(c)), {'iss':'ISSUER','iat':1000,'exp':2140,'aud':'appstoreconnect-v1'})
            raw = decode(s)
            self.assertEqual(len(raw), 64)
            ints = []
            for part in (raw[:32],raw[32:]):
                part = part.lstrip(b'\0') or b'\0'
                if part[0] & 128:
                    part = b'\0' + part
                ints.append(b'\2'+bytes([len(part)])+part)
            der = b''.join(ints)
            signature = Path(directory)/'signature'
            signature.write_bytes(b'\x30'+bytes([len(der)])+der)
            verified = subprocess.run(['openssl','dgst','-sha256','-verify',str(public),'-signature',str(signature)], input=(h+'.'+c).encode(),capture_output=True)
            self.assertEqual(verified.returncode,0,verified.stderr)
            self.assertEqual(token.get(),encoded)
            now[0] = 2100
            self.assertNotEqual(token.get(),encoded)

    def test_lengths_aggregate_and_trim(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)/'ios/en-US'; p.mkdir(parents=True)
            (p.parent/'listing.json').write_text('{"bundleId":"example","platform":"IOS"}')
            (p/'subtitle.txt').write_text('é'*31, encoding='utf-8')
            (p/'keywords.txt').write_text('é'*51, encoding='utf-8')
            with self.assertRaises(a.ConfigError) as error:
                a.load_listing(directory,'ios')
            self.assertIn('subtitle.txt: 31 characters exceeds limit 30', str(error.exception))
            self.assertIn('keywords.txt: 102 bytes exceeds limit 100', str(error.exception))
            (p/'subtitle.txt').write_text('é'*30 + '  \n', encoding='utf-8')
            (p/'keywords.txt').write_text('é'*50 + '\n', encoding='utf-8')
            fields = a.load_listing(directory,'ios')['locales']['en-US']['fields']
            self.assertEqual(fields, {'subtitle': 'é'*30, 'keywords': 'é'*50})

    def test_versions(self):
        for attr in ('appVersionState','appStoreState'):
            for state in a.EDITABLE:
                version=resource('appStoreVersions','v',versionString='1.0',**{attr:state})
                self.assertEqual(a.pick_version([version]),(version,True,False))
                with self.assertRaises(a.ConfigError): a.pick_version([version],'2.0')
        self.assertEqual(a.pick_version([], '2.0', True),(None,True,True))
        with self.assertRaises(a.ConfigError): a.pick_version([],None,True)

    def test_text_patch_exact_body(self):
        desired,live=fixture(); desired['locales']['en-US']['fields']={'name':'New','description':'New description'}
        changes,_=a.plan(desired,live); client=RecordingClient(); a.apply(client,desired,live,changes)
        self.assertEqual([c[:3] for c in client.calls],[
            ('PATCH','/v1/appInfoLocalizations/il',{'data':{'type':'appInfoLocalizations','id':'il','attributes':{'name':'New'}}}),
            ('PATCH','/v1/appStoreVersionLocalizations/vl',{'data':{'type':'appStoreVersionLocalizations','id':'vl','attributes':{'description':'New description'}}})])

    def test_localization_post_exact_body(self):
        desired,live=fixture(); desired['locales']={'fr-FR':{'fields':{'subtitle':'Bonjour','keywords':''},'screenshots':{}}}
        changes,notes=a.plan(desired,live); client=RecordingClient(); a.apply(client,desired,live,changes)
        self.assertIn('unmanaged locale',notes[0])
        self.assertEqual([c[2] for c in client.calls],[
            {'data':{'type':'appInfoLocalizations','attributes':{'subtitle':'Bonjour','locale':'fr-FR'},'relationships':{'appInfo':{'data':{'type':'appInfos','id':'info'}}}}},
            {'data':{'type':'appStoreVersionLocalizations','attributes':{'keywords':'','locale':'fr-FR'},'relationships':{'appStoreVersion':{'data':{'type':'appStoreVersions','id':'version'}}}}}])

    def test_new_version_copyright_body(self):
        desired,live=fixture(); live['creating']=True; desired['config']['copyright']='2026 Example'
        class NewVersionClient(RecordingClient):
            def all(self, path):
                if path != '/v1/appStoreVersions/new/appStoreVersionLocalizations':
                    raise AssertionError(path)
                return [resource('appStoreVersionLocalizations', 'new-loc', locale='en-US')]

        changes,_=a.plan(desired,live); client=NewVersionClient(); a.apply(client,desired,live,changes,'2.0',screenshots=False)
        self.assertEqual(client.calls[0][2],{'data':{'type':'appStoreVersions','attributes':{'platform':'IOS','versionString':'2.0'},'relationships':{'app':{'data':{'type':'apps','id':'app'}}}}})
        self.assertEqual(client.calls[1][2],{'data':{'type':'appStoreVersions','id':'new','attributes':{'copyright':'2026 Example'}}})

    def test_created_version_refreshes_editable_app_info(self):
        desired, live = fixture()
        live['creating'], live['info_editable'] = True, False
        desired['locales']['en-US']['fields'] = {'name': 'New name'}
        changes, _ = a.plan(desired, live)
        class NewVersionClient(RecordingClient):
            def all(self, path):
                if path == '/v1/appStoreVersions/new/appStoreVersionLocalizations':
                    return []
                if path.endswith('/appInfos'):
                    return [resource('appInfos', 'new-info', state='PREPARE_FOR_SUBMISSION')]
                return [resource('appInfoLocalizations', 'new-localized', locale='en-US', name='Old')]
        client = NewVersionClient()
        a.apply(client, desired, live, changes, '2.0')
        self.assertEqual(client.calls[-1][1], '/v1/appInfoLocalizations/new-localized')
        self.assertEqual(live['info']['id'], 'new-info')

    def test_create_version_compares_copy_then_applies_to_new_resources(self):
        desired, _ = fixture()
        desired['locales'] = {
            'en-US': {'fields': {'description': 'New', 'keywords': 'same', 'promotional_text': 'Refreshed'},
                      'screenshots': {'APP_IPHONE_67': [{'checksum': 'same'}]}},
            'fr-FR': {'fields': {'description': 'Bonjour'}, 'screenshots': {}},
        }
        old = resource('appStoreVersions', 'old', appVersionState='READY_FOR_DISTRIBUTION', versionString='1.0',
                       createdDate='2026-11-01T10:00:00Z')
        replaced = resource('appStoreVersions', 'older', appVersionState='REPLACED_WITH_NEW_VERSION',
                            versionString='0.9', createdDate='2026-10-01T10:00:00Z')
        new = resource('appStoreVersions', 'new', appVersionState='PREPARE_FOR_SUBMISSION', versionString='2.0')
        transport = FakeTransport({
            ('GET', '/v1/apps'): (200, {'data': [resource('apps', 'app')]}),
            ('GET', '/v1/apps/app/appStoreVersions'): (200, {'data': [replaced, old]}),
            ('GET', '/v1/apps/app/appInfos'): (200, {'data': []}),
            ('GET', '/v1/appStoreVersions/old/appStoreVersionLocalizations'): (
                200, {'data': [resource('appStoreVersionLocalizations', 'old-loc', locale='en-US',
                                       description='Old', keywords='same', promotionalText='Previous')]}),
            ('GET', '/v1/appStoreVersionLocalizations/old-loc/appScreenshotSets'): (
                200, {'data': [resource('appScreenshotSets', 'old-set', screenshotDisplayType='APP_IPHONE_67')]}),
            ('GET', '/v1/appScreenshotSets/old-set/appScreenshots'): (200, {'data': [screenshot('old-shot', 'same')]}),
            ('POST', '/v1/appStoreVersions'): (201, {'data': new}),
            ('GET', '/v1/appStoreVersions/new/appStoreVersionLocalizations'): (
                200, {'data': [resource('appStoreVersionLocalizations', 'new-loc', locale='en-US',
                                       description='Old', keywords='same', promotionalText='Refreshed')]}),
            ('GET', '/v1/appStoreVersionLocalizations/new-loc/appScreenshotSets'): (
                200, {'data': [resource('appScreenshotSets', 'new-set', screenshotDisplayType='APP_IPHONE_67')]}),
            ('GET', '/v1/appScreenshotSets/new-set/appScreenshots'): (200, {'data': [screenshot('new-shot', 'same')]}),
            ('PATCH', '/v1/appStoreVersionLocalizations/new-loc'): (204, None),
            ('POST', '/v1/appStoreVersionLocalizations'): (
                201, {'data': resource('appStoreVersionLocalizations', 'new-fr', locale='fr-FR')}),
        })
        client = transport.client()
        live = a.read_live(client, desired, '2.0', True)
        changes, notes = a.plan(desired, live)
        self.assertIn('starts with a copy of the localizations and screenshots from version 1.0', a.render(changes, notes))
        self.assertEqual([(c['locale'], c['field'], c['old']) for c in changes],
                         [('en-US', 'description', 'Old'), ('en-US', 'promotionalText', 'Previous'),
                          ('fr-FR', 'description', None)])
        self.assertEqual({method for method, _, _ in transport.calls}, {'GET'})

        a.apply(client, desired, live, changes, '2.0')
        self.assertIn(('GET', '/v1/appScreenshotSets/new-set/appScreenshots', None), transport.calls)
        writes = [(method, path, payload['data']) for method, path, payload in transport.calls if method != 'GET']
        self.assertEqual([(method, path) for method, path, _ in writes], [
            ('POST', '/v1/appStoreVersions'),
            ('PATCH', '/v1/appStoreVersionLocalizations/new-loc'),
            ('POST', '/v1/appStoreVersionLocalizations'),
        ])
        self.assertEqual(writes[1][2]['attributes'], {'description': 'New'})
        self.assertEqual(writes[2][2]['attributes'], {'description': 'Bonjour', 'locale': 'fr-FR'})
        self.assertEqual(writes[2][2]['relationships']['appStoreVersion']['data']['id'], 'new')

        old['attributes']['appVersionState'] = 'DEVELOPER_REMOVED_FROM_SALE'
        live = a.read_live(client, desired, '2.0', True)
        self.assertEqual(live['version']['id'], 'old')

    def test_needs_new_version_blocks_all_writes(self):
        desired,live=fixture(); live['editable']=False
        desired['locales']['en-US']['fields']={'description':'Changed','promotional_text':'Allowed'}
        changes,_=a.plan(desired,live)
        self.assertEqual([c['blocked'] for c in changes],['needs a new version',None])
        client=RecordingClient()
        with self.assertRaises(a.APIError): a.apply(client,desired,live,changes)
        self.assertEqual(client.calls,[])
        desired['locales']['en-US']['fields']={'promotional_text':'Allowed'}
        changes,_=a.plan(desired,live); a.apply(client,desired,live,changes)
        self.assertEqual(client.calls[0][0],'PATCH')

    def test_first_version_whats_new_skips(self):
        desired,live=fixture(); live['first']=True
        desired['locales']['en-US']['fields']={'whats_new':'New'}
        changes,notes=a.plan(desired,live)
        self.assertEqual(changes,[]); self.assertIn('first version',notes[0])

    def test_screenshot_comparison(self):
        wanted=[{'name':'a','checksum':'a'},{'name':'b','checksum':'b'}]
        existing=[screenshot('1','a'), screenshot('2','b','UPLOAD_COMPLETE')]
        p=a.screenshot_plan(wanted,existing)
        self.assertFalse(p['reorder']); self.assertEqual(p['uploads'],[]); self.assertEqual(p['deletes'],[])
        p=a.screenshot_plan(wanted,list(reversed(existing)))
        self.assertTrue(p['reorder']); self.assertEqual(p['order'],[{'id':'1'},{'id':'2'}])
        p=a.screenshot_plan([{'name':'c','checksum':'c'}],existing)
        self.assertEqual(p['deletes'],['1','2']); self.assertEqual(p['uploads'],[{'name':'c','checksum':'c'}])

    def test_screenshot_unfinished_assets_never_match(self):
        wanted = [{'name': 'a', 'checksum': 'a'}]
        for state in ('FAILED', 'AWAITING_UPLOAD', 'PROCESSING', None):
            with self.subTest(state=state):
                plan = a.screenshot_plan(wanted, [screenshot('old', 'a', state)])
                self.assertEqual(plan['uploads'], wanted)
                self.assertEqual(plan['deletes'], ['old'])

    def test_upload_deletes_failed_or_timed_out_asset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.png'
            path.write_bytes(b'png')
            asset = {'path': str(path), 'name': path.name, 'checksum': a.hashlib.md5(b'png').hexdigest()}
            screenshot_path = '/v1/appScreenshots/reserved'
            for state, polls, error in [('FAILED', 1, 'processing failed.*asset rejected'),
                                        ('UPLOAD_COMPLETE', 60, 'timed out: image.png')]:
                with self.subTest(state=state):
                    transport = FakeTransport({
                        ('POST', '/v1/appScreenshots'): (
                            201, {'data': resource('appScreenshots', 'reserved', uploadOperations=[])}),
                        ('PATCH', screenshot_path): (204, None),
                        ('GET', screenshot_path): (200, {'data': resource('appScreenshots', 'reserved',
                            assetDeliveryState={'state': state, 'errors': ['asset rejected']})}),
                        ('DELETE', screenshot_path): (204, None),
                    })
                    with self.assertRaisesRegex(a.APIError, error):
                        a.upload(transport.client(), 'set', asset)
                    self.assertEqual(transport.calls.count(('GET', screenshot_path, None)), polls)
                    self.assertEqual(transport.calls[-1], ('DELETE', screenshot_path, None))

    def test_asset_flow_and_part_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'image.png'; file.write_bytes(b'abcdef')
            calls=[]
            class UploadClient(RecordingClient):
                def request(self,method,path,body=None,*args,**kwargs):
                    calls.append((method,path,body,args,kwargs))
                    if method=='POST':
                        return {'data':resource('appScreenshots','shot',uploadOperations=[{'method':'PUT','url':'https://upload.invalid','offset':2,'length':3,'requestHeaders':[{'name':'Part','value':'yes'}]}])}
                    return {'data':resource('appScreenshots','shot',assetDeliveryState={'state':'COMPLETE'})}
            asset={'path':str(file),'name':'image.png','checksum':a.hashlib.md5(b'abcdef').hexdigest()}
            self.assertEqual(a.upload(UploadClient(),'set',asset),'shot')
            self.assertEqual(calls[0][2],{'data':{'type':'appScreenshots','attributes':{'fileName':'image.png','fileSize':6},'relationships':{'appScreenshotSet':{'data':{'type':'appScreenshotSets','id':'set'}}}}})
            self.assertEqual(calls[1],('PUT','https://upload.invalid',b'cde',({'Part':'yes'},),{'raw':True}))
            self.assertEqual(calls[2][2]['data']['attributes'],{'uploaded':True,'sourceFileChecksum':asset['checksum']})

    def test_screenshot_reorder_apply_and_unmanaged(self):
        desired,live=fixture()
        existing=[screenshot('a','a'), screenshot('b','b')]
        live['locales']['en-US']['screenshots']={'APP_DESKTOP':{'id':'set','images':existing},'OTHER':{'id':'other','images':[]}}
        desired['locales']['en-US']['screenshots']={'APP_DESKTOP':[{'checksum':'b'},{'checksum':'a'}]}
        changes,notes=a.plan(desired,live)
        relationship = '/v1/appScreenshotSets/set/relationships/appScreenshots'
        images = '/v1/appScreenshotSets/set/appScreenshots'
        transport = FakeTransport({
            ('PATCH', relationship): (204, None),
            ('GET', images): (200, {'data': list(reversed(existing))}),
        })
        a.apply(transport.client(),desired,live,changes)
        self.assertEqual(transport.calls, [
            ('PATCH', relationship, {'data': [{'type': 'appScreenshots', 'id': 'b'},
                                              {'type': 'appScreenshots', 'id': 'a'}]}),
            ('GET', images, None),
        ])
        self.assertTrue(any('OTHER (unmanaged' in n for n in notes))
        transport.responses['GET', images] = (200, {'data': existing})
        with self.assertRaisesRegex(a.APIError, 'Screenshot order differs for set set'):
            a.apply(transport.client(), desired, live, changes)

    def test_pagination_retry_and_raw_no_token(self):
        calls=[]; sleeps=[]
        responses=[(429,{'Retry-After':'3'},b'{}'),(200,{},b'{"data":[1],"links":{"next":"/second"}}'),(200,{},b'{"data":[2]}'),(200,{},b'')]
        def transport(*args): calls.append(args); return responses.pop(0)
        token=mock.Mock(); token.get.return_value='secret'
        client=a.Client('http://localhost',token,transport,sleeps.append)
        self.assertEqual(client.all('/first'),[1,2]); self.assertEqual(sleeps,[3])
        client.request('PUT','https://assets.invalid',b'png',{'Content-Type':'image/png'},raw=True)
        self.assertNotIn('Authorization',calls[-1][2])

    def test_errors(self):
        for status,content,expected in [(403,b'{"errors":[{"detail":"denied"}]}','App Manager or Admin'),(400,b'{"errors":[{"detail":"Bad field"}]}','Bad field')]:
            client=a.Client('http://localhost',mock.Mock(),lambda *args:(status,{},content))
            client.token.get.return_value='token'
            with self.assertRaisesRegex(a.APIError,expected): client.request('GET','/test')

    def test_auth_errors_have_distinct_guidance_and_include_details(self):
        for status, guidance in [
            (401, 'Token was rejected.*key ID, issuer ID, key itself, and clock'),
            (403, 'the key lacks access: editing a listing needs an App Manager or Admin key'),
        ]:
            with self.subTest(status=status):
                transport = FakeTransport({
                    ('GET', '/auth'): (status, {'errors': [{'detail': 'First detail'}, {'detail': 'Second detail'}]}),
                })
                with self.assertRaisesRegex(a.APIError, guidance + r'.*First detail; Second detail'):
                    transport.client().request('GET', '/auth')

    def test_status_outside_success_range(self):
        for status in (199, 302, 399):
            with self.subTest(status=status):
                transport = FakeTransport({('GET', '/test'): (status, [])})
                with self.assertRaisesRegex(a.APIError, 'HTTP %s' % status):
                    transport.client().request('GET', '/test')

    def test_redirect_does_not_send_authorization_to_destination(self):
        headers = Message()
        headers['Location'] = 'https://destination.invalid/listing'
        urls = []

        def respond(request):
            urls.append(request.full_url)
            if request.full_url == 'https://origin.invalid/listing':
                self.assertEqual(request.get_header('Authorization'), 'Bearer fake-token')
                response = addinfourl(io.BytesIO(b''), headers, request.full_url, 302)
                response.msg = 'Found'
                return response
            raise AssertionError('Unexpected request to redirect destination')

        client = a.Client('https://origin.invalid', mock.Mock(get=mock.Mock(return_value='fake-token')))
        with mock.patch.object(HTTPSHandler, 'https_open', side_effect=respond):
            with self.assertRaisesRegex(a.APIError, 'HTTP 302'):
                client.request('GET', '/listing')
        self.assertEqual(urls, ['https://origin.invalid/listing'])

    def test_missing_openssl_exits_two(self):
        with mock.patch.dict(os.environ, CREDS), mock.patch.object(a.subprocess, 'run', side_effect=FileNotFoundError), \
                mock.patch.object(a, 'Client') as factory, mock.patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(a.main(['--no-screenshots']), 2)
        factory.assert_not_called()
        self.assertIn('openssl is required', output.getvalue())
        self.assertIn('not found on PATH', output.getvalue())

    def test_transport_errors_become_api_errors_and_exit_one(self):
        client = a.Client('https://asc.invalid', mock.Mock(get=mock.Mock(return_value='token')))
        for error in (http.client.IncompleteRead(b'partial'), ConnectionResetError('signed-url'),
                      http.client.BadStatusLine('signed-url')):
            with self.subTest(error=type(error).__name__), mock.patch.object(a.OPENER, 'open') as open_response:
                response = open_response.return_value
                response.code, response.headers = 200, {}
                response.read.side_effect = error
                with self.assertRaisesRegex(a.APIError, type(error).__name__):
                    client.all('/v1/apps')
                with mock.patch.object(a, 'Client', return_value=client), mock.patch.dict(os.environ, CREDS), \
                        mock.patch.object(a.Token, 'get', return_value='token'), \
                        mock.patch('sys.stdout', new_callable=io.StringIO) as output:
                    self.assertEqual(a.main(['--no-screenshots']), 1)
                self.assertIn(type(error).__name__, output.getvalue())
                self.assertNotIn('signed-url', output.getvalue())

    def test_success_without_required_data_reports_method_and_path(self):
        desired, live = fixture()
        live['creating'] = True
        transport = FakeTransport({
            ('GET', '/v1/apps'): (200, {}),
            ('POST', '/v1/appStoreVersions'): (201, {}),
        })
        client = transport.client()
        with self.assertRaisesRegex(a.APIError, 'GET /v1/apps.*data'):
            client.all('/v1/apps')
        with self.assertRaisesRegex(a.APIError, 'POST /v1/appStoreVersions.*data'):
            a.apply(client, desired, live, [], '2.0')

    def test_summary_written_when_print_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / 'summary.md'
            with mock.patch.object(a, 'load_listing', side_effect=a.ConfigError('bad listing')), \
                    mock.patch('builtins.print', side_effect=BrokenPipeError):
                with self.assertRaises(BrokenPipeError):
                    a.main(['--summary', str(summary)])
            self.assertIn('Error: bad listing', summary.read_text())

    def test_pull_layout(self):
        desired,live=fixture()
        with tempfile.TemporaryDirectory() as directory:
            a.pull(desired,live,directory,'ios'); folder=Path(directory)/'ios'
            self.assertEqual((folder/'en-US/name.txt').read_text(),'Old\n')
            self.assertEqual((folder/'en-US/description.txt').read_text(),'Old\n')
            self.assertFalse((folder/'en-US/subtitle.txt').exists())
            self.assertEqual(json.loads((folder/'listing.json').read_text())['platform'],'IOS')

    def test_pull_ignores_invalid_screenshot_config_and_skips_screenshot_reads(self):
        transport = FakeTransport({
            ('GET', '/v1/apps'): (200, {'data': [resource('apps', 'app')]}),
            ('GET', '/v1/apps/app/appStoreVersions'): (200, {'data': [
                resource('appStoreVersions', 'version', appVersionState='READY_FOR_DISTRIBUTION', versionString='1.0')]}),
            ('GET', '/v1/apps/app/appInfos'): (200, {'data': []}),
            ('GET', '/v1/appStoreVersions/version/appStoreVersionLocalizations'): (200, {'data': [
                resource('appStoreVersionLocalizations', 'loc', locale='en-US', description='Live copy')]}),
        })
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'listing' / 'ios'
            source.mkdir(parents=True)
            (source / 'listing.json').write_text('{"bundleId":"example","platform":"IOS","screenshots":42}')
            out = Path(directory) / 'out'
            with mock.patch.object(a, 'Client', return_value=transport.client()), mock.patch.dict(os.environ, CREDS), \
                    mock.patch.object(a.Token, 'get', return_value='token'), mock.patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(a.main(['--mode', 'pull', '--listing', str(source.parent), '--out', str(out)]), 0)
            self.assertEqual((out / 'ios/en-US/description.txt').read_text(), 'Live copy\n')
            self.assertEqual(json.loads((out / 'ios/listing.json').read_text())['screenshots'], [])
        self.assertEqual({(method, path) for method, path, _ in transport.calls}, set(transport.responses))

    def test_pull_prefers_the_version_being_prepared(self):
        # The version in preparation holds the newest text; the live one is older.
        transport = FakeTransport({
            ('GET', '/v1/apps'): (200, {'data': [resource('apps', 'app')]}),
            ('GET', '/v1/apps/app/appStoreVersions'): (200, {'data': [
                resource('appStoreVersions', 'live', appVersionState='READY_FOR_DISTRIBUTION', versionString='1.0'),
                resource('appStoreVersions', 'next', appVersionState='PREPARE_FOR_SUBMISSION', versionString='1.1')]}),
            ('GET', '/v1/apps/app/appInfos'): (200, {'data': [
                resource('appInfos', 'info-live', state='READY_FOR_DISTRIBUTION'),
                resource('appInfos', 'info-next', state='PREPARE_FOR_SUBMISSION')]}),
            ('GET', '/v1/appInfos/info-next/appInfoLocalizations'): (200, {'data': [
                resource('appInfoLocalizations', 'il', locale='en-US', name='Next name')]}),
            ('GET', '/v1/appStoreVersions/next/appStoreVersionLocalizations'): (200, {'data': [
                resource('appStoreVersionLocalizations', 'loc', locale='en-US', description='Prepared copy')]}),
        })
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'listing' / 'ios'
            source.mkdir(parents=True)
            (source / 'listing.json').write_text('{"bundleId":"example","platform":"IOS"}')
            out = Path(directory) / 'out'
            with mock.patch.object(a, 'Client', return_value=transport.client()), mock.patch.dict(os.environ, CREDS), \
                    mock.patch.object(a.Token, 'get', return_value='token'), mock.patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(a.main(['--mode', 'pull', '--listing', str(source.parent), '--out', str(out)]), 0)
            self.assertEqual((out / 'ios/en-US/description.txt').read_text(), 'Prepared copy\n')
            self.assertEqual((out / 'ios/en-US/name.txt').read_text(), 'Next name\n')
        self.assertTrue(all(method == 'GET' for method, _, _ in transport.calls))

    def test_diff_has_no_writes(self):
        desired,live=fixture(); desired['locales']['en-US']['fields']={'name':'Changed'}
        with mock.patch.object(a,'load_listing',return_value=desired), mock.patch.object(a,'read_live',return_value=live), mock.patch.object(a.Token,'get',return_value='token'), mock.patch.object(a,'http_transport',side_effect=AssertionError('No HTTP expected')), mock.patch.object(a,'apply',side_effect=AssertionError('No apply allowed')), mock.patch.dict(os.environ,{'ASC_KEY':'-----BEGIN PRIVATE KEY-----','ASC_KEY_ID':'id','ASC_ISSUER_ID':'issuer'}), mock.patch('sys.stdout',new_callable=io.StringIO):
            self.assertEqual(a.main(['--mode','diff']),0)

    def test_read_live_diff_only_gets(self):
        desired,_=fixture(); calls=[]
        def transport(method,url,headers,data):
            calls.append(method)
            if '/apps?' in url: rows=[resource('apps','app')]
            elif 'appStoreVersions?' in url: rows=[resource('appStoreVersions','version',appVersionState='PREPARE_FOR_SUBMISSION',versionString='1.0')]
            elif url.endswith('/appInfos'): rows=[resource('appInfos','info',appStoreState='PREPARE_FOR_SUBMISSION')]
            elif url.endswith('/appInfoLocalizations'): rows=[resource('appInfoLocalizations','il',locale='en-US')]
            elif url.endswith('/appStoreVersionLocalizations'): rows=[resource('appStoreVersionLocalizations','vl',locale='en-US')]
            else: rows=[]
            return 200,{},json.dumps({'data':rows}).encode()
        token=mock.Mock(); token.get.return_value='token'; client=a.Client('http://localhost',token,transport)
        live=a.read_live(client,desired); a.plan(desired,live)
        self.assertTrue(calls); self.assertEqual(set(calls),{'GET'})

    def test_validation_before_credentials_or_network(self):
        with mock.patch.object(a,'load_listing',side_effect=a.ConfigError('subtitle.txt: exceeds limit 30')), mock.patch.object(a.Token,'get',side_effect=AssertionError('No token')), mock.patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(a.main([]),2); self.assertIn('limit 30',output.getvalue())

    def test_apply_validates_all_locales_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            platform = Path(directory) / 'ios'
            for locale in ('en-US', 'fr-FR', 'ja'):
                (platform / locale).mkdir(parents=True)
            (platform / 'listing.json').write_text('{"bundleId":"example","platform":"IOS"}')
            (platform / 'en-US/description.txt').write_text('Valid change')
            (platform / 'fr-FR/keywords.txt').write_text('é' * 51, encoding='utf-8')
            (platform / 'ja/subtitle.txt').write_text('語' * 31, encoding='utf-8')
            with mock.patch.dict(os.environ, CREDS), mock.patch.object(a.Token, 'get', return_value='token'), \
                    mock.patch.object(a, 'Client') as factory, mock.patch('sys.stdout', new_callable=io.StringIO) as output:
                self.assertEqual(a.main(['--mode', 'apply', '--listing', directory]), 2)
            factory.assert_not_called()
            self.assertIn('fr-FR/keywords.txt: 102 bytes', output.getvalue())
            self.assertIn('ja/subtitle.txt: 31 characters', output.getvalue())


if __name__ == '__main__':
    unittest.main()
