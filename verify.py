#!/usr/bin/env python3
"""Run the real Swift core tests and optionally the iOS simulator build.

No calendar is read or modified. Use --ios on a Mac with full Xcode installed.
"""
from pathlib import Path
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent


def run(*args, env=None):
    subprocess.run([str(x) for x in args], cwd=ROOT, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ios', action='store_true', help='Require a successful iOS Simulator build')
    args = parser.parse_args()
    swiftc = os.environ.get('SWIFTC') or shutil.which('swiftc')
    if not swiftc:
        raise SystemExit('No se encontró Swift. Instala Xcode en el Mac o indica SWIFTC.')

    run('python3', 'make_project.py')
    app = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())
    widget = plistlib.loads((ROOT / 'Widget/Info.plist').read_bytes())
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        assert app[key] == widget[key], f'App/widget mismatch: {key}'
    for key in ('NSCalendarsFullAccessUsageDescription', 'NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
        assert app.get(key), f'Missing permission description: {key}'
    ET.parse(ROOT / 'MiAgenda.xcodeproj/xcshareddata/xcschemes/MiAgenda.xcscheme')
    project = (ROOT / 'MiAgenda.xcodeproj/project.pbxproj').read_text()
    source_files = sorted(list((ROOT / 'App').glob('*.swift')) + list((ROOT / 'Shared').glob('*.swift')) + list((ROOT / 'Widget').glob('*.swift')))
    for source in source_files:
        assert f'path = "{source.relative_to(ROOT)}";' in project, f'Missing project source: {source}'
        # Syntax parsing does not import, typecheck or link Apple frameworks.
        run(swiftc, '-frontend', '-parse', source)
    print('Project metadata and Swift syntax: OK', flush=True)

    suites = [
        ('calendar', ['Shared/AgendaModels.swift', 'Shared/AgendaMath.swift', 'Tests/AgendaMathTests.swift']),
        ('conversation', ['Shared/AgendaModels.swift', 'Shared/AgendaConversation.swift', 'Tests/AgendaConversationTests.swift']),
        ('voice', ['Shared/VoiceTurnGate.swift', 'Tests/VoiceTurnGateTests.swift']),
    ]
    with tempfile.TemporaryDirectory(prefix='miagenda-tests-') as build:
        for name, sources in suites:
            binary = Path(build) / name
            run(swiftc, '-swift-version', '5', *sources, '-o', binary)
            for zone in ('Europe/Madrid', 'UTC'):
                print(f'{name}: TZ={zone}', flush=True)
                run(binary, env=dict(os.environ, TZ=zone))
    if args.ios:
        if not shutil.which('xcodebuild'):
            raise SystemExit('Las pruebas del núcleo pasaron. Falta Xcode: la compilación iOS NO se ha realizado.')
        with tempfile.TemporaryDirectory(prefix='miagenda-ios-') as build:
            run('xcodebuild', '-project', 'MiAgenda.xcodeproj', '-scheme', 'MiAgenda',
                '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
                '-derivedDataPath', build, 'CODE_SIGNING_ALLOWED=NO', 'build')
        print('iOS Simulator build: OK. Las pruebas de dispositivo siguen siendo necesarias.')
    else:
        print('Núcleo verificado. iOS NO compilado; voz, SwiftUI, EventKit y widget pendientes de pruebas en iPhone.')


if __name__ == '__main__':
    main()
