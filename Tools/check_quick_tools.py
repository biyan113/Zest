#!/usr/bin/env python3
"""Run quick-tool checks without enabling any real system action."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from build_local import ROOT, BUILD


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    BUILD.mkdir(exist_ok=True)
    sdk = os.environ.get("ZEST_MACOS_SDK", "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    if not Path(sdk).exists():
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    run("xcrun", "swiftc", "-swift-version", "5", "-sdk", sdk, "-module-cache-path", BUILD / "ModuleCache26.5",
        "Sources/App/L10n.swift", "Sources/Core/QuickTool.swift", "Tools/QuickToolsChecks.swift", "-o", BUILD / "quick-tools-checks")
    run(BUILD / "quick-tools-checks")
    run(sys.executable, "Tools/check_power_session.py")
    run("/bin/sh", "-n", "Resources/PowerSession.sh")
    run("plutil", "-lint", "Zest.xcodeproj/project.pbxproj", "Resources/Info.plist", "Resources/Zest.entitlements")
    scripts = {
        "dark-mode": 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode',
        "menu-bar": 'tell application "System Events" to tell dock preferences to set autohide menu bar to not autohide menu bar',
        "empty-trash": 'tell application "Finder" to empty trash',
    }
    for name, script in scripts.items():
        run("osacompile", "-o", BUILD / (name + ".scpt"), "-e", script)
    # Every catalog entry must have both languages, with matching format arguments.
    for name in ["Localizable", "InfoPlist"]:
        data = json.loads((ROOT / "Resources" / (name + ".xcstrings")).read_text())
        for key, entry in data["strings"].items():
            values = [entry["localizations"][language]["stringUnit"]["value"] for language in ["zh-Hans", "en"]]
            assert all(value.strip() for value in values), key
            pattern = r"%(?:[0-9]+\$)?(?:\.[0-9]+)?(?:lld|@|d|f)"
            normalize = lambda value: sorted(re.sub(r"%[0-9]+\$", "%", match) for match in re.findall(pattern, value))
            assert normalize(values[0]) == normalize(values[1]), "Format argument mismatch: " + key
    keys = set()
    files = [ROOT / "Sources/Core/QuickTool.swift", ROOT / "Sources/App/QuickToolsController.swift",
             ROOT / "Sources/App/ToolCleaner.swift", ROOT / "Sources/App/ToolHotkeys.swift", ROOT / "Sources/UI/QuickToolsView.swift"]
    catalog = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text())["strings"]
    for file in files:
        for raw in re.findall(r'L10n\.text\("((?:[^"\\]|\\.)*)"(?:\)|,\s*defaultValue:)', file.read_text()):
            key = json.loads('"' + raw + '"')
            assert key in catalog, "Missing localization: " + key
            keys.add(key)
    print(f"Validated {len(keys)} tool strings, catalog placeholders, AppleScript syntax, and project resources.")


if __name__ == "__main__":
    main()
