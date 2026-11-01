#!/usr/bin/env python3
"""Build the local custom app using Command Line Tools; no full Xcode required."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
SPARKLE_VERSION = "2.10.0"
SPARKLE_SHA256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    if os.uname().sysname != "Darwin":
        raise SystemExit("This application requires macOS.")
    BUILD.mkdir(exist_ok=True)
    sdk = os.environ.get("ZEST_MACOS_SDK")
    if not sdk:
        compatible = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
        sdk = str(compatible) if compatible.exists() else subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    machine = os.uname().machine
    target = machine + "-apple-macosx13.0"
    dependencies = BUILD / "dependencies"
    dependencies.mkdir(exist_ok=True)
    archive = dependencies / ("Sparkle-" + SPARKLE_VERSION + ".zip")
    if not archive.exists():
        url = "https://github.com/sparkle-project/Sparkle/releases/download/" + SPARKLE_VERSION + "/Sparkle-for-Swift-Package-Manager.zip"
        print("Downloading pinned Sparkle " + SPARKLE_VERSION, flush=True)
        with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_SHA256:
        raise SystemExit("Sparkle checksum mismatch; remove " + str(archive) + " and retry.")
    unpacked = dependencies / "Sparkle-runtime"
    if not (unpacked / "Sparkle.xcframework").exists():
        run("ditto", "-x", "-k", archive, unpacked)
    framework = next(unpacked.rglob("macos-arm64_x86_64/Sparkle.framework"))

    app = BUILD / "Zest-next.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    resources = contents / "Resources"
    for path in [contents / "MacOS", contents / "Frameworks", resources, BUILD / "objects"]:
        path.mkdir(parents=True, exist_ok=True)
    run("ditto", framework, contents / "Frameworks/Sparkle.framework")
    # Remove XML comments before parsing: the original contains '--account' in a comment.
    info = plistlib.loads(re.sub(rb"<!--.*?-->", b"", (ROOT / "Resources/Info.plist").read_bytes(), flags=re.S))
    variables = {"EXECUTABLE_NAME": "Zest", "PRODUCT_BUNDLE_IDENTIFIER": "app.zest.monitor", "PRODUCT_NAME": "Zest",
                 "MARKETING_VERSION": re.search(r"MARKETING_VERSION = ([^;]+);", (ROOT / "Zest.xcodeproj/project.pbxproj").read_text()).group(1).strip('"'),
                 "CURRENT_PROJECT_VERSION": re.search(r"CURRENT_PROJECT_VERSION = ([^;]+);", (ROOT / "Zest.xcodeproj/project.pbxproj").read_text()).group(1).strip('"'), "MACOSX_DEPLOYMENT_TARGET": "13.0"}
    for key, value in info.items():
        if isinstance(value, str):
            for name, replacement in variables.items():
                value = value.replace("$(" + name + ")", replacement)
            info[key] = value
    info.update(CFBundleIconFile="AppIcon.icns", CFBundleSupportedPlatforms=["MacOSX"], ZestCustomBuild=True)
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    (contents / "PkgInfo").write_bytes(b"APPL????")
    for path in (ROOT / "Resources/Data").iterdir():
        if path.is_file():
            shutil.copy2(path, resources / path.name)
    for path in (ROOT / "Resources").glob("*.sh"):
        shutil.copy2(path, resources / path.name)
    for catalog in (ROOT / "Resources").glob("*.xcstrings"):
        data = json.loads(catalog.read_text())
        tables = {}
        for key, entry in data["strings"].items():
            localized = entry.get("localizations", {})
            for language, translation in localized.items():
                if set(translation) != {"stringUnit"}:
                    raise ValueError("Unsupported string variation: " + key)
                tables.setdefault(language, {})[key] = translation["stringUnit"]["value"]
            if data["sourceLanguage"] not in localized:
                tables.setdefault(data["sourceLanguage"], {})[key] = key
        for language, table in tables.items():
            directory = resources / (language + ".lproj")
            directory.mkdir(exist_ok=True)
            with (directory / (catalog.stem + ".strings")).open("wb") as output:
                plistlib.dump(table, output, fmt=plistlib.FMT_BINARY)
    icons = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
    iconset = BUILD / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for entry in json.loads((icons / "Contents.json").read_text())["images"]:
        size = entry["size"].split("x")[0]
        scale = "@2x" if entry["scale"] == "2x" else ""
        shutil.copy2(icons / entry["filename"], iconset / ("icon_" + size + "x" + size + scale + ".png"))
    run("iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns")
    run("xcrun", "clang", "-target", target, "-isysroot", sdk, "-O2", "-c", "Sources/SMC/SMCBridge.c", "-o", BUILD / "objects/SMCBridge.o")
    sources = sorted((ROOT / "Sources").rglob("*.swift"))
    print("Compiling " + str(len(sources)) + " Swift files with " + sdk, flush=True)
    run("xcrun", "swiftc", "-swift-version", "5", "-O", "-whole-module-optimization", "-module-name", "Zest",
        "-target", target, "-sdk", sdk, "-module-cache-path", BUILD / "ModuleCache26.5", "-F", contents / "Frameworks",
        "-framework", "Sparkle", "-framework", "IOKit", "-lsqlite3", "-lz", "-import-objc-header", "Sources/SMC/Zest-Bridging-Header.h",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", *sources, BUILD / "objects/SMCBridge.o",
        "-o", contents / "MacOS/Zest")
    run("codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", "Resources/Zest.entitlements", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    destination = BUILD / "Zest.app"
    if destination.exists():
        destination.rename(BUILD / ("Zest-previous-" + str(time.time_ns()) + ".app"))
    app.rename(destination)
    print("Built and verified: " + str(destination))


if __name__ == "__main__":
    main()
