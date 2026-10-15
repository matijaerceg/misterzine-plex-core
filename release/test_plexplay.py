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


if __name__ == '__main__':
    unittest.main()
