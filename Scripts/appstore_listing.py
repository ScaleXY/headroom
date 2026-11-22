#!/usr/bin/env python3
"""Compare, update or export App Store listing metadata using repository files.

    python3 -I Scripts/appstore_listing.py --mode diff --platform ios
    python3 -I Scripts/appstore_listing.py --mode apply --version 1.2.3 --create-version
    python3 -I Scripts/appstore_listing.py --mode pull --out /tmp/listing

Requires openssl and ASC_KEY (PEM or base64), ASC_KEY_ID and ASC_ISSUER_ID.
No dependency installation is needed. diff and pull never write to the API.
"""

import argparse
import base64
import collections
import difflib
import email.utils
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
INFO = {'name': 'name', 'subtitle': 'subtitle', 'privacy_url': 'privacyPolicyUrl'}
VERSION = {'promotional_text': 'promotionalText', 'description': 'description',
           'keywords': 'keywords', 'whats_new': 'whatsNew', 'support_url': 'supportUrl',
           'marketing_url': 'marketingUrl'}
LIMITS = {'name': 30, 'subtitle': 30, 'promotional_text': 170, 'keywords': 100,
          'description': 4000, 'whats_new': 4000}
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED',
            'METADATA_REJECTED', 'INVALID_BINARY'}
LIVE = {'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION'}
MATCHABLE_SCREENSHOTS = {'COMPLETE', 'UPLOAD_COMPLETE'}


class ConfigError(Exception):
    pass


class APIError(Exception):
    pass


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def der_to_raw(signature):
    """Decode ASN.1 lengths explicitly; OpenSSL may pad either positive integer."""
    pos = 0

    def read(tag):
        nonlocal pos
        if pos >= len(signature) or signature[pos] != tag:
            raise ValueError('Invalid DER signature')
        pos += 1
        size = signature[pos]
        pos += 1
        if size & 128:
            n = size & 127
            size = int.from_bytes(signature[pos:pos + n], 'big')
            pos += n
        end = pos + size
        if end > len(signature):
            raise ValueError('Truncated DER signature')
        result = signature[pos:end]
        pos = end
        return result

    sequence = read(48)
    if pos != len(signature):
        raise ValueError('Trailing DER data')
    signature, pos = sequence, 0
    values = [read(2), read(2)]
    if pos != len(signature):
        raise ValueError('Trailing DER integers')
    result = b''
    for value in values:
        if not value or value[0] & 128:
            raise ValueError('Invalid DER integer')
        value = value.lstrip(b'\0')
        if len(value) > 32:
            raise ValueError('DER integer exceeds P-256')
        result += value.rjust(32, b'\0')
    return result


class Token:
    def __init__(self, key, key_id, issuer, clock=time.time):
        try:
            self.key = key.encode() if '-----BEGIN' in key else base64.b64decode(''.join(key.split()), validate=True)
        except ValueError as exc:
            raise ConfigError('ASC_KEY must be PEM or base64 of PEM') from exc
        self.key_id, self.issuer, self.clock = key_id, issuer, clock
        self.value, self.expires = None, 0

    def get(self):
        now = int(self.clock())
        if self.value and now < self.expires - 60:
            return self.value
        self.expires = now + 1140
        header = {'alg': 'ES256', 'kid': self.key_id, 'typ': 'JWT'}
        claims = {'iss': self.issuer, 'iat': now, 'exp': self.expires, 'aud': 'appstoreconnect-v1'}
        payload = '.'.join(b64(json.dumps(x, separators=(',', ':')).encode()) for x in (header, claims))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'key.p8'
            path.write_bytes(self.key)
            path.chmod(0o600)
            try:
                result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(path)],
                                        input=payload.encode(), capture_output=True)
            except FileNotFoundError as exc:
                raise ConfigError('openssl is required to sign an ES256 JWT but was not found on PATH') from exc
        if result.returncode:
            raise ConfigError('ASC_KEY could not sign an ES256 JWT with openssl')
        try:
            self.value = payload + '.' + b64(der_to_raw(result.stdout))
        except (ValueError, IndexError) as exc:
            raise ConfigError('ASC_KEY must be a P-256 private key') from exc
        return self.value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def http_transport(method, url, headers, data):
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        response = OPENER.open(request, timeout=60)
    except urllib.error.HTTPError as exc:
        response = exc
    with response:
        return response.code, dict(response.headers), response.read()


