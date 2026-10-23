"""Release metadata shared by publishing tools and the independent installer."""
import json
import re
from urllib.parse import urlsplit
from urllib.request import urlopen

CATALOGUE_URL = 'https://raw.githubusercontent.com/matijaerceg/misterzine-plex-core/distribution/catalogue.json'
DB_ID = 'misterzine_plex'
STAGING = 'misterzine-plex-downloads'
VERSION = re.compile(r'v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?')
IDENT = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}')
HASH = re.compile(r'[0-9a-f]{64}')
BATCH = re.compile(r'[a-z0-9][a-z0-9-]{0,47}')


def https(value):
    if not isinstance(value, str) or len(value) > 2048:
        raise ValueError('Invalid release URL')
    u = urlsplit(value)
    if u.scheme != 'https' or not u.hostname or u.username or u.password or u.fragment or any(ord(c) < 33 for c in value):
        raise ValueError('Release URLs must use HTTPS')
    return value


def entry(value):
    if not isinstance(value, dict):
        raise ValueError('Invalid release entry')
    for name, pattern in (('id', IDENT), ('version', VERSION), ('sha256', HASH)):
        if not isinstance(value.get(name), str) or not pattern.fullmatch(value[name]):
            raise ValueError('Invalid release ' + name)
    channel = value.get('channel')
    if channel not in ('public', 'beta') or (channel == 'public' and '-' in value['version']):
        raise ValueError('Invalid release channel')
    if type(value.get('size')) is not int or not 0 < value['size'] <= 256 * 1024 * 1024:
        raise ValueError('Invalid release size')
    for key in ('url', 'db_url'):
        https(value.get(key))
    source = value.get('source')
    if (not isinstance(source, dict) or set(source) != {'filename', 'size', 'sha256', 'url'}
            or not isinstance(source.get('filename'), str)
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.zip', source['filename'])
            or type(source.get('size')) is not int or not 0 < source['size'] <= 1024 * 1024 * 1024
            or not isinstance(source.get('sha256'), str) or not HASH.fullmatch(source['sha256'])):
        raise ValueError('Invalid corresponding-source metadata')
    https(source['url'])
    if not isinstance(value.get('notes'), str) or len(value['notes']) > 16000:
        raise ValueError('Invalid release notes')
    access = value.get('access')
    if channel == 'public':
        if access is not None:
            raise ValueError('Public releases cannot require a code')
    elif (not isinstance(access, dict) or set(access) != {'batch', 'sha256'}
          or not isinstance(access['batch'], str) or not BATCH.fullmatch(access['batch'])
          or not isinstance(access['sha256'], str) or not HASH.fullmatch(access['sha256'])):
        raise ValueError('Invalid beta access requirement')
    return value


CHANNELS = ('public', 'beta')


def slot(value, name):
    """Check one channel-to-entry map. An id may appear in both slots, never twice in one."""
    releases = value.get(name)
    if not isinstance(releases, dict):
        raise ValueError('Unsupported release catalogue')
    if not set(releases) <= set(CHANNELS):
        raise ValueError('Unknown release channel')
    ids = set()
    for channel, release in releases.items():
        entry(release)
        if release['channel'] != channel or release['id'] in ids:
            raise ValueError('Conflicting release entry')
        ids.add(release['id'])


def catalogue(value):
    # "releases" is the legacy slot read by cards from before "current"
    # existed; "current" is what newer cards install. "legacy_pin" names the
    # channels whose legacy entry is frozen for those older cards.
    if not isinstance(value, dict) or value.get('schema') != 1:
        raise ValueError('Unsupported release catalogue')
    slot(value, 'releases')
    if 'current' in value:
        slot(value, 'current')
    pins = value.get('legacy_pin', [])
    if (not isinstance(pins, list) or len(set(map(str, pins))) != len(pins)
            or not all(isinstance(c, str) and c in CHANNELS for c in pins)):
        raise ValueError('Invalid legacy pin')
    return value


def offered(value, channel):
    """The entry this card installs for a channel, or None.

    A catalogue written by older tooling has no "current"; a channel published
    only by older tooling is missing from it. Both fall back to "releases".
    """
    release = value.get('current', {}).get(channel)
    return release if release is not None else value['releases'].get(channel)


def offered_channels(value):
    return [c for c in CHANNELS if offered(value, c) is not None]


def fetch(url=CATALOGUE_URL):
    https(url)
    with urlopen(url, timeout=20) as response:
        https(response.geturl())
        data = response.read(128 * 1024 + 1)
    if len(data) > 128 * 1024:
        raise ValueError('Release catalogue is too large')
    return catalogue(json.loads(data))


def manifest_matches(manifest, release):
    return all(manifest.get(k) == release.get(k) for k in ('id', 'version', 'channel', 'access'))
