import json
import re
import subprocess
import sys
from pathlib import Path


def check_configuration(app, source):
    widget = app / 'Contents/PlugIns/DeskMoteWidgets.appex/Contents'
    metadata = json.loads((widget / 'Resources/Metadata.appintents/extract.actionsdata').read_text())
    configuration = metadata.get('actions', {}).get('ConfigureAirQuality', {})
    name = 'DeskMoteWidgets.ConfigureAirQuality'
    kind = 'SaintPetersburgAirQuality'
    if configuration.get('identifier') != 'ConfigureAirQuality' or configuration.get('fullyQualifiedTypeName') != name:
        raise SystemExit('The configuration intent is missing from App Intents metadata')

    parameters = configuration.get('parameters', [])
    string_type = {'primitive': {'wrapper': {'typeIdentifier': 0}}}
    if (len(parameters) != 1 or parameters[0].get('name') != 'sourceURL'
            or parameters[0].get('isOptional') is not True or parameters[0].get('valueType') != string_type):
        raise SystemExit('ConfigureAirQuality must have one optional string parameter named sourceURL')

    executable = widget / 'MacOS/DeskMoteWidgets'
    symbols = subprocess.check_output(['/usr/bin/nm', str(executable)])
    demangled = subprocess.check_output(['/usr/bin/xcrun', 'swift-demangle', '--compact'], input=symbols).decode().splitlines()
    if not any(line.endswith(f' nominal type descriptor for {name}') for line in demangled):
        raise SystemExit(f'No Swift type descriptor matches {name}')

    literals = subprocess.check_output(['/usr/bin/strings', '-a', str(executable)]).splitlines()
    if kind.encode() not in literals:
        raise SystemExit(f'The widget executable is missing the kind {kind}')

    calls = re.findall(r'(?m)^\s*AppIntentConfiguration\s*\(\s*kind:\s*"([^"]+)"\s*,'
                       r'\s*intent:\s*(\w+)\.self\s*,', source.read_text())
    if calls != [(kind, 'ConfigureAirQuality')]:
        raise SystemExit(f'The widget must configure {kind} with ConfigureAirQuality')


if __name__ == '__main__':
    source = Path(__file__).resolve().parents[2] / 'Extensions/Widgets/AirQualityWidget.swift'
    check_configuration(Path(sys.argv[1]), source)
    print('The AQI widget kind, configuration intent, and sourceURL parameter match')
