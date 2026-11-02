#!/usr/bin/env python3
"""Package a built app without launching it or modifying the source bundle."""

import argparse
import hashlib
import plistlib
import subprocess
import tempfile
from pathlib import Path


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--notes", type=Path, required=True)
    signing = parser.add_mutually_exclusive_group()
    signing.add_argument("--ad-hoc", action="store_true", help="Sign the staged copy locally; no Developer ID or notarization")
    signing.add_argument("--identity", help="Sign the staged copy with an installed code-signing identity")
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    root = Path(__file__).resolve().parent.parent
    if not (app / "Contents/Info.plist").is_file():
        parser.error("app must be a built macOS app bundle")
    app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    widget_info = plistlib.loads((app / "Contents/PlugIns/Claude UsageWidget.appex/Contents/Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not app_info.get(key) or widget_info.get(key) != app_info[key]:
            parser.error(f"app and widget must have matching {key}; rebuild both targets")
    if output.suffix != ".dmg":
        parser.error("output must end in .dmg")
    if output.exists() or output.with_suffix(".dmg.sha256").exists():
        parser.error("output already exists; choose a new filename")
    notes = args.notes.read_text()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="claude-usage-dmg-") as temporary:
        stage = Path(temporary) / "image"
        stage.mkdir()
        staged_app = stage / app.name
        run("ditto", app, staged_app)
        identity = "-" if args.ad_hoc else args.identity
        if identity:
            sparkle = staged_app / "Contents/Frameworks/Sparkle.framework"
            nested = [
                (staged_app / "Contents/PlugIns/Claude UsageWidget.appex", root / "ClaudeUsageWidget/ClaudeUsageWidget.entitlements"),
                (sparkle / "Versions/B/XPCServices/Installer.xpc", None),
                (sparkle / "Versions/B/XPCServices/Downloader.xpc", None),
                (sparkle / "Versions/B/Autoupdate", None),
                (sparkle / "Versions/B/Updater.app", None),
                (sparkle, None),
                (staged_app, root / "Claude Usage/Claude UsageRelease.entitlements"),
            ]
            for component, entitlements in nested:
                if not component.exists():
                    raise FileNotFoundError(component)
                command = ["codesign", "--force", "--sign", identity,
                           "--timestamp=none" if args.ad_hoc else "--timestamp", "--options", "runtime"]
                if entitlements:
                    command += ["--entitlements", str(entitlements)]
                run(*command, component)
        run("codesign", "--verify", "--deep", "--strict", staged_app)
        info = plistlib.loads((staged_app / "Contents/Info.plist").read_bytes())
        if info.get("ProviderIntegrationUpdatesEnabled") is not False:
            raise ValueError("candidate must keep incompatible upstream updates disabled")
        if info.get("CFBundleIdentifier") != "HamedElfayome.Claude-Usage":
            raise ValueError("unexpected app preferences domain")
        (stage / "Applications").symlink_to("/Applications")
        (stage / "READ BEFORE UPGRADING.txt").write_text(notes)
        run("hdiutil", "create", "-volname", "Claude Usage Integration", "-srcfolder", stage,
            "-format", "UDZO", output)
    run("hdiutil", "verify", output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".dmg.sha256").write_text(f"{digest}  {output.name}\n")
    print(f"Created: {output}")
    print("The app was packaged without being launched or installed.")
    if args.ad_hoc:
        print("Local ad-hoc signature only. Not Developer ID signed or notarized.")
    elif args.identity:
        print("Signed with the supplied identity. Notarization is a separate step.")


if __name__ == "__main__":
    main()
