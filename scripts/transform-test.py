"""Live test of command mode (ctrl + fn) against the installed app.

TextEdit gets a sentence, the app selects it (test control `selectAll`), a command recording
starts (test control `command`), `say` speaks the instruction, and the script checks that the
selection was replaced. Needs "testControl": true. Do not use the Mac while it runs.

    python3 scripts/transform-test.py
"""

import subprocess
import time

CASES = [
    {"id": "preset-formal", "voice": "Anna", "instruction": "Formal",
     "text": "hey leute, das deployment hat heute nicht geklappt, ich schau morgen nochmal rein",
     "must_all": ["Deployment", "morgen"], "must_not": ["hey", "Hey", "sonal", " the "]},
    {"id": "free-english", "voice": "Anna", "instruction": "Übersetze das ins Englische.",
     "text": "Das Meeting ist morgen um zehn Uhr im großen Raum.",
     "must_all": ["tomorrow"], "must_not": ["morgen"]},
    {"id": "preset-bullets", "voice": "Samantha", "instruction": "Bullet points",
     "text": "We need the change log, the migration script and the new screenshots before Friday.",
     "must_any": ["- "], "must_not": ["Ensure", "submitted"]},
]


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def post(name):
    js = ('ObjC.import("Foundation");'
          '$.NSDistributedNotificationCenter.defaultCenter'
          f'.postNotificationNameObjectUserInfoDeliverImmediately("local.dictation.LocalDictation.test.{name}", $(), $(), true);')
    subprocess.run(["osascript", "-l", "JavaScript", "-e", js], check=True, capture_output=True)


def main():
    volume = osa("output volume of (get volume settings)")
    osa("set volume output volume 50")
    passed = 0
    try:
        for case in CASES:
            osa('tell application "TextEdit" to activate')
            osa('tell application "TextEdit" to make new document')
            osa(f'tell application "TextEdit" to set text of document 1 to "{case["text"]}"')
            time.sleep(0.8)
            post("selectAll")
            time.sleep(0.4)
            post("command")
            time.sleep(0.8)
            subprocess.run(["say", "-v", case["voice"], case["instruction"]], check=True)
            time.sleep(0.3)
            post("stop")
            text = case["text"]
            for _ in range(60):
                time.sleep(0.5)
                text = osa('tell application "TextEdit" to get text of document 1')
                if text != case["text"]:
                    time.sleep(1.0)
                    text = osa('tell application "TextEdit" to get text of document 1')
                    break
            ok = text != case["text"] and not any(m in text for m in case["must_not"])
            if "must_any" in case:
                ok = ok and any(m in text for m in case["must_any"])
            ok = ok and all(m in text for m in case.get("must_all", []))
            passed += ok
            print(f"{'PASS' if ok else 'FAIL'} {case['id']:<16} {text!r}")
            osa('tell application "TextEdit" to close document 1 saving no')
            time.sleep(0.5)
    finally:
        osa(f"set volume output volume {volume}")
    print(f"\npassed {passed}/{len(CASES)}")


if __name__ == "__main__":
    main()
