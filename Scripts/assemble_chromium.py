#!/usr/bin/env python3
"""Package Cobble with WebKit and the pinned Chromium runtime, using Cobble's identity."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import hashlib
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, capture=False):
    print("+", " ".join(map(str, arguments)), flush=True)
    return subprocess.run(list(map(str, arguments)), cwd=ROOT, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def read_plist(path):
    with path.open("rb") as stream:
        try:
            return plistlib.load(stream)
        except plistlib.InvalidFileException:
            pass
    # Xcode emits UTF-16 .strings; Chromium ships binary plists.
    xml = run(["plutil", "-convert", "xml1", "-o", "-", path], capture=True)
    return plistlib.loads(xml.encode())


def install_cobble_resources(cobble_resources, dest_resources):
    for resource in cobble_resources.iterdir():
        target = dest_resources / resource.name
        if target.exists() and not (resource.suffix == ".lproj" and resource.is_dir() and target.is_dir()):
            raise ValueError(f"Cobble resource conflicts with a Chromium resource: {resource.name}")
        # ponytail: Cobble overwrites same-named files inside .lproj; key-merge if Chromium InfoPlist keys are needed
        run(["ditto", resource, target])


def write_plist(path, value):
    with path.open("wb") as stream:
        plistlib.dump(value, stream)


def apply_cobble_branding(output, cobble_info):
    resources = output / "Contents/Resources"
    name = cobble_info.get("CFBundleName") or cobble_info.get("CFBundleDisplayName") or "Cobble"
    for strings in resources.glob("*.lproj/InfoPlist.strings"):
        data = read_plist(strings)
        data["CFBundleName"] = name
        data["CFBundleDisplayName"] = name
        write_plist(strings, data)
    return name


def app_metadata(engine_info, cobble_info, version):
    # Runtime launcher keys remain Chromium-owned; application identity comes from Cobble.
    for key in list(engine_info):
        if key.startswith("CFBundleIcon") or key in (
                "CFBundleURLTypes", "CFBundleDocumentTypes", "LSHasLocalizedDisplayName", "LSEnvironment"):
            engine_info.pop(key)
    for key, value in cobble_info.items():
        if key not in ("CFBundleExecutable", "NSPrincipalClass"):
            engine_info[key] = value
    engine_info.update({"CFBundleIdentifier": "com.ignacio.cobble",
                        "CFBundleName": "Cobble", "CFBundleDisplayName": "Cobble",
                        "CobbleChromiumVersion": version,
                        "CrProductDirName": "Cobble/Chromium"})
    engine_info.pop("LSEnvironment", None)
    return engine_info


def signed_entitlements(path):
    result = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(path)],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def sign_app(output, cobble_app):
    # Use the exact leaf identity that signed Fast, including a --team override.
    with tempfile.TemporaryDirectory() as directory:
        prefix = Path(directory) / "certificate"
        run(["codesign", "--display", "--extract-certificates=" + str(prefix), cobble_app])
        certificate = Path(str(prefix) + "0")
        if not certificate.is_file():
            raise ValueError("Full requires a certificate-signed Cobble.app; build Fast with your Development Team")
        identity = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
        # Sign inside out. GN development outputs may have no runtime flags or JIT
        # entitlements, so retaining their signatures alone is insufficient.
        magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
        nested = []
        for path in (output / "Contents").rglob("*"):
            if path.is_symlink():
                continue
            if path.is_dir() and path.suffix in (".app", ".framework", ".xpc"):
                nested.append(path)
            elif path.is_file():
                with path.open("rb") as stream:
                    if stream.read(4) in magic:
                        nested.append(path)
        for path in sorted(nested, key=lambda p: len(p.parts), reverse=True):
            command = ["codesign", "--force", "--sign", identity,
                       "--preserve-metadata=identifier,entitlements,flags,runtime"]
            if path.is_dir() and path.suffix == ".app" and "Helpers" in path.parts and "Sparkle.framework" not in path.parts:
                # Match Chromium's installer/mac/signing/parts.py: renderer/GPU
                # helpers (including Aperitif variants) need JIT. Other helpers
                # use explicit library validation; dylibs have no runtime policy.
                jit = path.stem.endswith((" Renderer)", " (Renderer)", " GPU)", " (GPU)"))
                options = "restrict,kill,runtime" + ("" if jit else ",library")
                helper_entitlements = signed_entitlements(path)
                if jit:
                    helper_entitlements["com.apple.security.cs.allow-jit"] = True
                helper_file = Path(directory) / "helper-entitlements.plist"
                write_plist(helper_file, helper_entitlements)
                command += ["--options", options, "--entitlements", helper_file]
            elif path.name in ("chrome_crashpad_handler", "app_mode_loader", "web_app_shortcut_copier"):
                command += ["--options", "restrict,kill,runtime,library"]
            run([*command, path])
        entitlements = {}
        for app in (output, cobble_app):
            entitlements.update(signed_entitlements(app))
        entitlements.pop("com.apple.security.app-sandbox", None)
        entitlements.pop("com.apple.security.get-task-allow", None)
        entitlement_file = Path(directory) / "entitlements.plist"
        write_plist(entitlement_file, entitlements)
        run(["codesign", "--force", "--sign", identity, "--options", "runtime",
             "--entitlements", entitlement_file, output])
    run(["codesign", "--verify", "--deep", "--strict", output])


def assemble(chromium_app, cobble_app, output, configuration="Release", enable_updates=False):
    configuration = configuration.lower()
    chromium_app, cobble_app, output = (path.resolve() for path in (chromium_app, cobble_app, output))
    if enable_updates and configuration != "release":
        raise ValueError("Automatic updates require a Release configuration")
    if output.exists():
        raise ValueError("Choose a new output path; existing apps are never replaced")
    local_sdk = os.environ.get("COBBLE_CHROMIUM_SDK_PATH")
    sdk = Path(local_sdk) if local_sdk else ROOT / ".build/checkouts/chrome-sdk"
    if not sdk.is_absolute():
        raise ValueError("COBBLE_CHROMIUM_SDK_PATH must be an absolute path")
    run(["swift", "build", "--configuration", configuration, "--product", "CobbleNativeClient"])
    products = Path(run(["swift", "build", "--configuration", configuration, "--show-bin-path"], True).strip())
    sys.path.insert(0, str(sdk / "scripts"))
    from assemble_harness import validate_embedded_manifest
    from build import read_lock, required_sdk_exports
    lock = read_lock()
    engine_info = read_plist(chromium_app / "Contents/Info.plist")
    cobble_info = read_plist(cobble_app / "Contents/Info.plist")
    if enable_updates:
        signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(cobble_app)],
                                   check=True, capture_output=True, text=True).stderr
        if "Authority=Developer ID Application:" not in signature:
            raise ValueError("Automatic updates require Developer ID Application signing")
        if not cobble_info.get("SUPublicEDKey") or not cobble_info.get("SURequireSignedFeed"):
            raise ValueError("Automatic updates require the public update key and signed feed policy")
    if engine_info.get("CFBundleShortVersionString") != lock["version"]:
        raise ValueError("The runtime version differs from Cobble's selected SDK")
    validate_embedded_manifest(chromium_app, lock)
    framework = chromium_app / "Contents/Frameworks/Chromium Framework.framework/Versions" / lock["version"] / "Chromium Framework"
    symbols = {line.split()[-1] for line in run(["nm", "-gU", framework], True).splitlines() if line.split()}
    missing = sorted(required_sdk_exports() - symbols)
    if missing:
        raise ValueError("The runtime is missing required SDK exports: " + ", ".join(missing))
    client = products / "libCobbleNativeClient.dylib"
    if not client.is_file():
        raise ValueError("Cobble's native client library was not built")
    run(["codesign", "--verify", "--deep", "--strict", chromium_app])
    run(["ditto", chromium_app, output])
    destination = output / "Contents/Frameworks/CobbleChromiumClient.dylib"
    run(["ditto", client, destination])
    sparkle = products / "Sparkle.framework"
    if not sparkle.is_dir():
        raise ValueError("SwiftPM did not stage Sparkle.framework beside the client")
    run(["ditto", sparkle, output / "Contents/Frameworks/Sparkle.framework"])
    # Remove Chromium's app branding before copying Cobble's asset catalog and icons.
    resources = output / "Contents/Resources"
    for filename in ("app.icns", "Assets.car"):
        (resources / filename).unlink(missing_ok=True)
    install_cobble_resources(cobble_app / "Contents/Resources", resources)
    run(["ditto", ROOT / "docs/licenses/Sparkle.txt", resources / "Sparkle-LICENSE.txt"])
    apply_cobble_branding(output, cobble_info)
    app_metadata(engine_info, cobble_info, lock["version"])
    engine_info["CobbleUpdatesEnabled"] = enable_updates
    write_plist(output / "Contents/Info.plist", engine_info)
    profile = cobble_app / "Contents/embedded.provisionprofile"
    if profile.is_file():
        run(["ditto", profile, output / "Contents/embedded.provisionprofile"])
    sign_app(output, cobble_app)
    print(json.dumps({"app": str(output), "data_root": str(Path.home() / "Library/Application Support/Cobble"),
                      "chromium_version": lock["version"], "release_ready": False}, indent=2))


def self_check():
    import tempfile
    from unittest.mock import patch
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        with patch.dict(os.environ, {"COBBLE_CHROMIUM_SDK_PATH": "relative-sdk"}):
            try:
                assemble(root / "engine.app", root / "host.app", root / "output.app")
            except ValueError as error:
                assert "absolute path" in str(error)
            else:
                raise AssertionError("expected relative SDK path rejection before building")
        try:
            assemble(root / "engine.app", root / "host.app", root / "output.app",
                     configuration="Debug", enable_updates=True)
        except ValueError as error:
            assert "Release configuration" in str(error)
        else:
            raise AssertionError("expected Debug updates to be rejected")
        cobble, dest = root / "cobble", root / "dest"
        (cobble / "es.lproj").mkdir(parents=True)
        (dest / "es.lproj").mkdir(parents=True)
        (cobble / "es.lproj" / "Localizable.strings").write_text("cobble")
        (cobble / "es.lproj" / "InfoPlist.strings").write_text("cobble-info")
        (dest / "es.lproj" / "InfoPlist.strings").write_text("chromium-info")
        (cobble / "Cobble.sdef").write_text("sdef")
        (dest / "keep.txt").write_text("chromium")
        install_cobble_resources(cobble, dest)
        assert (dest / "es.lproj" / "Localizable.strings").read_text() == "cobble"
        assert (dest / "es.lproj" / "InfoPlist.strings").read_text() == "cobble-info"
        assert (dest / "Cobble.sdef").read_text() == "sdef"
        assert (dest / "keep.txt").read_text() == "chromium"
        (cobble / "Cobble.sdef").unlink()
        (cobble / "keep.txt").write_text("clash")
        try:
            install_cobble_resources(cobble, dest)
        except ValueError as error:
            assert "keep.txt" in str(error)
        else:
            raise AssertionError("expected file conflict")

        branded = root / "branded.app"
        resources = branded / "Contents/Resources/en.lproj"
        resources.mkdir(parents=True)
        (branded / "Contents/Resources/app.icns").write_bytes(b"icon")
        (branded / "Contents/Resources/Assets.car").write_bytes(b"car")
        write_plist(resources / "InfoPlist.strings", {"CFBundleName": "Chromium", "NSCameraUsageDescription": "keep"})
        assert apply_cobble_branding(branded, {"CFBundleName": "Cobble"}) == "Cobble"
        assert (branded / "Contents/Resources/app.icns").exists()
        assert (branded / "Contents/Resources/Assets.car").exists()
        localized = read_plist(resources / "InfoPlist.strings")
        assert localized["CFBundleName"] == "Cobble"
        assert localized["CFBundleDisplayName"] == "Cobble"
        assert localized["NSCameraUsageDescription"] == "keep"

        utf16_app = root / "utf16.app"
        utf16_dir = utf16_app / "Contents/Resources/es.lproj"
        utf16_dir.mkdir(parents=True)
        (utf16_dir / "InfoPlist.strings").write_text(
            '"NSCameraUsageDescription" = "keep";\n', encoding="utf-16"
        )
        assert apply_cobble_branding(utf16_app, {"CFBundleName": "Cobble"}) == "Cobble"
        utf16 = read_plist(utf16_dir / "InfoPlist.strings")
        assert utf16["CFBundleName"] == "Cobble"
        assert utf16["NSCameraUsageDescription"] == "keep"
    info = app_metadata({"CFBundleExecutable": "Chromium", "CFBundleIconFile": "app.icns",
                         "LSEnvironment": {"COBBLE_DATA_DIRECTORY": "/old"}},
                        {"CFBundleExecutable": "Cobble", "CFBundleIdentifier": "com.ignacio.cobble",
                         "CFBundleURLTypes": [{"CFBundleURLSchemes": ["http", "https"]}],
                         "CFBundleIconName": "CobbleIcon", "OSAScriptingDefinition": "Cobble.sdef"}, "123")
    assert info["CFBundleExecutable"] == "Chromium"
    assert info["CFBundleIdentifier"] == "com.ignacio.cobble"
    assert info["CFBundleIconName"] == "CobbleIcon" and "CFBundleIconFile" not in info
    assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["http", "https"]
    assert info["OSAScriptingDefinition"] == "Cobble.sdef"
    assert info["CrProductDirName"] == "Cobble/Chromium" and "LSEnvironment" not in info
    print("assemble_chromium self-check ok")


def main():
    if "--self-check" in sys.argv:
        self_check()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chromium_app", type=Path)
    parser.add_argument("--cobble-app", type=Path, required=True,
                        help="Built regular Cobble.app supplying native resources and metadata")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--enable-updates", action="store_true",
                        help="Enable signed GitHub updates in a Developer ID Release build")
    args = parser.parse_args()
    assemble(args.chromium_app, args.cobble_app, args.output, args.configuration, args.enable_updates)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
