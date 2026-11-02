import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import manager


class NetworkFactsTests(unittest.TestCase):
    def test_addresses_routes_static_and_privacy(self):
        with tempfile.TemporaryDirectory() as tmp:
            etc = Path(tmp)
            (etc / 'network').mkdir()
            (etc / 'resolv.conf').write_text('search private.example\nnameserver 10.50.0.1\nnameserver 8.8.8.8\nnameserver 2001:4860:4860::8888\n')
            (etc / 'dhcpcd.conf').write_text('# static ip_address=10.50.0.8/24\ninterface eth0\nstatic ip_address=10.50.0.2/32\n')
            (etc / 'network/interfaces').write_text('iface eth0 inet dhcp\n# address 10.50.0.2\n')
            def run(args):
                return {'link': '2: eth0: <BROADCAST,UP,LOWER_UP> mtu 1500 state UP link/ether aa:bb:cc:dd:ee:ff\n3: private-host: <BROADCAST> mtu 1500 state DOWN\n',
                        'addr': '2: eth0 inet 10.50.0.2/32 scope global\n2: eth0 inet 10.2.3.4/24 scope global\n3: private-host inet 8.8.4.4/24 scope global\n',
                        'route': 'default via 10.50.0.1 dev eth0\ndefault via 10.2.3.1 dev eth0\n'}[next(v for v in ('link', 'addr', 'route') if v in args)]
            facts = manager.network_facts(run, etc)
            self.assertEqual(facts['interfaces'][0]['ipv4'], ['10.50.0.2/32', '10.2.3.4/24'])
            self.assertEqual([r['on_link'] for r in facts['default_routes']], [False, True])
            self.assertFalse(facts['interfaces'][1]['up'])
            self.assertEqual(facts['static_ipv4_configured'], {'dhcpcd.conf': True, 'network/interfaces': False})
            text = json.dumps(facts)
            for secret in ('private.example', 'private-host', 'aa:bb:cc:dd:ee:ff', '8.8.8.8', '8.8.4.4', '2001:4860'):
                self.assertNotIn(secret, text)
            (etc / 'dhcpcd.conf').write_text('# static ip_address=10.50.0.2/24\n')
            (etc / 'network/interfaces').write_text('iface eth0 inet static\n address 10.2.3.4\n')
            self.assertEqual(manager.network_facts(run, etc)['static_ipv4_configured'], {'dhcpcd.conf': False, 'network/interfaces': True})

    def test_missing_commands_and_files_are_unknown(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired('ip', 3), subprocess.CalledProcessError(1, 'ip')):
            with tempfile.TemporaryDirectory() as tmp:
                facts = manager.network_facts(mock.Mock(side_effect=error), Path(tmp))
            self.assertEqual(facts['interfaces'], 'unknown')
            self.assertEqual(facts['default_routes'], 'unknown')
            self.assertEqual(facts['nameservers'], 'unknown')
            self.assertTrue(all(v == 'unknown' for v in facts['static_ipv4_configured'].values()))

    def test_report_includes_network_without_saved_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'app'
            root.mkdir()
            expected = {'interfaces': [{'ipv4': ['10.20.30.40/24']}]}
            with mock.patch.object(manager, 'network_facts', return_value=expected):
                report = manager.build_report(root, proc_root=Path(tmp), tmp=Path(tmp))
            self.assertIn('network: ' + json.dumps(expected, sort_keys=True), report)
