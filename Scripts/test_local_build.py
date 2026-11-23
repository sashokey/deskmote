import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class LocalBuildTests(unittest.TestCase):
    def test_exclusion_builds_reject_excluded_targets_even_if_the_bundle_is_valid(self):
        for variant, target in [("no-widget", "DeskMoteWidgets"), ("no-finder", "DeskMoteFinderService")]:
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
            widget_check = root / "Tests/Widgets/CheckIntent.py"
            widget_check.parent.mkdir(parents=True)
            widget_check.touch()
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
