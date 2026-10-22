#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""fake_server.py -- a scripted Jellyfin 10.11 for the client's host test (Python stdlib only).

  fake_server.py --dir TESTDIR --media MEDIA --log LOG.json --portfile FILE
                 [--runtime-a S] [--runtime-b S] [--runtime-c S] [--runtime-d S]

HTTP on 127.0.0.1 (a free port, written to --portfile) and a hand-written WebSocket on /socket.
The endpoints are the ones src/jf.c calls, answered as the server's source does
(docs/jellyfin.md S4): Quick Connect (Initiate by POST only -- GET is 405, as 12.0 answers; the
first two Connect polls unapproved), the MediaBrowser header (the token in it, or ApiKey= on a
URL; legacy forms refused), PlaybackInfo per item, the media with HTTP ranges, the HLS transcode
(master -> main -> segments, every URI carrying ApiKey as the server's do), the playback reports.

MEDIA holds A.mkv (direct play, its A.srt as an External subtitle stream), C.mkv (direct play, no
audio: the pad's item), B.mkv (CAVLC: the
server offers it for direct play -- it cannot see CABAC -- and the client must refuse it) and
hls/main.m3u8 + segments (B's transcode, offered when a PlaybackInfo has EnableDirectPlay false
and AllowVideoStreamCopy false), and hlsD/ (item D: a 1080p HEVC source, offered only as a
transcode -- one TS segment whose audio comes first after 3 s of video, then 6.5 s ahead of it:
the server's muxer of 2026-10-09, docs/jellyfin.md S12).

The scenario (a thread; every wait on a condition, with a timeout that ends the run): sign-in
by Quick Connect -> capabilities -> the socket; ForceKeepAlive (a KeepAlive expected within
2 s); Play A from 0 with its subtitle -> the Playing report -> 3 s -> Pause -> 1.5 s -> Unpause
-> Seek to 6 s (its open answered 1.2 s late: a transcode's restart) -> the seek's Progress -> 1 s ->
SetSubtitleStreamIndex -1 -> 1 s -> SetSubtitleStreamIndex 2 -> 1.5 s ->
SetVolume 50 -> Stop; Play C (300 s, one colour) -> 1 s -> TESTDIR/pad_taps (test_client taps the
pad's RIGHT three times; the seek's open slow) -> the seek's Progress -> 1.5 s -> TESTDIR/pad_hold (RIGHT
held 1.2 s; the open slow again) ->
the seek's Progress -> 1 s -> Stop; Play B -> PlaybackInfo again with direct play off
-> the transcode -> 2 s -> Seek to 4 s (the transcode's segment URLs carry runtimeTicks, so the
client opens the playlist from the segment holding 4 s) -> 2 s -> SetVolume 100 -> played to its end (the Stopped report);
Play D -> its transcode played to its end (the Stopped report). Then TESTDIR/stop (test_client stops
the client), and once TESTDIR/client_done appears (run_test.sh) the log: every request (its
Authorization header, its body), the reports with their times, the socket's messages both
ways, the scenario's times and timeouts.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import struct
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ITEM_A = "a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0"
ITEM_B = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
ITEM_C = "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
ITEM_D = "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"
HLS_DIR = {ITEM_B: "hls", ITEM_D: "hlsD"}
USER_ID = "c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"
SERVER_ID = "d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0"
TOKEN = secrets.token_hex(16)
QC_SECRET = secrets.token_hex(32)
QC_CODE = "418273"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TICKS = 10_000_000

lock = threading.Condition()
st = {
    "requests": [], "reports": [], "ws": [], "events": [], "timeouts": [], "pbinfo": [],
    "qc_initiate_post": 0, "qc_initiate_get": 0, "qc_polls": 0, "qc_authed": False,
    "capabilities": None, "ws_open": False, "srt_fetched": 0,
    "slow_armed": {}, "slow": [],        # the open after a seek made slow (a transcode's restart)
    "srt": [],                           # each .srt request: t_request, t_answer, the start ticks in its URL, slow
}
SLOW_S = 1.2
SLOW_SRT_S = 2.5    # the subtitle switch's .srt: Jellyfin extracting a file's embedded tracks on first request
ws_conn = None          # the open socket: an object with send(text)
args = None


def now():
    return time.time()


def event(what, **kw):
    with lock:
        st["events"].append(dict(t=now(), what=what, **kw))
        lock.notify_all()


def auth_fields(h):
    if not h or not h.startswith("MediaBrowser "):
        return None
    return {k: urllib.parse.unquote(v) for k, v in re.findall(r'(\w+)="([^"]*)"', h)}


class WS(object):
    """the server's side of one WebSocket (RFC 6455): unmasked frames out, masked frames in"""

    def __init__(self, rfile, wfile):
        self.rfile, self.wfile = rfile, wfile
        self.wlock = threading.Lock()
        self.closed = False

    def send(self, text):
        data = text.encode()
        n = len(data)
        hdr = bytes([0x81])
        if n < 126:
            hdr += bytes([n])
        elif n < 65536:
            hdr += bytes([126]) + struct.pack(">H", n)
        else:
            hdr += bytes([127]) + struct.pack(">Q", n)
        with self.wlock:
            self.wfile.write(hdr + data)
            self.wfile.flush()
        with lock:
            st["ws"].append({"t": now(), "dir": "tx", "msg": json.loads(text)})
            lock.notify_all()

    def read_exact(self, n):
        b = b""
        while len(b) < n:
            c = self.rfile.read(n - len(b))
            if not c:
                raise EOFError
            b += c
        return b

    def loop(self):
        buf, unmasked = b"", 0
        while True:
            b0, b1 = self.read_exact(2)
            fin, op, masked, n = b0 & 0x80, b0 & 0x0F, b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self.read_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self.read_exact(8))[0]
            mask = self.read_exact(4) if masked else b"\0\0\0\0"
            if not masked:
                unmasked += 1
            p = bytes(c ^ mask[i % 4] for i, c in enumerate(self.read_exact(n)))
            if op == 8:                                    # close: answer it
                with self.wlock:
                    self.wfile.write(bytes([0x88, 0]))
                    self.wfile.flush()
                break
            if op == 9:                                    # ping -> pong
                with self.wlock:
                    self.wfile.write(bytes([0x8A, len(p)]) + p)
                    self.wfile.flush()
                continue
            if op in (0, 1, 2):
                buf += p
                if fin:
                    try:
                        msg = json.loads(buf.decode())
                    except ValueError:
                        msg = {"_unparsed": buf.decode(errors="replace")}
                    with lock:
                        st["ws"].append({"t": now(), "dir": "rx", "msg": msg, "unmasked_frames": unmasked})
                        lock.notify_all()
                    buf = b""
        self.closed = True


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeJellyfin/10.11"

    def log_message(self, fmt, *a):
        pass

    # ---- helpers ----
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def reply(self, status, obj=None, ctype="application/json; charset=utf-8", raw=None):
        data = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        try:
            self.send_response(status)
            if data or status not in (204,):
                self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if data and self.command != "HEAD":
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return status

    def send_file(self, path, ctype):
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        a, b, status = 0, size - 1, 200
        m = re.match(r"bytes=(\d*)-(\d*)$", rng or "")
        if m:
            if m.group(1):
                a = int(m.group(1))
                if m.group(2):
                    b = min(int(m.group(2)), size - 1)
            elif m.group(2):
                a = max(0, size - int(m.group(2)))
            if a >= size:
                try:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return 416
            status = 206
        try:
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(b - a + 1))
            if status == 206:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (a, b, size))
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(a)
                left = b - a + 1
                while left > 0:
                    chunk = f.read(min(left, 1 << 16))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return status

    def authed(self, q):
        f = auth_fields(self.headers.get("Authorization"))
        return (f is not None and f.get("Token") == TOKEN) or q.get("ApiKey", [None])[0] == TOKEN

    # ---- the dispatcher ----
    def handle_any(self, method):
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query)
        path = u.path
        raw = self.body() if method == "POST" else b""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = {"_unparsed": raw.decode(errors="replace")}
        rec = {"t": now(), "method": method, "path": self.path, "auth": self.headers.get("Authorization"),
               "body": body, "range": self.headers.get("Range")}
        with lock:
            st["requests"].append(rec)
        status = self.route(method, path, q, body)
        rec["status"] = status
        with lock:
            lock.notify_all()

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")

    def route(self, method, path, q, body):
        lp = path.lower()
        if path == "/System/Info/Public" and method == "GET":
            return self.reply(200, {"ServerName": "Fake Jellyfin", "Version": "10.11.0", "Id": SERVER_ID,
                                    "ProductName": "Jellyfin Server", "StartupWizardCompleted": True})
        if path == "/QuickConnect/Enabled" and method == "GET":
            return self.reply(200, True)
        if path == "/QuickConnect/Initiate":
            if method != "POST":                          # 12.0: the GET form is gone
                with lock:
                    st["qc_initiate_get"] += 1
                return self.reply(405)
            with lock:
                st["qc_initiate_post"] += 1
            event("qc_initiate")
            return self.reply(200, {"Authenticated": False, "Secret": QC_SECRET, "Code": QC_CODE,
                                    "DeviceId": "", "DeviceName": "", "AppName": "", "AppVersion": ""})
        if path == "/QuickConnect/Connect" and method == "GET":
            if q.get("secret", [None])[0] != QC_SECRET:
                return self.reply(404)
            with lock:
                st["qc_polls"] += 1
                ok = st["qc_polls"] > 2
                st["qc_authed"] = st["qc_authed"] or ok
            return self.reply(200, {"Authenticated": ok, "Secret": QC_SECRET, "Code": QC_CODE})
        if path == "/Users/AuthenticateWithQuickConnect" and method == "POST":
            with lock:
                ok = st["qc_authed"] and isinstance(body, dict) and body.get("Secret") == QC_SECRET
            if not ok:
                return self.reply(401)
            event("signed_in")
            return self.reply(200, {"AccessToken": TOKEN, "ServerId": SERVER_ID,
                                    "User": {"Id": USER_ID, "Name": "test"}, "SessionInfo": {}})
        # ---- everything below needs the token ----
        if not self.authed(q):
            return self.reply(401)
        if path == "/Users/Me" and method == "GET":
            f = auth_fields(self.headers.get("Authorization"))
            if not f or f.get("Token") != TOKEN:          # the header's token, not ApiKey
                return self.reply(401)
            return self.reply(200, {"Id": USER_ID, "Name": "test"})
        if path == "/Sessions/Capabilities/Full" and method == "POST":
            with lock:
                st["capabilities"] = body
            event("capabilities")
            return self.reply(204)
        if path == "/socket" and method == "GET":
            return self.websocket(q)
        m = re.match(r"^/Items/([0-9a-f]{32})$", path)
        if m and method == "GET":
            item = m.group(1)
            if item not in (ITEM_A, ITEM_B, ITEM_C, ITEM_D):
                return self.reply(404)
            name, rt = {ITEM_A: ("Item A", args.runtime_a), ITEM_B: ("Item B", args.runtime_b),
                        ITEM_C: ("Item C", args.runtime_c), ITEM_D: ("Item D", args.runtime_d)}[item]
            return self.reply(200, {"Id": item, "Name": name, "Type": "Movie", "RunTimeTicks": int(rt * TICKS),
                                    "MediaType": "Video"})
        m = re.match(r"^/Items/([0-9a-f]{32})/PlaybackInfo$", path)
        if m and method == "POST":
            return self.playback_info(m.group(1), body)
        m = re.match(r"^/Videos/([0-9a-f]{32})/stream$", path)
        if m and method == "GET":
            item = m.group(1)
            event("media", item=item, range=self.headers.get("Range"))
            with lock:
                slow = st["slow_armed"].pop(item, None)
            if slow:                                       # the first media request after a seek: slow
                t_req = now()
                time.sleep(SLOW_S)
                with lock:
                    st["slow"].append({"what": slow, "t_request": t_req, "t_answer": now()})
            fn = {ITEM_A: "A.mkv", ITEM_B: "B.mkv", ITEM_C: "C.mkv"}.get(item)
            if not fn:
                return self.reply(404)
            return self.send_file(os.path.join(args.media, fn), "video/x-matroska")
        m = re.match(r"^/Videos/%s/%s/Subtitles/2/(\d+)/Stream\.srt$" % (ITEM_A, ITEM_A), path)
        if m and method == "GET":
            ticks = int(m.group(1))
            t_req = now()
            with lock:
                st["srt_fetched"] += 1
                slow = st["slow_armed"].pop("srt", None)
            if slow:                                       # the first request of a track: extracted, slow
                time.sleep(SLOW_SRT_S)
            with lock:
                st["srt"].append({"t_request": t_req, "t_answer": now(), "ticks": ticks, "slow": bool(slow)})
            event("srt", ticks=ticks)
            text = open(os.path.join(args.media, "A.srt"), encoding="utf-8").read()
            if ticks:                                      # as Jellyfin's FilterEvents: earlier cues dropped, the rest shifted
                text = rebase_srt(text, ticks / TICKS)
            return self.reply(200, raw=text.encode(), ctype="application/x-subrip")
        m = re.match(r"^/videos/(%s|%s)/master\.m3u8$" % (ITEM_B, ITEM_D), lp)
        if m and method == "GET":
            event("hls_master", item=m.group(1))
            text = ("#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=2500000,CODECS=\"avc1.640028,mp4a.40.2\","
                    "RESOLUTION=640x360\nmain.m3u8?ApiKey=%s&PlaySessionId=ps%s\n" % (TOKEN, m.group(1)[:1].upper()))
            return self.reply(200, raw=text.encode(), ctype="application/vnd.apple.mpegurl")
        m = re.match(r"^/videos/(%s|%s)/main\.m3u8$" % (ITEM_B, ITEM_D), lp)
        if m and method == "GET":
            # each segment's URL carries its start and length in the item's ticks, as Jellyfin's do
            # (hls1/main/N.ts?...&runtimeTicks=N&actualSegmentLengthTicks=M): the client trims the
            # playlist to the segment holding its start
            out, t = [], 0
            for ln in open(os.path.join(args.media, HLS_DIR[m.group(1)], "main.m3u8")).read().splitlines():
                if ln.startswith("#EXTINF:"):
                    dur = float(ln[8:].split(",")[0])
                elif re.match(r"^d?seg\d+\.ts$", ln):
                    ln = "%s?ApiKey=%s&runtimeTicks=%d&actualSegmentLengthTicks=%d" % (
                        ln, TOKEN, round(t * TICKS), round(dur * TICKS))
                    t += dur
                out.append(ln)
            text = "\n".join(out) + "\n"
            return self.reply(200, raw=text.encode(), ctype="application/vnd.apple.mpegurl")
        m = re.match(r"^/videos/(%s|%s)/(d?seg\d+\.ts)$" % (ITEM_B, ITEM_D), lp)
        if m and method == "GET":
            event("hls_segment", item=m.group(1), name=m.group(2))
            return self.send_file(os.path.join(args.media, HLS_DIR[m.group(1)], m.group(2)), "video/mp2t")
        rep = {"/Sessions/Playing": "Playing", "/Sessions/Playing/Progress": "Progress",
               "/Sessions/Playing/Stopped": "Stopped"}.get(path)
        if rep and method == "POST":
            with lock:
                st["reports"].append({"t": now(), "kind": rep, "body": body})
                lock.notify_all()
            return self.reply(204)
        return self.reply(404)

    def playback_info(self, item, body):
        if item not in (ITEM_A, ITEM_B, ITEM_C, ITEM_D):
            return self.reply(404)
        body = body if isinstance(body, dict) else {}
        with lock:
            st["pbinfo"].append({"t": now(), "item": item, "body": body})
            n_b = sum(1 for p in st["pbinfo"] if p["item"] == ITEM_B)
            lock.notify_all()
        video = {"Type": "Video", "Index": 0, "Codec": "h264", "Width": 640, "Height": 360, "IsInterlaced": False,
                 "Profile": "High", "BitDepth": 8, "VideoRangeType": "SDR", "DisplayTitle": "360p H264 SDR"}
        if item == ITEM_B:              # (0.16) the transcoded item's source tagged BT.709: the client's override
            video["ColorSpace"] = "bt709"   # must say 3 -- the size rule alone (640x360) would say 1
        audio = {"Type": "Audio", "Index": 1, "Codec": "aac", "Channels": 2, "SampleRate": 48000,
                 "DisplayTitle": "AAC - Stereo", "IsDefault": True}
        ms = {"Id": item, "Protocol": "File", "Container": "mkv", "SupportsDirectPlay": True,
              "SupportsDirectStream": True, "SupportsTranscoding": True, "DefaultAudioStreamIndex": 1,
              "MediaStreams": [video, audio]}
        if item == ITEM_D:                                 # a source only a transcode can carry (the maintainer's film)
            ms["RunTimeTicks"] = int(args.runtime_d * TICKS)
            ms["MediaStreams"] = [dict(video, Codec="hevc", Width=1920, Height=1080, Profile="Main 10", BitDepth=10,
                                       DisplayTitle="1080p HEVC SDR"),
                                  dict(audio, Codec="eac3", Channels=6, DisplayTitle="E-AC-3 - 5.1")]
            ms["SupportsDirectPlay"] = ms["SupportsDirectStream"] = False
            ms["TranscodingUrl"] = ("/videos/%s/master.m3u8?DeviceId=x&MediaSourceId=%s&VideoCodec=h264"
                                    "&AudioCodec=aac&MaxWidth=854&MaxHeight=480&PlaySessionId=psD&ApiKey=%s"
                                    % (ITEM_D, ITEM_D, TOKEN))
            ms["TranscodingSubProtocol"] = "hls"
            ms["TranscodingContainer"] = "ts"
        elif item == ITEM_C:                               # one colour, no audio
            ms["RunTimeTicks"] = int(args.runtime_c * TICKS)
            ms["MediaStreams"] = [dict(video, Width=320, Height=180)]
            ms.pop("DefaultAudioStreamIndex")
        elif item == ITEM_A:
            ms["RunTimeTicks"] = int(args.runtime_a * TICKS)
            ms["MediaStreams"].append({
                "Type": "Subtitle", "Index": 2, "Codec": "srt", "Language": "eng", "DisplayTitle": "English - SRT",
                "IsExternal": True, "DeliveryMethod": "External", "IsTextSubtitleStream": True,
                # the URL carries the StartTimeTicks asked for, as Jellyfin's does (StreamInfo's subtitle URL)
                "DeliveryUrl": "/Videos/%s/%s/Subtitles/2/%d/Stream.srt?ApiKey=%s" % (
                    ITEM_A, ITEM_A, int(body.get("StartTimeTicks") or 0), TOKEN)})
        else:
            ms["RunTimeTicks"] = int(args.runtime_b * TICKS)
            ms["MediaStreams"][0]["Profile"] = "High"      # CAVLC High: the server cannot tell
            forced = body.get("EnableDirectPlay") is False and body.get("AllowVideoStreamCopy") is False
            if forced:
                ms["SupportsDirectPlay"] = ms["SupportsDirectStream"] = False
                ms["TranscodingUrl"] = ("/videos/%s/master.m3u8?DeviceId=x&MediaSourceId=%s&VideoCodec=h264"
                                        "&AudioCodec=aac&MaxWidth=854&MaxHeight=480&PlaySessionId=psB&ApiKey=%s"
                                        % (ITEM_B, ITEM_B, TOKEN))
                ms["TranscodingSubProtocol"] = "hls"
                ms["TranscodingContainer"] = "ts"
            event("pbinfo_b", n=n_b, forced=forced)
        return self.reply(200, {"MediaSources": [ms], "PlaySessionId": "ps%s%d" % (item[:1], len(st["pbinfo"]))})

    def websocket(self, q):
        global ws_conn
        key = self.headers.get("Sec-WebSocket-Key")
        if (self.headers.get("Upgrade") or "").lower() != "websocket" or not key:
            return self.reply(400)
        acc = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", acc)
        self.end_headers()
        self.wfile.flush()
        ws = WS(self.rfile, self.wfile)
        with lock:
            ws_conn = ws
            st["ws_open"] = True
            st["ws_query"] = self.path
        event("ws_open")
        try:
            ws.loop()
        except (EOFError, OSError, ValueError):
            pass
        with lock:
            if ws_conn is ws:
                ws_conn = None
                st["ws_open"] = False
        event("ws_closed")
        self.close_connection = True
        return 101