class Client:
    def __init__(self, base, token, transport=http_transport, sleep=time.sleep):
        self.base, self.token, self.transport, self.sleep = base.rstrip('/'), token, transport, sleep

    def request(self, method, path, body=None, headers=None, raw=False, *, expect=None):
        url = path if raw else urllib.parse.urljoin(self.base + '/', path)
        if not raw and urllib.parse.urlsplit(url)[:2] != urllib.parse.urlsplit(self.base)[:2]:
            raise APIError('Refusing API pagination to a different origin')
        data = body if raw else (json.dumps(body).encode() if body is not None else None)
        for attempt in range(5):
            hdr = dict(headers or {})
            if not raw:
                hdr.update({'Authorization': 'Bearer ' + self.token.get(), 'Content-Type': 'application/json'})
            try:
                status, response_headers, response_body = self.transport(method, url, hdr, data)
            except (OSError, http.client.HTTPException, ValueError) as exc:
                # Upload URLs can contain signatures.
                raise APIError('HTTP connection failed (' + type(exc).__name__ + ')') from exc
            if status == 429 or 500 <= status <= 599:
                if attempt < 4:
                    retry = next((v for k, v in response_headers.items() if k.lower() == 'retry-after'), None)
                    delay = 2 ** attempt
                    if retry:
                        try:
                            delay = max(0, float(retry))
                        except ValueError:
                            try:
                                delay = max(0, email.utils.parsedate_to_datetime(retry).timestamp() - time.time())
                            except (ValueError, TypeError):
                                pass
                    self.sleep(delay)
                    continue
            if not 200 <= status < 300:
                try:
                    details = '; '.join(e.get('detail', e.get('title', 'API error'))
                                        for e in json.loads(response_body).get('errors', []))
                except (AttributeError, ValueError, TypeError):
                    details = ''
                if status == 401:
                    raise APIError(('Token was rejected (HTTP 401). Check the key ID, issuer ID, key itself, and clock. ' +
                                    details).rstrip())
                if status == 403:
                    raise APIError(('HTTP 403: the key lacks access: editing a listing needs an App Manager or Admin key. ' +
                                    details).rstrip())
                raise APIError('HTTP %s: %s' % (status, details or 'request failed'))
            if raw:
                return {}
            try:
                response = json.loads(response_body) if response_body else {}
            except ValueError as exc:
                raise APIError('%s %s: API returned invalid JSON' % (method, path)) from exc
            if expect and not (isinstance(response, dict) and isinstance(response.get('data'), expect)):
                raise APIError('%s %s: API response is missing or has invalid data' % (method, path))
            return response

    def all(self, path):
        result, seen = [], set()
        while path:
            if path in seen:
                raise APIError('API pagination repeated a page')
            seen.add(path)
            page = self.request('GET', path, expect=list)
            result.extend(page['data'])
            path = page.get('links', {}).get('next')
        return result


