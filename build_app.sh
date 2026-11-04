#!/bin/bash
# Build release binary and assemble a standalone .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="砸壳工坊"
OUT_DIR="${1:-../outputs}"
APP="$OUT_DIR/$APP_NAME.app"
if [ -e "$APP" ]; then
  echo "Output app already exists. Choose a fresh output directory: $APP" >&2
  exit 1
fi

# This public repository contains sources only. Prepare helpers explicitly.
for dependency in \
  vendor/ipatool-2.7.0-macos-arm64 \
  vendor/ipatool-profile-2.7.0-macos-arm64 \
  vendor/ipatool-hk-arm64 \
  vendor/fairplay-decrypt-helper-macos-arm64 \
  vendor/fairplay-device-bundle/credential.ios \
  vendor/fairplay-device-bundle/driver.ios \
  vendor/fairplay-device-bundle/trigger.ios \
  vendor/fairplay-device-bundle/static-key-table.bin \
  vendor/fairplay-device-bundle/core4-word-table.bin; do
  if [ ! -f "$dependency" ]; then
    echo "Missing $dependency. Run: bash scripts/prepare_dependencies.sh" >&2
    exit 1
  fi
done

echo "[1/4] swift build -c release"
swift build -c release

echo "[2/4] assemble bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DumpShop "$APP/Contents/MacOS/DumpShop"
chmod +x "$APP/Contents/MacOS/DumpShop"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The Python engine ships as app resources, so the bundle is self-contained.
mkdir -p "$APP/Contents/Resources/engine"
cp engine/dumper.py engine/probe.py engine/applist.py engine/mount_ddi.py engine/appsize.py engine/devices.py engine/store.py engine/store_history.py "$APP/Contents/Resources/engine/"

# Session setup stays outside the app UI. The script is shipped next to the app
# and is also retained in Resources for the combined release archive.
mkdir -p "$APP/Contents/Resources/scripts"
cp scripts/初始化下载会话.command "$APP/Contents/Resources/scripts/"
chmod +x "$APP/Contents/Resources/scripts/初始化下载会话.command"
cp scripts/初始化下载会话.command "$OUT_DIR/初始化下载会话.command"
chmod +x "$OUT_DIR/初始化下载会话.command"

# App Store downloads go through ipatool (MIT). The vendored copies were unpacked
# from the official release tarballs after checking their published sha256, so the
# .app needs no Homebrew and no first-run download on a matching Mac. store.py
# still verifies any copy it fetches itself.
mkdir -p "$APP/Contents/Resources/bin"
for f in vendor/ipatool-*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  case "$name" in
    ipatool-hk-*)
      arch="${name##*-}"
      cp "$f" "$APP/Contents/Resources/bin/ipatool-hk-$arch"
      chmod +x "$APP/Contents/Resources/bin/ipatool-hk-$arch"
      ;;
    ipatool-profile-*)
      arch="${name##*-macos-}"
      cp "$f" "$APP/Contents/Resources/bin/ipatool-profile-$arch"
      chmod +x "$APP/Contents/Resources/bin/ipatool-profile-$arch"
      echo "  vendored ipatool-profile-$arch"
      ;;
    *)
      arch="$(printf '%s' "$name" | sed -e 's/^ipatool-[0-9.]*-macos-//' -e 's/\.tar\.gz$//')"
      cp "$f" "$APP/Contents/Resources/bin/ipatool-$arch"
      chmod +x "$APP/Contents/Resources/bin/ipatool-$arch"
      echo "  vendored ipatool-$arch"
      ;;
  esac
done
cp vendor/fairplay-decrypt-helper-macos-arm64 \
  "$APP/Contents/Resources/bin/fairplay-decrypt-helper-arm64"
chmod +x "$APP/Contents/Resources/bin/fairplay-decrypt-helper-arm64"
echo "  vendored fairplay-decrypt-helper-arm64"
cp scripts/engine-runtime "$APP/Contents/Resources/bin/engine-runtime"
chmod +x "$APP/Contents/Resources/bin/engine-runtime"

