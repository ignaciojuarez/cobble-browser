#!/usr/bin/env python3
"""Stage a signed Sparkle update from a notarized Full app. Never uploads anything."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "com.ignacio.cobble.sparkle"
REPOSITORY = "https://github.com/ignaciojuarez/cobble-browser"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True).stdout.strip()


def validate(info, expected, previous):
    if info.get("CFBundleIdentifier") != "com.ignacio.cobble" or not info.get("CobbleChromiumVersion"):
        raise ValueError("Expected the Cobble Full app")
    if not info.get("CobbleUpdatesEnabled") or not info.get("SURequireSignedFeed"):
        raise ValueError("Assemble a Release with --enable-updates first")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("Signed feeds require SUVerifyUpdateBeforeExtraction")
    for key in ("SUPublicEDKey", "SUFeedURL"):
        if info.get(key) != expected.get(key):
            raise ValueError(f"App's {key} does not match this checkout")
    version = str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[1-9][0-9]*", version):
        raise ValueError("Use a positive integer CURRENT_PROJECT_VERSION (build number)")
    if any(not item.isdigit() or int(item) >= int(version) for item in previous):
        raise ValueError("Build number must be greater than every published update")
    return version


def prepare(app, tools, output, tag, notes):
    if not re.fullmatch(r"v[0-9][A-Za-z0-9._-]*", tag):
        raise ValueError("Use a release tag such as v0.1.0-beta.1")
    if output.is_relative_to(ROOT):
        raise ValueError("Stage release binaries outside the source repository")
    if output.exists():
        raise ValueError("Choose a new staging directory; existing files are never replaced")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    feed = ROOT / "updates/appcast.xml"
    previous = [node.text or "" for node in ET.parse(feed).iter(SPARKLE + "version")]
    version = validate(info, expected, previous)
    public_key = run(tools / "generate_keys", "--account", ACCOUNT, "-p")
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("The Keychain update key does not match the app's public key")
    run("codesign", "--verify", "--deep", "--strict", app)
    signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)],
                               check=True, capture_output=True, text=True).stderr
    if "Authority=Developer ID Application:" not in signature:
        raise ValueError("A Developer ID Application signature is required")
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", app)
    output.mkdir(parents=True)
    archive = output / f"Cobble-{tag}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    # Preserve old tagged URLs. Generate only this version with the new prefix.
    shutil.copy2(feed, output / "appcast.xml")
    if notes:
        shutil.copy2(notes, archive.with_suffix(".md"))
    run(tools / "generate_appcast", "--account", ACCOUNT,
        "--download-url-prefix", f"{REPOSITORY}/releases/download/{tag}/",
        "--versions", version, "--maximum-deltas", "0", "--embed-release-notes", output)
    run(tools / "sign_update", "--account", ACCOUNT, "--verify", output / "appcast.xml")
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    checksum = digest.hexdigest()
    (output / "SHA256SUMS").write_text(f"{checksum}  {archive.name}\n")
    print(f"Prepared {archive}\nUpload ZIP + SHA256SUMS, verify the downloaded bytes, then publish appcast.xml LAST.")


def self_check():
    expected = {"SUPublicEDKey": "public", "SUFeedURL": "https://example.org/appcast.xml"}
    info = dict(expected, CFBundleIdentifier="com.ignacio.cobble", CobbleChromiumVersion="1",
                CobbleUpdatesEnabled=True, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, CFBundleVersion="2")
    assert validate(info, expected, ["1"]) == "2"
    for changed, previous in [({"CobbleUpdatesEnabled": False}, []),
                              ({"CobbleChromiumVersion": ""}, []),
                              ({"SUPublicEDKey": "wrong"}, []),
                              ({"SURequireSignedFeed": False}, []),
                              ({"SUVerifyUpdateBeforeExtraction": False}, []),
                              ({"CFBundleVersion": "0"}, []), ({}, ["2"]), ({}, ["3"])]:
        try:
            validate(info | changed, expected, previous)
        except ValueError:
            pass
        else:
            raise AssertionError((changed, previous))
    print("prepare_update self-check ok")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        self_check()
        sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--tools", type=Path, required=True, help="Sparkle 2.10.0 bin directory")
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repo")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--notes", type=Path, help="Markdown release notes")
    args = parser.parse_args()
    try:
        prepare(args.app.resolve(), args.tools.resolve(), args.output.resolve(), args.tag, args.notes)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error) + ("\n" + error.stderr if isinstance(error, subprocess.CalledProcessError) and error.stderr else ""))