def load_listing(directory, platform, screenshots=True, root=ROOT):
    directory = Path(directory) / platform
    problems, locales = [], {}
    try:
        config = json.loads((directory / 'listing.json').read_text(encoding='utf-8'))
        if not isinstance(config, dict):
            raise ValueError('expected an object')
    except (OSError, ValueError) as exc:
        raise ConfigError('%s: %s' % (directory / 'listing.json', exc)) from exc
    expected = {'ios': 'IOS', 'macos': 'MAC_OS'}[platform]
    if not isinstance(config.get('bundleId'), str) or not config.get('bundleId'):
        problems.append('listing.json: bundleId must be a nonempty string')
    if config.get('platform') != expected:
        problems.append('listing.json: platform must be ' + expected)
    if 'copyright' in config and not isinstance(config['copyright'], str):
        problems.append('listing.json: copyright must be text')
    for folder in sorted(directory.iterdir()):
        if not folder.is_dir() or folder.name.startswith('.'):
            continue
        fields = {}
        for field in dict(INFO, **VERSION):
            path = folder / (field + '.txt')
            if path.exists():
                try:
                    value = path.read_text(encoding='utf-8').rstrip()
                    size, unit = (len(value.encode('utf-8')), 'bytes') if field == 'keywords' else (len(value), 'characters')
                    if field in LIMITS and size > LIMITS[field]:
                        problems.append('%s: %s %s exceeds limit %s' % (path, size, unit, LIMITS[field]))
                    fields[field] = value
                except (OSError, UnicodeError) as exc:
                    problems.append('%s: %s' % (path, exc))
        locales[folder.name] = {'fields': fields, 'screenshots': {}}
    mappings = config.get('screenshots', []) if screenshots else []
    if not isinstance(mappings, list):
        problems.append('listing.json: screenshots must be a list')
        mappings = []
    for item in mappings:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k] for k in ('displayType', 'folder')):
            problems.append('listing.json: each screenshot entry needs displayType and folder strings')
            continue
        locale = item.get('locale')
        if locale is not None and locale not in locales:
            problems.append('listing.json: screenshot locale has no folder: ' + str(locale))
            continue
        folder = root / item['folder']
        if Path(item['folder']).is_absolute() or not folder.resolve().is_relative_to(root.resolve()):
            problems.append('listing.json: screenshot folder must be relative to the repo root')
            continue
        files = sorted(folder.glob('*.png')) if folder.is_dir() else []
        if not files:
            problems.append('%s: screenshot folder must exist and contain PNGs' % folder)
        if len(files) > 10:
            problems.append('%s: maximum 10 screenshots per set' % folder)
        assets = []
        for path in files:
            try:
                data = path.read_bytes()
                if not data.startswith(b'\x89PNG\r\n\x1a\n'):
                    problems.append('%s: invalid PNG signature' % path)
                assets.append({'path': str(path), 'name': path.name, 'size': len(data), 'checksum': hashlib.md5(data).hexdigest()})
            except OSError as exc:
                problems.append('%s: %s' % (path, exc))
        for name, values in locales.items():
            if locale is None or name == locale:
                if item['displayType'] in values['screenshots']:
                    problems.append('listing.json: duplicate screenshot mapping for ' + name + '/' + item['displayType'])
                values['screenshots'][item['displayType']] = assets
    if problems:
        raise ConfigError('\n'.join(problems))
    return {'config': config, 'locales': locales}


def state(resource):
    attrs = resource['attributes']
    return attrs.get('appVersionState') or attrs.get('state') or attrs.get('appStoreState')


def pick_version(versions, version=None, create=False):
    editable = [v for v in versions if state(v) in EDITABLE]
    if len(editable) > 1:
        raise ConfigError('More than one editable version; resolve this in App Store Connect')
    if editable:
        selected = editable[0]
        if version and selected['attributes']['versionString'] != version:
            raise ConfigError('--version does not match the editable version')
        return selected, True, False
    if create:
        if not version:
            raise ConfigError('--create-version requires --version')
        if any(v['attributes']['versionString'] == version for v in versions):
            raise ConfigError('--version already exists and is not editable')
        return None, True, True
    live = next((v for v in versions if state(v) in LIVE), None)
    if version and (not live or live['attributes']['versionString'] != version):
        raise ConfigError('--version does not match a live or editable version; use --create-version')
    return live, False, False


def read_version_locales(client, version, locales, screenshots):
    for localized in client.all('/v1/appStoreVersions/%s/appStoreVersionLocalizations' % version['id']):
        entry = locales.setdefault(localized['attributes']['locale'], {'screenshots': {}})
        entry['version'] = localized
        if screenshots:
            for resource in client.all('/v1/appStoreVersionLocalizations/%s/appScreenshotSets' % localized['id']):
                images = client.all('/v1/appScreenshotSets/%s/appScreenshots' % resource['id'])
                entry['screenshots'][resource['attributes']['screenshotDisplayType']] = dict(resource, images=images)


