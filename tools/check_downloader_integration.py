"""Exercise the official Downloader archive against an isolated synthetic card.

Usage: python3 tools/check_downloader_integration.py /path/to/downloader_latest.zip
Only its HTTP transport is substituted; database/filter/hash/store handling is real.
The supplied archive is never installed on the user's card.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'release'))
import catalogue
import update_service

RUNNER = '''
import contextlib, io, runpy, sys
from pathlib import Path
archive, assets = sys.argv[1:3]
sys.path.insert(0, archive)
from downloader.http_gateway import HttpGateway
class Fixture(io.BytesIO):
    status = 200
    def getheader(self, name, default=None):
        return str(len(self.getvalue())) if name.lower() == 'content-length' else default
@contextlib.contextmanager
def transport(self, url, *args, **kwargs):
    prefix = 'https://example.org/plex-fixture/'
    if not url.startswith(prefix) or Path(url[len(prefix):]).name != url[len(prefix):]:
        raise RuntimeError('Unexpected fixture request')
    with Fixture((Path(assets) / url[len(prefix):]).read_bytes()) as response:
        yield url, response
HttpGateway.open = transport
sys.argv = [archive] + sys.argv[3:]
runpy.run_path(archive, run_name='__main__')
'''


def exercise(archive):
    archive = Path(archive).resolve()
    # Downloader intentionally rejects card roots outside /media.
    with tempfile.TemporaryDirectory(prefix='plex-downloader-', dir='/media') as tmp:
        base = Path(tmp)
        card, server = base / 'card', base / 'server'
        card.mkdir(); server.mkdir()
        root = card / 'misterzine-plex'
        (root / 'updates').mkdir(parents=True)
        (root / 'active.json').write_bytes(b'unchanged selection')
        (root / 'plexcrt.json').write_bytes(b'synthetic settings')
        unrelated = card / 'unrelated.txt'
        unrelated.write_bytes(b'unrelated')
        original = '[MiSTer]\nfilter=arcade console\n[unrelated]\ndb_url=https://example.org/unrelated\n'
        (card / 'downloader.ini').write_text(original)
        runner = base / 'runner.py'; runner.write_text(RUNNER)
        url = 'https://example.org/plex-fixture/'
        release = {'db_url': url + 'db.json.zip'}
        ini = root / 'updates/downloader.ini'

        def publish(payload, timestamp):
            release.update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            (server / 'package.zip').write_bytes(payload)
            db = {'v':1, 'db_id':catalogue.DB_ID, 'timestamp':timestamp,
                  'folders':{catalogue.STAGING:{}}, 'files':{
                  catalogue.STAGING+'/package.zip':{'url':url+'package.zip','size':len(payload),
                                                    'hash':hashlib.md5(payload).hexdigest()}}}
            with zipfile.ZipFile(server/'db.json.zip','w') as z:
                z.writestr('misterzine_plex.json', json.dumps(db))

        def run(command, env, **kwargs):
            env.update(SKIP_FREE_SPACE_CHECKS='true', SSL_CERT_FILE='', CURL_SSL='')
            env.pop('PC_LAUNCHER', None)
            result = subprocess.run([sys.executable,str(runner),str(archive),str(server),*command[-2:]],
                                    env=env,cwd=card,**kwargs)
            if result.returncode and (root/'updates/download-output.log').exists():
                print((root/'updates/download-output.log').read_text())
            return result

        from unittest.mock import patch
        with patch.object(update_service,'engine',return_value=[sys.executable,str(archive)]), patch.object(update_service,'other_downloader',return_value=False):
            publish(b'first synthetic archive',1)
            update_service.download(card,root,release,runner=run)
            staged=card/catalogue.STAGING/'package.zip'
            assert staged.read_bytes()==b'first synthetic archive'
            # Simulate an ordinary external run with restrictive global filters.
            ini.write_text('[MiSTer]\nfilter=arcade console\nupdate_linux=false\n'+update_service.database_text(release))
            env=dict(os.environ,FORCED_BASE_PATH=str(card),DEFAULT_BASE_PATH=str(card),
                     DOWNLOADER_INI_PATH=str(ini),EXTRA_DROP_IN_DATABASE_FILES='',UPDATE_LINUX='false',ALLOW_REBOOT='0',
                     DOWNLOADER_LAUNCHER_PATH=str(card/'Scripts/downloader.sh'),FAIL_ON_FILE_ERROR='true',LOGFILE=str(base/'log'))
            publish(b'second synthetic archive',2)
            result=run(['--run-only',catalogue.DB_ID],env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
            if result.returncode: raise RuntimeError(result.stdout.decode(errors='replace'))
            assert staged.read_bytes()==b'second synthetic archive'
            staged.unlink()
            update_service.download(card,root,release,runner=run)
            assert staged.read_bytes()==b'second synthetic archive', 'same-version repair failed'
        assert (root/'active.json').read_bytes()==b'unchanged selection'
        assert (root/'plexcrt.json').read_bytes()==b'synthetic settings'
        assert unrelated.read_bytes()==b'unrelated'
        assert (card/'downloader.ini').read_text()==original
        print('PASS: real Downloader staging, restrictive filters, external refresh, repair, unrelated-file isolation')


if __name__ == '__main__':
    exercise(sys.argv[1])
