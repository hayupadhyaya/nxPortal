#!/bin/bash
# Installs the commit-msg hook into nxPortal's common git dir (never another repo's).
# usage: scripts/install_git_hooks.sh [--remove]   -> .claude/conventions.md § documentation-rule
set -euo pipefail

cd "$(dirname "$0")/.."   # location-based: always this repo, whatever the caller's cwd
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
HOOK="$COMMON/hooks/commit-msg"
MARK="# nxportal-commit-msg-hook"

if [ "${1:-}" = "--remove" ]; then
  if [ -f "$HOOK" ] && grep -q "$MARK" "$HOOK"; then rm "$HOOK"; echo "removed $HOOK"; else echo "no nxPortal hook installed"; fi
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [--remove]" >&2; exit 64; }

if [ -f "$HOOK" ] && ! grep -q "$MARK" "$HOOK"; then
  echo "refusing to overwrite a foreign hook: $HOOK" >&2; exit 1
fi
if [ -n "$(git config core.hooksPath || true)" ]; then
  echo "core.hooksPath is set; hook in $COMMON/hooks would not run" >&2; exit 1
fi

cat > "$HOOK" <<'HOOK_EOF'
#!/bin/bash
# nxportal-commit-msg-hook
# Rejects: structural change without its topic doc ([skip-doc] bypasses), a banned
# word in message or staged diff, a code commit without a State: block.
set -euo pipefail
msg_file="$1"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
fail() { echo "commit-msg: $*" >&2; exit 1; }

# banned words: never echo the word
words="$COMMON/info/banned-words"
if [ -f "$words" ] && grep -q -v '^[[:space:]]*$' "$words"; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.diff"' EXIT
  grep -v '^[[:space:]]*$' "$words" > "$tmp"
  grep -q -i -F -f "$tmp" "$msg_file" && fail "banned word in the commit message"
  git diff --cached --no-renames -U0 | grep -E '^\+' > "$tmp.diff" || true
  if grep -q -i -F -f "$tmp" "$tmp.diff"; then rm -f "$tmp.diff"; fail "banned word in the staged diff"; fi
  rm -f "$tmp.diff"
fi

# State: block for code commits -> .claude/conventions.md § state-block
names="$(git diff --cached --name-only)"
if printf '%s\n' "$names" | grep -qE '^(PortalKit|Host|Client|scripts)/'; then
  grep -q '^State:' "$msg_file" || fail "code commit needs a State: block (What / Platforms / Verified / Owed)"
fi

# doc gate -> .claude/conventions.md § documentation-rule (mapping: scripts/doc_map.sh)
grep -q -F '[skip-doc]' "$msg_file" && exit 0
top="$(git rev-parse --show-toplevel)"   # the committing worktree's own scripts/
if [ ! -f "$top/scripts/doc_map.sh" ]; then
  echo "commit-msg: warning: $top/scripts/doc_map.sh missing, doc gate skipped" >&2; exit 0
fi
. "$top/scripts/doc_map.sh"
staged="$(git diff --cached --no-renames --name-only)"
missing=""
while IFS="$(printf '\t')" read -r status path; do
  case "$status" in
    A|D) ;;
    M) [ "$path" = "PortalKit/Package.swift" ] || continue ;;
    *) continue ;;
  esac
  doc="$(doc_for "$path")"
  [ -n "$doc" ] || continue
  printf '%s\n' "$staged" | grep -qx ".claude/$doc" || missing="$missing .claude/$doc($path)"
done <<STATUS
$(git diff --cached --no-renames --name-status)
STATUS
[ -z "$missing" ] || fail "structural change without its topic doc:$missing (or add [skip-doc])"
exit 0
HOOK_EOF
chmod +x "$HOOK"
echo "installed $HOOK"
