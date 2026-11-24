import contextlib
import io
import json
import runpy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class WidgetIntentTests(unittest.TestCase):
    script = Path(__file__).resolve().parents[1] / "Tests/Widgets/CheckIntent.py"
    intent = "ConfigureAirQuality"
    type_name = "DeskMoteWidgets.ConfigureAirQuality"
    kind = "SaintPetersburgAirQuality"

    def check_artifact(self, parameter="sourceURL", kind=kind, identifier=intent, source_kind=kind, type_id=0):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "DeskMote.app"
            widget = app / "Contents/PlugIns/DeskMoteWidgets.appex/Contents"
            resource = widget / "Resources/Metadata.appintents/extract.actionsdata"
            resource.parent.mkdir(parents=True)
            resource.write_text(json.dumps({"actions": {identifier: {
                "identifier": identifier,
                "fullyQualifiedTypeName": self.type_name,
                "parameters": [{
                    "name": parameter,
                    "isOptional": True,
                    "valueType": {"primitive": {"wrapper": {"typeIdentifier": type_id}}},
                }],
            }}}))
            read_text = Path.read_text

            def read_fixture(path, *args, **kwargs):
                if path.name == "AirQualityWidget.swift":
                    return (
                        f'    AppIntentConfiguration(kind: "{source_kind}", intent: ConfigureAirQuality.self,\n'
                        '    provider: AQIProvider()) { entry in makeCard(entry) }\n'
                    )
                return read_text(path, *args, **kwargs)

            responses = {
                "/usr/bin/nm": b"symbols",
                "/usr/bin/xcrun": f"0000 s nominal type descriptor for {self.type_name}\n".encode(),
                "/usr/bin/strings": f"{kind}\n".encode(),
            }

            def check_output(args, **kwargs):
                return responses[args[0]]

            with patch.object(sys, "argv", [str(self.script), str(app)]), \
                 patch("subprocess.check_output", side_effect=check_output), \
                 patch.object(Path, "read_text", read_fixture), \
                 contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(self.script), run_name="__main__")

    def test_stable_widget_identity(self):
        self.check_artifact()

    def test_renamed_intent(self):
        with self.assertRaisesRegex(SystemExit, "configuration intent"):
            self.check_artifact(identifier="ConfigureOther")

    def test_renamed_parameter(self):
        with self.assertRaisesRegex(SystemExit, "sourceURL"):
            self.check_artifact(parameter="Address")

    def test_changed_parameter_type(self):
        with self.assertRaisesRegex(SystemExit, "sourceURL"):
            self.check_artifact(type_id=2)

    def test_changed_configuration_with_stable_literal_elsewhere(self):
        with self.assertRaisesRegex(SystemExit, "SaintPetersburgAirQuality"):
            self.check_artifact(source_kind="DifferentAirQuality")

    def test_renamed_kind(self):
        with self.assertRaisesRegex(SystemExit, "SaintPetersburgAirQuality"):
            self.check_artifact(kind="DifferentAirQuality")

    def test_kind_substring_in_binary(self):
        with self.assertRaisesRegex(SystemExit, "SaintPetersburgAirQuality"):
            self.check_artifact(kind=self.kind + "New")


if __name__ == "__main__":
    unittest.main()
