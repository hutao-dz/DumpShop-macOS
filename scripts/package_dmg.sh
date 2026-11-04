#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE_ROOT="$PWD/.build/dmg-release"
IMAGE_ROOT="$RELEASE_ROOT/image"
DESTINATION="${1:-$PWD/outputs/砸壳工坊-2.3-macOS15-arm64.dmg}"
if [[ -e "$IMAGE_ROOT" || -e "$DESTINATION" ]]; then
  echo 'Release directory or destination exists; choose a fresh output before rebuilding.' >&2
  exit 1
fi
mkdir -p "$IMAGE_ROOT" "$(dirname "$DESTINATION")"
bash build_app.sh "$IMAGE_ROOT"
cp docs/使用说明.md "$IMAGE_ROOT/使用说明.md"
cp README.md "$IMAGE_ROOT/开源与致谢.md"
cp LICENSE "$IMAGE_ROOT/LICENSE"
ln -s /Applications "$IMAGE_ROOT/Applications"
hdiutil create -volname '砸壳工坊安装' -srcfolder "$IMAGE_ROOT" \
  -format UDZO -ov "$DESTINATION"
hdiutil verify "$DESTINATION"
shasum -a 256 "$DESTINATION" > "$DESTINATION.sha256"
echo "Created: $DESTINATION"
