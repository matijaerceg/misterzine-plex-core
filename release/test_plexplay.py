import os
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import MagicMock, patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
old_host, old_token = os.environ.get('PLEX_HOST'), os.environ.get('PLEX_TOKEN')
os.environ['PLEX_HOST'] = 'http://plex.test:32400'
os.environ['PLEX_TOKEN'] = 'synthetic-token'
sys.path.insert(0, str(ROOT / 'arm'))
import plexplay
if old_host is None:
    os.environ.pop('PLEX_HOST', None)
else:
    os.environ['PLEX_HOST'] = old_host
if old_token is None:
    os.environ.pop('PLEX_TOKEN', None)
else:
    os.environ['PLEX_TOKEN'] = old_token


class Pipe:
    def close(self):
        pass


class Process:
    def __init__(self):
        self.stdout = Pipe()
        self.stderr = Pipe()
        self.stdin = Pipe()


class ServerAddressTests(unittest.TestCase):
    def test_private_lan_from_either_connection_form(self):
        self.assertIs(plexplay.private_host('10-0-0-2.abcdef.plex.direct'), True)
        self.assertIs(plexplay.private_host('1-1-1-1.abcdef.plex.direct'), False)
        self.assertIs(plexplay.private_host('10.0.0.2'), True)
        self.assertIs(plexplay.private_host('1.1.1.1'), False)
        self.assertIsNone(plexplay.private_host('plex.test'))


class SubtitleTranscodeTests(unittest.TestCase):
    def test_size_is_sent_to_decision_and_start_requests(self):
        player = plexplay.Player.__new__(plexplay.Player)
        player.rk = '123'
        player.offset = 42.8
        player.sess = 'synthetic-session'
        player.subtitle_size = 150
        player.src_fps = 23.976
        player.pump = False
        player.resp = None
        player.paused = True
        ff, fb = Process(), Process()
        xml = b'<MediaContainer transcodeDecisionCode="1000" transcodeDecisionText="OK">' \
              b'<Media videoFrameRate="24p"><Stream streamType="1" frameRate="23.976"/></Media></MediaContainer>'
        with patch.object(plexplay, 'get', return_value=xml) as get, \
             patch.object(plexplay.subprocess, 'Popen', side_effect=[ff, fb]) as popen, \
             patch.object(plexplay.threading, 'Thread'), \
             patch.object(plexplay.os, 'unlink'):
            player.start()
        decision_params = get.call_args.args[1]
        start_command = popen.call_args_list[0].args[0]
        url = start_command[start_command.index('-i') + 1]
        start_params = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertEqual(decision_params['subtitleSize'], 150)
        self.assertEqual(start_params['subtitleSize'], ['150'])
        self.assertEqual(decision_params['offset'], 42)
        self.assertTrue(player.paused, 'starting a presenter must preserve desired pause state')

    def test_pause_waits_for_ready_marker_and_honors_resume_during_restart(self):
        player = plexplay.Player.__new__(plexplay.Player)
        player.restart_paused = True
        player.paused = True
        player.lock = threading.Lock()
        player.p_fb = MagicMock()
        player.p_fb.poll.return_value = None
        player.timeline = MagicMock()
        with patch.object(plexplay.os.path, 'exists', return_value=False):
            self.assertFalse(player.restore_pause_if_ready())
        player.p_fb.send_signal.assert_not_called()
        with patch.object(plexplay.os.path, 'exists', return_value=True):
            self.assertTrue(player.restore_pause_if_ready())
        player.p_fb.send_signal.assert_called_once_with(plexplay.signal.SIGUSR1)

        player.restart_paused = True
        player.paused = True
        player.p_fb.reset_mock()
        with patch.object(plexplay.os.path, 'exists', return_value=False):
            player.command('resume')
            self.assertFalse(player.restore_pause_if_ready())
        player.p_fb.send_signal.assert_not_called()
        self.assertFalse(player.paused)
        with patch.object(plexplay.os.path, 'exists', return_value=True):
            self.assertTrue(player.restore_pause_if_ready())
            self.assertFalse(player.restore_pause_if_ready())
        player.p_fb.send_signal.assert_not_called()

    def test_size_without_restart_updates_next_stream(self):
        player = plexplay.Player.__new__(plexplay.Player)
        player.subtitle_size = 100
        player.paused = False
        player.restart_paused = False
        player.lock = threading.Lock()
        player.pending = None
        player.position = lambda: 42.0
        player.interrupt = MagicMock()
        player.command('subtitle_size 150 0')
        self.assertEqual(player.subtitle_size, 150)
        self.assertIsNone(player.pending)
        player.interrupt.assert_not_called()

    def test_active_size_restart_captures_position_and_pause_state(self):
        player = plexplay.Player.__new__(plexplay.Player)
        player.subtitle_size = 100
        player.paused = True
        player.lock = threading.Lock()
        player.pending = None
        player.position = lambda: 42.5
        player.interrupt = MagicMock()
        player.command('subtitle_size 150 1')
        self.assertEqual(player.pending, ('subtitle_size', 150, 42.5, True))
        player.interrupt.assert_called_once_with(hold=True)
        player.interrupt.reset_mock()
        player.command('subtitle_size 150 1')
        self.assertEqual(player.pending, ('subtitle_size', 150, 42.5, True))
        player.interrupt.assert_not_called()


