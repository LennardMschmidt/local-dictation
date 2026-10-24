#!/usr/bin/env python3
"""Merges the team's dictionary, places, transforms and model choices into LocalDictation's settings.

Usage: python3 -I scripts/apply-team-settings.py [team/team-settings.json] [--keep-models]

Words, replacements, places and transforms are added to the ones already there; existing entries stay
as they are. The model choices (ai, asr, llm, assistant) are taken from the team file unless
--keep-models is given. The app must be quit, because it writes settings.json itself; the previous file
is kept as settings.json.before-team.
"""
import json
import os
import subprocess
import sys

SETTINGS = os.path.expanduser("~/Library/Application Support/LocalDictation/settings.json")
MODEL_SECTIONS = ["ai", "asr", "llm", "assistant"]


def union(existing, added, key=lambda item: item):
    seen = {key(item) for item in existing}
    return existing + [item for item in added if key(item) not in seen]


def main():
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    team_file = arguments[0] if arguments else os.path.join(os.path.dirname(__file__), "..", "team", "team-settings.json")
    if subprocess.run(["pgrep", "-x", "LocalDictation"], capture_output=True).returncode == 0:
        sys.exit("LocalDictation is running. Quit it from the menu bar first, then run this again.")

    team = json.load(open(team_file, encoding="utf-8"))
    settings = json.load(open(SETTINGS, encoding="utf-8")) if os.path.exists(SETTINGS) else {}
    before = json.dumps(settings, sort_keys=True)

    for name in ["vocabulary", "starredWords", "languages", "dictionaryGroups"]:
        settings[name] = union(settings.get(name, []), team.get(name, []), key=str.lower)
    settings["replacements"] = union(settings.get("replacements", []), team.get("replacements", []),
                                     key=lambda r: r["from"].lower())
    settings["places"] = union(settings.get("places", []), team.get("places", []), key=lambda p: p["name"].lower())
    settings["transforms"] = union(settings.get("transforms", []), team.get("transforms", []),
                                   key=lambda t: t["name"].lower())
    word_groups = settings.get("wordGroups", {})
    settings["wordGroups"] = {**team.get("wordGroups", {}), **word_groups}
    style_groups = settings.get("styleGroups", {})
    for style, groups in team.get("styleGroups", {}).items():
        style_groups[style] = union(style_groups.get(style, []), groups)
    settings["styleGroups"] = style_groups
    for name in ["transformsEnabled", "codeModeEnabled"]:
        settings.setdefault(name, team[name])
    if "--keep-models" not in sys.argv:
        for name in MODEL_SECTIONS:
            settings[name] = {**settings.get(name, {}), **team.get(name, {})}

    if json.dumps(settings, sort_keys=True) == before:
        print("Nothing to change.")
        return
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    if os.path.exists(SETTINGS):
        os.replace(SETTINGS, SETTINGS + ".before-team")
    with open(SETTINGS, "w", encoding="utf-8") as file:
        json.dump(settings, file, ensure_ascii=False, indent=2)
    print(f"{len(settings['vocabulary'])} words, {len(settings['replacements'])} replacements, "
          f"{len(settings['places'])} places, {len(settings['transforms'])} transforms in {SETTINGS}")
    print("Start LocalDictation again.")


if __name__ == "__main__":
    main()
