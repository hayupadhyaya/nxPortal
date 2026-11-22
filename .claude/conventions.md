# Convention reference

Detail behind the one-liners in `CLAUDE.md`; this file wins when they
conflict. Reference as `.claude/conventions.md § <anchor>`; grep the anchor,
read only that section.

#### branch-model

- `main` — integration branch. Bootstrap docs and rules are its first commit.
- Every change: a worktree at `.claude/worktrees/<short-kebab-name>/`, branch
  `worktree-<short-kebab-name>`, off `main`.
  ```bash
  git worktree add .claude/worktrees/wt-foo -b worktree-foo main
  # work, commit; gate green; rebase on main
  git -C <repo root> merge --ff-only worktree-foo
  git worktree remove .claude/worktrees/wt-foo && git branch -d worktree-foo
  ```
- History on `main` stays linear (rebase, then fast-forward).
- Docs-only commits (specs, plans, rules, `todo.md`) may go straight to `main`.
- Cleanup after merge is mandatory; leftover worktrees confuse later sessions.
- **Tap:** `nxnative/` is a worktree of the owner's local nxnative clone,
  branch `stream-tap`, off upstream `main` at the pinned commit
  (`§ tap-pin`). nxPortal's git ignores it. Never commit to that clone's `main`.
- Pushes, releases and upstream PRs are the maintainer's (`§ publishing`).
  Changes go by PR into `main` with green checks; release tiers
  (alpha / beta / store) are defined at the first TestFlight cut.

#### publishing

- Pushes, releases, TestFlight / App Store uploads, notarized builds and
  upstream pull requests are the maintainer's.
- The tap is published as a patch file (`tap/stream-tap.patch`, applied by
  `scripts/apply_tap.sh`), not as a fork of nxnative.
- Commits use the committer's own git identity. nxnative's `AGENTS.md` names the
  upstream maintainer's identity for commits there; it is not used.

#### tap-pin

- nxnative commit the tap is based on: `184847c5` (upstream `main` of 2026-11-22; before it `c8d312c0`, and `e4b0d9b7` at the start). Tap protocol stays 2 across both moves.
- Moving the pin (done twice on 2026-11-22, in this order):
  - rebase `stream-tap` onto the new commit; keep the old head as a safety branch (`stream-tap-before-rebase-<n>`) and compare with `git range-diff` and a diff of the socket's files (byte-identical = protocol unchanged);
  - baseline upstream alone in a scratch worktree of the new commit (`.claude/build.md § nxnative-baseline`), then the tap's tests on the rebased head; same counts plus the tap's own;
  - read every upstream change a headless stream meets (present path, pipelines, sound, front end and launcher, input): the tap's new commits answer what the stream newly does there (`.claude/tap.md § upstream-meets`);
  - pack one game again and run it through the test Host, new copy against old copy (`.claude/tap.md § real-run`);
  - then the pin commit here: `scripts/preflight.sh` `TAP_PIN`, `scripts/apply_tap.sh` `PIN` (the full hash), `tap/stream-tap.patch` written again (`.claude/tap.md § patch-file`), this line, `build.md § nxnative-baseline`, `tap.md`, `todo.md`.
- A game copy packed at the old base cannot take the new host binary (`.claude/build.md § real-game`): pack again, or copy the new pack and prepare it on the target Mac.
- Keep the tap small: new files directly in `dm/host/` (`stream*.{h,c,m}`), hooks in existing
  files as few lines as possible. Upstream wants an issue first for anything
  near 1,000 lines.

#### documentation-rule

Structural change (new / removed / renamed files, public API, build
commands, dependencies, targets, conventions) → matching doc in the same
commit. Topic docs are created with the first code in their area.

- By target under `PortalKit/` (tests follow their target):
  - `Sources/PortalKit`, `Sources/PortalTestSupport`, `Sources/portal-fakegame`,
    `Package.swift` → `.claude/portalkit.md`
  - `Sources/PortalHostCore`, `Sources/portal-hostd` → `.claude/host.md`
  - `Sources/PortalClientCore`, `Sources/PortalPlayer`, `Sources/portal-fakeclient` → `.claude/client.md`
- `Host/` → `.claude/host.md`
- `Client/` → `.claude/client.md`
- `nxnative/` tap files → `.claude/tap.md`
- build / run / test commands, toolchain → `.claude/build.md`
- new convention or pitfall → this file
- bypass per commit: `[skip-doc]` in the message (doc-only and trivial commits)
- enforced by the commit-msg hook and `scripts/preflight.sh` on added / removed
  files (and `Package.swift` edits); the mapping lives once in `scripts/doc_map.sh`

State lives in `todo.md` and each code commit's `State:` block
(`§ state-block`); there is no separate state file.

#### protocol-versioning

- Two wire formats, each with one version constant in PortalKit: the
  network protocol (Host ↔ Client) and the tap socket protocol (game ↔ Host).
  The tap carries the same tap version on its side.
- Any change to a message layout or meaning bumps that version and adds a
  `CHANGELOG-protocol.md` entry in the same commit.
- A mismatch is refused with a message that names both versions; it never
  half-works.

#### owner-data

- Never modify or delete: game files and dumps, anything under a game's
  build or work folder, `prod.keys` / `title.keys`, saves in
  `~/Library/Application Support/nxnative/`, the nxnative clone's `main` checkout.
- Keys are passed as a path. Never print, copy or log their contents.
- Automated tests use the test tools (a fake game), never a real save.
  End-to-end runs on a real game are read-only on its save folder unless the
  owner is playing.

#### public-repo

- Never commit: secrets, tokens, signing team IDs, device names or
  identifiers, addresses, real usernames or other personal data.
- The signing team and the bundle ID prefix come from the environment, as
  nxnative's `DM_BUNDLE_ID` does.
- Nothing from Nintendo or a game publisher in the repo or the apps: no
  names in code or UI, no art, keys or game data. Game names and icons come
  from the user's Mac at run time. Docs may name a game as a test subject.
- Logs carry no personal data and no addresses.

#### simulators

- `-destination` by UDID only; name-based destinations are banned.
- At most 2 simulators running; check `memory_pressure` first.
- Use only the simulators named `nxPortal …` (`.claude/build.md § simulators`).
- Create or delete a simulator only with the maintainer's OK.
- UDIDs are per machine: look them up by name, never commit them.

#### state-block

Every code commit's body ends with:

```
State:
- What: one line
- Platforms: Host / Client iOS / Client tvOS / tap / PortalKit
- Verified: what was run and seen (tests, device, tool)
- Owed: what still needs a device or the owner
```

Lives in the commit body until PRs exist, then in the PR body.

#### focus-list

- `todo.md`: `## Open` (current phase, cap ~6) and `## Backlog`.
- After every commit: finished items are removed from `todo.md`; a fix that is
  merged but not VERIFIED stays in Open with its status
  (`FIXED in <hash> — <surface> verify owed`).
- One line per item; detail behind an anchor in the topic doc.

#### user-adjustable

- A streaming parameter with a sensible range is a setting with a tested
  default, not a constant: bitrate, size cap, frame-rate cap, controller
  mapping, in-play menu trigger, audio buffer.
- Confirm the settings surface when designing a new screen or behaviour.
