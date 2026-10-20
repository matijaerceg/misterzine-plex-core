#!/usr/bin/env python3
"""plexplay - play one Plex library item on the PlexCRT core.

    plexplay.py "title substring" [offset_s]   search the movie library, play first hit
    plexplay.py rk:<rating-key> [offset_s]    play a ratingKey directly
    plexplay.py list [section]                 list a few titles
    plexplay.py ctl <command>                  drive a running player (see below)

Without an offset, playback resumes from the server's saved position (viewOffset)
when there is one, like every other Plex client.

Asks the server for a 720-wide H.264 transcode as progressive Matroska over
plain HTTP (one GET, one demux), pipes it through ffmpeg: video as planar YUV
and audio as PCM in one AVI into plexfb, which shows the picture from the
core's frame ring and releases the sound against the same field clock. The
presenter fits the square-pixel picture Plex delivers to a 4:3 CRT with 720
non-square pixels per line (letterbox or pillarbox) as it copies each frame.

Control while playing: write a line to the FIFO /tmp/plexplay.ctl
    pause | resume | toggle       hold / continue (audio stops with the picture)
    seek <seconds>                absolute position
    seek +30 | seek -10           relative
    subtitle_size <100|150|200> <restart 0|1>
                                  change Plex's burned-in subtitle size; restart
                                  only when an active subtitle needs rebaking
    stop                          end playback
`plexplay.py ctl seek +30` does the write for you.

Robustness:
  - timeline pings every 10 s (state playing/paused/stopped) so the server keeps
    the transcoder alive, records the resume point and marks the item watched;
  - if the pipeline dies before the end (network drop, server restart) playback
    restarts from the last shown position, up to RETRIES times;
  - if ffmpeg cannot open the stream at all (its own HTTP or TLS client failing
    against a server this script reaches fine), the stream is fetched here
    and piped into ffmpeg instead; PLEX_STREAM=pipe selects that from the start;
  - the first time a pipeline ends without showing a frame, a few seconds of
    self-test go into the log: how the server answers this script and ffmpeg,
    and whether colour bars reach the screen through the presenter. That makes
    one diagnostics report enough to place a black screen. PLEX_SELFTEST=1
    runs it before playing.
  - stop/seek/end all shut the transcode session down; a seek leaves the
    last frame on screen until the new stream's first frame.
  - the source file, then what each timeline reply says about the transcode
    (speed, how far ahead of playback, hardware use) next to the frames the
    presenter missed, the server's CPU when the account may see it, and a
    summary at the end go into the log, so one report tells a server that
    cannot keep up from a board that cannot.
"""
import os, sys, uuid, subprocess, signal, threading, time, errno, socket, stat as st_
import urllib.request, urllib.parse, urllib.error
sys.stdout.reconfigure(line_buffering=True)   # logs stay readable when redirected
import xml.etree.ElementTree as ET

HOST = os.environ.get('PLEX_HOST', '').rstrip('/')
TOKEN = os.environ.get('PLEX_TOKEN', '')
if not HOST or not TOKEN:
    raise SystemExit('Sign in through MisterZine Plex Core before starting playback.')
CLIENT_ID = os.environ.get('PLEX_CLIENT_ID') or 'mister-plexcrt-0001'
BITRATE = int(os.environ.get('PLEX_BITRATE') or 3000)   # kbit/s cap for the transcode
# gain the server applies when it folds surround to stereo (100 is unity);
# stereo tracks are copied, so it changes nothing for them
AUDIO_BOOST = int(os.environ.get('PLEX_AUDIO_BOOST') or 300)
# Plex uses 100 for the original size; larger values enlarge burned-in subs.
SUBTITLE_SIZE = int(os.environ.get('PLEX_SUBTITLE_SIZE') or 100)
HOME = os.path.dirname(os.path.abspath(__file__))
FF = os.environ.get('PLEX_FFMPEG') or os.path.join(HOME, 'ffmpeg')
PLEXFB = os.path.join(HOME, 'plexfb')
CTL_FIFO = '/tmp/plexplay.ctl'
STATUS = '/tmp/plexfb.stat'
PLAYSTAT = '/tmp/plexplay.stat'      # for the UI's overlay: position, length, paused
TIMELINE_S = 10          # ping interval while playing or paused
RETRIES = 3              # restarts after an unexpected pipeline death
END_SLACK = 5.0          # within this many seconds of the end counts as finished

# PMS matches a hardcoded client profile from these; "Chrome" is the one that works.
PLEX_HDRS = {
    'X-Plex-Token': TOKEN,
    'X-Plex-Client-Identifier': CLIENT_ID,
    'X-Plex-Product': 'Plex Web',
    'X-Plex-Version': '4.0.0',
    'X-Plex-Platform': 'Chrome',
    'X-Plex-Platform-Version': '120.0',
    'X-Plex-Device': 'Linux',
    'X-Plex-Device-Name': 'MiSTer CRT',
    'Accept': 'application/xml',
}