def read_live(client, listing, version=None, create=False, screenshots=True, pull=False):
    config = listing['config']
    apps = client.all('/v1/apps?' + urllib.parse.urlencode({'filter[bundleId]': config['bundleId']}))
    if len(apps) != 1:
        raise APIError('Expected one app for bundle id ' + config['bundleId'])
    app = apps[0]['id']
    versions = client.all('/v1/apps/%s/appStoreVersions?%s' % (app, urllib.parse.urlencode({'filter[platform]': config['platform']})))
    if pull:
        # The version being prepared when there is one: it holds the newest text, which the repo
        # should start from rather than overwrite with what's live.
        selected = next((v for v in versions if state(v) in EDITABLE), None) or next((v for v in versions if state(v) in LIVE), None)
        if not selected:
            raise APIError('No editable or live version to pull for ' + config['platform'])
        if version and selected['attributes']['versionString'] != version:
            raise ConfigError('--version does not match the version being pulled')
        editable, creating = False, False
    else:
        selected, editable, creating = pick_version(versions, version, create)
        if creating:
            selected = max(versions, default=None,
                           key=lambda v: (state(v) in LIVE, v['attributes'].get('createdDate') or ''))
    infos = client.all('/v1/apps/%s/appInfos' % app)
    info = next((i for i in infos if state(i) in EDITABLE), None)
    info_editable = bool(info and state(info) in EDITABLE)
    if not info:
        info = next((i for i in infos if state(i) in LIVE), None)
    info_locales = client.all('/v1/appInfos/%s/appInfoLocalizations' % info['id']) if info else []
    locales = {r['attributes']['locale']: {'info': r, 'screenshots': {}} for r in info_locales}
    if selected:
        read_version_locales(client, selected, locales, screenshots and not pull)
    return {'app': app, 'version': selected, 'info': info, 'editable': editable,
            'info_editable': info_editable, 'creating': creating,
            'first': not any(state(v) in LIVE or state(v) == 'REPLACED_WITH_NEW_VERSION' for v in versions),
            'locales': locales}


def screenshot_plan(wanted, existing):
    available = collections.defaultdict(list)
    for image in existing:
        attrs = image['attributes']
        if (attrs.get('assetDeliveryState') or {}).get('state') in MATCHABLE_SCREENSHOTS:
            available[(attrs.get('sourceFileChecksum') or '').lower()].append(image)
    order, uploads = [], []
    for asset in wanted:
        matches = available[asset['checksum']]
        if matches:
            order.append({'id': matches.pop(0)['id']})
        else:
            order.append({'upload': len(uploads)})
            uploads.append(asset)
    kept = {item['id'] for item in order if 'id' in item}
    deletes = [image['id'] for image in existing if image['id'] not in kept]
    reorder = [x.get('id') for x in order] != [x['id'] for x in existing]
    return {'uploads': uploads, 'deletes': deletes, 'order': order, 'reorder': reorder}


