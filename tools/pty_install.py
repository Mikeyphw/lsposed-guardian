#!/usr/bin/env python3
"""Give KernelSU's installer a real child PTY inside Devtool's streamed command runner.

Devtool owns output collection and starts a new session; `pty.spawn` gives `ksud`
a controlling pseudoterminal while carrying input from the user's attached Termux
terminal. Do not run in CI/background; never substitute a pipe for installer input.
"""
from __future__ import annotations
import os
import pty
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print('Usage: pty_install.py COMMAND [ARGS...]', file=sys.stderr)
        return 2
    if not os.isatty(sys.stdin.fileno()):
        print('ERROR: Guardian installation requires an interactive Termux terminal (stdin not a TTY).',file=sys.stderr)
        return 2
    try:
        status = pty.spawn(sys.argv[1:])
    except (OSError, KeyboardInterrupt) as exc:
        print(f'ERROR: PTY installer failed: {exc}',file=sys.stderr)
        return 1
    if hasattr(os, 'waitstatus_to_exitcode'):
        return os.waitstatus_to_exitcode(status)
    return (status >> 8) & 0xff

if __name__ == '__main__':
    raise SystemExit(main())
