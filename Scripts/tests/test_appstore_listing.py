"""Offline contract tests: no App Store Connect credentials or network required."""
import base64
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('listing', Path(__file__).resolve().parents[1] / 'appstore_listing.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def resource(kind, identity, **attributes):
    return {'type': kind, 'id': identity, 'attributes': attributes}


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
            (p/'subtitle.txt').write_text('x'*31)
            (p/'keywords.txt').write_text('x'*101)
            with self.assertRaises(a.ConfigError) as error:
                a.load_listing(directory,'ios')
            self.assertIn('subtitle.txt',str(error.exception)); self.assertIn('limit 30',str(error.exception))
            self.assertIn('keywords.txt',str(error.exception)); self.assertIn('limit 100',str(error.exception))
            (p/'subtitle.txt').write_text('trim me  \n')
            (p/'keywords.txt').write_text('')
            fields = a.load_listing(directory,'ios')['locales']['en-US']['fields']
            self.assertEqual(fields,{'subtitle':'trim me','keywords':''})

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
        changes,_=a.plan(desired,live); client=RecordingClient(); a.apply(client,desired,live,changes,'2.0')
        self.assertEqual(client.calls[0][2],{'data':{'type':'appStoreVersions','attributes':{'platform':'IOS','versionString':'2.0'},'relationships':{'app':{'data':{'type':'apps','id':'app'}}}}})
        self.assertEqual(client.calls[1][2],{'data':{'type':'appStoreVersions','id':'new','attributes':{'copyright':'2026 Example'}}})

    def test_created_version_refreshes_editable_app_info(self):
        desired, live = fixture()
        live['creating'], live['info_editable'] = True, False
        desired['locales']['en-US']['fields'] = {'name': 'New name'}
        changes, _ = a.plan(desired, live)
        class NewVersionClient(RecordingClient):
            def all(self, path):
                if path.endswith('/appInfos'):
                    return [resource('appInfos', 'new-info', state='PREPARE_FOR_SUBMISSION')]
                return [resource('appInfoLocalizations', 'new-localized', locale='en-US', name='Old')]
        client = NewVersionClient()
        a.apply(client, desired, live, changes, '2.0')
        self.assertEqual(client.calls[-1][1], '/v1/appInfoLocalizations/new-localized')
        self.assertEqual(live['info']['id'], 'new-info')

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
        existing=[resource('appScreenshots','1',sourceFileChecksum='a'),resource('appScreenshots','2',sourceFileChecksum='b')]
        p=a.screenshot_plan(wanted,existing)
        self.assertFalse(p['reorder']); self.assertEqual(p['uploads'],[]); self.assertEqual(p['deletes'],[])
        p=a.screenshot_plan(wanted,list(reversed(existing)))
        self.assertTrue(p['reorder']); self.assertEqual(p['order'],[{'id':'1'},{'id':'2'}])
        p=a.screenshot_plan([{'name':'c','checksum':'c'}],existing)
        self.assertEqual(p['deletes'],['1','2']); self.assertEqual(p['uploads'],[{'name':'c','checksum':'c'}])

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
        existing=[resource('appScreenshots','a',sourceFileChecksum='a'),resource('appScreenshots','b',sourceFileChecksum='b')]
        live['locales']['en-US']['screenshots']={'APP_DESKTOP':{'id':'set','images':existing},'OTHER':{'id':'other','images':[]}}
        desired['locales']['en-US']['screenshots']={'APP_DESKTOP':[{'checksum':'b'},{'checksum':'a'}]}
        changes,notes=a.plan(desired,live); client=RecordingClient(); a.apply(client,desired,live,changes)
        self.assertEqual(client.calls[0][:3],('PATCH','/v1/appScreenshotSets/set/relationships/appScreenshots',{'data':[{'type':'appScreenshots','id':'b'},{'type':'appScreenshots','id':'a'}]}))
        self.assertTrue(any('OTHER (unmanaged' in n for n in notes))

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

    def test_pull_layout(self):
        desired,live=fixture()
        with tempfile.TemporaryDirectory() as directory:
            a.pull(desired,live,directory,'ios'); folder=Path(directory)/'ios'
            self.assertEqual((folder/'en-US/name.txt').read_text(),'Old\n')
            self.assertEqual((folder/'en-US/description.txt').read_text(),'Old\n')
            self.assertFalse((folder/'en-US/subtitle.txt').exists())
            self.assertEqual(json.loads((folder/'listing.json').read_text())['platform'],'IOS')

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


if __name__ == '__main__':
    unittest.main()
