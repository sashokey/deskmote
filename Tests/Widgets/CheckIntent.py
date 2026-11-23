import json
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
widget = app / 'Contents/PlugIns/DeskMoteWidgets.appex/Contents'
metadata = json.loads((widget / 'Resources/Metadata.appintents/extract.actionsdata').read_text())

def find_configuration(value):
    if isinstance(value, dict):
        if value.get('identifier') == 'ConfigureAirQuality' and 'fullyQualifiedTypeName' in value:
            return value['fullyQualifiedTypeName']
        values = value.values()
    elif isinstance(value, list):
        values = value
    else:
        return None
    return next((name for item in values if (name := find_configuration(item))), None)

name = find_configuration(metadata)
if not name:
    raise SystemExit('The configuration intent is missing from App Intents metadata')
symbols = subprocess.check_output(['/usr/bin/nm', str(widget / 'MacOS/DeskMoteWidgets')])
demangled = subprocess.check_output(['/usr/bin/xcrun', 'swift-demangle', '--compact'], input=symbols, text=False).decode().splitlines()
if not any(line.endswith(f' nominal type descriptor for {name}') for line in demangled):
    raise SystemExit(f'No Swift type descriptor matches {name}')
print(f'App Intents metadata matches Swift type descriptor for {name}')
