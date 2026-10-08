#!/usr/bin/env python3
"""Validate both targets, including syntax, duplicate keys and locale coverage."""
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
key_pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=', re.MULTILINE)
failures = []
locale_sets = []
for target in ("Claude Usage", "ClaudeUsageWidget"):
    resources = root / target / "Resources"
    files = sorted(resources.glob("*.lproj/Localizable.strings"))
    base_file = resources / "en.lproj/Localizable.strings"
    if not base_file.exists():
        failures.append(f"{target}: English localization missing")
        continue
    base_keys = set(key_pattern.findall(base_file.read_text()))
    locales = set()
    for file in files:
        locale = file.parent.stem
        locales.add("zh-Hans" if locale == "zh-ch" else locale)
        lint = subprocess.run(["plutil", "-lint", str(file)], capture_output=True, text=True)
        if lint.returncode:
            failures.append(lint.stdout.strip() or lint.stderr.strip())
        keys = key_pattern.findall(file.read_text())
        if len(keys) != len(set(keys)):
            failures.append(f"{target}/{locale}: duplicate keys")
        missing, extra = base_keys - set(keys), set(keys) - base_keys
        if missing or extra:
            failures.append(f"{target}/{locale}: missing {sorted(missing)}, extra {sorted(extra)}")
    locale_sets.append(locales)
    print(f"{target}: {len(files)} locales, {len(base_keys)} keys")
if len(locale_sets) == 2 and locale_sets[0] != locale_sets[1]:
    failures.append(f"Locale coverage differs between app and widget: {locale_sets[0] ^ locale_sets[1]}")
for failure in failures:
    print(f"ERROR: {failure}")
if failures:
    raise SystemExit(1)
print("Localization validation passed.")
