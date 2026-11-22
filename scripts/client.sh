#!/bin/bash
# Build and run the iOS / tvOS client app: .claude/build.md § client-app
# usage: scripts/client.sh gen | build-sim | run-sim [--sim "nxPortal <name>" | --tv] [app args...] | build-device [--tv] [<model substring>]
#        | install <model substring> | launch <model substring> [app args...] | logs <model substring> [<dir>]
#        | archive <ios|tvos> <build number> | export <ios|tvos> [upload]
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
NX_DEV="$(env_value NX_DEVELOPER_DIR)"
NX_DEV="${NX_DEV:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$NX_DEV"

CONFIG="${CONFIGURATION:-Debug}"
OUT="$REPO/build/client"
DERIVED="$OUT/derived"
PROJECT="$WT/Client/NxPortal.xcodeproj"
SIM_NAME="nxPortal iPhone"

die() { printf 'client.sh: %s\n' "$*" >&2; exit 1; }

gen() {
  command -v xcodegen >/dev/null || die "xcodegen is not installed (brew install xcodegen)"
  (cd "$WT/Client" && xcodegen generate --quiet)
}

# build <scheme> <destination> [extra xcodebuild args...]: full log in $OUT, warnings and errors printed
build() {
  local scheme="$1" dest="$2"; shift 2
  mkdir -p "$OUT"
  local log="$OUT/$scheme-$CONFIG.log"
  local shown="$dest"
  case "$dest" in id=*) shown="the connected device" ;; esac  # the identifier is never printed
  echo "client.sh: building $scheme ($shown, $CONFIG)"
  if ! xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration "$CONFIG" \
      -destination "$dest" -derivedDataPath "$DERIVED" \
      PORTAL_BUNDLE_PREFIX="$PREFIX" "$@" build >"$log" 2>&1; then
    if grep -q 'No Accounts' "$log"; then
      die "Xcode has no signed-in account (Xcode → Settings → Accounts); a new device cannot be registered"
    fi
    { grep -E 'error:|warning:' "$log" | sort -u | head -40 | sed "s/${DEVICE_UDID:-@@none@@}/<device>/g"; } || true
    die "$scheme failed, log: $log"
  fi
  local warnings
  warnings="$(grep -E 'warning:' "$log" | grep -v appintentsmetadataprocessor | sort -u | sed "s/${DEVICE_UDID:-@@none@@}/<device>/g" || true)"
  [ -z "$warnings" ] || printf '%s\n' "$warnings"
  echo "client.sh: $scheme BUILD SUCCEEDED"
}

sim_prefix() { echo "${PREFIX:-local.dev}"; }

build_ios_sim() {
  PREFIX="$(sim_prefix)"
  build NxPortal 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
}

build_sim() {
  gen
  build_ios_sim
  build NxPortalTV 'generic/platform=tvOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
}

# sim_udid: the UDID of the available simulator named exactly $SIM_NAME (fixed text, not a pattern)
sim_udid() {
  xcrun simctl list devices available | awk -v want="$SIM_NAME (" '
    { line = $0; sub(/^ +/, "", line) }
    index(line, want) == 1 { rest = substr(line, length(want) + 1); i = index(rest, ")"); if (i > 1) { print substr(rest, 1, i - 1); exit } }'
}

# run-sim [--sim "nxPortal <name>" | --tv] [app args...]: an existing simulator only, never created
run_sim() {
  local tv=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --sim) [ $# -ge 2 ] || die "--sim needs a simulator name"; SIM_NAME="$2"; shift 2 ;;
      --tv) tv=1; shift ;;
      *) break ;;
    esac
  done
  [ "$tv" = 0 ] || SIM_NAME="nxPortal Apple TV"
  case "$SIM_NAME" in "nxPortal "*) ;; *) die "the simulator name must begin with 'nxPortal '" ;; esac
  local udid app
  udid="$(sim_udid)"
  [ -n "$udid" ] || die "no simulator named '$SIM_NAME'"  # before the build: a wrong name fails at once
  gen
  if [ "$tv" = 1 ]; then
    PREFIX="$(sim_prefix)"
    build NxPortalTV 'generic/platform=tvOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
    app="$DERIVED/Build/Products/$CONFIG-appletvsimulator/NxPortal.app"
  else
    build_ios_sim
    app="$DERIVED/Build/Products/$CONFIG-iphonesimulator/NxPortal.app"
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$app"
  xcrun simctl launch --console-pty --terminate-running-process "$udid" "$PREFIX.nxportal" "$@"
}

need_signing() {
  [ -n "$TEAM" ] || die "DEVELOPMENT_TEAM is empty in $ENV_FILE"
  [ -n "$PREFIX" ] || die "PORTAL_BUNDLE_PREFIX is empty in $ENV_FILE"
}

