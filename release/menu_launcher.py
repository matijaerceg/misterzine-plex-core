#!/usr/bin/env python3
"""Launch the installed app when its MiSTer main-menu entry is selected."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import time

# The entry loads the core itself; 'misterzine-plex' is the pre-beta.4 menu bounce.
SELECTIONS = ('MisterZine Plex Core', 'MisterZine Plex', 'misterzine-plex')


def start_upkeep(card, root):
    """Check the Plex entries once as the watch starts (at boot, or after an
    install): `manager.py maintain`. A child process, so the watch starts at
    once; the caller reaps it."""
    try:
        with open('/tmp/misterzine-plex-maintain.log', 'wb') as log:
            return subprocess.Popen([sys.executable, str(root / 'manager.py'), 'maintain', '--card', str(card)],
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    except OSError:
        return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--card', type=Path, default=Path('/media/fat'))
    card = p.parse_args().card.resolve()
    root = card / 'misterzine-plex'
    key = hashlib.sha256(str(card).encode()).hexdigest()[:16]
    with open('/tmp/misterzine-plex-menu-' + key + '.lock', 'a') as singleton:
        try:
            fcntl.flock(singleton, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        handled = None
        upkeep = start_upkeep(card, root)
        while root.is_dir() and (root / 'menu_launcher.py').is_file():
            time.sleep(.1)
            if upkeep is not None and upkeep.poll() is not None:
                upkeep = None
            try:
                name = Path('/tmp/CORENAME')
                stamp = name.stat().st_mtime_ns
                if stamp == handled or name.read_text().strip() not in SELECTIONS:
                    continue
                # An activation/uninstall must finish before a menu launch: keep
                # the selection and look again, holding no lock meanwhile.
                with (root / 'updates/worker.lock').open('a') as worker:
                    try:
                        fcntl.flock(worker, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except BlockingIOError:
                        continue
                    handled = stamp
                    with (root / 'manager.lock').open('a') as manager:
                        try:
                            fcntl.flock(manager, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            # Something else started the app on this core load
                            # (an update restart, for one); it is not ours to launch.
                            continue
                    if name.read_text().strip() not in SELECTIONS or not (root / 'active.json').is_file():
                        continue
                    # Keep the previous attempt: a launch that bounces and starts
                    # again would otherwise erase the log that explains it.
                    try:
                        os.replace('/tmp/misterzine-plex-menu-run.log', '/tmp/misterzine-plex-menu-run.log.1')
                    except OSError:
                        pass
                    with open('/tmp/misterzine-plex-menu-run.log', 'wb') as log:
                        child = subprocess.Popen([sys.executable, str(root / 'manager.py'), 'run', '--card', str(card)],
                            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                # A new pick always passes through the menu first. Any other
                # change of the core name while the app runs (a forked main
                # rewrites it when the app dies) is not a pick: mark it handled
                # so a crashed app never relaunches by itself.
                left = False
                while child.poll() is None:
                    time.sleep(.1)
                    if upkeep is not None and upkeep.poll() is not None:
                        upkeep = None
                    try:
                        left = left or name.read_text().strip() not in SELECTIONS
                    except OSError:
                        pass
                if not left:
                    try:
                        handled = name.stat().st_mtime_ns
                    except OSError:
                        pass
            except OSError:
                time.sleep(1)


if __name__ == '__main__':
    main()
