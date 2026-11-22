# CLAUDE.md

Guidance for agents working in this repository. Symlinked as `AGENTS.md`
and `GEMINI.md`; edit `CLAUDE.md` only. Each rule's detail is in
`.claude/conventions.md`.

nxPortal streams a game built with [nxnative](https://github.com/seedds/nxnative)
from an Apple silicon Mac to an Apple TV, iPad or iPhone. Four parts:

- **Tap** — a small patch to nxnative (headless, video + sound out, input in).
- **Host** — the Mac menu-bar app (pairing, library, launch, network).
- **Client** — one app for iOS and tvOS.
- **PortalKit** — the Swift package both apps share (protocol, crypto, session rules).

Design: `docs/superpowers/specs/2026-11-17-nxportal-design.md`. Read it first.

## Non-negotiables — re-check after every compaction and before every commit

1. **Before writing ANY code:** confirm you are in a worktree
   (`git rev-parse --show-toplevel` ends in `.claude/worktrees/<name>`),
   branched off `main`. Tap code goes in the nxnative worktree
   (`nxnative/`, branch `stream-tap`), never on nxnative's `main`
   -> `conventions.md § branch-model`.
2. **Pushes, releases, TestFlight / App Store uploads, notarized builds and
   upstream pull requests are the maintainer's** -> `conventions.md § publishing`.
3. **Before writing ANY fix:** root-cause first. State the evidence — the
   exact log line, packet, or failing test that proves the cause. No
   evidence = keep investigating. A failure on a branch is run on the base
   commit before the branch is blamed.
4. **Before `git commit`:**
   (a) changed a wire format (network or tap socket)? → bump its protocol
   version + `CHANGELOG-protocol.md` entry in the same commit
   -> `conventions.md § protocol-versioning`;
   (b) structural change? → matching `.claude/<topic>.md` in the same commit
   -> `conventions.md § documentation-rule`;
   (c) code commit? → body carries a `State:` block (What / Platforms /
   Verified / Owed). No `--no-verify` for code commits.
5. **Before ANY merge into `main`:** the gate is green (tests for every
   touched part) and the branch is rebased on `main`. Owner-only: pushes,
   releases, TestFlight / App Store uploads, notarized builds, upstream PRs.
6. **Never modify or delete the owner's game data:** game files, saves,
   keys, and the nxnative clone's `main` checkout. `prod.keys` is only ever a
   path; never print it -> `conventions.md § owner-data`.
7. **This repo will be public.** Never commit secrets, signing teams,
   device names, addresses or personal data; nothing from Nintendo or a game
   publisher (names in code or UI, art, keys, game data)
   -> `conventions.md § public-repo`.
8. **Subagent output that decides your next action:** re-verify with one
   direct check yourself. Label conclusions VERIFIED (you saw the evidence)
   vs UNVERIFIED (inferred, needs device or log confirmation).
9. **Measure the test DELTA, not the endpoint.** Run tests → fix → run again
   → diff the failure sets. Touching tests too? Four runs: baseline → tests
   changed, code unchanged → code fixed → confirm. A new failure is the
   branch's only after the same test ran on the base commit and in isolation.
10. **A fix lands with a test that failed before it.** Write the failing
    test first, or reintroduce the bug and watch the test fail.

## Session conduct — output + delegation

Chat is a status channel, not a report. Commit messages and docs carry the
explanation.

1. **Mechanical asks get one-line acks.** Do it, then one line.
2. **Findings that change a decision: ≤4 lines, evidence first**, then the
   conclusion. The rest goes in docs or the commit.
3. **Elaborate ONLY when:** something failed or surprised you, the owner
   asked, or an irreversible step needs confirmation.
4. **Questions belong to planning.** In brainstorm / spec / plan phases ask
   freely, batched in one message. During execution do not ask "shall I
   continue"; stop only for destructive actions or real scope changes. A
   genuinely ambiguous requirement gets ONE precise question with a
   recommended default.
5. **Delegate to keep context lean:** mechanical work goes out with a
   complete brief. Briefs and reports move as files, never pasted into
   chat. The controller reviews every diff and re-runs the gate itself.
6. **No end-of-turn summaries** of finished work: one line + tracker
   updates. Don't re-litigate decided things or list options you won't pursue.
7. **Terse docs + comments — bullets, not prose.**
   - State the rule inline, park the reason behind an anchor:
     `// sealed before send — .claude/conventions.md § public-repo`.
     The inline half carries the constraint; the anchor carries the why.
   - Comment the invariant, never the incident.
   - Anchors are stable slugs, never line numbers.
   - Bug history lives in exactly one place.

## Reference hierarchy

Spec answers WHAT, PortalKit answers HOW, nxnative answers the tap's STYLE.

- **Intent** → the design doc is canonical. Code that contradicts it is a
  bug, or the design is fixed in the same commit; never silently diverged from.
- **Logic** (protocol, pairing, sessions, loss handling, timing) lives once,
  in **PortalKit**. Host and Client never reimplement it. The command-line
  test tools are its reference users.
- **Debugging corollary:** reproduce with the test tools over loopback
  before any device round trip.
- **Inside the tap**, nxnative's own `AGENTS.md` governs code style, logs
  (`[RED] `), switches (`docs/env_switches.tsv`) and tests — except its
  commit identity line, which is the upstream maintainer's.
- **Look:** no design system yet; phase 1 screens are plain.

## Common commands

Only commands that exist today -> `.claude/build.md`. Simulators: by UDID,
never by name; reuse, never create or delete without the owner's OK
-> `conventions.md § simulators`.

## Topic index (`.claude/`)

Load on demand. A new topic doc gets its row here in the same commit.

| Topic | File |
|-------|------|
| Standing-rule deep dives | [conventions.md](.claude/conventions.md) |
| Build, test, toolchain, devices | [build.md](.claude/build.md) |
| PortalKit package (targets, layout, test network) | [portalkit.md](.claude/portalkit.md) |
| Host core (tap server, game launch, fake game, library, pairing store, network service, portal-hostd), the menu model and the menu-bar app (menu, files, log, quit, automation) | [host.md](.claude/host.md) |
| Client core, player target and the iOS / tvOS app (session, stats, decode, screens, build script, portal-fakeclient) | [client.md](.claude/client.md) |
| Tap (nxnative patch: video hook, size, tests) | [tap.md](.claude/tap.md) |
| Design (WHAT) | [docs/superpowers/specs/](docs/superpowers/specs/) |
| Focus list (Open / Backlog) | [todo.md](todo.md) |

## Standing rules (full text in `.claude/conventions.md`)

- **User-adjustable, not hard-coded** — bitrate, size cap, frame-rate cap,
  controller mapping and the in-play menu trigger are settings with tested
  defaults.
- **Guide as we go** — a user-visible change updates `README.md` (later
  `docs/guide/`) in the same commit.
- **Tests are gap-finding** — a test that surfaces a Host / Client / tap
  divergence gets the product fixed per the reference hierarchy, not tested
  around.
- **Focus list** — keep `todo.md` current after every commit. Finished items
  are removed from it; a fix stays listed until VERIFIED.
- **Link, don't inline** — hot files carry one line per fact; detail lives
  behind a stable `#### anchor` in the topic doc. Reference as `file § anchor`.
- **Verify the running binary matches the source before debugging** (a game
  app built from an older tap is the common trap).

## Closeout checklist (when a phase or sub-project wraps)

1. `State:` block in the final commit · 2. `.claude/<topic>.md` current ·
3. `README.md` / guide current · 4. `todo.md` reconciled, only VERIFIED rows
removed · 5. design doc matches what was built · 6. a design doc that is
fully built moves to `docs/superpowers/specs/completed/` ·
7. gate green on `main` · 8. worktree removed, branch deleted.

## Swift LSP

Use it for all Swift: check diagnostics after every edit, use references /
definition for caller sweeps. A fresh worktree reports false "No such
module" until built once. clangd diagnostics for the tap's C and
Objective-C are noise; the nxnative Makefile build is the only truth.

## Workflow infrastructure

- `scripts/preflight.sh [--quick] [--strict]` — the gate, run in a worktree
  (exit codes -> `.claude/build.md § preflight`).
- `scripts/install_git_hooks.sh [--remove]` — commit-msg hook in this repo's
  common git dir only: doc gate (`[skip-doc]` bypasses), banned words, `State:` block.
- Machine values (nxnative clone, game folder, signing team, bundle prefix)
  live in `.claude/local.env` in the main checkout, git-ignored; keys in
  `.claude/local.env.example`.