HOSTNAME = urllib.parse.urlsplit(HOST).hostname or ''

def private_host(host):
    """True for a home-network address, False for a public one, None when the
    name does not tell: plex.direct names carry the address with dashes, and
    a plain HTTP connection is the address itself"""
    if host.endswith('.plex.direct'):
        return bool(__import__('re').match(r'(10-|192-168-|172-(1[6-9]|2\d|3[01])-)', host))
    try: return __import__('ipaddress').ip_address(host).is_private
    except ValueError: return None

def safe_text(value):
    text = str(value)
    for secret in (TOKEN, urllib.parse.quote(TOKEN, safe=''), urllib.parse.quote_plus(TOKEN)):
        if secret: text = text.replace(secret, '[redacted]')
    if HOSTNAME: text = text.replace(HOSTNAME, '[server]')
    return text

def log(*a):
    print(time.strftime('%H:%M:%S'), *(safe_text(v) for v in a))

def drain_stderr(pipe):
    with pipe:
        while True:
            line = pipe.readline(65537)
            if not line: return
            if len(line) > 65536:
                while line and not line.endswith(b'\n'): line = pipe.readline(65537)
                log('[oversized decoder log line omitted]')
            else:
                log(line.decode('utf-8', 'replace').rstrip())

def pump(resp, sink):
    """copy a stream response into ffmpeg's stdin until either side ends"""
    try:
        with resp, sink:
            while True:
                chunk = resp.read(256 * 1024)
                if not chunk: return
                sink.write(chunk)
    except (OSError, ValueError):
        return

def get(path, params=None, timeout=30):
    url = HOST + path
    if params:
        url += ('&' if '?' in url else '?') + urllib.parse.urlencode(params)
    r = urllib.request.urlopen(urllib.request.Request(url, headers=PLEX_HDRS), timeout=timeout)
    return r.read()

