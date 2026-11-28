import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class LocalBuildTests(unittest.TestCase):
    def test_only_finder_is_packaged_and_only_in_full(self):
        import check_bundle

        self.assertEqual(check_bundle.VARIANTS, {
            "full": {"DeskMoteFinder.appex"}, "base": set(), "no-finder": set(),
        })
        self.assertEqual(set(check_bundle.EXTENSIONS), {"DeskMoteFinder.appex"})
        self.assertEqual(check_bundle.FINDER_SERVICE, "DeskMoteFinderService.xpc")

    def test_widget_has_no_target_or_implicit_embed(self):
        root = Path(__file__).resolve().parents[1]
        project = root / "DeskMote.xcodeproj/project.pbxproj"
        graph = subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project)])
        objects = json.loads(graph)["objects"]
        targets = {obj["name"] for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"}
        self.assertTrue({"DeskMoteFinder", "DeskMoteFinderService", "DeskMoteApps"} <= targets)
        for value in (b"DeskMoteWidgets", b"WidgetRecovery.swift", b"DESKMOTE_WIDGET", b"VARIANT_TARGETS_no_widget"):
            self.assertNotIn(value, graph)

    def test_no_widget_alias_is_rejected_before_build_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            scripts = Path(directory) / "Scripts"
            (scripts / "lib").mkdir(parents=True)
            for name in ("xcode.sh", "release_binary.sh"):
                (scripts / "lib" / name).write_text("require_deskmote_platform() { return 42; }\n")
            shutil.copyfile(Path(__file__).with_name("build.sh"), scripts / "build.sh")
            result = subprocess.run(["/bin/bash", str(scripts / "build.sh"), "no-widget"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_release_diagnostic_scan_rejects_dev_fill_check(self):
        verifier = Path(__file__).with_name("lib") / "release_binary.sh"
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "DeskMote"
            binary.write_bytes(b"ordinary app text\x00")
            command = [
                "/bin/bash", "-c",
                'source "$1"; nm() { printf "U _malloc\\n"; }; verify_release_diagnostics "$2"',
                "scan", str(verifier), str(binary),
            ]
            clean = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            for marker in (b"--deskmote-dev-fill-check", b"DevFillCheck"):
                with self.subTest(marker=marker):
                    binary.write_bytes(b"ordinary app text\x00" + marker + b"\x00")
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn("test entry", result.stderr)

    def test_base_excludes_apps_target(self):
        self.assert_excluded_build_target("base", "DeskMoteApps")

    def test_apps_strings_table_matches_variant(self):
        import check_bundle

        check_apps_table = getattr(check_bundle, "check_apps_table", None)
        self.assertTrue(callable(check_apps_table), "The bundle verifier must check the Apps table")
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "DeskMote.app"
            resources = app / "Contents/Resources"
            expected = {
                language: {"Pinned": value}
                for language, value in (("en", "Pinned"), ("ru", "Закреплённые"), ("de", "Angeheftet"))
            }
            catalog = Path(directory) / "Apps.xcstrings"
            catalog.write_text(json.dumps({"strings": {"Pinned": {"localizations": {
                language: {"stringUnit": {"value": entries["Pinned"]}}
                for language, entries in expected.items()
            }}}}))
            check_apps_table(app, "base", catalog)
            with self.assertRaisesRegex(SystemExit, "Missing Apps"):
                check_apps_table(app, "full", catalog)
            for language, entries in expected.items():
                table = resources / f"{language}.lproj/Apps.strings"
                table.parent.mkdir(parents=True)
                table.write_bytes(plistlib.dumps(entries))
            for variant in ("full", "no-finder"):
                check_apps_table(app, variant, catalog)
            with self.assertRaisesRegex(SystemExit, "Unexpected Apps"):
                check_apps_table(app, "base", catalog)
            (resources / "ru.lproj/Apps.strings").write_bytes(plistlib.dumps({"Pinned": "Pinned"}))
            with self.assertRaisesRegex(SystemExit, "Unexpected Apps translation"):
                check_apps_table(app, "full", catalog)

    def test_exclusion_builds_reject_excluded_targets_even_if_the_bundle_is_valid(self):
        self.assert_excluded_build_target("no-finder", "DeskMoteFinderService")

    def assert_excluded_build_target(self, variant, target):
        with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            (scripts / "lib").mkdir(parents=True)
            (root / ".github").mkdir()
            (root / ".github/release.json").write_text('{"version": "v1"}')
            (root / "LICENSE").touch()
            (scripts / "check_bundle.py").touch()
            (scripts / "check_availability_warnings.py").touch()
            (scripts / "lib/release_binary.sh").write_text(
                "strip_release_binary() { :; }\nverify_release_binary() { :; }\n")
            (scripts / "lib/xcode.sh").write_text(f"""
require_deskmote_platform() {{ :; }}
select_deskmote_xcode() {{ :; }}
git() {{ printf '%040d\\n' 1; }}
codesign() {{ :; }}
xcodebuild() {{
  while [[ "$1" != -derivedDataPath ]]; do shift; done
  mkdir -p "$2/Build/Products/Release/DeskMote.app/Contents/Resources"
  printf "    Target '{target}' in project 'DeskMote'\\n"
}}
""")
            shutil.copyfile(Path(__file__).with_name("build.sh"), scripts / "build.sh")
            result = subprocess.run(["/bin/bash", "Scripts/build.sh", variant], cwd=root,
                                    env={"PATH": os.environ["PATH"]}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn(variant, result.stderr)

    def test_failed_archive_verification_leaves_the_release_name_available(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            scripts.mkdir()
            (root / ".github").mkdir()
            (root / ".github/release.json").write_text('{"version": "v1"}')
            (root / "DeskMote.app").mkdir()
            test_bin = root / "bin"
            test_bin.mkdir()
            git = test_bin / "git"
            git.write_text("#!/bin/bash\nprintf '%040d\\n' 1\n")
            git.chmod(0o755)
            (scripts / "build.sh").write_text('printf "%s/DeskMote.app\\n" "$PWD"\n')
            (scripts / "check_bundle.py").write_text("raise SystemExit(31)\n")
            shutil.copyfile(Path(__file__).with_name("package_release.sh"), scripts / "package_release.sh")
            environment = {"PATH": f"{test_bin}:{os.environ['PATH']}", "TMPDIR": directory}

            def package():
                return subprocess.run(["/bin/bash", "Scripts/package_release.sh"], cwd=root,
                                      env=environment, capture_output=True, text=True)

            archive = root / "dist/DeskMote-v1.zip"
            failed = package()
            self.assertEqual(failed.returncode, 31, failed.stderr)
            self.assertFalse(archive.exists())
            (scripts / "check_bundle.py").write_text("")
            retried = package()
            self.assertEqual(retried.returncode, 0, retried.stderr)
            self.assertTrue(archive.is_file())

    def test_tag_build_reaches_xcode_without_a_keychain_query(self):
        revision = "1" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "Scripts"
            (scripts / "lib").mkdir(parents=True)
            (root / ".github").mkdir()
            (root / ".github/release.json").write_text('{"version": "v1"}')
            shutil.copyfile(Path(__file__).with_name("build.sh"), scripts / "build.sh")
            (scripts / "lib/release_binary.sh").touch()
            (scripts / "lib/xcode.sh").write_text(f"""
require_deskmote_platform() {{ :; }}
select_deskmote_xcode() {{ :; }}
git() {{
  case "$*" in
    'rev-parse --verify HEAD'|'rev-parse --verify refs/tags/v1^{{commit}}') printf '%s\\n' '{revision}';;
    'status --porcelain --untracked-files=normal') return "${{DESKMOTE_TEST_STATUS_EXIT:-0}}";;
    *) return 90;;
  esac
}}
security() {{ printf 'Unexpected signing identity query\\n' >&2; return 90; }}
xcodebuild() {{ printf '%s\\n' "$@"; return 42; }}
""")
            run = subprocess.run(
                ["/bin/bash", "Scripts/build.sh", "full", "--local", "v1"],
                cwd=root, env={key: os.environ[key] for key in ("PATH", "HOME")}, capture_output=True, text=True,
            )
            unknown_state = subprocess.run(
                ["/bin/bash", "Scripts/build.sh", "full", "--local", "v1"],
                cwd=root, env={"PATH": os.environ["PATH"], "DESKMOTE_TEST_STATUS_EXIT": "29"},
                capture_output=True, text=True,
            )
        self.assertEqual(run.returncode, 42, run.stderr)
        self.assertIn("DESKMOTE_PUBLIC_VERSION=v1", run.stderr)
        self.assertIn(f"DESKMOTE_SOURCE_REVISION={revision}", run.stderr)
        self.assertEqual(unknown_state.returncode, 29, unknown_state.stderr)
        self.assertNotIn("DESKMOTE_SOURCE_REVISION=", unknown_state.stderr)
