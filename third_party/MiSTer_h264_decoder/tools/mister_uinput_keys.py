#!/usr/bin/env python3
"""
mister_uinput_keys.py -- a scripted keyboard ON the MiSTer, for input rounds that need keys
held and overlapping (a key held across the OSD's opening, a chord), which the harness's key
daemon (tools/mister_keyd.py: one make+break at a time) cannot do.

    scp tools/mister_uinput_keys.py root@<mister-ip>:/tmp/
    ssh root@<mister-ip> python3 /tmp/mister_uinput_keys.py TOKEN...

    d:CODE  key down        u:CODE  key up
    p:CODE  press (50 ms)   s:SEC   sleep
    (CODE: a Linux keycode -- h 35, e 18, l 38, o 24, z 44, a 30, b 48, c 46, Enter 28, F12 88)

It creates ONE uinput keyboard ("ML input test"), waits 2 s for its readers to open it,
plays the tokens, and destroys the device (Main then re-enumerates every input device:
harmless between rounds, not something to do mid-measurement -- tools/mister_keyd.py).
Like every device it is grabbed by Main while a core runs, so its keys reach Main (and,
through hps_io, the core) -- not a program reading /dev/input (docs/moonlight.md M5).

The instrument used with it (docs/history.md §12): a text editor on the PC's captured display,
read back through the stream by `mister.py shot`; the PC's own key repeat is the control
arm (a key held 2 s with nothing in the way types a row of repeats).
"""
import fcntl
import os
import struct
import sys
import time

UI_DEV_CREATE, UI_SET_EVBIT, UI_SET_KEYBIT = 0x5501, 0x40045564, 0x40045565
EV_SYN, EV_KEY = 0, 1


def main(tokens):
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in range(1, 249):                 # every ordinary key (mister_keyd.py explains why)
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    # struct uinput_user_dev: name[80], input_id (4 x u16), ff_effects_max, 4 x 64 ints
    os.write(fd, b'ML input test'.ljust(80, b'\0') + struct.pack('<HHHH', 3, 0xDEAD, 0xBEF0, 1)
             + struct.pack('<i', 0) + b'\0' * (4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(2.0)

    def key(code, value):
        os.write(fd, struct.pack('<llHHi', 0, 0, EV_KEY, code, value))
        os.write(fd, struct.pack('<llHHi', 0, 0, EV_SYN, 0, 0))

    for tok in tokens:
        op, arg = tok.split(':')
        if op == 'd':
            key(int(arg), 1)
        elif op == 'u':
            key(int(arg), 0)
        elif op == 'p':
            key(int(arg), 1)
            time.sleep(0.05)
            key(int(arg), 0)
            time.sleep(0.08)
        elif op == 's':
            time.sleep(float(arg))
        else:
            sys.exit('unknown token %r' % tok)
    time.sleep(0.5)
    os.close(fd)


if __name__ == '__main__':
    main(sys.argv[1:])
