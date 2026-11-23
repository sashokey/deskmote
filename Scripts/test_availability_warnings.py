import pathlib
import tempfile
import unittest

from check_availability_warnings import availability_warnings


class AvailabilityWarningsTests(unittest.TestCase):
    def test_reports_app_and_tool_warnings_once_but_ignores_sdk_diagnostics(self):
        warning = "/repo/App/View.swift:4: warning: API is only available in macOS 27.0 or newer"
        tool = "/repo/Tools/DeskMoteWindowLab/CommandLine/main.swift:8: warning: API is only available in macOS 27.0 or newer"
        sdk = "/SDK/Foundation.swift:9: warning: API is only available in macOS 27.0 or newer"
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "build.log"
            module = "/repo/Modules/BatteryRun/My File.swift:8:10: warning: API is only available in macOS 28 or newer"
            extension = "/repo/Extensions/Widgets/Widget.swift:8:10: error: API is only available in macOS 28 or newer"
            log.write_text("\n".join([warning, warning, tool, module, extension, sdk, "BUILD SUCCEEDED"]))
            self.assertEqual(availability_warnings([log]), [warning, tool, module, extension])

    def test_missing_logs_do_not_count_as_a_clean_build(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                availability_warnings([pathlib.Path(directory) / "missing.log"])

    def test_clean_log_has_no_violations(self):
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "build.log"
            log.write_text("BUILD SUCCEEDED\n")
            self.assertEqual(availability_warnings([log]), [])


if __name__ == "__main__":
    unittest.main()
