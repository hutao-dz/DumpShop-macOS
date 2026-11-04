#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Full packaging currently requires macOS on Apple Silicon." >&2
  exit 1
fi
for tool in python3 go xcrun codesign ldid make; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing build tool: $tool. See README.md." >&2
    exit 1
  fi
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null

python3 scripts/build_macos15_runtime.py

echo '[1/4] Official CN download helper (verified release SHA256)'
python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'engine')
import store
destination = Path('vendor/ipatool-2.7.0-macos-arm64')
if not destination.exists():
    store.download_ipatool(destination, on_line=print)
else:
    print('Existing local helper retained. Delete it to re-fetch the verified release.')
PY

echo '[2/4] Regional helpers from vendored source'
bash build_ipatool_profiles.sh
echo '[3/4] Standalone Python helper'
bash build_fairplay_helper.sh
echo '[4/4] Device-side tools from vendored source'
make -C vendor/fairplay-decrypt credential-bundle
mkdir -p vendor/fairplay-device-bundle
cp vendor/fairplay-decrypt/credential-retrieval/build/bundle/* vendor/fairplay-device-bundle/
echo 'Dependencies ready. Run: bash build_app.sh ./outputs'