# build_device [<model substring>]: with a model, builds for that device and lets Xcode register it in the
# team's provisioning profile; without, a generic build (TV=1, from `--tv`: the Apple TV app, tvOS)
build_device() {
  need_signing
  gen
  local scheme=NxPortal generic='generic/platform=iOS'
  if [ "$TV" = 1 ]; then scheme=NxPortalTV; generic='generic/platform=tvOS'; fi
  if [ -n "${1:-}" ]; then
    find_device "$1"
    [ -n "$DEVICE_UDID" ] || die "the device reports no hardware UDID"
    build "$scheme" "id=$DEVICE_UDID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM"
  else
    build "$scheme" "$generic" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM"
  fi
}

# platform_scheme <ios|tvos>: sets SCHEME, ARCH_DEST, ARCH_TAG
platform_scheme() {
  case "${1:-}" in
    ios) SCHEME=NxPortal; ARCH_DEST='generic/platform=iOS'; ARCH_TAG=ios ;;
    tvos) SCHEME=NxPortalTV; ARCH_DEST='generic/platform=tvOS'; ARCH_TAG=tvos ;;
    *) die "usage: $0 $CMD <ios|tvos> ..." ;;
  esac
}

ARCHIVES="$OUT/archives"

# archive <ios|tvos> <build number>: Release archive for the store, signed for distribution by Xcode
archive() {
  platform_scheme "${1:-}"
  local n="${2:-}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "the build number must be a positive integer"
  need_signing
  gen
  mkdir -p "$ARCHIVES"
  local path="$ARCHIVES/NxPortal-$ARCH_TAG-$n.xcarchive" log="$OUT/$SCHEME-archive.log"
  [ ! -e "$path" ] || die "$path exists; use a build number not used before"
  echo "client.sh: archiving $SCHEME (Release, build $n)"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination "$ARCH_DEST" \
      -derivedDataPath "$DERIVED" -archivePath "$path" -allowProvisioningUpdates \
      PORTAL_BUNDLE_PREFIX="$PREFIX" DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$n" archive >"$log" 2>&1; then
    if grep -q 'No Accounts' "$log"; then
      die "Xcode has no signed-in account (Xcode → Settings → Accounts)"
    fi
    { grep -E 'error:|warning:' "$log" | sort -u | head -40 | sed -e "s/$TEAM/<team>/g" -e "s/$PREFIX/<prefix>/g"; } || true
    die "$SCHEME archive failed, log: $log"
  fi
  echo "client.sh: archive: $path"
}

# export <ios|tvos> [upload]: the newest archive of that platform -> an upload package (destination export) or an
# upload to App Store Connect (destination upload). The plist (it carries the team) is written to $OUT, never printed.
export_archive() {
  platform_scheme "${1:-}"
  local dest=export
  case "${2:-}" in "") ;; upload) dest=upload ;; *) die "usage: $0 export <ios|tvos> [upload]" ;; esac
  need_signing
  local archive
  archive="$(ls -dt "$ARCHIVES"/NxPortal-"$ARCH_TAG"-*.xcarchive 2>/dev/null | head -1 || true)"
  [ -n "$archive" ] || die "no $ARCH_TAG archive yet: run archive $ARCH_TAG <build number> first"
  local plist="$OUT/ExportOptions-$ARCH_TAG.plist" pkg="$OUT/export/$ARCH_TAG" log="$OUT/$SCHEME-export.log"
  mkdir -p "$OUT"
  cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$dest</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
  chmod 600 "$plist"
  echo "client.sh: exporting $archive ($dest)"
  if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$plist" -exportPath "$pkg" \
      -allowProvisioningUpdates >"$log" 2>&1; then
    { grep -E 'error:|warning:' "$log" | sort -u | head -40 | sed -e "s/$TEAM/<team>/g" -e "s/$PREFIX/<prefix>/g"; } || true
    die "export failed, log: $log"
  fi
  echo "client.sh: export options: $plist"
  echo "client.sh: $dest done: $pkg"
}

