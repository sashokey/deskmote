import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path

from check_release_inputs import check_executables, check_registrations

FINDER = "DeskMoteFinder.appex"
FINDER_SERVICE = "DeskMoteFinderService.xpc"
BUNDLE_ID = "io.github.sashokey.deskmote"
VARIANTS = {
    "full": {FINDER},
    "base": set(),
    "no-finder": set(),
}
EXTENSIONS = {
    FINDER: ("finder-sync", "com.apple.FinderSync", {
        "com.apple.security.app-sandbox": True,
    }),
}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def check_signature(bundle, expected):
    entitlements = run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(bundle))
    actual = plistlib.loads(entitlements) if entitlements else {}
    require(actual == expected, f"Unexpected entitlements in {bundle.name}")
    details = subprocess.run(
        ["/usr/bin/codesign", "-dv", str(bundle)], check=True, capture_output=True, text=True,
    ).stderr.splitlines()
    require("Signature=adhoc" in details, f"Expected an ad hoc signature on {bundle.name}")


def check_apps_table(app: Path, variant: str, catalog=None) -> None:
    resources = app / "Contents/Resources"
    if variant == "base":
        require(not any(resources.glob("*.lproj/Apps.strings")) and
                not any(resources.glob("*.lproj/Apps.stringsdict")),
                "Unexpected Apps localization in Base")
        return

    if catalog is None:
        catalog = Path(__file__).resolve().parent.parent / "Modules/Apps/Resources/Apps.xcstrings"
    expected = {}
    for key, entry in json.loads(catalog.read_text(encoding="utf-8"))["strings"].items():
        for language, translation in entry.get("localizations", {}).items():
            expected.setdefault(language, {})[key] = translation["stringUnit"]["value"]
    require(bool(expected), "Empty Apps localization catalog")
    for language, entries in expected.items():
        table = resources / f"{language}.lproj/Apps.strings"
        require(table.is_file(), f"Missing Apps localization for {language}")
        actual = plistlib.loads(run("/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(table)))
        for key, value in entries.items():
            require(actual.get(key) == value, f"Unexpected Apps translation for {language}: {key}")


def check_bundle(app, variant, version, source):
    require(app.name == "DeskMote.app", "Unexpected application name")
    number = version[1:]
    bundle_versions = (f"{number}.0.0", number)
    executables = []

    def check_info(bundle, identifier, package_type, executable):
        with (bundle / "Contents/Info.plist").open("rb") as plist:
            info = plistlib.load(plist)
        require(info["CFBundleIdentifier"] == identifier, f"Unexpected identifier in {bundle.name}")
        require(info["CFBundlePackageType"] == package_type, f"Unexpected package type in {bundle.name}")
        require(
            (info["CFBundleShortVersionString"], info["CFBundleVersion"]) == bundle_versions,
            f"Unexpected version in {bundle.name}",
        )
        require(info["LSMinimumSystemVersion"] == "27.0", f"Unexpected deployment target in {bundle.name}")
        require(info["CFBundleExecutable"] == executable, f"Unexpected executable name in {bundle.name}")
        check_registrations(info, executable)
        binary = bundle / "Contents/MacOS" / executable
        require(run("/usr/bin/lipo", "-archs", str(binary)).strip() == b"arm64",
                f"Unexpected architecture in {bundle.name}")
        executables.append((binary, executable))
        return info

    plugins = app / "Contents/PlugIns"
    actual_extensions = {entry.name for entry in plugins.iterdir()} if plugins.exists() else set()
    require(actual_extensions == VARIANTS[variant],
            f"Unexpected extensions in {variant}: {', '.join(sorted(actual_extensions))}")
    info = check_info(app, BUNDLE_ID, "APPL", "DeskMote")
    require(info["CFBundleName"] == info["CFBundleDisplayName"] == info["CFBundleExecutable"] == "DeskMote",
            "Unexpected application display name or executable")
    require(info["DeskMoteVersion"] == version, "Unexpected public version")
    require(info["DeskMoteSourceRevision"] == source, "Unexpected source revision")
    require(info["LSUIElement"] and info["CFBundleIconName"] == "AppIcon", "Unexpected status app or icon setup")
    require(not any(key.startswith(("SU", "NSAppleEventsUsage")) for key in info),
            "Unexpected updater or Apple Events usage")
    require((app / "Contents/Resources/LICENSE").is_file(), "Application license is missing")
    for extension in sorted(actual_extensions):
        suffix, point, entitlements = EXTENSIONS[extension]
        bundle = plugins / extension
        extension_info = check_info(bundle, f"{BUNDLE_ID}.{suffix}", "XPC!", "DeskMoteFinder")
        require(extension_info["NSExtension"]["NSExtensionPointIdentifier"] == point,
                f"Unexpected extension point in {extension}")
        if extension == FINDER:
            services = bundle / "Contents/XPCServices"
            require(services.is_dir() and {entry.name for entry in services.iterdir()} == {FINDER_SERVICE},
                    "Unexpected Finder XPC services")
            service = services / FINDER_SERVICE
            service_info = check_info(service, f"{BUNDLE_ID}.finder-sync.service", "XPC!", "DeskMoteFinderService")
            require(service_info["XPCService"]["ServiceType"] == "Application", "Unexpected Finder XPC service type")
            check_signature(service, {})
        check_signature(bundle, entitlements)
    check_apps_table(app, variant)
    check_executables(app, variant, executables, run)
    check_signature(app, {})
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    print(f"Verified {variant} DeskMote {version} for {source}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("variant", choices=VARIANTS)
    parser.add_argument("version")
    parser.add_argument("source")
    args = parser.parse_args()
    require(re.fullmatch(r"v[1-9][0-9]*", args.version), "Version must be vN")
    require(re.fullmatch(r"[0-9a-f]{40}", args.source), "Expected a full commit SHA")
    check_bundle(args.app, args.variant, args.version, args.source)


if __name__ == "__main__":
    main()
