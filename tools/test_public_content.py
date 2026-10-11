import unittest
from check_public_content import issues


class ContentTests(unittest.TestCase):
    def test_internal_state_rejected(self):
        for name in ('HANDOFF.md', 'docs/M2_RESULTS.md', 'release/private-beta/key.zip', 'beta.key', 'plexcrt.json.bak', '.env'):
            self.assertTrue(issues(name, b''), name)

    def test_safe_examples_and_source_allowed(self):
        self.assertEqual(issues('.env.example', b'PLEX_TOKEN=example'), [])
        self.assertEqual(issues('app/player.go', b'// frame ownership'), [])
        self.assertEqual(issues('app/home.go', b'/api/home/users/123/switch'), [])

    def test_home_api_exception_keeps_filesystem_paths_private(self):
        for path in (b'/home/' + b'example/project', b'/home/' + b'users/private'):
            self.assertIn('personal machine path or device address', issues('notes.txt', path))

    def test_private_content_rejected_without_printing_it(self):
        path = b'C:' + b'/Users/' + b'example/project'
        self.assertIn('personal machine path or device address', issues('README.md', path))
        token = b'ghp_' + b'a' * 36
        self.assertIn('possible credential', issues('settings.txt', token))
        server = b'http://' + b'203.0.113.1:32400'
        self.assertIn('literal server address; use configuration', issues('client.py', server))


if __name__ == '__main__':
    unittest.main()