# Native helpers are rebuilt against macOS 15, isolated from host Homebrew libraries.
NATIVE_PREFIX="${DUMPSHOP_NATIVE_PREFIX:-$PWD/.build/macos15/prefix}"
for tool in idevice_id ideviceinfo ideviceinstaller iproxy sshpass; do
  if [ ! -x "$NATIVE_PREFIX/bin/$tool" ]; then
    echo "Missing $tool. Run python3 scripts/build_macos15_runtime.py first." >&2
    exit 1
  fi
  cp "$NATIVE_PREFIX/bin/$tool" "$APP/Contents/Resources/bin/$tool"
done
python3 scripts/bundle_native_dependencies.py "$APP" "$NATIVE_PREFIX"

mkdir -p "$APP/Contents/Resources/fairplay-decrypt/device-bundle"
cp vendor/fairplay-device-bundle/* \
  "$APP/Contents/Resources/fairplay-decrypt/device-bundle/"
mkdir -p "$APP/Contents/Resources/fairplay-decrypt/source"
rsync -a --delete --delete-excluded --exclude='.git' --exclude='build' \
  --exclude='._*' --exclude='__pycache__' --exclude='*.pyc' \
  vendor/fairplay-decrypt/ \
  "$APP/Contents/Resources/fairplay-decrypt/source/"
mkdir -p "$APP/Contents/Resources/licenses/runtime"
cp LICENSE "$APP/Contents/Resources/licenses/DumpShop-LICENSE.txt"
cp -R vendor/runtime-licenses/. "$APP/Contents/Resources/licenses/runtime/"
cp vendor/fairplay-decrypt/LICENSE "$APP/Contents/Resources/licenses/fairplay-decrypt-LICENSE.txt"
cp vendor/ipatool/LICENSE docs/DEPENDENCIES.md \
  vendor/patches/ipatool-macos.patch "$APP/Contents/Resources/licenses/"
printf 'fairplay-decrypt commit: %s\n' \
  "$(cat vendor/fairplay-decrypt/UPSTREAM_REVISION)" \
  > "$APP/Contents/Resources/licenses/fairplay-decrypt-commit.txt"

# A Go binary ships with only the linker's ad-hoc signature. Once it sits inside a
# bundle, macOS rejects that on exec ("Taskgated Invalid Signature" -> SIGKILL), so
# each nested executable gets a real ad-hoc signature before the app is signed.
echo "[2.5/4] sign nested binaries"
for f in "$APP/Contents/Resources/bin/"* "$APP/Contents/Resources/lib/"*; do
  [ -f "$f" ] || continue
  if [[ "$(basename "$f")" == engine-runtime ]]; then
    continue
  fi
  # Every store helper keeps its existing identity and Keychain access.
  if [[ "$(basename "$f")" == ipatool-* ]]; then
    echo "  kept existing signature: $(basename "$f")"
    continue
  fi
  codesign --force -s - "$f" 2>&1 | tail -1
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>砸壳工坊</string>
  <key>CFBundleDisplayName</key><string>砸壳工坊</string>
  <key>CFBundleIdentifier</key><string>local.lance.dumpshop</string>
  <key>CFBundleExecutable</key><string>DumpShop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.3</string>
  <key>CFBundleVersion</key><string>23</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Inspect both the outer executables and the embedded Python runtime.
python3 scripts/check_macos_compatibility.py "$APP" --maximum 15.0
"$APP/Contents/Resources/bin/fairplay-decrypt-helper-arm64" python   scripts/check_macos_compatibility.py --embedded --maximum 15.0

echo "[3/4] ad-hoc sign"
# This workspace can live on a filesystem without native extended attributes.
# macOS then materializes AppleDouble "._*" files, and codesign rejects them as
# unsigned bundle subcomponents even though they are only metadata.
find "$APP" -name '._*' -type f -delete
codesign --force -s - "$APP" 2>&1 | tail -2

echo "[4/4] verify"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2
/usr/bin/file "$APP/Contents/MacOS/DumpShop" | sed 's/,.*//'
du -sh "$APP"
echo "built: $APP"