# find_device <model substring>: sets DEVICE_ID (CoreDevice identifier, for devicectl) and DEVICE_UDID (hardware
# UDID, for xcodebuild); neither is printed; prints the model
find_device() {
  local want="${1:-}"
  [ -n "$want" ] || die "usage: $0 $CMD <model substring>"
  mkdir -p "$OUT"
  xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1 || die "devicectl could not list devices"
  local found
  found="$(python3 -I - "$OUT/devices.json" "$want" "$([ "$TV" = 1 ] && echo tvOS || echo iOS)" <<'PY'
import json, sys
want = sys.argv[2].lower()
platform = sys.argv[3]
hits = []
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties") or d.get("properties", {}).get("hardware", {})
    conn = d.get("connectionProperties") or {}
    # simulators carry the same model names as devices: these commands are for real devices only
    if hw.get("platform") != platform or conn.get("tunnelState") == "unavailable" or hw.get("reality") == "simulated":
        continue
    model = hw.get("marketingName", "")
    if want in model.lower():
        hits.append((model, d["identifier"], hw.get("udid", "")))
print(len(hits))
if len(hits) == 1:
    print(hits[0][0]); print(hits[0][1]); print(hits[0][2])
PY
)"
  local count
  count="$(printf '%s\n' "$found" | sed -n 1p)"
  [ "$count" != "0" ] || die "no connected device whose model contains '$want'"
  [ "$count" = "1" ] || die "$count connected devices match '$want'; use a more exact model"
  echo "client.sh: device model: $(printf '%s\n' "$found" | sed -n 2p)"
  DEVICE_ID="$(printf '%s\n' "$found" | sed -n 3p)"
  DEVICE_UDID="$(printf '%s\n' "$found" | sed -n 4p)"
}

device_app() { echo "$DERIVED/Build/Products/$CONFIG-$([ "$TV" = 1 ] && echo appletvos || echo iphoneos)/NxPortal.app"; }

CMD="${1:-}"
[ "$#" -eq 0 ] || shift
# `--tv` after build-device / install / launch / logs: the Apple TV app and an Apple TV
TV=0
case "$CMD" in build-device|install|launch|logs) if [ "${1:-}" = "--tv" ]; then TV=1; shift; fi ;; esac
case "$CMD" in
  gen) gen ;;
  build-sim) build_sim ;;
  run-sim) run_sim "$@" ;;
  build-device) build_device "${1:-}" ;;
  install)
    find_device "${1:-}"
    [ -d "$(device_app)" ] || die "no device build yet: run build-device first"
    # devicectl's own error text stays visible (stderr not redirected)
    xcrun devicectl device install app --device "$DEVICE_ID" "$(device_app)" >/dev/null \
      || die "install failed (see the devicectl message above)"
    echo "client.sh: installed"
    ;;
  launch)
    find_device "${1:-}"; shift
    [ -n "$PREFIX" ] || die "PORTAL_BUNDLE_PREFIX is empty in $ENV_FILE"
    if [ "$#" -gt 0 ]; then
      xcrun devicectl device process launch --device "$DEVICE_ID" --console --terminate-existing "$PREFIX.nxportal" -- "$@"
    else
      xcrun devicectl device process launch --device "$DEVICE_ID" --console --terminate-existing "$PREFIX.nxportal"
    fi
    ;;
  archive) archive "${1:-}" "${2:-}" ;;
  export) export_archive "${1:-}" "${2:-}" ;;
  logs)
    find_device "${1:-}"
    [ -n "$PREFIX" ] || die "PORTAL_BUNDLE_PREFIX is empty in $ENV_FILE"
    dest="${2:-$OUT/sessions/$(date -u +%Y%m%d-%H%M%S)}"
    mkdir -p "$dest"
    # the app's session numbers: Documents/sessions in its data container (the identifier is never printed)
    # devicectl's text can name the app and the device: its last line is printed with those values replaced
    if ! err="$(xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer \
        --domain-identifier "$PREFIX.nxportal" --source Documents/sessions --destination "$dest" 2>&1 >/dev/null)"; then
      printf '%s\n' "$err" | tail -n 1 | python3 -I -c '
import json, sys
line = sys.stdin.read()
secrets = [sys.argv[1], sys.argv[2], sys.argv[3]]
try:
    for d in json.load(open(sys.argv[4]))["result"]["devices"]:
        hw = d.get("hardwareProperties") or {}
        dp = d.get("deviceProperties") or {}
        secrets += [d.get("identifier", ""), hw.get("udid", ""), hw.get("serialNumber", ""), dp.get("name", "")]
except Exception:
    pass
for v in sorted(set(x for x in secrets if x), key=len, reverse=True):
    line = line.replace(v, "<hidden>")
sys.stdout.write(line)' "$PREFIX.nxportal" "$PREFIX" "$DEVICE_ID" "$OUT/devices.json" >&2
      die "copy failed (no session has been recorded yet if the folder is missing)"
    fi
    echo "client.sh: session numbers copied to $dest"
    ;;
  *) echo "usage: $0 gen | build-sim | run-sim [--sim <name> | --tv] [app args...] | build-device [--tv] [<model>] | install [--tv] <model> | launch [--tv] <model> [app args...] | logs [--tv] <model> [<dir>] | archive <ios|tvos> <build number> | export <ios|tvos> [upload]" >&2; exit 64 ;;
esac
