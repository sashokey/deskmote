import argparse
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RAW_INPUT = re.compile(
    r"CGEventTap(?:Create|Enable|IsEnabled)|CGGetEventTapList|CGEventSource(?:ButtonState|KeyState|FlagsState|SecondsSinceLastEventType)|CGEventCreate\b"
    r"|(?:^|\$)(?:mouseLocationOutsideOfEventStream|pressedMouseButtons|mouseLocation|modifierFlags)$",
    re.MULTILINE,
)
EVENT_MONITOR = re.compile(r"(?:addLocal|addGlobal)MonitorForEvents|removeMonitor:")
INJECTION = re.compile(r"CGEvent(?:Post|CreateKeyboardEvent|CreateMouseEvent|CreateScrollWheelEvent)|postEvent:atStart:|CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition")
LOG_IMPORT = re.compile(r"\b_+(?:os_log\w*|os_signpost\w*|NSLogv?)\b|\$s2os(?:6Logger|12OSSignposter)")
DEV_MARKER = re.compile(r"deskmote-dev-(?:test|fill-check)|Dev(?:TestScenario|TestSession|FillCheck)|io\.github\.sashokey\.deskmote\.dev(?:[.\W]|$)|DOCK_[A-Z0-9_]+|(?:window-inventory(?:\.[0-9]+)?|click-latency|hover-trace|taskbar-visibility)\.jsonl")
IPC = re.compile(r"NSXPC(?:Connection|Listener)|GlobalMachService|MachServiceName|CFSocket|NWListener|DistributedNotificationCenter|NSScriptCommand")
PROCESS = re.compile(r"OBJC_CLASS_\$_NSTask|Foundation7Process|\b_posix_spawnp?\b|\b_execv[a-z]*\b|\b_system\b")
NESTED = {"DeskMoteFinder", "DeskMoteFinderService"}
FULL = {"DeskMote", "DeskMoteApps", "CommandShift", "NaturalSwitch", "BatteryRun", *NESTED}
VARIANT_TARGETS = {"full": FULL, "base": {"DeskMote"}, "no-finder": FULL - NESTED}
MACHO = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def audit_symbols(target, imports, literals, *, linked_targets=None):
    roles = {target} if linked_targets is None else linked_targets
    require(not LOG_IMPORT.search(imports), f"Release logging import in {target}")
    require(not DEV_MARKER.search(literals) and "SLSCopyWindowsWithOptionsAndTags" not in literals,
            f"Dev entry, test-only API or journal in {target}")
    symbols = imports + "\n" + literals
    require(not INJECTION.search(symbols), f"Input injection in {target}")
    require("CommandShift" in roles or not RAW_INPUT.search(symbols), f"Raw input in {target}")
    require("DeskMoteApps" in roles or not EVENT_MONITOR.search(symbols), f"Event monitor in {target}")
    require(bool(NESTED & roles) or not IPC.search(symbols), f"Unexpected command IPC in {target}")
    require("BatteryRun" in roles or not PROCESS.search(imports), f"Unexpected subprocess in {target}")


def symbols(path, reader):
    imports = reader("/usr/bin/nm", "-u", str(path)).decode("utf-8", errors="replace")
    literals = reader("/usr/bin/strings", "-a", str(path)).decode("utf-8", errors="replace")
    return imports, literals


def check_dependencies(path, target, reader):
    listing = reader("/usr/bin/otool", "-L", str(path)).decode().splitlines()
    require(len(listing) > 1 and listing[0].endswith(":"), f"Invalid dependency listing for {target}")
    for row in listing[1:]:
        dependency = re.fullmatch(r"\s+(\S+) \(compatibility version .*\)", row)
        require(dependency is not None, f"Invalid dependency entry for {target}")
        location = dependency[1]
        require(location.startswith(("/System/Library/Frameworks/", "/System/Library/PrivateFrameworks/", "/usr/lib/"))
                and ".." not in Path(location).parts, f"Unexpected linked library in {target}: {location}")
    commands = reader("/usr/bin/otool", "-l", str(path)).decode()
    paths = re.findall(r"\bcmd LC_RPATH\s+cmdsize \d+\s+path (\S+) \(offset \d+\)", commands)
    require(len(paths) == commands.count("cmd LC_RPATH"), f"Invalid rpath command in {target}")
    expected = {"DeskMote": {"@executable_path/../Frameworks"},
                "DeskMoteFinder": {"@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"},
                "DeskMoteFinderService": set()}
    require(set(paths) <= expected[target] and "LC_DYLD_ENVIRONMENT" not in commands,
            f"Unexpected dynamic loader configuration in {target}")


