#!/usr/bin/env python3
"""Integration check: launch the built app and verify SIGTERM/SIGINT exit.

Uses the app's normal CLI configuration. No model requests are made.
Run after building, with the normal app instance closed.
"""
import argparse
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("executable", type=Path)
args = parser.parse_args()
executable = args.executable.resolve(strict=True)

for termination_signal in (signal.SIGTERM, signal.SIGINT):
    process = subprocess.Popen([str(executable)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1)
        if process.poll() is not None:
            raise RuntimeError("App exited before the termination check")
        process.send_signal(termination_signal)
        result = process.wait(timeout=5)
        if result != 0:
            raise RuntimeError(f"{termination_signal.name}: unexpected exit code {result}")
        print(f"PASS: {termination_signal.name} — app exited normally")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