def plan(listing, live):
    """Pure comparison; blocked changes remain visible and make apply fail."""
    changes, notes = [], []
    if live['creating'] and live['version']:
        notes.append('The new version starts with a copy of the localizations and screenshots from version %s.' %
                     live['version']['attributes']['versionString'])
    for locale in sorted(set(live['locales']) - set(listing['locales'])):
        notes.append(locale + ': unmanaged locale; left alone')
    for locale, current in live['locales'].items():
        configured = listing['locales'].get(locale, {}).get('screenshots', {})
        for display in current.get('screenshots', {}):
            notes.append(locale + ': existing screenshot display type ' + display +
                         (' (unmanaged; left alone)' if display not in configured else ''))
    for locale, desired in listing['locales'].items():
        current = live['locales'].get(locale, {})
        for field, value in desired['fields'].items():
            group, api_field = ('info', INFO[field]) if field in INFO else ('version', VERSION[field])
            resource = current.get(group)
            old = resource['attributes'].get(api_field) if resource else None
            if (old or '') == value and resource:
                continue
            reason = None
            if field == 'whats_new' and live['first']:
                notes.append(locale + '/whats_new: first version cannot set what’s new; skipped')
                continue
            if group == 'info' and not live['info_editable'] and not live['creating']:
                reason = 'needs editable app info'
            elif group == 'version' and not live['editable'] and (field != 'promotional_text' or not resource):
                reason = 'needs a new version'
            changes.append({'locale': locale, 'group': group, 'field': api_field,
                            'old': old, 'new': value, 'blocked': reason})
        for display, assets in desired['screenshots'].items():
            resource = current.get('screenshots', {}).get(display)
            comparison = screenshot_plan(assets, resource['images'] if resource else [])
            if comparison['uploads'] or comparison['deletes'] or comparison['reorder']:
                changes.append({'locale': locale, 'group': 'screenshots', 'display': display,
                                'plan': comparison, 'blocked': None if live['editable'] else 'needs a new version'})
    if 'copyright' in listing['config']:
        old = live['version']['attributes'].get('copyright') if live['version'] else None
        value = listing['config']['copyright']
        if old != value:
            changes.append({'group': 'copyright', 'field': 'copyright', 'old': old, 'new': value,
                            'blocked': None if live['editable'] else 'needs a new version'})
    return changes, notes


def body(kind, attributes, resource_id=None, parent=None):
    data = {'type': kind, 'attributes': attributes}
    if resource_id:
        data['id'] = resource_id
    if parent:
        relationship, parent_type, parent_id = parent
        data['relationships'] = {relationship: {'data': {'type': parent_type, 'id': parent_id}}}
    return {'data': data}


def upload(client, set_id, asset):
    content = Path(asset['path']).read_bytes()
    if hashlib.md5(content).hexdigest() != asset['checksum']:
        raise APIError('Screenshot changed during run: ' + asset['name'])
    resource = client.request('POST', '/v1/appScreenshots', body('appScreenshots',
                              {'fileName': asset['name'], 'fileSize': len(content)},
                              parent=('appScreenshotSet', 'appScreenshotSets', set_id)), expect=dict)['data']
    path = '/v1/appScreenshots/' + resource['id']
    try:
        for operation in resource['attributes']['uploadOperations']:
            start, length = operation['offset'], operation['length']
            client.request(operation['method'], operation['url'], content[start:start + length],
                           {h['name']: h['value'] for h in operation['requestHeaders']}, raw=True)
        client.request('PATCH', path, body('appScreenshots',
                       {'uploaded': True, 'sourceFileChecksum': asset['checksum']}, resource['id']))
        for _ in range(60):
            attrs = client.request('GET', path, expect=dict)['data']['attributes']
            delivered = attrs.get('assetDeliveryState') or {}
            if delivered.get('state') == 'COMPLETE':
                return resource['id']
            if delivered.get('state') == 'FAILED':
                raise APIError('Screenshot processing failed: ' + json.dumps(delivered.get('errors', [])))
            client.sleep(5)
        raise APIError('Screenshot processing timed out: ' + asset['name'])
    except APIError as exc:
        try:
            client.request('DELETE', path)
        except APIError as cleanup:
            raise APIError('%s. Could not delete screenshot %s: %s' % (exc, resource['id'], cleanup)) from cleanup
        raise


