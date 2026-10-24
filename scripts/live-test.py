"""Live test of the installed app: microphone, panel, pipeline, paste and clipboard restore.

The app must run with "testControl": true in its settings. For each case the script puts a fresh
TextEdit document in front, puts a marker on the clipboard, starts a recording through the test
control, speaks the sentence through the speakers with `say`, stops the recording and reads what
arrived in TextEdit. Only the Fn key itself is not exercised.

Do not use the Mac while it runs: the app pastes into whatever app is in front.

    python3 scripts/live-test.py [--volume 50]
"""

import argparse
import json
import subprocess
import time
from pathlib import Path

LOG = Path.home() / "Library/Application Support/LocalDictation/app.log"
MARKER = "clipboard-marker-7f3a"

CASES = [
    {"id": "de-basic", "voice": "Anna", "speech": "Äh, das ist ein Test mit Polarion und LiveDoc.",
     "must": ["Test", "Polarion", "LiveDoc"], "must_not": ["Äh"]},
    {"id": "de-correction", "voice": "Anna",
     "speech": "Wir treffen uns am Dienstag, nein, am Mittwoch um drei.",
     "must": ["Mittwoch", "3"], "must_not": ["Dienstag"]},
    {"id": "en-basic", "voice": "Samantha",
     "speech": "Um, so we need to deploy the new widget to the demo server today.",
     "must": ["deploy", "widget", "demo server"], "must_not": ["Um,"]},
    {"id": "de-list", "voice": "Anna",
     "speech": "Für morgen brauchen wir erstens den Server, zweitens die Testdaten und drittens die Folien.",
     "must": ["1.", "2.", "3.", "Folien"], "must_not": []},
    {"id": "pill-click", "voice": "Anna", "via": "click",
     "speech": "Meine Stichpunkte sind das Budget, der Zeitplan und die offenen Fragen.",
     "must": ["\n- ", "Budget", "Zeitplan"], "must_not": []},
    {"id": "cancel", "voice": "Anna", "speech": "Das hier soll nicht eingefügt werden.",
     "cancel": True, "must": [], "must_not": ["eingefügt"]},
]


def run(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check).stdout.strip()


def osa(script):
    return run("osascript", "-e", script)


def post(name):
    js = ('ObjC.import("Foundation");'
          '$.NSDistributedNotificationCenter.defaultCenter'
          f'.postNotificationNameObjectUserInfoDeliverImmediately("local.dictation.LocalDictation.test.{name}", $(), $(), true);')
    run("osascript", "-l", "JavaScript", "-e", js)


def new_document():
    osa('tell application "TextEdit" to activate')
    osa('tell application "TextEdit" to make new document')
    time.sleep(0.8)
    front = osa('tell application "System Events" to get bundle identifier of first application process whose frontmost is true')
    return front


def document_text():
    return osa('tell application "TextEdit" to get text of document 1')


def log_lines_since(offset):
    with open(LOG, encoding="utf-8") as f:
        f.seek(offset)
        return f.read().splitlines()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--volume", type=int, default=50)
    args = parser.parse_args()

    previous_volume = osa("output volume of (get volume settings)")
    osa(f"set volume output volume {args.volume}")
    results = []
    try:
        for case in CASES:
            front = new_document()
            run("bash", "-c", f"printf %s {MARKER} | pbcopy")
            offset = LOG.stat().st_size
            click = case.get("via") == "click"
            post("click" if click else "start")
            time.sleep(0.6)
            run("say", "-v", case["voice"], case["speech"])
            time.sleep(0.3)
            post("click" if click else ("cancel" if case.get("cancel") else "stop"))
            text = ""
            for _ in range(30):
                time.sleep(0.5)
                lines = log_lines_since(offset)
                if any("dictation audio" in l or "recording cancelled" in l or "Nothing" in l for l in lines):
                    time.sleep(1.0)
                    break
            text = document_text()
            clipboard = run("pbpaste")
            lines = log_lines_since(offset)
            timing = next((l.split("INFO ", 1)[1] for l in lines if "dictation audio" in l), "")
            missing = [m for m in case["must"] if m not in text]
            present = [m for m in case["must_not"] if m in text]
            ok = not missing and not present and clipboard == MARKER
            if case.get("cancel"):
                ok = ok and text.strip() == ""
            results.append({"id": case["id"], "ok": ok, "front": front, "text": text,
                            "clipboard_restored": clipboard == MARKER, "timing": timing,
                            "missing": missing, "present": present})
            print(f"{'PASS' if ok else 'FAIL'} {case['id']:<14} front={front} clipboard_restored={clipboard == MARKER}")
            print(f"     text: {text!r}")
            print(f"     {timing}")
            osa('tell application "TextEdit" to close document 1 saving no')
            time.sleep(0.5)
    finally:
        osa(f"set volume output volume {previous_volume}")
    passed = sum(r["ok"] for r in results)
    print(f"\npassed {passed}/{len(results)}")
    Path("e2e-out").mkdir(exist_ok=True)
    Path("e2e-out/live-report.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
