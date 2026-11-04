#!/bin/bash
# Build the self-contained fairplay-decrypt helper used by the .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

PYTHON="${PYTHON:-$PWD/.build/macos15/python15/bin/python3.13}"
VENV="${DUMPSHOP_HELPER_VENV:-.build/fairplay-helper-venv15}"
export MACOSX_DEPLOYMENT_TARGET=15.0

if [ ! -x "$PYTHON" ]; then
  echo "Build the compatible runtime first: python3 scripts/build_macos15_runtime.py" >&2
  exit 1
fi
if [ ! -x "$VENV/bin/python3" ]; then
  "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python3" -m pip install --quiet --upgrade pip
"$VENV/bin/python3" -m pip install --quiet "cryptography==50.0.2" "pyinstaller==6.22.3"

# Ship licenses from the exact runtime versions used for this build.
"$VENV/bin/python3" - <<'PY'
from pathlib import Path
from importlib.metadata import distribution
import os
import shutil

root = Path(os.environ.get('DUMPSHOP_RUNTIME_BUILD', '.build/macos15'))
licenses = Path('vendor/runtime-licenses')
(licenses / 'python').mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'prefix/share/dumpshop-licenses/python/LICENSE',
                licenses / 'python/LICENSE.txt')
for name in ('cryptography', 'pyinstaller'):
    target = licenses / name
    if target.exists():
        shutil.rmtree(target)
    package = distribution(name)
    for item in package.files:
        if '.dist-info/licenses/' in str(item):
            relative = str(item).split('.dist-info/licenses/', 1)[1]
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(package.locate_file(item), destination)
PY

"$VENV/bin/pyinstaller" \
  --noconfirm --clean --onefile \
  --name fairplay-decrypt-helper \
  --paths vendor/fairplay-decrypt \
  --paths vendor/fairplay-decrypt/credential-retrieval \
  --paths engine \
  --hidden-import core \
  --hidden-import decrypt \
  --hidden-import retrieve \
  --hidden-import native_ssh \
  --hidden-import store \
  --hidden-import store_history \
  --distpath .build/fairplay-helper-dist \
  --workpath .build/fairplay-helper-work \
  --specpath .build \
  engine/fairplay_helper.py

cp .build/fairplay-helper-dist/fairplay-decrypt-helper \
  vendor/fairplay-decrypt-helper-macos-arm64
chmod 755 vendor/fairplay-decrypt-helper-macos-arm64
shasum -a 256 vendor/fairplay-decrypt-helper-macos-arm64
