#!/usr/bin/env python3
"""Keep modifier keys in the i3 window (Xephyr) in sync with the real keyboard.

Usage: unstick-keys.py HOST_DISPLAY NESTED_DISPLAY     e.g.  :0 :1

Xephyr only learns that a key was released if it has focus at that moment.
Let go of Alt while another window has focus (Alt+Tab to a Windows app, for
example) and Xephyr keeps Alt "held": every d then opens the launcher and
every Enter a terminal.

Four times a second this asks both X servers which modifier keys they think
are held. Any key the i3 window thinks is held but WSLg's X server (which
follows the real keyboard) doesn't, gets a "released" event sent to the i3
window. Uses only libX11 (always present) and xdotool. Exits when either
display goes away.
"""
import ctypes
import os
import subprocess
import sys
import time

MODIFIERS = ["Alt_L", "Alt_R", "Meta_L", "Meta_R", "Control_L", "Control_R",
             "Shift_L", "Shift_R", "Super_L", "Super_R"]


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    host_name, nested_name = sys.argv[1], sys.argv[2]

    x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XStringToKeysym.restype = ctypes.c_ulong
    x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
    x11.XKeysymToKeycode.restype = ctypes.c_ubyte
    x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XQueryKeymap.argtypes = [ctypes.c_void_p, ctypes.c_char * 32]

    # When a display closes (i3 window shut), exit quietly instead of printing
    # Xlib's fatal error message.
    io_handler_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
    on_io_error = io_handler_type(lambda _display: os._exit(0))
    x11.XSetIOErrorHandler(on_io_error)

    host = x11.XOpenDisplay(host_name.encode())
    nested = x11.XOpenDisplay(nested_name.encode())
    if not host or not nested:
        return 0

    def keycodes(display):
        return {name: x11.XKeysymToKeycode(display, x11.XStringToKeysym(name.encode()))
                for name in MODIFIERS}

    def held(display, codes):
        buf = (ctypes.c_char * 32)()
        x11.XQueryKeymap(display, buf)
        keys = buf.raw
        return {name for name, code in codes.items()
                if code and (keys[code >> 3] >> (code & 7)) & 1}

    host_codes = keycodes(host)
    env = dict(os.environ, DISPLAY=nested_name)
    while True:
        # Re-read the nested keymap each time: the layout can change (setxkbmap).
        stuck = held(nested, keycodes(nested)) - held(host, host_codes)
        if stuck:
            subprocess.run(["xdotool", "keyup", *sorted(stuck)], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.25)


if __name__ == "__main__":
    sys.exit(main())
