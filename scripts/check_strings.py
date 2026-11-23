#!/usr/bin/env python3
"""Validate translations: every key from keys.json present, format specifiers preserved, file parses."""
import json, re, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Localization"
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ld|lu|[@dDuUxXoOfeEgGcCsSp])")

def specs(text):
    found = SPEC.findall(text)
    # positional (%1$d) and plain (%d) are interchangeable as long as the multiset of types matches
    return sorted(re.sub(r"\d+\$", "", s) for s in found)

def main(langs):
    keys = json.loads((ROOT / "keys.json").read_text())
    ok = True
    for lang in langs:
        path = ROOT / f"{lang}.lproj" / "Localizable.strings"
        if not path.exists():
            print(f"[{lang}] missing {path}"); ok = False; continue
        lint = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True)
        if lint.returncode:
            print(f"[{lang}] parse error: {lint.stderr.strip()}"); ok = False; continue
        table = json.loads(lint.stdout)
        missing = [k for k in keys if k not in table]
        extra = [k for k in table if k not in keys]
        bad = [k for k in keys if k in table and specs(k) != specs(table[k])]
        empty = [k for k in keys if k in table and not table[k].strip()]
        for name, items in (("missing", missing), ("unknown", extra), ("format mismatch", bad), ("empty", empty)):
            if items:
                ok = False
                print(f"[{lang}] {name} ({len(items)}): " + " | ".join(items[:8]))
        if not (missing or extra or bad or empty):
            print(f"[{lang}] OK – {len(table)} strings")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["cs", "de", "fr", "pl", "ru", "ja", "zh-Hans"]))
