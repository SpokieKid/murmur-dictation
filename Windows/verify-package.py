#!/usr/bin/env python3
"""Verify actual NSIS payload and .NET single-file contents; no Windows execution."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import tempfile
import argparse
import re
import zlib

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=Path, default=root / 'build/windows/public')
parser.add_argument('--allow-bundled-key', action='store_true')
args = parser.parse_args()
directory = args.directory.resolve()
installer = directory / 'Murmur-0.6.0-Windows-x64-Setup.exe'
published = directory / 'publish/Murmur.exe'


def pe(data):
    assert data[:2] == b'MZ', 'Missing DOS header'
    start = struct.unpack_from('<I', data, 60)[0]
    assert data[start:start + 4] == b'PE\0\0', 'Missing PE header'
    machine = struct.unpack_from('<H', data, start + 4)[0]
    optional = start + 24
    magic = struct.unpack_from('<H', data, optional)[0]
    directories = optional + (112 if magic == 0x20b else 96)
    _, signature_size = struct.unpack_from('<II', data, directories + 4 * 8)
    return machine, signature_size > 0


subprocess.run(['7z', 't', str(installer)], check=True, capture_output=True)
with tempfile.TemporaryDirectory(prefix='murmur-windows-package-') as temp:
    subprocess.run(['7z', 'x', '-y', '-o' + temp, str(installer),
                    'Murmur.exe', '使用说明.txt', 'LICENSE.txt', 'dotnet-notices.txt'], check=True, capture_output=True)
    payload = Path(temp) / 'Murmur.exe'
    assert payload.is_file(), 'Installer does not contain the app'
    assert hashlib.sha256(payload.read_bytes()).digest() == hashlib.sha256(published.read_bytes()).digest(), 'Payload differs from published app'
    for name in ['使用说明.txt', 'LICENSE.txt', 'dotnet-notices.txt']:
        assert (Path(temp) / name).stat().st_size > 100, f'Missing {name}'

data = published.read_bytes()
machine, app_signed = pe(data)
assert machine == 0x8664, 'Expected AMD64 application'
_, installer_signed = pe(installer.read_bytes())
marker = bytes.fromhex('8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae')
location = data.find(marker)
assert location >= 8, 'Missing .NET single-file marker'
cursor = struct.unpack_from('<Q', data, location - 8)[0]
major, minor, count = struct.unpack_from('<III', data, cursor)
assert major == 6 and 0 < count < 10000, 'Unexpected .NET bundle format'
cursor += 12


def string():
    global cursor
    length = shift = 0
    while True:
        value = data[cursor]
        cursor += 1
        length |= (value & 127) << shift
        shift += 7
        if not value & 128:
            break
    result = data[cursor:cursor + length].decode()
    cursor += length
    return result


string()
_, _, config_offset, config_size, _ = struct.unpack_from('<QQQQQ', data, cursor)
cursor += 40
entries = []
app_assemblies = []
for _ in range(count):
    offset, size, compressed = struct.unpack_from('<QQQ', data, cursor)
    cursor += 24
    kind = data[cursor]
    cursor += 1
    name = string()
    assert offset + (compressed or size) <= len(data), f'Invalid bundle entry {name}'
    entries.append(name)
    if name in ('Murmur.dll', 'Murmur.Core.dll'):
        content = data[offset:offset + (compressed or size)]
        if compressed:
            content = zlib.decompress(content, -15)
        assert len(content) == size, f'Invalid decompressed assembly {name}'
        app_assemblies.append(content)

if not args.allow_bundled_key:
    assembly = app_assemblies[0]
    config_start = assembly.find(b'{"ApiKey":')
    assert config_start >= 0, 'Missing explicit public configuration resource'
    config, _ = json.JSONDecoder().raw_decode(assembly[config_start:].decode('utf-8', errors='replace'))
    assert not config.get('ApiKey'), 'Public installer contains a bundled API key'
    swift = root / 'Sources/Murmur/Defaults.swift'
    known = re.search(r'static let defaultAPIKey = "([^"\n]*)"', swift.read_text())
    for content in app_assemblies:
        if known and len(known.group(1)) > 10:
            assert known.group(1).encode() not in content and known.group(1).encode('utf-16-le') not in content, 'Credential found in app assembly'
        assert not re.search(rb'sk-[A-Za-z0-9._-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}', content), 'Credential pattern found in app assembly'

for name in ['Murmur.dll', 'Murmur.Core.dll', 'System.Private.CoreLib.dll',
             'System.Windows.Forms.dll', 'UIAutomationClient.dll', 'UIAutomationTypes.dll']:
    assert name in entries, f'Missing bundled dependency {name}'
runtime = json.loads(data[config_offset:config_offset + config_size])['runtimeOptions']
frameworks = runtime['includedFrameworks']
assert {x['name'] for x in frameworks} >= {'Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App'}
assert not runtime.get('frameworks'), 'Package still requires an external runtime'

result = {
    'version': '0.6.0', 'architecture': 'win-x64',
    'installer_bytes': installer.stat().st_size,
    'installer_sha256': hashlib.sha256(installer.read_bytes()).hexdigest(),
    'app_sha256': hashlib.sha256(data).hexdigest(),
    'archive_crc': 'passed', 'extracted_app_matches_publish': True,
    'embedded_bundle_files': count, 'self_contained_frameworks': frameworks,
    'authenticode_signed': installer_signed and app_signed,
    'bundled_api_key_absent': not args.allow_bundled_key,
    'native_windows_install_audio_hotkey_and_paste_tested': False,
}
(directory / 'verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(result, ensure_ascii=False, indent=2))
