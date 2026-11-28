import subprocess
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import check_bundle
from check_release_inputs import ROOT, audit_symbols, check_source, validate_link_map


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "Scripts/lib/release_binary.sh"


class ReleaseHygieneTests(unittest.TestCase):
    @staticmethod
    def compile_object(path, value):
        subprocess.run(["/usr/bin/xcrun", "clang", "-x", "c", "-c", "-o", str(path), "-"],
                       input=f"int fixture(void) {{ return {value}; }}".encode(), check=True)

    def test_link_map_rejects_a_same_named_archive_outside_build_products(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            products = root / "Release"
            sdk = root / "Developer/Platforms/macOS/Developer/SDKs/MacOS.sdk"
            source = root / "KeyboardMonitor.o"
            link = root / "DeskMote-LinkMap-normal-arm64.txt"
            known = {"CommandShift": {source.name: source}}
            products.mkdir()
            self.compile_object(source, 1)
            subprocess.run(["/usr/bin/ar", "-rc", str(products / "libCommandShift.a"), str(source)], check=True)
            for archive in (products / "libCommandShift.a", root / "Other/libCommandShift.a"):
                link.write_text(f"# Object files:\n[  1] {archive}({source.name})\n# Sections:\n")
                if archive.parent == products:
                    self.assertEqual(validate_link_map(link, known, {"CommandShift"}, sdk, products), {"CommandShift"})
                else:
                    with self.assertRaisesRegex(SystemExit, "Unexpected archive member"):
                        validate_link_map(link, known, {"CommandShift"}, sdk, products)

    def test_archive_contents_must_equal_the_audited_compiler_object(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            products, foreign = root / "Release", root / "Foreign"
            products.mkdir()
            foreign.mkdir()
            source = root / "KeyboardMonitor.o"
            impostor = foreign / source.name
            self.compile_object(source, 1)
            self.compile_object(impostor, 2)
            archive = products / "libCommandShift.a"
            link = root / "DeskMote-LinkMap-normal-arm64.txt"
            link.write_text(f"# Object files:\n[  1] {archive}({source.name})\n# Sections:\n")
            sdk = root / "Developer/Platforms/macOS/Developer/SDKs/MacOS.sdk"
            known = {"CommandShift": {source.name: source}}
            subprocess.run(["/usr/bin/ar", "-rc", str(archive), str(source)], check=True)
            self.assertEqual(validate_link_map(link, known, {"CommandShift"}, sdk, products), {"CommandShift"})
            archive.unlink()
            subprocess.run(["/usr/bin/ar", "-rc", str(archive), str(impostor)], check=True)
            with self.assertRaisesRegex(SystemExit, "differs from its compiled object"):
                validate_link_map(link, known, {"CommandShift"}, sdk, products)

    def test_input_imports_are_owned_by_the_compiled_target(self):
        quartz = "                 U _CGEventSourceKeyState\n"
        apps = "addGlobalMonitorForEventsMatchingMask:handler:\n"
        audit_symbols("CommandShift", quartz, "")
        audit_symbols("DeskMoteApps", "", apps)
        audit_symbols("DeskMote", quartz, apps, linked_targets={"DeskMote", "CommandShift", "DeskMoteApps"})
        for target in ("DeskMote", "DeskMoteApps", "DeskMoteFinder"):
            with self.subTest(target=target), self.assertRaisesRegex(SystemExit, "Raw input"):
                audit_symbols(target, quartz, "")
        with self.assertRaisesRegex(SystemExit, "Event monitor"):
            audit_symbols("DeskMote", "", apps)
        with self.assertRaisesRegex(SystemExit, "Input injection"):
            audit_symbols("CommandShift", "                 U _CGEventPost\n", "")

    def test_source_accepts_exact_masks_and_read_only_history_and_rejects_changed_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ("Modules/Apps/AppsPopup.swift", "Modules/CommandShift/KeyboardMonitor.swift",
                     "Modules/BatteryRun/PowerHistoryLoader.swift", "Modules/BatteryRun/BatteryMonitor.swift")
            for name in names:
                destination = root / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((ROOT / name).read_bytes())
            check_source(root)
            for name, token, replacement, message in (
                (names[0], "= .leftMouseDown", "= .leftMouseUp", "leftMouseDown"),
                (names[0], "matching: Self.outsideClickMask", "matching: .leftMouseUp", "Local event mask"),
                (names[1], ".tailAppendEventTap, .listenOnly", ".tailAppendEventTap, .defaultTap", "passive"),
                (names[2], '"/usr/bin/pmset"', '"/bin/sh"', "journal"),
                (names[2], '["-g", "log"]', '["-g"]', "journal"),
                (names[2], 'process.executableURL = executable', 'process.executableURL = URL(fileURLWithPath: "/bin/sh")', "journal"),
                (names[2], 'process.arguments = arguments', 'process.arguments = ["-g"]', "journal"),
                (names[3], 'PowerHistoryLoader.run()', 'PowerHistoryLoader.run(arguments: ["-g"])', "fixed"),
            ):
                path = root / name
                original = path.read_text()
                self.assertIn(token, original)
                path.write_text(original.replace(token, replacement, 1))
                with self.subTest(token=token), self.assertRaisesRegex(SystemExit, message):
                    check_source(root)
                path.write_text(original)

    def test_bundle_refuses_an_external_url_command_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.base_app(Path(directory), CFBundleURLTypes=[{"CFBundleURLSchemes": ["deskmote-dev"]}])
            with patch.object(check_bundle, "run", side_effect=self.mock_binary_read), \
                    patch.object(check_bundle, "check_signature"):
                with self.assertRaisesRegex(SystemExit, "registration"):
                    check_bundle.check_bundle(app, "base", "v8", "a" * 40)

    def test_bundle_refuses_an_unrecognized_ancillary_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.base_app(Path(directory))
            helper = app / "Contents/Resources/UnexpectedHelper"
            helper.write_bytes(b"\xcf\xfa\xed\xfe")
            with patch.object(check_bundle, "run", side_effect=self.mock_binary_read), \
                    patch.object(check_bundle, "check_signature"):
                with self.assertRaisesRegex(SystemExit, "Unexpected executable"):
                    check_bundle.check_bundle(app, "base", "v8", "a" * 40)

    def test_verified_base_app_has_only_its_main_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.base_app(Path(directory))
            with patch.object(check_bundle, "run", side_effect=self.mock_binary_read), \
                    patch.object(check_bundle, "check_signature"):
                check_bundle.check_bundle(app, "base", "v8", "a" * 40)

    def test_bundle_refuses_an_external_library(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.base_app(Path(directory))

            def external_dependency(tool, *args):
                if Path(tool).name == "otool" and args[0] == "-L":
                    return b"app:\n\t@rpath/libUnexpected.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
                return self.mock_binary_read(tool, *args)

            with patch.object(check_bundle, "run", side_effect=external_dependency), \
                    patch.object(check_bundle, "check_signature"):
                with self.assertRaisesRegex(SystemExit, "Unexpected linked library"):
                    check_bundle.check_bundle(app, "base", "v8", "a" * 40)

    @staticmethod
    def base_app(root, **additional):
        app = root / "DeskMote.app"
        executable = app / "Contents/MacOS/DeskMote"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"\xcf\xfa\xed\xfe")
        resources = app / "Contents/Resources"
        resources.mkdir()
        (resources / "LICENSE").touch()
        info = {
            "CFBundleIdentifier": "io.github.sashokey.deskmote", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "8.0.0", "CFBundleVersion": "8", "LSMinimumSystemVersion": "27.0",
            "CFBundleName": "DeskMote", "CFBundleDisplayName": "DeskMote", "CFBundleExecutable": "DeskMote",
            "DeskMoteVersion": "v8", "DeskMoteSourceRevision": "a" * 40, "LSUIElement": True,
            "CFBundleIconName": "AppIcon", **additional,
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        return app

    @staticmethod
    def mock_binary_read(executable, *args):
        if Path(executable).name == "lipo":
            return b"arm64"
        if Path(executable).name == "otool" and args[0] == "-L":
            return b"app:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)\n"
        return b""

    def scan(self, *, imports="", strings="", nested=False, isolated=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / (
                "DeskMote.app/Contents/PlugIns/DeskMoteFinder.appex/Contents/"
                "XPCServices/DeskMoteFinderService.xpc/Contents/MacOS/DeskMoteFinderService"
                if nested else "DeskMote"
            )
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.touch()
            Path(f"{binary}.imports").write_text(imports)
            Path(f"{binary}.strings").write_text(strings)
            verifier = VERIFIER
            if isolated:
                verifier = root / "Scripts/lib/release_binary.sh"
                verifier.parent.mkdir(parents=True)
                verifier.write_bytes(VERIFIER.read_bytes())
            return subprocess.run(
                ["/bin/bash", "-c", """
                    nm() { cat "$2.imports"; }
                    strings() { cat "$2.strings"; }
                    source "$1"
                    verify_release_diagnostics "$2"
                """, "release-hygiene-test", str(verifier), str(binary)],
                capture_output=True, text=True, check=False,
            )

    def test_clean_binary_without_development_sources(self):
        result = self.scan(imports="                 U _CFRelease\n", isolated=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_test_entries_and_owned_journals(self):
        for marker in (
            "--deskmote-dev-test", "--deskmote-dev-fill-check", "DevTestScenario",
            "window-inventory.jsonl", "click-latency.jsonl", "hover-trace.jsonl",
            "DOCK_RECONCILE_SKIP", "io.github.sashokey.deskmote.dev.finder-sync.service",
        ):
            with self.subTest(marker=marker):
                result = self.scan(strings=marker + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release binary", result.stderr)

    def test_rejects_logging_imports_in_nested_executable(self):
        for symbol in ("__os_log_impl", "__os_signpost_emit_with_name_impl", "_NSLog", "_$s2os6LoggerV"):
            with self.subTest(symbol=symbol):
                result = self.scan(imports=f"                 U {symbol}\n", nested=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("imports logging or signpost APIs", result.stderr)