def find(query, section=1):
    root = ET.fromstring(get('/library/sections/%d/all' % section, {'title': query}))
    return [(v.get('ratingKey'), v.get('title'), v.get('year'), int(v.get('duration', 0)) // 60000)
            for v in root.findall('Video')]

def item_info(rk):
    """title, duration (s), saved resume point (s), source frame rate (0 if unknown),
    a one-line description of the file the server converts"""
    v = ET.fromstring(get('/library/metadata/%s' % rk)).find('Video')
    s, m = v.find('.//Stream[@streamType="1"]'), v.find('Media')
    try: fps = float(s.get('frameRate') or 0) if s is not None else 0.0
    except ValueError: fps = 0.0
    if not fps and m is not None:
        fps = {'50p': 50.0, '60p': 59.94}.get(m.get('videoFrameRate') or '', 0.0)
    return (v.get('title'), int(v.get('duration', 0)) / 1000.0, int(v.get('viewOffset', 0)) / 1000.0, fps,
            source_text(v))

def source_text(video):
    """what the server has to decode for us: the first version, which the
    transcode asks for (mediaIndex 0), and how many versions there are"""
    media = video.findall('Media')
    if not media: return 'unknown'
    m, s = media[0], media[0].find('.//Stream[@streamType="1"]')
    s = s if s is not None else ET.Element('Stream')
    words = [m.get('videoCodec') or '?', '%sx%s' % (m.get('width') or '?', m.get('height') or '?')]
    if s.get('bitDepth'): words.append('%s-bit' % s.get('bitDepth'))
    if s.get('DOVIPresent') == '1': words.append('Dolby Vision')
    elif s.get('colorTrc') in ('smpte2084', 'arib-std-b67'): words.append('HDR')
    words.append('%s kbps %s' % (m.get('bitrate') or '?', m.get('container') or '?'))
    return '%s, %d version%s' % (' '.join(words), len(media), '' if len(media) == 1 else 's')

def transcode_health(body):
    """the server's own account of this client's transcode, from a timeline
    reply: speed, throttled, maxOffsetAvailable, hardware use ... (or None)"""
    try: ts = ET.fromstring(body).find('TranscodeSession')
    except ET.ParseError: return None
    return dict(ts.attrib) if ts is not None else None

def flag(value):
    return value in ('1', 'true')

def hardware_text(ts):
    """what the server says about hardware transcoding for this session"""
    dec = ts.get('transcodeHwDecodingTitle') or ts.get('transcodeHwDecoding')
    enc = ts.get('transcodeHwEncodingTitle') or ts.get('transcodeHwEncoding')
    if dec or enc:
        return 'decode %s, encode %s' % (dec or 'software', enc or 'software')
    return 'requested but not in use' if flag(ts.get('transcodeHwRequested')) else 'off'

def health_text(ts, pos, missed):
    """one log line: how fast the server converts, how far ahead of our
    position it is, and how many frames the presenter found missing"""
    try: ahead = float(ts['maxOffsetAvailable']) - pos
    except (KeyError, ValueError): ahead = None
    try: speed = float(ts.get('speed') or 0)
    except ValueError: speed = 0.0
    # a throttled transcoder is idling far enough ahead; its speed reads 0 then,
    # and for a moment after it starts again
    if flag(ts.get('throttled')): words = ['throttled (ahead enough, resting)']
    else: words = ['converting at %.1fx' % speed if speed > 0 else 'converting (speed not measured yet)']
    if ahead is not None: words.append('%.0f s ahead of playback' % ahead)
    words.append('video %s from %s' % (ts.get('videoDecision') or '?', ts.get('sourceVideoCodec') or '?'))
    words.append('hardware %s' % hardware_text(ts))
    return 'server: %s; frames missed here: %d' % (', '.join(words), missed)

def profile_extra(src_fps):
    """the limits added to the Plex Web client profile for this item"""
    # the Plex Web profile allows six-channel AAC; cap audio at stereo so the
    # server downmixes (and boosts) rather than ffmpeg on the ARM
    extra = 'add-limitation(scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.channels&value=2)'
    # 50 and 60 fps would arrive at their full rate, more frames than the
    # board decodes: ask for exactly half, every other frame (25 or 29.97)
    if src_fps >= 45:
        extra += ('+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.frameRate&value=%.3f)'
                  % (src_fps / 2))
    return extra

def read_status():
    """plexfb's progress file -> dict, or {} if not there yet"""
    try:
        d = {}
        for kv in open(STATUS).read().split():
            k, v = kv.split('=', 1)
            d[k] = float(v)
        return d
    except (OSError, ValueError):
        return {}


class StreamError(Exception):
    """the stream could not be fetched this time; worth another try"""


class Player:
    def __init__(self, rk, offset):
        self.rk = rk
        self.offset = offset          # stream start position, seconds
        self.p_ff = self.p_fb = None
        self.resp = None              # the stream response when fetched here
        self.pump = os.environ.get('PLEX_STREAM') == 'pipe'
        self.tested = False           # self-test done for this play
        self.probes = []              # self-test children, ended by a stop
        self.sess = None
        self.fps = 23.976
        self.paused = False
        self.subtitle_size = SUBTITLE_SIZE
        self.restart_paused = False
        self.pending = None           # 'stop' | ('seek', seconds)
        self.last_pos = 0.0
        self.lock = threading.Lock()
        self.title, self.duration, _, self.src_fps, self.source = item_info(rk)
        # what the server says about its transcode, gathered from timeline replies
        self.health = {'first': None, 'logged': 0.0, 'starved': 0, 'missed': 0, 'reports': 0,
                       'throttled': 0, 'speeds': [], 'closest': None, 'hardware': [], 'silent': False}
        self.cpu = None               # None | 'asking' | 'refused'

    # ---- position ----
    def position(self):
        s = read_status()
        return self.offset + s.get('pos', 0.0)

    def write_playstat(self):
        try:
            tmp = PLAYSTAT + '.tmp'
            with open(tmp, 'w') as f:
                f.write('{"pos": %.2f, "dur": %.2f, "paused": %s, "rk": "%s"}\n'
                        % (self.position(), self.duration, 'true' if self.paused else 'false', self.rk))
            os.replace(tmp, PLAYSTAT)
        except OSError:
            pass

    # ---- one transcode session ----
    def transcode_params(self, offset=None, session=None):
        """Parameters shared by decision and start for one transcode."""
        if offset is None:
            offset = self.offset
        if session is None:
            session = self.sess
        return {
            'path': '/library/metadata/%s' % self.rk, 'mediaIndex': 0, 'partIndex': 0,
            'protocol': 'http', 'directPlay': 0, 'directStream': 0,
            'videoResolution': '720x480', 'maxVideoBitrate': BITRATE, 'videoQuality': 100,
            'audioBoost': AUDIO_BOOST, 'subtitles': 'burn', 'subtitleSize': self.subtitle_size,
            'X-Plex-Client-Profile-Extra': profile_extra(self.src_fps),
            'session': session, 'X-Plex-Session-Identifier': session,
            'copyts': 1, 'offset': int(offset), 'fastSeek': 1,
            'location': 'wan', 'mediaBufferSize': 12288, 'hasMDE': 1,
        }

    def start(self):
        # one session id for the whole play, like plex-for-kodi: a seek or a
        # restart re-issues decision+start on it and the server replaces the
        # transcoder; stop once at the end.
        if not self.sess: self.sess = str(uuid.uuid4())
        sess = self.sess
        params = self.transcode_params(session=sess)
        # The server 400s a bare start request; a decision call on the same session
        # first is what makes it accept the stream request (and tells us the shape).
        root = ET.fromstring(get('/video/:/transcode/universal/decision', params, timeout=60))
        med = root.find('.//Media')
        mg = lambda k: med.get(k) if med is not None else '?'
        as_ = root.find('.//Stream[@streamType="2"]')
        log('decision: %s -> %sx%s %s/%s %sch (boost %d), cap %d kbps' % (root.get('transcodeDecisionText'),
            mg('width'), mg('height'), mg('videoCodec'), mg('audioCodec'),
            as_.get('channels') if as_ is not None else '?', AUDIO_BOOST, BITRATE))
        if root.get('transcodeDecisionCode') not in (None, '1000', '1001'):
            # the server will not transcode this file: say why and give up
            self.show_error(safe_text(root.get('transcodeDecisionText') or 'Cannot play this file.'))
            raise RuntimeError('unplayable: %s' % root.get('transcodeDecisionText'))
        # Source frame rate drives the presenter: 23.976 -> 2.5 fields per frame,
        # which the presenter turns into a 3:2 field cadence, like a DVD player.
        FR = {'24p': 23.976, 'NTSC': 29.97, 'PAL': 25.0, '25p': 25.0, '30p': 29.97,
              '50p': 50.0, '60p': 59.94, 'ntsc': 29.97, 'pal': 25.0}
        fr_tag = (med.get('videoFrameRate') if med is not None else None) or ''
        vs_ = root.find('.//Stream[@streamType="1"]')
        self.fps = FR.get(fr_tag) or (float(vs_.get('frameRate')) if vs_ is not None and vs_.get('frameRate') else 29.97)
        log('frame rate: %s -> %.3f fps (%.2f fields per frame), offset %ds%s' % (fr_tag or '?', self.fps, 59.94 / self.fps,
            self.offset, ', source %.3f fps halved' % self.src_fps if self.src_fps >= 45 else ''))
        params.update({k:v for k,v in PLEX_HDRS.items() if k not in ('Accept','X-Plex-Token')})
        url = HOST + '/video/:/transcode/universal/start.mkv?' + urllib.parse.urlencode(params)

        # frames leave ffmpeg at the size Plex sent them: the presenter fits them
        # to the 4:3 raster while it copies them into the frame ring, which costs
        # a third of what ffmpeg's scaler did and pays for the H.264 loop filter.
        # Without the filter, block edges build up until the next keyframe and
        # show in dark scenes. PLEX_SKIP_LOOP_FILTER=noref|all is for lab tests.
        skip = os.environ.get('PLEX_SKIP_LOOP_FILTER')
        decode = ['-skip_loop_filter', skip] if skip else []
        output = ['-map', '0:v:0', '-c:v', 'rawvideo', '-pix_fmt', 'yuv420p',
                  '-map', '0:a:0', '-ac', '2', '-ar', '48000', '-c:a', 'pcm_s16le',
                  '-f', 'avi', 'pipe:1']
        if self.pump:
            self.resp = self.open_stream(url)
            ff = [FF, '-loglevel', 'warning', '-threads', '2'] + decode + ['-i', 'pipe:0'] + output
        else:
            ff = [FF, '-nostdin', '-loglevel', 'warning', '-threads', '2'] + decode + [
                  '-reconnect', '1', '-reconnect_streamed', '1', '-rw_timeout', '15000000',
                  '-headers', 'X-Plex-Token: '+TOKEN+'\r\n', '-i', url] + output
        fb = [PLEXFB, 'avi', '%.4f' % self.fps]
        env = dict(os.environ, PLEXFB_DEV='/dev/fb0', PLEXFB_STATUS=STATUS)
        try: os.unlink(STATUS)
        except OSError: pass
        self.p_ff = subprocess.Popen(ff, stdin=subprocess.PIPE if self.pump else None,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        threading.Thread(target=drain_stderr, args=(self.p_ff.stderr,), daemon=True).start()
        if self.pump:
            threading.Thread(target=pump, args=(self.resp, self.p_ff.stdin), daemon=True).start()
        self.p_fb = subprocess.Popen(fb, stdin=self.p_ff.stdout, env=env)
        self.p_ff.stdout.close()

    def open_stream(self, url):
        # The same client that just made the decision call fetches the stream,
        # so a server answer is logged as such, not as a decoder I/O error.
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers=PLEX_HDRS), timeout=60)
        except urllib.error.HTTPError as e:
            body = ''
            try: body = e.read(300).decode('utf-8', 'replace').replace('\n', ' ').strip()
            except Exception: pass
            try: e.close()
            except Exception: pass
            log('stream request: HTTP %d %s: %s' % (e.code, e.reason, body))
            self.show_error('The server refused the stream (HTTP %d).' % e.code)
            raise RuntimeError('unplayable: the server refused the stream (HTTP %d)' % e.code)
        except (urllib.error.URLError, OSError) as e:
            # a network hiccup, not a verdict: the main loop retries like any
            # other early pipeline death
            log('stream request: %r' % e)
            raise StreamError(type(e).__name__)

    def show_error(self, text):
        try:
            with open(PLAYSTAT + '.err', 'w') as f: f.write(text)
        except OSError: pass

    # ---- self-test ----
    def stopping(self):
        with self.lock: return self.pending == 'stop'

    def self_test(self):
        """a few seconds of probes, each on its own, none fatal, all bounded;
        a stop ends the children at once and the rest within the deadline"""
        self.tested = True
        deadline = time.time() + 8
        log('selftest: start')
        self.end_session()            # the failed session; a retry opens a new one
        results = {}
        def probe(name, fn):
            try: results[name] = fn()
            except Exception as e: results[name] = 'failed: %r' % e
        def lookup():
            u = urllib.parse.urlsplit(HOST)
            host = u.hostname or ''
            kind = 'relay' if u.port == 8443 else 'plex.direct' if host.endswith('.plex.direct') else 'address'
            private = private_host(host) if kind != 'relay' else None
            log('selftest: server %s %s port %s%s' % (u.scheme, kind, u.port or 'default',
                {True: ' (private LAN address)', False: ' (public address)'}.get(private, '')))
            t = time.time()
            addrs = socket.getaddrinfo(host, u.port or 32400, socket.AF_UNSPEC, socket.SOCK_STREAM)
            fams = sorted({'IPv6' if a[0] == socket.AF_INET6 else 'IPv4' for a in addrs})
            return '%d address(es) %s in %.2f s' % (len(addrs), '/'.join(fams), time.time() - t)
        def py_identity():
            t = time.time()
            r = urllib.request.urlopen(urllib.request.Request(HOST + '/identity', headers=PLEX_HDRS), timeout=5)
            return 'HTTP %d in %.2f s' % (r.status, time.time() - t)
        def py_stream():
            sess = str(uuid.uuid4())
            params = self.transcode_params(offset=0, session=sess)
            try:
                get('/video/:/transcode/universal/decision', params, timeout=5)
                t = time.time()
                r = urllib.request.urlopen(urllib.request.Request(
                    HOST + '/video/:/transcode/universal/start.mkv?' + urllib.parse.urlencode(params),
                    headers=PLEX_HDRS), timeout=5)
                self.probes.append(r)
                n, first = 0, None
                while time.time() - t < 4 and n < 512 * 1024 and not self.stopping():
                    chunk = r.read(65536)
                    if not chunk: break
                    if first is None: first = chunk[:4]
                    n += len(chunk)
                r.close()
                return 'HTTP %d %s, %d bytes in %.1f s, %s' % (r.status, r.headers.get('Content-Type', '?'), n, time.time() - t,
                    'matroska' if first == b'\x1a\x45\xdf\xa3' else 'not matroska (%r)' % first)
            except urllib.error.HTTPError as e:
                body = ''
                try: body = e.read(200).decode('utf-8', 'replace').replace('\n', ' ').strip()
                except Exception: pass
                return 'HTTP %d %s %s' % (e.code, e.reason, body)
            finally:
                try: get('/video/:/transcode/universal/stop', {'session': sess}, timeout=5)
                except Exception: pass
        def ff_http():
            r = subprocess.Popen([FF, '-v', 'error', '-rw_timeout', '5000000', '-headers', 'X-Plex-Token: ' + TOKEN + '\r\n',
                                  '-i', HOST + '/identity', '-f', 'null', '-'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            self.probes.append(r)
            try: _, err = r.communicate(timeout=7)
            except subprocess.TimeoutExpired:
                r.kill(); _, err = r.communicate()
                return 'no answer in 7 s'
            err = safe_text(err.decode('utf-8', 'replace')).strip().splitlines()
            # /identity is XML, so the demuxer complaint means the bytes arrived
            if any('Invalid data found' in line for line in err): return 'reached the server (rc=%d)' % r.returncode
            return 'rc=%d %s' % (r.returncode, ' | '.join(line[:120] for line in err[:3]))
        def bars():
            try: os.unlink(STATUS)
            except OSError: pass
            # 8:9 pixels: the 4:3 raster, so the presenter shows the bars full screen
            ff = subprocess.Popen([FF, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=720x480:rate=30,setsar=8/9',
                                   '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '2',
                                   '-c:v', 'rawvideo', '-pix_fmt', 'yuv420p', '-ac', '2', '-c:a', 'pcm_s16le',
                                   '-f', 'avi', 'pipe:1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            fb = subprocess.Popen([PLEXFB, 'avi', '29.97'], stdin=ff.stdout,
                                  env=dict(os.environ, PLEXFB_DEV='/dev/fb0', PLEXFB_STATUS=STATUS))
            self.probes += [ff, fb]
            ff.stdout.close()
            for p in (fb, ff):
                try: p.wait(timeout=max(0.5, deadline - time.time()))
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait()
            err = ff.stderr.read().decode('utf-8', 'replace').strip()
            st = read_status()
            return 'shown=%s filled=%s starved=%s presenter rc=%s%s' % (
                int(st.get('shown', 0)), int(st.get('filled', 0)), int(st.get('starved', 0)), fb.returncode,
                ' ffmpeg: ' + err[:120] if err else '')
        names = ('name lookup', 'this script, /identity', 'this script, stream', 'ffmpeg, /identity')
        threads = [threading.Thread(target=probe, args=a, daemon=True) for a in zip(names, (lookup, py_identity, py_stream, ff_http))]
        for t in threads: t.start()
        probe('colour bars through the presenter', bars)
        for t in threads: t.join(max(0.0, deadline - time.time()))
        self.end_probes()
        for name in names + ('colour bars through the presenter',):
            log('selftest: %s: %s' % (name, results.get(name, 'no answer in time')))
        log('selftest: done')

    def end_probes(self):
        for p in self.probes:
            try:
                if isinstance(p, subprocess.Popen):
                    if p.poll() is None: p.kill()
                else:
                    try: p.fp.raw._sock.shutdown(socket.SHUT_RDWR)
                    except Exception: pass
                    p.close()
            except Exception: pass
        self.probes = []

    def kill(self):
        # ffmpeg first, so it is gone before its pipe closes and does not log
        # a screenful of broken-pipe errors; plexfb blanks the screen on SIGTERM
        for p in (self.p_ff, self.p_fb):
            if p and p.poll() is None:
                try: p.terminate()
                except Exception: pass
            if p:
                try: p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait()
        if self.resp:
            # a pump thread blocked in a read must not hold up a stop or seek:
            # shut the socket down under it before closing the response
            try: self.resp.fp.raw._sock.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: self.resp.close()
            except Exception: pass
            self.resp = None

    def end_session(self):
        # the transcoder was reused across seeks and restarts: shut it once.
        # 404 means the server already tore it down when the socket closed.
        if not self.sess: return
        try: get('/video/:/transcode/universal/stop', {'session': self.sess}, timeout=10)
        except urllib.error.HTTPError as e:
            if e.code != 404: log('stop session: %r' % e)
        except Exception as e: log('stop session: %r' % e)
        self.sess = None

    # ---- timeline ----
    def timeline(self, state, health=False):
        try:
            body = get('/:/timeline', {
                'ratingKey': self.rk, 'key': '/library/metadata/%s' % self.rk,
                'state': state, 'time': int(self.position() * 1000),
                'duration': int(self.duration * 1000),
                'X-Plex-Session-Identifier': self.sess or '',
                'identifier': 'com.plexapp.plugins.library', 'hasMDE': 1, 'continuing': 0,
            }, timeout=10)
        except Exception as e:
            log('timeline %s: %r' % (state, e)); return
        if health and state == 'playing':
            self.note_health(body)

    # ---- the server's side of a stutter ----
    def note_health(self, body):
        """Log what the timeline reply says about our transcode next to what the
        presenter saw, so one report shows whether the server kept ahead. Every
        reply for the first two minutes, then once a minute, and whenever frames
        went missing or the server is close to running dry."""
        h = self.health
        ts = transcode_health(body)
        if ts is None:
            if not h['silent']: log('server: no transcode report in the timeline reply')
            h['silent'] = True
            return
        starved = int(read_status().get('starved', 0))
        if starved < h['starved']: h['starved'] = 0      # a new presenter counts from zero
        missed, h['starved'] = starved - h['starved'], starved
        pos = self.position()
        try: ahead = float(ts['maxOffsetAvailable']) - pos
        except (KeyError, ValueError): ahead = None
        throttled = flag(ts.get('throttled'))
        h['reports'] += 1
        h['missed'] += missed
        if throttled: h['throttled'] += 1
        else:
            # 0 before the transcoder has measured itself
            try: speed = float(ts.get('speed') or 0)
            except ValueError: speed = 0.0
            if speed > 0: h['speeds'].append(speed)
        if ahead is not None and (h['closest'] is None or ahead < h['closest']): h['closest'] = ahead
        hw = hardware_text(ts)
        if hw not in h['hardware']: h['hardware'].append(hw)
        now = time.time()
        h['first'] = h['first'] or now
        if (now - h['first'] < 120 or now - h['logged'] >= 60 or missed
                or (not throttled and ahead is not None and ahead < 10)):
            log(health_text(ts, pos, missed))
            h['logged'] = now
            self.server_cpu()

    def server_cpu(self):
        """The server's own CPU figures, in the background. Plex shows them to
        the server's owner only; anyone else is asked once."""
        if self.cpu: return
        self.cpu = 'asking'
        def ask():
            state = None
            try:
                rows = ET.fromstring(get('/statistics/resources', {'timespan': 6}, timeout=5)).findall('StatisticsResources')
                if rows:
                    r = max(rows, key=lambda e: float(e.get('at') or 0))
                    log('server CPU (last 6 s): whole machine %.0f%%, Plex %.0f%%'
                        % (float(r.get('hostCpuUtilization') or 0), float(r.get('processCpuUtilization') or 0)))
            except urllib.error.HTTPError as e:
                if e.code in (401, 403):
                    log('server CPU: not shown to this account'); state = 'refused'
                else: log('server CPU: %r' % e)
            except Exception as e:
                log('server CPU: %r' % e)
            self.cpu = state
        threading.Thread(target=ask, daemon=True).start()

    def health_summary(self):
        h = self.health
        if not h['reports']: return
        sp = sorted(h['speeds'])
        speed = ('lowest %.1fx, median %.1fx' % (sp[0], sp[len(sp) // 2])) if sp else 'not measured'
        log('server summary: %d reports; converting speed %s; throttled in %d of %d; closest to playback %s; '
            'hardware %s; frames missed here %d'
            % (h['reports'], speed, h['throttled'], h['reports'],
               '%.0f s ahead' % h['closest'] if h['closest'] is not None else 'unknown',
               ' / '.join(h['hardware']), h['missed']))

    # ---- control ----
    def command(self, line):
        w = line.split()
        if not w: return
        c = w[0]
        if c in ('pause', 'resume', 'toggle'):
            changed = False
            with self.lock:
                want = {'pause': True, 'resume': False}.get(c, not self.paused)
                if self.restart_paused:
                    self.paused = want
                    changed = True
                elif want != self.paused and self.p_fb and self.p_fb.poll() is None:
                    self.p_fb.send_signal(signal.SIGUSR1)
                    self.paused = want
                    changed = True
            if changed:
                log('paused' if want else 'resumed')
                self.timeline('paused' if want else 'playing')
        elif c == 'seek' and len(w) > 1:
            pos = self.position()
            t = pos + float(w[1]) if w[1][0] in '+-' else float(w[1])
            t = max(0.0, min(t, self.duration - END_SLACK))
            log('seek %.1f -> %.1f' % (pos, t))
            with self.lock: self.pending = ('seek', t)
            self.interrupt(hold=True)
        elif c == 'subtitle_size' and len(w) > 1:
            try: size = max(100, min(200, int(w[1])))
            except ValueError:
                log('invalid subtitle size %r' % w[1]); return
            if size not in (100, 150, 200):
                log('unsupported subtitle size %d' % size); return
            restart = len(w) < 3 or w[2] == '1'
            if size == self.subtitle_size: return
            pos = self.position()
            was_paused = self.paused
            log('subtitle size %d -> %d%s' % (self.subtitle_size, size,
                ' at %.1f s%s' % (pos, ' (paused)' if was_paused else '') if restart else ' (next stream)'))
            self.subtitle_size = size
            if restart:
                with self.lock: self.pending = ('subtitle_size', size, pos, was_paused)
                self.interrupt(hold=True)
        elif c == 'stop':
            with self.lock: self.pending = 'stop'
            self.interrupt()
        else:
            log('unknown command %r' % line)

    def restore_pause_if_ready(self):
        """Apply the desired pause state after plexfb installs its handler."""
        with self.lock:
            if not self.restart_paused or not self.p_fb or self.p_fb.poll() is not None:
                return False
            if not os.path.exists(STATUS):
                return False
            if self.paused:
                self.p_fb.send_signal(signal.SIGUSR1)
            self.restart_paused = False
        return True

    def interrupt(self, hold=False):
        # ffmpeg first so its pipe is never the thing that fails, then plexfb,
        # which exits (blanking the screen, or with hold keeping its last
        # frame up for the next presenter); the main loop sees it and acts
        for p in (self.p_ff, self.p_fb):
            if p and p.poll() is None:
                try:
                    if hold and p is self.p_fb: p.send_signal(signal.SIGUSR2)
                    else: p.terminate()
                except Exception: pass
        if not hold: self.end_probes()

    def fifo_thread(self):
        while True:
            try:
                with open(CTL_FIFO) as f:          # blocks until a writer opens it
                    for line in f:
                        self.command(line.strip())
            except OSError as e:
                log('fifo: %r' % e); time.sleep(1)

    # ---- main loop ----
    def run(self):
        try:
            if os.path.exists(CTL_FIFO) and not st_.S_ISFIFO(os.stat(CTL_FIFO).st_mode):
                os.unlink(CTL_FIFO)
            if not os.path.exists(CTL_FIFO): os.mkfifo(CTL_FIFO)
        except OSError as e:
            log('control fifo unavailable: %r' % e)
        threading.Thread(target=self.fifo_thread, daemon=True).start()
        signal.signal(signal.SIGTERM, lambda *a: self.command('stop'))
        signal.signal(signal.SIGINT, lambda *a: self.command('stop'))

        retries = 0
        log('playing: %s, %.0f min' % (self.title, self.duration / 60))
        log('source: %s' % self.source)
        if os.environ.get('PLEX_SELFTEST'):
            self.self_test()
        try: os.unlink(PLAYSTAT + '.err')
        except OSError: pass
        while not self.stopping():
            with self.lock:
                if not self.restart_paused:
                    self.paused = False
            try:
                self.start()
            except RuntimeError as e:
                log(str(e)); break
            except StreamError as e:
                self.kill()
                retries += 1
                if retries > RETRIES:
                    log('giving up after %d attempts to fetch the stream' % RETRIES)
                    self.show_error('Could not fetch the stream from the server.')
                    break
                log('stream not fetched (%s), retry %d/%d' % (e, retries, RETRIES))
                time.sleep(2 * retries)
                continue
            if not self.restart_paused:
                self.timeline('playing')
            tping = time.time()
            while self.p_fb.poll() is None:
                time.sleep(0.25)
                if self.restore_pause_if_ready():
                    self.timeline('paused' if self.paused else 'playing')
                self.write_playstat()
                if time.time() - tping >= TIMELINE_S:
                    tping = time.time()
                    self.timeline('paused' if self.paused else 'playing', health=True)
            out_pos = self.last_pos = self.position()
            s = read_status()
            with self.lock:
                pend, self.pending = self.pending, None
            self.kill()
            if pend == 'stop':
                log('stopped at %.1f s' % out_pos); break
            if isinstance(pend, tuple):
                if pend[0] == 'subtitle_size':
                    with self.lock:
                        self.subtitle_size, self.offset, self.restart_paused = pend[1:]
                        self.paused = self.restart_paused
                else: # seek: new session from there
                    self.offset = pend[1]
                retries = 0; continue
            if s.get('eof') == 1 and out_pos >= self.duration - END_SLACK:
                log('end of stream at %.1f s' % out_pos); break
            if not s.get('shown') and not self.tested:
                self.self_test()
                with self.lock: pend = self.pending
                if pend == 'stop':
                    log('stopped at %.1f s' % out_pos); break
            if not self.pump and not s.get('shown') and self.p_ff.returncode not in (None, 0):
                # ffmpeg never got a frame out of the URL. Its HTTP client is not
                # the one that reached the server a moment ago; use that one.
                log('decoder could not open the stream (rc=%s); fetching it here instead' % self.p_ff.returncode)
                self.pump = True; continue
            # died early: network, server, decoder. Try again from where we were.
            retries += 1
            if retries > RETRIES:
                log('giving up after %d restarts at %.1f s' % (RETRIES, out_pos)); break
            log('pipeline ended early at %.1f s (eof=%s, ffmpeg rc=%s), restart %d/%d'
                % (out_pos, s.get('eof'), self.p_ff.returncode, retries, RETRIES))
            self.offset = max(0.0, out_pos - 1.0)
            time.sleep(2 * retries)
        self.health_summary()
        self.timeline('stopped')
        try: os.unlink(PLAYSTAT)
        except OSError: pass
        self.end_session()
        # what every client does at 90%: mark watched, clear the resume point
        if self.duration and self.last_pos >= 0.9 * self.duration:
            try:
                get('/:/scrobble', {'key': self.rk, 'identifier': 'com.plexapp.plugins.library'}, timeout=10)
                log('marked watched')
            except Exception as e: log('scrobble: %r' % e)


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    arg = sys.argv[1]
    if arg == 'list':
        sec = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        root = ET.fromstring(get('/library/sections/%d/all' % sec, {'X-Plex-Container-Size': 15}))
        for v in root.findall('Video'):
            print('rk:%s  %s (%s)  %d min' % (v.get('ratingKey'), v.get('title'), v.get('year'),
                                              int(v.get('duration', 0)) // 60000))
        return 0
    if arg == 'ctl':
        try:                                   # non-blocking: fails instead of hanging with no player
            fd = os.open(CTL_FIFO, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            print('no player running (%s)' % e.strerror); return 1
        os.write(fd, (' '.join(sys.argv[2:]) + '\n').encode()); os.close(fd)
        return 0
    if arg.startswith('rk:'):
        rk = arg[3:]
    else:
        hits = find(arg)
        if not hits:
            print('no match for %r' % arg); return 1
        rk = hits[0][0]
    if len(sys.argv) > 2 and sys.argv[2].replace('.', '').isdigit():
        offset = float(sys.argv[2])
    else:
        _, dur, offset, _, _ = item_info(rk)
        if offset: log('resuming from saved position %.0f s' % offset)
    os.nice(-10)
    Player(rk, offset).run()
    return 0

if __name__ == '__main__':
    sys.exit(main())