def apply(client, listing, live, changes, version=None, screenshots=True):
    if any(change['blocked'] for change in changes):
        raise APIError('Apply blocked: some changes need a new version or editable app info; no writes made')
    if live['creating']:
        live['version'] = client.request('POST', '/v1/appStoreVersions', body('appStoreVersions',
            {'platform': listing['config']['platform'], 'versionString': version},
            parent=('app', 'apps', live['app'])), expect=dict)['data']
        live['creating'] = False
        live['locales'] = {locale: {'info': entry['info'], 'screenshots': {}}
                           for locale, entry in live['locales'].items() if 'info' in entry}
        read_version_locales(client, live['version'], live['locales'], screenshots)
        if any(c['group'] == 'info' for c in changes) and not live['info_editable']:
            # Creating a version may produce a new editable app info; never patch the live one.
            infos = client.all('/v1/apps/%s/appInfos' % live['app'])
            info = next((i for i in infos if state(i) in EDITABLE), None)
            if not info:
                raise APIError('Version created, but no editable app info exists; rerun diff before continuing')
            live['info'], live['info_editable'] = info, True
            for entry in live['locales'].values():
                entry.pop('info', None)
            for localized in client.all('/v1/appInfos/%s/appInfoLocalizations' % info['id']):
                live['locales'].setdefault(localized['attributes']['locale'], {'screenshots': {}})['info'] = localized
        changes, _ = plan(listing, live)
    groups = collections.defaultdict(dict)
    for change in changes:
        if change['group'] != 'screenshots':
            groups[(change.get('locale'), change['group'])][change['field']] = change['new']
    for (locale, group), attributes in groups.items():
        if group == 'copyright':
            resource = live['version']
            client.request('PATCH', '/v1/appStoreVersions/' + resource['id'], body('appStoreVersions', attributes, resource['id']))
            continue
        entry = live['locales'].setdefault(locale, {'screenshots': {}})
        kind, relationship, parent_kind = (('appInfoLocalizations', 'appInfo', 'appInfos') if group == 'info'
                                           else ('appStoreVersionLocalizations', 'appStoreVersion', 'appStoreVersions'))
        resource = entry.get(group)
        if resource:
            client.request('PATCH', '/v1/' + kind + '/' + resource['id'], body(kind, attributes, resource['id']))
        else:
            entry[group] = client.request('POST', '/v1/' + kind, body(kind, dict(attributes, locale=locale),
                         parent=(relationship, parent_kind, live[group]['id'])), expect=dict)['data']
    for change in changes:
        if change['group'] != 'screenshots':
            continue
        entry = live['locales'].setdefault(change['locale'], {'screenshots': {}})
        if 'version' not in entry:
            entry['version'] = client.request('POST', '/v1/appStoreVersionLocalizations',
                body('appStoreVersionLocalizations', {'locale': change['locale']},
                     parent=('appStoreVersion', 'appStoreVersions', live['version']['id'])), expect=dict)['data']
        resource = entry['screenshots'].get(change['display'])
        if not resource:
            resource = client.request('POST', '/v1/appScreenshotSets', body('appScreenshotSets',
                {'screenshotDisplayType': change['display']}, parent=('appStoreVersionLocalization',
                 'appStoreVersionLocalizations', entry['version']['id'])), expect=dict)['data']
        comparison = change['plan']
        # Remove obsolete assets first: a full set cannot reserve an eleventh screenshot.
        for resource_id in comparison['deletes']:
            client.request('DELETE', '/v1/appScreenshots/' + resource_id)
        uploaded = [upload(client, resource['id'], asset) for asset in comparison['uploads']]
        order = [item['id'] if 'id' in item else uploaded[item['upload']] for item in comparison['order']]
        set_path = '/v1/appScreenshotSets/' + resource['id']
        client.request('PATCH', set_path + '/relationships/appScreenshots',
                       {'data': [{'type': 'appScreenshots', 'id': x} for x in order]})
        actual = [image['id'] for image in client.all(set_path + '/appScreenshots')]
        if actual != order:
            raise APIError('Screenshot order differs for set %s: expected %s, got %s' % (resource['id'], order, actual))
    return changes


def pull(listing, live, out, platform):
    directory = Path(out) / platform
    if directory.exists() and any(directory.iterdir()):
        raise ConfigError('Pull output must be empty: ' + str(directory))
    directory.mkdir(parents=True, exist_ok=True)
    config = {'bundleId': listing['config']['bundleId'], 'platform': listing['config']['platform'], 'screenshots': []}
    if live['version'] and live['version']['attributes'].get('copyright') is not None:
        config['copyright'] = live['version']['attributes']['copyright']
    (directory / 'listing.json').write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
    for locale, entry in live['locales'].items():
        if Path(locale).name != locale or locale in ('.', '..'):
            raise APIError('Invalid locale returned by API')
        folder = directory / locale
        folder.mkdir(exist_ok=True)
        for mapping, group in ((INFO, 'info'), (VERSION, 'version')):
            for field, attribute in mapping.items():
                value = entry.get(group, {}).get('attributes', {}).get(attribute)
                if value is not None:
                    (folder / (field + '.txt')).write_text(value + '\n', encoding='utf-8')


