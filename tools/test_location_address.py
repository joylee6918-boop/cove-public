#!/usr/bin/env python3
"""macOS-only offline check of the actual shared Swift model and address resolver.
Uses synthetic postal fixtures and a fake geocoder; no GPS/network/model calls.
"""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ios/Cove/LocationSharing.swift').read_text()
model = source[source.index('struct SharedLocation:'):source.index('struct LocationGrant:')]
resolver = source[source.index('@MainActor protocol LocationGeocoding:'):source.index('// CoreLocation delivers delegate callbacks')]
with tempfile.TemporaryDirectory(prefix='cove-address-test-') as directory:
    folder = Path(directory)
    swift = folder / 'Production.swift'
    swift.write_text('import Foundation\nimport CoreLocation\nimport MapKit\nimport Contacts\n' + model + resolver)
    executable = folder / 'address-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), str(Path(__file__).with_name('LocationAddressTests.swift')), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)

assert 'return try await resolveAddress(snapshot)' in source
assert 'let resolved = try await capture.resolveAddress(value)' in source
assert 'body["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))' in source
assert 'guard let location, !busy, !resolvingAddress else { return }' in source
assert 'token == selectionGeneration, !Task.isCancelled' in source
assert 'if phase == .background { cancelSelection()' in source
card = source[source.index('struct SharedLocationCard:'):source.index('struct LocationPickerSheet:')]
assert 'Text(location.displayAddress)' in card and '.task' not in card and 'resolveAddress' not in card
assert 'enqueueChatText(location.message,' in (ROOT / 'ios/Cove/CoveStore.swift').read_text()
sys.path.insert(0, str(ROOT / 'server'))
from location_share import snapshot
from datetime import datetime
raw = {'latitude': 30, 'longitude': 110, 'accuracyMeters': 27, 'capturedAt': '2026-11-01T12:00:00Z',
       'source': 'current', 'name': '合成测试地点', 'address': '测试省测试市测试路100号（非真实地址）'}
clock = datetime.fromisoformat(raw['capturedAt'].replace('Z', '+00:00')).timestamp()
assert snapshot(raw, clock, clock) == raw
print('PASS manual/automatic message wiring and server address preservation')
