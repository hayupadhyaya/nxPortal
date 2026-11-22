#!/bin/bash
# Build and package the Host menu-bar app: .claude/build.md § host-app
# usage: scripts/host.sh gen | build | path | package      (CONFIGURATION=Release for a Release build; package always builds Release)
set -euo pipefail

cd "$(dirname "$0")/.."
WT="$(git rev-parse --show-toplevel)"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
REPO="$(dirname "$COMMON")"
ENV_FILE="$REPO/.claude/local.env"

# env_value KEY: the value in local.env, surrounding quotes stripped; empty when absent
env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" || true
}

TEAM="$(env_value DEVELOPMENT_TEAM)"
PREFIX="$(env_value PORTAL_BUNDLE_PREFIX)"
PREFIX="${PREFIX:-local.dev}"  # an ad hoc build still needs a valid bundle ID
NX_DEV="$(env_value NX_DEVELOPER_DIR)"
NX_DEV="${NX_DEV:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$NX_DEV"

CONFIG="${CONFIGURATION:-Debug}"
OUT="$REPO/build/host"
DERIVED="$OUT/derived"
PROJECT="$WT/Host/NxPortalHost.xcodeproj"
APP_NAME="nxPortal Host"
APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"

die() { printf 'host.sh: %s\n' "$*" >&2; exit 1; }

gen() {
  command -v xcodegen >/dev/null || die "xcodegen is not installed (brew install xcodegen)"
  (cd "$WT/Host" && xcodegen generate --quiet)
}

# build: full log in $OUT, warnings and errors printed; signed with the team when local.env has one, ad hoc otherwise
build() {
  gen
  mkdir -p "$OUT"
  local log="$OUT/build-$CONFIG.log"
  local signing
  if [ -n "$TEAM" ]; then
    signing=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM")
    echo "host.sh: building ($CONFIG, signed with the team)"
  else
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
    echo "host.sh: building ($CONFIG, ad hoc signature)"
  fi
  if ! xcodebuild -project "$PROJECT" -scheme NxPortalHost -configuration "$CONFIG" \
      -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
      PORTAL_BUNDLE_PREFIX="$PREFIX" "${signing[@]}" build >"$log" 2>&1; then
    { grep -E 'error:|warning:' "$log" | sort -u | head -40; } || true
    die "build failed, log: $log"
  fi
  local warnings
  warnings="$(grep -E 'warning:' "$log" | grep -v appintentsmetadataprocessor | sort -u || true)"
  [ -z "$warnings" ] || printf '%s\n' "$warnings"
  echo "host.sh: BUILD SUCCEEDED"
}

# package: builds Release itself (whatever was built before), then <repo>/build/host/nxPortal-Host.zip; ditto keeps the
# signature and the bundle's structure. The one line on stdout names the zip.
package() {
  CONFIG=Release
  APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
  build >&2
  [ -d "$APP" ] || die "no Release build"
  local zip="$OUT/nxPortal-Host.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  echo "packaged the Release build: $zip"
}

CMD="${1:-}"
[ "$#" -eq 0 ] || shift
case "$CMD" in
  gen) gen ;;
  build) build ;;
  path) echo "$APP/Contents/MacOS/$APP_NAME" ;;
  package) package ;;
  *) echo "usage: $0 gen | build | path | package" >&2; exit 64 ;;
esac
