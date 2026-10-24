"""End-to-end test of the dictation pipeline with generated speech.

Generates each case with macOS `say`, converts it to 16 kHz mono WAV, runs all files through
the `dictate` CLI in one process (the Whisper model loads once), and checks the cleaned text
against the expectations in e2e-cases.json. Prints a table, the pass rate and latency figures,
and exits non-zero when the pass rate or the median latency of clips up to 8 s misses its target.

    python3 scripts/e2e.py [--dictate PATH] [--out DIR] [--min-pass 0.9] [--max-median 2.0] [--no-cleanup]
"""

import argparse
import json
import statistics
import struct
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The latency target applies to clips up to this length; longer ones are reported separately.
SHORT_CLIP_SECONDS = 8.0


def make_audio(case, out_dir):
    wav = out_dir / f"{case['id']}.wav"
    if "silence_seconds" in case:
        frames = int(16000 * case["silence_seconds"])
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(struct.pack("<h", 0) * frames)
        return wav
    aiff = out_dir / f"{case['id']}.aiff"
    subprocess.run(["say", "-v", case["voice"], "-o", str(aiff), case["speech"]], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
    aiff.unlink()
    return wav


def add_noise(wav, level, seed):
    """Mixes white noise at `level` (fraction of full scale, e.g. 0.02) into a 16-bit mono WAV."""
    import random
    rng = random.Random(seed)
    with wave.open(str(wav), "rb") as r:
        params = r.getparams()
        frames = r.readframes(r.getnframes())
    samples = struct.unpack("<%dh" % (len(frames) // 2), frames)
    noisy = [max(-32768, min(32767, int(s + rng.gauss(0, level * 32767)))) for s in samples]
    with wave.open(str(wav), "wb") as w:
        w.setparams(params)
        w.writeframes(struct.pack("<%dh" % len(noisy), *noisy))


def check(case, result):
    text = result["text"]
    if case.get("must_empty"):
        return (text.strip() == "", "expected no text")
    missing = [m for m in case.get("must", []) if m not in text]
    present = [m for m in case.get("must_not", []) if m in text]
    if missing or present:
        return (False, f"missing {missing} present {present}")
    return (True, "")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dictate", default=str(ROOT / ".build/release/dictate"))
    parser.add_argument("--out", default=str(ROOT / "e2e-out"))
    parser.add_argument("--cases", default=str(ROOT / "scripts/e2e-cases.json"))
    parser.add_argument("--min-pass", type=float, default=0.9)
    parser.add_argument("--max-median", type=float, default=2.0)
    parser.add_argument("--no-cleanup", action="store_true")
    parser.add_argument("--llm-url")
    parser.add_argument("--noise", type=float, default=0.0,
                        help="white noise level as fraction of full scale, e.g. 0.02")
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    cases = json.loads(Path(args.cases).read_text())
    files = {case["id"]: make_audio(case, out_dir) for case in cases}
    if args.noise > 0:
        for index, wav in enumerate(files.values()):
            add_noise(wav, args.noise, seed=index)

    # A neutral settings file, so the user's own settings do not change the result.
    settings = out_dir / "settings.json"
    settings.write_text("{}")
    by_app = {}
    for case in cases:
        by_app.setdefault(case.get("app"), []).append(case)

    results = {}
    for app, group in by_app.items():
        command = [args.dictate, "--settings", str(settings)]
        if app:
            command += ["--app", app]
        if args.no_cleanup:
            command.append("--no-cleanup")
        if args.llm_url:
            command += ["--llm-url", args.llm_url]
        command += [str(files[c["id"]]) for c in group]
        proc = subprocess.run(command, capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr, file=sys.stderr)
            sys.exit(f"dictate failed with exit code {proc.returncode}")
        for line in proc.stdout.splitlines():
            result = json.loads(line)
            results[Path(result["file"]).stem] = result

    passed = 0
    latencies = []
    long_latencies = []
    report = []
    for case in cases:
        result = results[case["id"]]
        ok, reason = check(case, result)
        passed += ok
        latency = result["transcription_seconds"] + result["cleanup_seconds"]
        if not case.get("must_empty"):
            (latencies if result["audio_seconds"] <= SHORT_CLIP_SECONDS else long_latencies).append(latency)
        report.append({"id": case["id"], "ok": ok, "reason": reason, "latency": latency, **result})
        print(f"{'PASS' if ok else 'FAIL'} {case['id']:<26} {result['audio_seconds']:4.1f}s audio "
              f"asr {result['transcription_seconds']:.2f}s llm {result['cleanup_seconds']:.2f}s "
              f"[{result['cleanup'][:40]}] {result['text']!r} {reason}")

    rate = passed / len(cases)
    median = statistics.median(latencies)
    print(f"\npassed {passed}/{len(cases)} ({rate:.0%}), clips up to {SHORT_CLIP_SECONDS:.0f}s: "
          f"median latency {median:.2f}s, max {max(latencies):.2f}s")
    if long_latencies:
        print(f"longer clips: " + ", ".join(f"{x:.2f}s" for x in long_latencies))
    (out_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    if rate < args.min_pass or median > args.max_median:
        sys.exit(1)


if __name__ == "__main__":
    main()
