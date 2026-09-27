#!/usr/bin/env python3
"""Build/notarize a Full release, or publish a tested staged release to GitHub."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

from prepare_update import ROOT, SPARKLE, prepare

REPO = "ignaciojuarez/cobble-browser"


def run(*args, capture=False):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def clean_revision():
    if run("git", "status", "--porcelain", capture=True):
        raise ValueError("Commit source changes before building or publishing a release")
    return run("git", "rev-parse", "HEAD", capture=True)


def validate_version(version, build):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or build < 1:
        raise ValueError("Use a numeric version such as 0.1.0 and a positive integer build")


def build_release(args):
    validate_version(args.version, args.build)
    if not re.fullmatch(r"v[0-9][A-Za-z0-9._-]*", args.tag):
        raise ValueError("Invalid release tag")
    revision = clean_revision()
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(ROOT):
        raise ValueError("Choose a new release directory outside the repository")
    output.mkdir(parents=True)
    archive = output / "shell.xcarchive"
    run("xcodebuild", "-project", "Cobble.xcodeproj", "-scheme", "Cobble",
        "-configuration", "Release", "-destination", "generic/platform=macOS",
        "-archivePath", archive, "-derivedDataPath", output / "DerivedData",
        f"DEVELOPMENT_TEAM={args.team}", f"MARKETING_VERSION={args.version}",
        f"CURRENT_PROJECT_VERSION={args.build}", "-allowProvisioningUpdates", "archive")
    options = output / "export-options.plist"
    options.write_bytes(plistlib.dumps(dict(method="developer-id", teamID=args.team,
        signingStyle="automatic", signingCertificate="Developer ID Application", destination="export")))
    run("xcodebuild", "-exportArchive", "-archivePath", archive,
        "-exportOptionsPlist", options, "-exportPath", output / "shell", "-allowProvisioningUpdates")
    app = output / "Cobble.app"
    run(sys.executable, ROOT / "Scripts/assemble_chromium.py", args.chromium.resolve(),
        "--cobble-app", output / "shell/Cobble.app", "--configuration", "Release",
        "--enable-updates", "--output", app)
    metadata = dict(tag=args.tag, revision=revision, version=args.version, build=args.build)
    (output / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if args.notes:
        shutil.copy2(args.notes, output / "release-notes.md")
    # Keep the original shell archive; notarize the complete Chromium app.
    full_archive = output / "Full.xcarchive"
    full_archive.mkdir()
    shutil.copy2(archive / "Info.plist", full_archive / "Info.plist")
    run("ditto", app, full_archive / "Products/Applications/Cobble.app")
    upload_options = plistlib.loads(options.read_bytes())
    upload_options["destination"] = "upload"
    upload = output / "upload-options.plist"
    upload.write_bytes(plistlib.dumps(upload_options))
    run("xcodebuild", "-exportArchive", "-archivePath", full_archive,
        "-exportOptionsPlist", upload, "-allowProvisioningUpdates")
    print(f"If Apple is still processing, resume later with: python3 Scripts/release.py finish {output} --tools {args.tools}", flush=True)
    args.directory = output
    finish(args)


def finish(args):
    output = args.directory.resolve()
    metadata = json.loads((output / "release.json").read_text())
    if metadata["revision"] != clean_revision():
        raise ValueError("Finish from the same clean source commit used to build")
    run("xcodebuild", "-exportNotarizedApp", "-archivePath", output / "Full.xcarchive",
        "-exportPath", output / "notarized")
    app = output / "notarized/Cobble.app"
    run("xcrun", "stapler", "validate", app)
    notes = output / "release-notes.md"
    assets = output / "assets"
    prepare(app, args.tools.resolve(), assets, metadata["tag"], notes if notes.is_file() else None)
    shutil.copy2(output / "release.json", assets / "release.json")
    print(f"Ready for install/update testing: {app}\nAfter testing: python3 Scripts/release.py publish {assets} --tools {args.tools}")


def publish(args):
    assets = args.assets.resolve()
    metadata = json.loads((assets / "release.json").read_text())
    if metadata["revision"] != clean_revision():
        raise ValueError("Publish from the same clean source commit used to build")
    tag = metadata["tag"]
    if not re.fullmatch(r"v[0-9][A-Za-z0-9._-]*", tag):
        raise ValueError("Invalid release tag")
    archive = assets / f"Cobble-{tag}.zip"
    feed = assets / "appcast.xml"
    run(args.tools.resolve() / "sign_update", "--account", "com.ignacio.cobble.sparkle", "--verify", feed)
    expected_url = f"https://github.com/{REPO}/releases/download/{tag}/{archive.name}"
    item = next((item for item in ET.parse(feed).findall("./channel/item")
                 if item.findtext(SPARKLE + "version") == str(metadata["build"])), None)
    if item is None or item.find("enclosure") is None or item.find("enclosure").get("url") != expected_url:
        raise ValueError("Feed does not advertise the expected release asset")
    signature = item.find("enclosure").get(SPARKLE + "edSignature")
    if not signature:
        raise ValueError("Missing archive signature")
    run(args.tools.resolve() / "sign_update", "--account", "com.ignacio.cobble.sparkle",
        "--verify", archive, signature)
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if (assets / "SHA256SUMS").read_text() != f"{digest}  {archive.name}\n":
        raise ValueError("Archive checksum changed after staging")
    run("git", "fetch", "origin", "main")
    if run("git", "rev-parse", "origin/main", capture=True) != metadata["revision"]:
        raise ValueError("Push the build's source commit to main first; do not publish over newer changes")
    # Existing tags/assets are never overwritten. The feed is published last.
    with tempfile.TemporaryDirectory() as directory:
        notes = Path(directory) / "notes.md"
        notes.write_text("Full Cobble browser for Apple silicon and macOS 26+.\n\nDownload the ZIP, extract Cobble, and drag it into Applications.\n\nIncludes WebKit, Chromium and signed in-app updates.\n")
        if archive.with_suffix(".md").is_file():
            notes = archive.with_suffix(".md")
        run("gh", "release", "create", tag, archive, assets / "SHA256SUMS", "--repo", REPO,
            "--target", metadata["revision"], "--title", f"Cobble {tag}", "--notes-file", notes,
            *( ["--prerelease"] if "-" in tag else [] ))
        downloaded = hashlib.sha256()
        with urllib.request.urlopen(expected_url, timeout=60) as response:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                downloaded.update(block)
        if downloaded.hexdigest() != digest:
            raise ValueError("Public download checksum mismatch; update feed was NOT published")
    shutil.copy2(feed, ROOT / "updates/appcast.xml")
    run("git", "add", "updates/appcast.xml")
    run("git", "commit", "-m", f"Publish signed update feed for {tag}")
    run("git", "push", "origin", "HEAD:main")
    print(f"Published https://github.com/{REPO}/releases/tag/{tag}")


def self_check():
    from types import SimpleNamespace
    from unittest.mock import patch
    validate_version("0.1.0", 1)
    for version, number in [("latest", 1), ("0.1.0", 0)]:
        try:
            validate_version(version, number)
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid version accepted")
    # A changed ZIP must never reach GitHub or mutate the public feed.
    with tempfile.TemporaryDirectory() as directory:
        assets = Path(directory)
        (assets / "release.json").write_text(json.dumps(dict(tag="v0.1.0", revision="source", build=1)))
        (assets / "Cobble-v0.1.0.zip").write_bytes(b"changed archive")
        (assets / "SHA256SUMS").write_text("wrong checksum")
        (assets / "appcast.xml").write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1</sparkle:version><enclosure url="https://github.com/ignaciojuarez/cobble-browser/releases/download/v0.1.0/Cobble-v0.1.0.zip" sparkle:edSignature="signature"/></item></channel></rss>')
        with patch(__name__ + ".clean_revision", return_value="source"), patch(__name__ + ".run") as command:
            try:
                publish(SimpleNamespace(assets=assets, tools=assets))
            except ValueError as error:
                assert "checksum" in str(error)
            else:
                raise AssertionError("Changed archive accepted")
            assert all(str(call.args[0]).endswith("sign_update") for call in command.call_args_list)
    print("release self-check ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="Archive, sign, notarize and stage; does not publish")
    for name in ("version", "tag", "team"):
        build.add_argument("--" + name, required=True)
    build.add_argument("--build", type=int, required=True)
    for name in ("chromium", "tools", "output"):
        build.add_argument("--" + name, type=Path, required=True)
    build.add_argument("--notes", type=Path)
    resume = sub.add_parser("finish", help="Resume after Apple finishes notarization")
    resume.add_argument("directory", type=Path)
    resume.add_argument("--tools", type=Path, required=True)
    release = sub.add_parser("publish", help="Publish a staged release AFTER install/update qualification")
    release.add_argument("assets", type=Path)
    release.add_argument("--tools", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("COBBLE_CHROMIUM_SDK_PATH"):
        raise ValueError("Public releases must use the pinned SDK, not a local override")
    {"build": build_release, "finish": finish, "publish": publish}[args.command](args)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-check"]:
            self_check()
        else:
            main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
