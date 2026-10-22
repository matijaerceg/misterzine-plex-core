#!/usr/bin/env python3
"""Check the public Git file inventory for internal notes and sensitive state."""
import argparse
import ipaddress
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
INTERNAL = re.compile(r'^(HANDOFF|RESEARCH|PUBLIC_TESTING|ACCOUNT_NAME|BITRATE_TESTING|FEATURE_RESULTS|LIBRARY_SCROLLING|SEARCH_PROTOTYPE|SHOW_TRANSITIONS|M[0-9]+_RESULTS)\.md$', re.I)
PERSONAL = re.compile(rb'(?:[A-Za-z]:[/\\]Users[/\\][A-Za-z0-9_.-]+[/\\]|(?<!/api)/home/[A-Za-z0-9_.-]+/|/Users/[A-Za-z0-9_.-]+/|192\.168\.\d{1,3}\.\d{1,3})')
TOKEN = re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk_live_[A-Za-z0-9]{20,})\b|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
# A Plex account token (20 characters) in a URL or header, or a server's
# plex.direct name, which carries its address and its certificate's hash.
PLEX = re.compile(rb'(?i:x-plex-token)[\x22\x27]?\s*[=:]\s*[\x22\x27]?[A-Za-z0-9_-]{20}(?![A-Za-z0-9_-])|\b(?:\d{1,3}-){3}\d{1,3}\.[0-9a-f]{32}\.plex\.direct\b')
SERVER = re.compile(rb'https?://((?:\d{1,3}\.){3}\d{1,3})(?=[:/\s\x27\x22]|$)')
DOCUMENTATION_NETWORKS = tuple(map(ipaddress.ip_network, ('192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24')))


def literal_server_address(data):
    for match in SERVER.finditer(data):
        try:
            address = ipaddress.ip_address(match.group(1).decode('ascii'))
        except ValueError:
            return True
        if address.is_loopback or any(address in network for network in DOCUMENTATION_NETWORKS):
            continue
        return True
    return False


def issues(name, data):
    p = PurePosixPath(name)
    errors = []
    if p.name in ('access-codes.json', 'PRIVATE_ASSEMBLY.json') or re.search(rb'^//go:build premium(?:\s|$)', data, re.M):
        errors.append('private supporter implementation or registry')
    if INTERNAL.fullmatch(p.name):
        errors.append('internal working document')
    if p.suffix in ('.key', '.code', '.receipt') or p.name.startswith(('plexcrt.json', '.plextoken', '.env')) and p.name != '.env.example' or any(x in p.parts for x in ('private-beta', '.claude', '__pycache__', 'node_modules')):
        errors.append('private state or generated directory')
    if b'\x00' not in data:
        if PERSONAL.search(data): errors.append('personal machine path or device address')
        if TOKEN.search(data): errors.append('possible credential')
        if PLEX.search(data): errors.append('Plex token or plex.direct address')
        if literal_server_address(data): errors.append('literal server address; use configuration')
        if re.search(rb'^(<<<<<<< |=======\r?$|>>>>>>> )', data, re.M): errors.append('unresolved merge marker')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='inspect exactly the index that will be committed')
    args = parser.parse_args()
    command = ['git', 'ls-files', '-z', '--cached']
    if not args.staged: command += ['--others', '--exclude-standard']
    names = sorted(set(subprocess.check_output(command, cwd=ROOT).decode().strip('\0').split('\0')))
    failures = []
    for name in filter(None, names):
        if args.staged:
            data = subprocess.check_output(['git', 'show', ':' + name], cwd=ROOT)
        else:
            if not (ROOT / name).is_file(): continue
            data = (ROOT / name).read_bytes()
        failures += [name + ': ' + error for error in issues(name, data)]
    if failures:
        print('\n'.join(failures))
        return 1
    print('Public content check passed:', len(names), 'files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
