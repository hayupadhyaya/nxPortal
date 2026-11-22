#!/bin/bash
# A patched nxnative clone for nxPortal: .claude/tap.md § patch-file
# usage: scripts/apply_tap.sh [<folder> [<nxnative git URL or local clone>]]
#   <folder>  where the clone goes; default <repo>/nxnative (git-ignored, where the gate looks)
# Result: branch stream-tap = the pinned nxnative commit + tap/stream-tap.patch, as one commit.
set -euo pipefail

PIN=184847c51117bdee6502b654d72585bc69d7e1f5   # the nxnative commit the patch was made for
BRANCH=stream-tap

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$here/nxnative}"
src="${2:-https://github.com/seedds/nxnative}"
patch="$here/tap/stream-tap.patch"

die() { echo "apply_tap.sh: $*" >&2; exit 1; }

[ -f "$patch" ] || die "no patch at $patch"
command -v git >/dev/null || die "git is not installed"

if [ -e "$dest" ]; then
  git -C "$dest" rev-parse --git-dir >/dev/null 2>&1 || die "$dest exists and is not a git clone"
  [ -z "$(git -C "$dest" status --porcelain)" ] || die "$dest has uncommitted changes: commit or stash them first"
else
  git clone "$src" "$dest" || die "could not clone $src"
fi

if git -C "$dest" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
  die "$dest already has a branch $BRANCH: delete it (git branch -D $BRANCH) to apply again"
fi
if ! git -C "$dest" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  git -C "$dest" fetch origin || die "could not fetch from the clone's origin"
  git -C "$dest" cat-file -e "$PIN^{commit}" 2>/dev/null || die "commit $PIN is not in $dest"
fi

git -C "$dest" checkout -q -b "$BRANCH" "$PIN"
if ! git -C "$dest" apply --index --check "$patch"; then
  git -C "$dest" checkout -q - && git -C "$dest" branch -q -D "$BRANCH"
  die "the patch does not apply to $PIN (a changed patch file, or a wrong nxnative)"
fi
git -C "$dest" apply --index "$patch"

# a commit needs an identity; a machine without one gets a neutral one for this commit only
if git -C "$dest" config user.email >/dev/null; then
  git -C "$dest" commit -q -m "nxPortal stream tap (tap/stream-tap.patch)"
else
  git -C "$dest" -c user.name="nxPortal" -c user.email="nxportal@localhost" \
    commit -q -m "nxPortal stream tap (tap/stream-tap.patch)"
fi

echo "apply_tap.sh: $dest is on $BRANCH: nxnative $(git -C "$dest" rev-parse --short "$PIN") + the stream tap"
echo "apply_tap.sh: pack a game from there as nxnative's own README says (--platform mac-app)"