# ---- the scenario ----
class Abort(Exception):
    pass


def wait_for(pred, timeout, what):
    t_end = now() + timeout
    with lock:
        while not pred():
            left = t_end - now()
            if left <= 0:
                st["timeouts"].append({"t": now(), "what": what})
                raise Abort(what)
            lock.wait(min(left, 0.1))


def soft_wait(pred, timeout, what):
    """a wait whose timeout is recorded (check (0) fails) but does not end the scenario"""
    try:
        wait_for(pred, timeout, what)
    except Abort:
        pass


def send(msg_type, data=None):
    with lock:
        ws = ws_conn
    if ws is None:
        raise Abort("no socket to send %s" % msg_type)
    m = {"MessageType": msg_type, "MessageId": secrets.token_hex(16)}
    if data is not None:
        m["Data"] = data
    ws.send(json.dumps(m))
    return now()


def rebase_srt(text, start):
    """Jellyfin's SubtitleEncoder.FilterEvents without copyTimestamps: the cues ending before
    `start` dropped, the rest shifted by -start"""
    def stamp(x):
        h, m, rest = x.split(":")
        s_, ms = rest.replace(".", ",").split(",")
        return int(h) * 3600 + int(m) * 60 + int(s_) + int(ms) / 1000.0

    def fmt(t):
        ms = int(round(max(0.0, t) * 1000))
        return "%02d:%02d:%02d,%03d" % (ms // 3600000, ms // 60000 % 60, ms // 1000 % 60, ms % 1000)
    out = []
    for block in text.replace("\r\n", "\n").strip().split("\n\n"):
        lines = block.split("\n")
        if len(lines) < 3 or "-->" not in lines[1]:
            continue
        a, b = [stamp(x.strip()) for x in lines[1].split("-->")]
        if b <= start:
            continue
        out.append("\n".join([lines[0], "%s --> %s" % (fmt(a - start), fmt(b - start))] + lines[2:]))
    return "\n\n".join(out) + "\n"


def slow_next(item, what):
    """the next media request for `item` is answered SLOW_S late (the open after a seek)"""
    with lock:
        st["slow_armed"][item] = what


def cue(name):
    """a control file test_client acts on (the pad's presses), the time it was written"""
    t = now()
    open(os.path.join(args.dir, name), "w").close()
    return t


def reports(kind=None, item=None, after=0.0):
    return [r for r in st["reports"] if (kind is None or r["kind"] == kind) and r["t"] > after and
            (item is None or (isinstance(r["body"], dict) and r["body"].get("ItemId") == item))]


def scenario(times):
    t0 = now()
    wait_for(lambda: st["qc_initiate_post"] > 0, 20, "Quick Connect Initiate (POST)")
    wait_for(lambda: any(e["what"] == "signed_in" for e in st["events"]), 30, "the sign-in")
    wait_for(lambda: st["capabilities"] is not None and st["ws_open"], 15, "the capabilities and the socket")
    times["signed_in"] = now()
    # the keep-alive
    t = times["force_keepalive"] = send("ForceKeepAlive", 60)
    try:
        wait_for(lambda: any(w["dir"] == "rx" and w["msg"].get("MessageType") == "KeepAlive" and w["t"] > t
                             for w in st["ws"]), 3, "the KeepAlive")
    except Abort:
        pass                                            # check_client scores it; the run goes on
    # item A: play with its subtitle, pause, unpause, seek, volume, stop
    times["play_a"] = send("Play", {"ItemIds": [ITEM_A], "StartPositionTicks": 0, "PlayCommand": "PlayNow",
                                    "AudioStreamIndex": 1, "SubtitleStreamIndex": 2, "StartIndex": 0,
                                    "ControllingUserId": USER_ID})
    wait_for(lambda: reports("Playing", ITEM_A, times["play_a"]), 20, "item A's Playing report")
    time.sleep(3.0)
    times["pause"] = send("Playstate", {"Command": "Pause", "ControllingUserId": USER_ID})
    time.sleep(1.5)
    times["unpause"] = send("Playstate", {"Command": "Unpause", "ControllingUserId": USER_ID})
    time.sleep(0.5)
    slow_next(ITEM_A, "seek")
    times["seek"] = send("Playstate", {"Command": "Seek", "SeekPositionTicks": 6 * TICKS,
                                       "ControllingUserId": USER_ID})
    # the held seek: the old picture stays up through the slow open; its Progress comes at the release
    soft_wait(lambda: reports("Progress", ITEM_A, times["seek"]), SLOW_S + 3, "item A's seek (the release)")
    time.sleep(1.0)
    # the subtitles off and on again: a text track is the overlay's -- no restart of the stream
    times["sub_off"] = send("GeneralCommand", {"Name": "SetSubtitleStreamIndex", "Arguments": {"Index": "-1"},
                                               "ControllingUserId": USER_ID})
    time.sleep(1.0)
    slow_next("srt", "sub_on")                          # the switch's .srt answered SLOW_SRT_S late
    times["sub_on"] = send("GeneralCommand", {"Name": "SetSubtitleStreamIndex", "Arguments": {"Index": "2"},
                                              "ControllingUserId": USER_ID})
    time.sleep(SLOW_SRT_S + 1.0)
    times["volume"] = send("GeneralCommand", {"Name": "SetVolume", "Arguments": {"Volume": "50"},
                                              "ControllingUserId": USER_ID})
    time.sleep(0.5)
    times["stop_a"] = send("Playstate", {"Command": "Stop", "ControllingUserId": USER_ID})
    wait_for(lambda: reports("Stopped", ITEM_A, times["stop_a"]), 5, "item A's Stopped report")
    time.sleep(0.5)
    # item C: the pad -- three quick RIGHT taps, then RIGHT held (test_client injects them on a cue)
    times["play_c"] = send("Play", {"ItemIds": [ITEM_C], "StartPositionTicks": 0, "PlayCommand": "PlayNow",
                                    "ControllingUserId": USER_ID})
    wait_for(lambda: reports("Playing", ITEM_C, times["play_c"]), 20, "item C's Playing report")
    time.sleep(1.0)
    # the pad's waits never end the run: whatever the client did (one seek, several, none) is what
    # check (o) scores, so the phase always runs to C's Stop
    slow_next(ITEM_C, "taps")
    times["pad_taps"] = cue("pad_taps")
    soft_wait(lambda: reports("Progress", ITEM_C, times["pad_taps"]), 5 + SLOW_S, "item C's seek (the taps)")
    time.sleep(1.5)
    slow_next(ITEM_C, "hold")
    times["pad_hold"] = cue("pad_hold")
    time.sleep(1.2 + 0.6)                                  # the hold, then the client's settle
    soft_wait(lambda: reports("Progress", ITEM_C, times["pad_hold"] + 1.2), 3 + SLOW_S, "item C's seek (the hold)")
    time.sleep(1.0)
    times["stop_c"] = send("Playstate", {"Command": "Stop", "ControllingUserId": USER_ID})
    wait_for(lambda: reports("Stopped", ITEM_C, times["stop_c"]), 5, "item C's Stopped report")
    time.sleep(0.5)
    # item B: CAVLC -> the client asks again with direct play off -> the transcode to its end
    times["play_b"] = send("Play", {"ItemIds": [ITEM_B], "StartPositionTicks": 0, "PlayCommand": "PlayNow",
                                    "ControllingUserId": USER_ID})
    wait_for(lambda: sum(1 for p in st["pbinfo"] if p["item"] == ITEM_B) >= 2, 15, "item B's second PlaybackInfo")
    wait_for(lambda: reports("Playing", ITEM_B, times["play_b"]), 20, "item B's Playing report")
    # a seek in the transcode: the client opens the playlist trimmed to the segment holding 4 s
    time.sleep(2.0)
    times["seek_b"] = send("Playstate", {"Command": "Seek", "SeekPositionTicks": 4 * TICKS,
                                         "ControllingUserId": USER_ID})
    soft_wait(lambda: reports("Progress", ITEM_B, times["seek_b"]), 5, "item B's seek (the release)")
    # a report while the trimmed stream plays (its position: the PTS less the trimmed origin -- (h))
    time.sleep(2.0)
    times["volume_b"] = send("GeneralCommand", {"Name": "SetVolume", "Arguments": {"Volume": "100"},
                                                "ControllingUserId": USER_ID})
    wait_for(lambda: [r for r in reports("Stopped", ITEM_B, times["play_b"])
                      if r["t"] > reports("Playing", ITEM_B, times["play_b"])[0]["t"]],
             2 * args.runtime_b + 20, "item B's Stopped report at its end")
    times["end_b"] = now()
    time.sleep(0.5)
    # item D: the transcode whose audio the probe missed and which then runs seconds ahead of its video
    times["play_d"] = send("Play", {"ItemIds": [ITEM_D], "StartPositionTicks": 0, "PlayCommand": "PlayNow",
                                    "ControllingUserId": USER_ID})
    wait_for(lambda: reports("Playing", ITEM_D, times["play_d"]), 20, "item D's Playing report")
    wait_for(lambda: [r for r in reports("Stopped", ITEM_D, times["play_d"])
                      if r["t"] > reports("Playing", ITEM_D, times["play_d"])[0]["t"]],
             2 * args.runtime_d + 20, "item D's Stopped report at its end")
    times["end_d"] = now()


def main():
    global args
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--media", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--portfile", required=True)
    ap.add_argument("--runtime-a", type=float, default=12.0)
    ap.add_argument("--runtime-b", type=float, default=8.0)
    ap.add_argument("--runtime-c", type=float, default=300.0)
    ap.add_argument("--runtime-d", type=float, default=10.0)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    with open(args.portfile + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    os.rename(args.portfile + ".tmp", args.portfile)
    times = {"t0": now()}
    try:
        scenario(times)
        times["completed"] = True
    except Abort as e:
        times["completed"] = False
        times["aborted"] = str(e)
    open(os.path.join(args.dir, "stop"), "w").close()     # test_client stops the client
    done = os.path.join(args.dir, "client_done")
    for _ in range(600):                                 # the client's last reports, then the log
        if os.path.exists(done):
            break
        time.sleep(0.05)
    time.sleep(0.2)
    with lock:
        log = dict(st, times=times, token=TOKEN, items={"A": ITEM_A, "B": ITEM_B, "C": ITEM_C, "D": ITEM_D}, user=USER_ID,
                   qc_secret=QC_SECRET, runtime={"A": args.runtime_a, "B": args.runtime_b, "C": args.runtime_c,
                                                 "D": args.runtime_d})
        json.dump(log, open(args.log, "w"), indent=1, default=str)
    srv.shutdown()
    print("fake_server: scenario %s" % ("completed" if times["completed"] else "ABORTED: " + times["aborted"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
