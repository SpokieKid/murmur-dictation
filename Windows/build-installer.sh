#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DOTNET_BIN="${DOTNET_BIN:-$ROOT/build/tools/dotnet/dotnet}"
if [ ! -x "$DOTNET_BIN" ]; then DOTNET_BIN="$(command -v dotnet || true)"; fi
if [ -z "$DOTNET_BIN" ] || [ ! -x "$DOTNET_BIN" ]; then echo 'Install the .NET 10 SDK or set DOTNET_BIN.' >&2; exit 1; fi
command -v makensis >/dev/null || { echo 'Install NSIS (macOS: brew install makensis).' >&2; exit 1; }
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_GENERATE_ASPNET_CERTIFICATE=false
export MURMUR_WINDOWS_BUILD_KIND="${MURMUR_WINDOWS_BUILD_KIND:-public}"
case "$MURMUR_WINDOWS_BUILD_KIND" in public|internal) ;; *) echo 'Build kind must be public or internal.' >&2; exit 1 ;; esac
export MURMUR_WINDOWS_BUILD_DIR="$ROOT/build/windows/$MURMUR_WINDOWS_BUILD_KIND"
mkdir -p "$MURMUR_WINDOWS_BUILD_DIR"
# Public builds read Windows defaults only and embed an empty API key.
# Internal credentials require an explicit opt-in and a separate output directory.
python3 - <<'PY_CONFIG'
from pathlib import Path
import re,json,os
source=Path('Windows/Murmur.Core/AppConfig.cs').read_text()
def property_value(name):
    return re.search(r'public string '+name+r' .*?= "([^"\n]*)";',source).group(1)
data={'ApiKey':'','LlmModel':property_value('LlmModel'),
      'Model':property_value('Model'),'PolishPrompt':property_value('PolishPrompt')}
if os.environ['MURMUR_WINDOWS_BUILD_KIND']=='internal':
    swift=Path('Sources/Murmur/Defaults.swift').read_text()
    data['ApiKey']=re.search(r'static let defaultAPIKey = "([^"\n]+)"',swift).group(1)
Path(os.environ['MURMUR_WINDOWS_BUILD_DIR'],'TrialDefaults.json').write_text(json.dumps(data,ensure_ascii=False))
PY_CONFIG
"$DOTNET_BIN" run --project Windows/Murmur.Core.Tests -c Release
"$DOTNET_BIN" publish Windows/Murmur.Windows/Murmur.Windows.csproj -c Release -r win-x64 \
    --self-contained true -p:PublishReadyToRun=false -p:EnableCompressionInSingleFile=true \
    "-p:TrialDefaultsPath=$MURMUR_WINDOWS_BUILD_DIR/TrialDefaults.json" -o "$MURMUR_WINDOWS_BUILD_DIR/publish"
python3 - <<'PY'
from pathlib import Path
import json,os
assets=json.loads(Path('Windows/Murmur.Windows/obj/project.assets.json').read_text())
parts=[]
packages={name:lib['path'] for name,lib in assets['libraries'].items()}
for framework in assets['project']['frameworks'].values():
    for package in framework.get('downloadDependencies',[]):
        version=package['version'].strip('[]').split(',')[0].strip()
        packages[package['name']+'/'+version]=package['name'].lower()+'/'+version
seen=set()
for name,path in packages.items():
    if not name.lower().startswith(('microsoft.netcore.app.runtime.', 'microsoft.windowsdesktop.app.runtime.')): continue
    for folder in assets['packageFolders']:
        base=Path(folder)/path
        for filename in ['LICENSE','LICENSE.TXT','LICENSE.txt','THIRD-PARTY-NOTICES.TXT','ThirdPartyNotices.txt']:
            file=base/filename
            if file.is_file() and str(file).lower() not in seen:
                parts.append(name+' / '+filename+'\n'+file.read_text()); seen.add(str(file).lower())
if not parts: raise SystemExit('Missing .NET runtime notices')
Path(os.environ['MURMUR_WINDOWS_BUILD_DIR'],'runtime-notices.txt').write_text('\n\n'.join(parts))
PY
makensis -WX -V3 "-DPROJECT_ROOT=$ROOT" "-DPAYLOAD_DIR=$MURMUR_WINDOWS_BUILD_DIR/publish" "-DBUILD_DIR=$MURMUR_WINDOWS_BUILD_DIR" \
    "-DOUTPUT_FILE=$MURMUR_WINDOWS_BUILD_DIR/Murmur-0.6.0-Windows-x64-Setup.exe" Windows/installer.nsi
(
    cd "$MURMUR_WINDOWS_BUILD_DIR"
    shasum -a 256 Murmur-0.6.0-Windows-x64-Setup.exe > Murmur-0.6.0-Windows-x64-Setup.exe.sha256
)
echo "Created $MURMUR_WINDOWS_BUILD_DIR/Murmur-0.6.0-Windows-x64-Setup.exe"
