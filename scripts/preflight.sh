#!/bin/bash
# Gate for a nxPortal worktree: .claude/build.md § preflight
# usage: scripts/preflight.sh [--quick] [--strict]
# exit: 0 green, 1 dirty or not on worktree-*, 2 not rebased on main,
#       3 test failure, 4 doc warning (--strict), 5 banned word
set -euo pipefail

QUICK=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --strict) STRICT=1 ;;
    *) echo "usage: $0 [--quick] [--strict]" >&2; exit 64 ;;
  esac
done

TAP_PIN=184847c5          # .claude/conventions.md § tap-pin
TAP_BRANCH=stream-tap
TITLE_ID=0400486024DEC000

cd "$(dirname "$0")/.."
WT="$(git rev-parse --show-toplevel)"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
REPO="$(dirname "$COMMON")"
TAP="$REPO/nxnative"
# toolchain nxnative needs: NX_DEVELOPER_DIR in .claude/local.env, else Xcode.app -> .claude/build.md § toolchain
NX_DEV="$(sed -n 's/^NX_DEVELOPER_DIR=//p' "$REPO/.claude/local.env" 2>/dev/null | tail -1 \
  | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" || true)"  # surrounding quotes stripped
NX_DEV="${NX_DEV:-/Applications/Xcode.app/Contents/Developer}"

say() { printf 'preflight: %s\n' "$*"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1: clean tree, worktree branch
branch="$(git rev-parse --abbrev-ref HEAD)"
case "$branch" in
  worktree-*) ;;
  *) say "branch '$branch' is not worktree-*"; exit 1 ;;
esac
if [ -n "$(git status --porcelain)" ]; then
  say "working tree is dirty"; git status --short; exit 1
fi

# 2: rebased on main
if ! git merge-base --is-ancestor main HEAD; then
  say "not rebased on main"; exit 2
fi

# 5: banned words (never print the word itself)
BANNED="$COMMON/info/banned-words"
if [ -f "$BANNED" ]; then
  grep -v '^[[:space:]]*$' "$BANNED" > "$TMP/words" || true
  if [ -s "$TMP/words" ]; then
    hit=0
    files="$(git grep -I -i -l -F -f "$TMP/words" HEAD -- . || true)"
    if [ -n "$files" ]; then say "banned word in tree:"; echo "$files" | sed 's/^HEAD://'; hit=1; fi
    for sha in $(git rev-list main..HEAD); do
      git log -1 --format=%B "$sha" > "$TMP/msg"
      if grep -q -i -F -f "$TMP/words" "$TMP/msg"; then
        say "banned word in message of $(git rev-parse --short "$sha")"; hit=1
      fi
    done
    if [ -d "$TAP" ] && git -C "$TAP" rev-parse -q --verify "$TAP_BRANCH" >/dev/null; then
      for sha in $(git -C "$TAP" rev-list "$TAP_PIN..$TAP_BRANCH"); do
        git -C "$TAP" log -1 --format=%B "$sha" > "$TMP/msg"
        if grep -q -i -F -f "$TMP/words" "$TMP/msg"; then
          say "banned word in tap message of $(git -C "$TAP" rev-parse --short "$sha")"; hit=1
        fi
      done
    fi
    [ "$hit" -eq 0 ] || exit 5
  fi
fi

# 2b: the published patch is the clone's tap -> .claude/tap.md § patch-file
if [ -d "$TAP" ] && git -C "$TAP" rev-parse -q --verify "$TAP_BRANCH" >/dev/null; then
  if ! git -C "$TAP" diff --binary --full-index "$TAP_PIN..$TAP_BRANCH" | cmp -s - "$WT/tap/stream-tap.patch"; then
    say "tap/stream-tap.patch is not the clone's $TAP_PIN..$TAP_BRANCH: write it again (.claude/tap.md § patch-file)"; exit 3
  fi
fi
grep -q "^PIN=$TAP_PIN" "$WT/scripts/apply_tap.sh" || { say "scripts/apply_tap.sh PIN is not $TAP_PIN"; exit 3; }

# 3: tests
if [ "$QUICK" -eq 0 ]; then
  say "swift test (PortalKit)"
  swift test --package-path "$WT/PortalKit" || { say "PortalKit tests failed"; exit 3; }
  say "icons: the committed images are what scripts/make_icons.swift draws"
  swift "$WT/scripts/make_icons.swift" --check "$WT" || { say "icons differ from the recipe: run swift scripts/make_icons.swift <repo root>"; exit 3; }

  # tap targets exist from plan Tasks 8 and 9; skip until the tap has commits past the pin
  if [ -d "$TAP" ] && git -C "$TAP" rev-parse -q --verify "$TAP_BRANCH" >/dev/null \
     && [ -n "$(git -C "$TAP" rev-list "$TAP_PIN..$TAP_BRANCH" | head -1)" ]; then
    say "tap tests"
    DEVELOPER_DIR="$NX_DEV" make -C "$TAP/dm/gfx/tests" GAME="$TITLE_ID" check_t_stream_present || { say "tap gfx test failed"; exit 3; }
    DEVELOPER_DIR="$NX_DEV" make -C "$TAP/dm/host/tests" GAME="$TITLE_ID" run || { say "tap host tests failed"; exit 3; }
  else
    say "tap has no commits past $TAP_PIN: tap tests skipped"
  fi
else
  say "--quick: tests skipped"
fi

# 3b: the apps build when the client, the Host app or any package source they link changed against main (needs xcodegen)
if [ "$QUICK" -eq 0 ] && [ -n "$(git diff --name-only main...HEAD -- Client Host PortalKit/Sources PortalKit/Package.swift)" ]; then
  if command -v xcodegen >/dev/null; then
    say "client app build (scripts/client.sh build-sim)"
    bash "$WT/scripts/client.sh" build-sim || { say "client app build failed"; exit 3; }
    say "Host app build (scripts/host.sh build)"
    bash "$WT/scripts/host.sh" build || { say "Host app build failed"; exit 3; }
  else
    say "apps: skipped (xcodegen not installed)"
  fi
fi

# 4: doc gate (mapping in scripts/doc_map.sh)
# shellcheck source=doc_map.sh
. "$WT/scripts/doc_map.sh"
git diff --no-renames --name-status main...HEAD > "$TMP/changes"
git diff --no-renames --name-only main...HEAD > "$TMP/names"
warn=0
while IFS="$(printf '\t')" read -r status path; do
  case "$status" in
    A|D) ;;
    M) [ "$path" = "PortalKit/Package.swift" ] || continue ;;
    *) continue ;;
  esac
  doc="$(doc_for "$path")"
  [ -n "$doc" ] || continue
  if ! grep -qx ".claude/$doc" "$TMP/names"; then
    say "doc warning: $path ($status) needs .claude/$doc in main..HEAD"; warn=1
  fi
done < "$TMP/changes"
if [ "$warn" -eq 1 ] && [ "$STRICT" -eq 1 ]; then exit 4; fi

say "green"
