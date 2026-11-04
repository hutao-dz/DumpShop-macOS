#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "This packaging recipe requires an Apple Silicon Mac." >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=15.0
export CGO_CFLAGS="${CGO_CFLAGS:-} -mmacosx-version-min=15.0"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -mmacosx-version-min=15.0"
IPATOOL_OUTPUT="$PWD/vendor/ipatool-profile-2.7.0-macos-arm64"
(
  cd vendor/ipatool
  go test ./cmd -run 'TestDumpShopRegionalIsolation|TestNetworkCompatibility|TestCmd' -ginkgo.focus='State directory'
  GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -trimpath \
    -ldflags='-s -w -X github.com/majd/ipatool/v2/cmd.version=2.7.0-dumpshop-profiles' \
    -o "$IPATOOL_OUTPUT" .
)
# These are newly built helpers for new installations, not existing Keychain binaries.
codesign --force -s - "$IPATOOL_OUTPUT"
cp "$IPATOOL_OUTPUT" vendor/ipatool-hk-arm64