def check_executables(app, variant, executables, reader):
    expected = {path for path, _ in executables}
    actual = set()
    for path in app.rglob("*"):
        require(not path.is_symlink(), f"Unexpected symlink in bundle: {path.relative_to(app)}")
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(4)
        if header in MACHO or path.stat().st_mode & 0o111:
            actual.add(path)
    require(actual == expected, f"Unexpected executable layout: {sorted(str(path.relative_to(app)) for path in actual ^ expected)}")
    for path, target in executables:
        links = VARIANT_TARGETS[variant] - NESTED if target == "DeskMote" else None
        audit_symbols(target, *symbols(path, reader), linked_targets=links)
        check_dependencies(path, target, reader)


def check_registrations(info, target):
    prohibited = {"CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
                  "OSAScriptingDefinition", "NSAppleScriptEnabled", "NSAppleEventsUsageDescription", "NSBonjourServices",
                  "MachServices", "Sockets", "SMAuthorizedClients", "SMPrivilegedExecutables", "XPCServiceName",
                  "NSServices"}
    require(not prohibited & info.keys(), f"Unexpected external registration in {target}")
    if target == "DeskMoteFinder":
        extension = info.get("NSExtension", {})
        require(extension.get("NSExtensionPointIdentifier") == "com.apple.FinderSync"
                and extension.get("NSExtensionPrincipalClass") == "DeskMoteFinder.FinderSync"
                and not extension.get("NSExtensionAttributes", {})
                and set(extension) <= {"NSExtensionPointIdentifier", "NSExtensionPrincipalClass", "NSExtensionAttributes"},
                "Unexpected Finder extension registration")
    else:
        require("NSExtension" not in info, f"Unexpected extension registration in {target}")
    services = info.get("XPCService")
    if target == "DeskMoteFinderService":
        require(services == {"ServiceType": "Application"}, "Unexpected Finder XPC registration")
    else:
        require(services is None, f"Unexpected XPC registration in {target}")


def check_source(root):
    apps = root / "Modules/Apps/AppsPopup.swift"
    code = apps.read_text()
    require(len(re.findall(r"\bout\w*ClickMask:\s*NSEvent\.EventTypeMask\s*=\s*\.leftMouseDown\b", code)) == 1,
            "Apps must use one leftMouseDown mask")
    for scope in ("Local", "Global"):
        calls = re.findall(rf"NSEvent\.add{scope}MonitorForEvents\(matching:\s*([^\)]+)\)", code)
        require(calls == ["Self.outsideClickMask"], f"Unexpected Apps {scope} event mask")
    keyboard = (root / "Modules/CommandShift/KeyboardMonitor.swift").read_text()
    require(len(re.findall(r"\.cgSessionEventTap,\s*\.tailAppendEventTap,\s*\.listenOnly\b", keyboard)) == 1,
            "Command Shift must use a passive Quartz session tap")
    history = (root / "Modules/BatteryRun/PowerHistoryLoader.swift").read_text()
    require('URL(fileURLWithPath: "/usr/bin/pmset"), arguments: [String] = ["-g", "log"]' in history,
            "Battery Run must use the read-only pmset journal")
    for field, value in (("executableURL", "executable"), ("arguments", "arguments")):
        assignments = re.findall(rf"^\s*process\.{field}\s*=\s*(\S.*)$", history, re.MULTILINE)
        require(assignments == [value], f"Unexpected pmset journal launch {field}")
    for directory in ("App", "Core", "Modules", "Platform", "UI", "Extensions"):
        for path in (root / directory).rglob("*.swift"):
            source = path.read_text()
            relative = path.relative_to(root).as_posix()
            require(not any(token in source for token in ("mouseLocationOutsideOfEventStream", "CGEventPost", "CGEvent.post", "CGEvent.postToPid", "postEvent(")),
                    f"Unapproved input operation in {relative}")
            if not relative.startswith("Modules/CommandShift/"):
                require(not re.search(r"CGEvent\.(?:tapCreate|tapEnable|tapIsEnabled)|CGEventSource\.|NSEvent\.(?:pressedMouseButtons|mouseLocation|modifierFlags)", source),
                        f"Raw input outside Command Shift in {relative}")
            if path != apps:
                require(not EVENT_MONITOR.search(source), f"Event monitor outside Apps popup in {relative}")
            if not relative.startswith("Extensions/FinderFileCreator/"):
                require(not IPC.search(source), f"Command IPC outside the Finder pair in {relative}")
            if re.search(r"\bProcess\s*\(", source):
                require(relative == "Modules/BatteryRun/PowerHistoryLoader.swift", f"Unexpected subprocess in {relative}")
    callers = "\n".join(path.read_text() for path in (root / "Modules/BatteryRun").glob("*.swift"))
    require(re.findall(r"PowerHistoryLoader\.run\(([^)]*)\)", callers) == [""],
            "Battery Run must use the fixed system journal call")