TIMELINE_REPLY = (b'<MediaContainer size="2" playbackState="ignore"><Bandwidths><Bandwidth time="0" bandwidth="2384"/></Bandwidths>'
                  b'<TranscodeSession key="/transcode/sessions/synthetic" throttled="0" speed="0.80000001" '
                  b'maxOffsetAvailable="612.5" minOffsetAvailable="600.0" videoDecision="transcode" '
                  b'sourceVideoCodec="hevc" transcodeHwRequested="0"/></MediaContainer>')


class ServerHealthTests(unittest.TestCase):
    def player(self, starved=0, pos=610.0):
        player = plexplay.Player.__new__(plexplay.Player)
        player.health = {'first': None, 'logged': 0.0, 'starved': 0, 'missed': 0, 'reports': 0,
                         'throttled': 0, 'speeds': [], 'closest': None, 'hardware': [], 'silent': False,
                         'peak_mbps': None, 'cpu_peak': None}
        player.cpu = 'refused'
        player.intake = None
        player.position = lambda: pos
        return player

    def test_timeline_reply_becomes_one_plain_line(self):
        ts = plexplay.transcode_health(TIMELINE_REPLY)
        self.assertEqual(plexplay.health_text(ts, 610.0, 7),
                         'server: converting at 0.8x, 2 s ahead of playback, video transcode from hevc, '
                         'hardware off; frames missed here: 7')

    def test_throttled_and_hardware_sessions_read_as_such(self):
        ts = {'throttled': '1', 'speed': '0', 'maxOffsetAvailable': '700', 'videoDecision': 'transcode',
              'sourceVideoCodec': 'hevc', 'transcodeHwRequested': '1', 'transcodeHwDecoding': 'vaapi',
              'transcodeHwEncodingTitle': 'Intel (QuickSync)'}
        line = plexplay.health_text(ts, 600.0, 0)
        self.assertIn('throttled (ahead enough, resting), 100 s ahead', line)
        self.assertIn('hardware decode vaapi, encode Intel (QuickSync)', line)
        self.assertEqual(plexplay.hardware_text({'transcodeHwRequested': '1'}), 'requested but not in use')
        self.assertIn('converting (speed not measured yet)', plexplay.health_text({'throttled': '0', 'speed': '0'}, 0, 0))

    def test_replies_without_a_session_are_noted_once(self):
        self.assertIsNone(plexplay.transcode_health(b'<MediaContainer size="0"/>'))
        self.assertIsNone(plexplay.transcode_health(b'not xml'))
        player = self.player()
        with patch.object(plexplay, 'log') as log:
            player.note_health(b'<MediaContainer size="0"/>')
            player.note_health(b'<MediaContainer size="0"/>')
        log.assert_called_once_with('server: no transcode report in the timeline reply')

    def test_missed_frames_follow_the_presenter_count_and_feed_the_summary(self):
        player = self.player()
        with patch.object(plexplay, 'read_status', return_value={'starved': 12.0}), \
             patch.object(plexplay, 'log') as log:
            player.note_health(TIMELINE_REPLY)
        self.assertIn('frames missed here: 12', log.call_args_list[0].args[0])
        # a restarted presenter counts from zero again
        with patch.object(plexplay, 'read_status', return_value={'starved': 3.0}), \
             patch.object(plexplay, 'log') as log:
            player.note_health(TIMELINE_REPLY.replace(b'0.80000001', b'0.9'))
        self.assertIn('frames missed here: 3', log.call_args_list[0].args[0])
        with patch.object(plexplay, 'log') as log:
            player.health_summary()
        self.assertEqual(log.call_args.args[0],
                         'server summary: 2 reports; converting speed lowest 0.8x, median 0.9x; throttled in 0 of 2; '
                         'closest to playback 2 s ahead; hardware off; frames missed here 15; '
                         'network in peak second not measured; decoder cpu highest not measured')

    def test_quiet_healthy_minutes_are_not_logged_every_ping(self):
        player = self.player(pos=500.0)
        healthy = TIMELINE_REPLY.replace(b'throttled="0"', b'throttled="1"')
        with patch.object(plexplay, 'read_status', return_value={}), \
             patch.object(plexplay, 'log') as log, \
             patch.object(plexplay.time, 'time', side_effect=[1000.0, 1010.0, 1130.0, 1140.0, 1180.0]):
            for _ in range(5):
                player.note_health(healthy)
        # the first two minutes, then once a minute
        self.assertEqual(log.call_count, 6)   # each with its stream line
        self.assertEqual(player.health['reports'], 5)

    def fed(self, rates, ticks_per_s=150):
        intake = plexplay.Intake()
        b = 0
        intake.feed(b, 0, 0.0)
        for i, r in enumerate(rates, 1):
            b += r
            intake.feed(b, ticks_per_s * i, float(i))
        return intake

    def test_intake_averages_peaks_and_cpu(self):
        # 10 s: nine at 250 kB/s, one at 800 kB/s; 1.5 s of CPU per second at 100 Hz
        m = self.fed([250000] * 9 + [800000]).take(100, 2)
        self.assertAlmostEqual(m[0], 2.44)
        self.assertAlmostEqual(m[1], 6.4)
        self.assertAlmostEqual(m[2], 150.0)
        self.assertEqual(plexplay.intake_text(m),
                         'network in: avg 2.4 Mbps, peak second 6.4 Mbps; decoder cpu 150% of 200%')
        self.assertEqual(plexplay.intake_text(None), 'network in: not measured')

    def test_intake_window_resets_each_ping(self):
        intake = self.fed([800000, 250000])
        self.assertAlmostEqual(intake.take(100, 2)[1], 6.4)
        self.assertIsNone(intake.take(100, 2))
        intake.feed(1050000 + 250000, 450, 3.0)
        m = intake.take(100, 2)
        self.assertAlmostEqual(m[0], 2.0)
        self.assertAlmostEqual(m[1], 2.0)

    def test_stream_line_follows_the_server_line_and_feeds_the_summary(self):
        player = self.player()
        player.intake = self.fed([250000] * 9 + [800000])
        with patch.object(plexplay, 'read_status', return_value={}), \
             patch.object(plexplay, 'log') as log:
            player.note_health(TIMELINE_REPLY)
            player.note_health(TIMELINE_REPLY)
        lines = [c.args[0] for c in log.call_args_list]
        self.assertTrue(lines[0].startswith('server: '))
        self.assertRegex(lines[1], r'^network in: avg 2\.4 Mbps, peak second 6\.4 Mbps; decoder cpu \d+% of 200%$')
        self.assertEqual(lines[3], 'network in: not measured')
        self.assertAlmostEqual(player.health['peak_mbps'], 6.4)
        with patch.object(plexplay, 'log') as log:
            player.health_summary()
        self.assertRegex(log.call_args.args[0], r'; network in peak second 6\.4 Mbps; decoder cpu highest \d+%$')

    def test_network_bytes_skip_loopback(self):
        dev = ('Inter-|   Receive\n face |bytes    packets\n'
               '    lo:  999999   10 0 0 0 0 0 0 999999 10 0 0 0 0 0 0\n'
               '  eth0:1234567 900 0 0 0 0 0 0 5000 40 0 0 0 0 0 0\n'
               ' wlan0: 1000   5 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n')
        self.assertEqual(plexplay.net_rx(dev), 1235567)

    def test_source_names_what_the_server_decodes(self):
        video = plexplay.ET.fromstring(
            '<Video><Media videoCodec="hevc" width="3840" height="2160" bitrate="54808" container="mkv">'
            '<Part><Stream streamType="1" bitDepth="10" colorTrc="smpte2084"/></Part></Media>'
            '<Media videoCodec="h264" width="1920" height="1080"/></Video>')
        self.assertEqual(plexplay.source_text(video), 'hevc 3840x2160 10-bit HDR 54808 kbps mkv, 2 versions')
        self.assertEqual(plexplay.source_text(plexplay.ET.fromstring('<Video/>')), 'unknown')


if __name__ == '__main__':
    unittest.main()