def render(changes, notes):
    lines = list(notes)
    for change in changes:
        prefix = change.get('locale', 'version') + '/' + change.get('field', change.get('display', ''))
        if change.get('blocked'):
            prefix += ' [' + change['blocked'] + ']'
        if change['group'] == 'screenshots':
            p = change['plan']
            lines.append('%s: upload %s; delete %s; reorder %s' %
                         (prefix, [a['name'] for a in p['uploads']], p['deletes'], p['reorder']))
        elif max(len(change['old'] or ''), len(change['new'])) > 170:
            diff = list(difflib.unified_diff((change['old'] or '').splitlines(), change['new'].splitlines(),
                                            fromfile='live', tofile='repo', lineterm=''))
            lines.extend([prefix] + diff[:35] + (['… diff truncated'] if len(diff) > 35 else []))
        else:
            lines.append('%s: %r -> %r' % (prefix, change['old'], change['new']))
    return '\n'.join(lines or ['No changes.'])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mode', choices=('diff', 'apply', 'pull'), default='diff', help='compare (default), update, or export the text (of the version being prepared, else the live one)')
    parser.add_argument('--platform', choices=('ios', 'macos'), default='ios', help='platform directory (default: ios)')
    parser.add_argument('--listing', default=str(ROOT / 'appstore/listing'), help='listing root (default: appstore/listing)')
    parser.add_argument('--version', help='version string to edit or create')
    parser.add_argument('--create-version', action='store_true', help='create --version when no editable version exists')
    parser.add_argument('--no-screenshots', action='store_true', help='skip screenshot validation and synchronization')
    parser.add_argument('--out', help='pull output root; must have an empty platform subdirectory')
    parser.add_argument('--summary', help='write a Markdown run summary to this file')
    parser.add_argument('--api-base', default='https://api.appstoreconnect.apple.com', help='API origin (override for offline stub tests)')
    args = parser.parse_args(argv)
    result, code = '', 0
    try:
        if args.create_version and not args.version:
            raise ConfigError('--create-version requires --version')
        if args.mode == 'pull' and not args.out:
            raise ConfigError('--out is required for pull')
        screenshots = not args.no_screenshots
        listing = load_listing(args.listing, args.platform, screenshots and args.mode != 'pull')
        missing = [k for k in ('ASC_KEY', 'ASC_KEY_ID', 'ASC_ISSUER_ID') if not os.environ.get(k)]
        if missing:
            raise ConfigError('Missing credentials: ' + ', '.join(missing))
        token = Token(os.environ['ASC_KEY'], os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID'])
        token.get()
        client = Client(args.api_base, token)
        live = read_live(client, listing, args.version, args.create_version, screenshots, args.mode == 'pull')
        if args.mode == 'pull':
            pull(listing, live, args.out, args.platform)
            result = 'Exported live text to ' + args.out
        else:
            changes, notes = plan(listing, live)
            prefix = 'Create version ' + args.version + '\n' if live['creating'] else ''
            result = prefix + render(changes, notes)
            if args.mode == 'apply':
                applied = apply(client, listing, live, changes, args.version, screenshots)
                result = prefix + render(applied, notes) + '\nApplied %s change(s).' % len(applied)
    except ConfigError as exc:
        result += '\nError: ' + str(exc)
        code = 2
    except (APIError, OSError, ValueError) as exc:
        result += '\nError: ' + str(exc)
        code = 1
    try:
        print(result)
    finally:
        if args.summary:
            # Four-space indentation keeps arbitrary listing text from becoming Markdown markup.
            Path(args.summary).write_text('App Store listing: ' + args.mode + '\n\n' +
                                         '\n'.join('    ' + line for line in result.splitlines()) + '\n', encoding='utf-8')
    return code


if __name__ == '__main__':
    sys.exit(main())
