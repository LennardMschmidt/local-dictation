"""Measures whether the first dictation after an idle pause is slower.

Runs one live dictation through the test control, waits, runs another, and prints the timings
the app logged. The app must run with "testControl": true. Do not use the Mac meanwhile.

    python3 scripts/idle-test.py --pauses 0 60 180
"""

import argparse
import subprocess
import time
from pathlib import Path

LOG = Path.home() / "Library/Application Support/LocalDictation/app.log"


def post(name):
    js = ('ObjC.import("Foundation");'
          '$.NSDistributedNotificationCenter.defaultCenter'
          f'.postNotificationNameObjectUserInfoDeliverImmediately("local.dictation.LocalDictation.test.{name}", $(), $(), true);')
    subprocess.run(["osascript", "-l", "JavaScript", "-e", js], check=True, capture_output=True)


def dictate(sentence):
    offset = LOG.stat().st_size
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'], check=True)
    post("start")
    time.sleep(0.6)
    subprocess.run(["say", "-v", "Anna", sentence], check=True)
    time.sleep(0.3)
    post("stop")
    for _ in range(40):
        time.sleep(0.5)
        with open(LOG, encoding="utf-8") as f:
            f.seek(offset)
            for line in f.read().splitlines():
                if "dictation audio" in line:
                    return line.split("INFO ", 1)[1]
    return "no result"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pauses", type=int, nargs="+", default=[0, 60, 180])
    args = parser.parse_args()
    volume = subprocess.run(["osascript", "-e", "output volume of (get volume settings)"],
                            capture_output=True, text=True).stdout.strip()
    subprocess.run(["osascript", "-e", "set volume output volume 50"], check=True)
    subprocess.run(["osascript", "-e", 'tell application "TextEdit" to make new document'], check=True)
    try:
        for pause in args.pauses:
            if pause:
                time.sleep(pause)
            print(f"after {pause:>4}s idle: {dictate('Das ist ein kurzer Test nach einer Pause.')}", flush=True)
    finally:
        subprocess.run(["osascript", "-e", f"set volume output volume {volume}"])
        subprocess.run(["osascript", "-e", 'tell application "TextEdit" to close document 1 saving no'])


if __name__ == "__main__":
    main()