def validate_link_map(path, known_objects, allowed, sdk, products):
    seen = set()
    objects = False
    archive_members = {}
    for line in path.read_text().splitlines():
        if line == "# Object files:":
            objects = True
        elif objects and line.startswith("#"):
            break
        elif objects:
            match = re.fullmatch(r"\[\s*\d+\]\s+(.+)", line)
            require(match is not None, f"Unrecognized link-map entry in {path.name}")
            value = match[1]
            if value == "linker synthesized":
                continue
            archive = re.fullmatch(r"(.+\.a)(?:\[\d+\])?\(([^)]+)\)", value)
            resolved = Path(archive[1] if archive else value).resolve()
            if (resolved.suffix == ".tbd" and resolved.is_relative_to(sdk)) or (
                resolved.is_relative_to(sdk.parents[4] / "Toolchains") and resolved.suffix == ".a"
            ):
                continue
            if archive:
                owner = resolved.stem.removeprefix("lib")
                require(resolved == products / f"lib{owner}.a" and owner in allowed and archive[2] in known_objects[owner],
                        f"Unexpected archive member {value}")
                name = archive[2]
                if resolved not in archive_members:
                    archive_members[resolved] = run("/usr/bin/ar", "-t", str(resolved)).decode().splitlines()
                require(archive_members[resolved].count(name) == 1, f"Ambiguous object {name} in {resolved.name}")
                archived = run("/usr/bin/ar", "-p", str(resolved), name)
                require(archived == known_objects[owner][name].read_bytes(),
                        f"Archive member {name} differs from its compiled object")
            else:
                owners = [target for target in allowed if resolved == known_objects[target].get(resolved.name)]
                require(len(owners) == 1, f"Unowned linked object: {value}")
                owner = owners[0]
            seen.add(owner)
    require(objects and seen, f"Empty link map: {path.name}")
    return seen


def check_build(derived_data, variant):
    root = derived_data / "Build/Intermediates.noindex/DeskMote.build/Release"
    products = (derived_data / "Build/Products/Release").resolve(strict=True)
    sdk = Path(run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path").decode().strip()).resolve(strict=True)
    expected = VARIANT_TARGETS[variant]
    known_objects = {}
    maps = {}
    for target in sorted(expected):
        directory = root / f"{target}.build"
        compile_dir = directory / "Objects-normal/arm64"
        records = list(compile_dir.glob("*-OutputFileMap.json"))
        require(len(records) == 1, f"Missing unique compile record for {target}")
        mappings = json.loads(records[0].read_text())
        compiled = {}
        for record in mappings.values():
            output = record.get("object")
            if output and Path(output).is_file():
                path = Path(output).resolve()
                require(path.is_relative_to(compile_dir.resolve()), f"Foreign compiler output in {target}")
                require(path.name not in compiled or compiled[path.name] == path, f"Duplicate object in {target}")
                compiled[path.name] = path
        require(compiled, f"No compiled objects for {target}")
        known_objects[target] = compiled
        for path in compiled.values():
            audit_symbols(target, *symbols(path, run))
        if target == "DeskMote" or target in NESTED:
            candidates = list(directory.rglob("*LinkMap*arm64*.txt"))
            require(len(candidates) == 1, f"Missing unique link map for {target}")
            maps[target] = candidates[0]
    app_targets = expected - NESTED
    for target, path in maps.items():
        allowed = app_targets if target == "DeskMote" else {target}
        seen = validate_link_map(path, known_objects, allowed, sdk, products)
        require(seen == allowed, f"Linked roles differ for {target}: {sorted(seen ^ allowed)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("variant", choices=VARIANT_TARGETS)
    parser.add_argument("derived_data", type=Path)
    args = parser.parse_args()
    check_source(ROOT)
    check_build(args.derived_data, args.variant)
    print(f"Verified source and compiled input ownership for {args.variant}")


if __name__ == "__main__":
    main()
