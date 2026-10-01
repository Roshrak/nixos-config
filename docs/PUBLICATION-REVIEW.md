# Publication review — 2026-10-02

## Intended publication

Publish the declared configuration already activated and booted as generation 125,
plus the reviewed maintenance and restore tools. This publication does not update
flake inputs, packages, firmware, recovery generations, or the Nix store.
The lock file is unchanged. The seven curated desktop sessions and concurrent
login policy remain. Optional desktop modules present in source are not a claim
that those sessions are enabled or tested.

## Changes to maintenance

- `baby-step/update-and-push.sh --backup-only` checks declared/active equality,
  runs health checks, snapshots selected configuration, reviews and scans the
  staged tree, commits normally, and verifies the remote head. It never invokes
  the upgrade script. The default invocation still performs an upgrade.
- Existing staged work is rejected before an update/publication starts. Index
  recovery for this manual, explicitly authorized publication is retained locally.
- The full staged tree is checked, including previously committed files. Only
  approved source scopes are accepted. The Hermes exception is one code helper,
  not its credentials or home-directory state. Reports show path/line/reason,
  never matched credential values.
- The snapshot drops clipboard paths, `.catalog`, `.noctalia-cache.json`,
  `.setup-complete`, Fcitx layout cache, and giant backup copies from its prepared
  copy. It preserves live source files and settings/templates.
- Hyprland validation and the prepared restorable Lua now use the declarative
  source selected by the guarded session. The obsolete live personal Lua is
  preserved untouched; its unsafe old monitor callbacks are not published as
  the current restorable configuration.
- The two old `scripts/update-system-and-push*.sh` entry points now delegate to
  the maintained tool. Their `--sync-only` maps to `--backup-only`.
- Current summaries identify Gen125 and separate runtime observations from
  unfinished acceptance checks. Historical guides remain historical references.

## GitHub cleanup scope

Remove only verified generated/private runtime paths from the Git index and
new public tree. Keep all local files, settings, templates, source helpers,
recovery copies, and unknown configuration. Clipboard symlinks are inspected as
Git blobs, without following them into private live content. Encrypted clipboard
blobs from older commits remain in Git history; removing them from the new tree
is not erasure of previously published data. No history rewrite or force push
is part of this publication.

## Verification evidence and limits

The publication-safety suite uses disposable local Git and bare-remote fixtures.
It verifies the actual script's backup-only commit/push control flow, remote-object
presence, no invocation of the upgrade script, staging refusal/index preservation,
path/content rejection and value redaction. Nix, snapshot, and health calls in
that control-flow fixture are stubbed; this is not a production system test.

The production backup integration suite uses the actual snapshot entry point and
an offline candidate build in a disposable target. It checks destination refusal,
rollback, index preservation, and new runtime exclusions while preserving a live
clipboard symlink, its outside sentinel, and settings bytes. The fixture also checks declared/prepared Hyprland Lua equality and preservation
of the old personal source. GUI validation
commands in that fixture are stubbed; they do not prove graphical runtime.
The reviewed staged export must independently evaluate/build to the active
Gen125 system output before publication. Exact command results and hashes remain
in the private local audit evidence directory.

The reboot check proves active/profile/booted equality, Hyprland startup with
`windowsOut=1.0` and `fadeOut=1.0`, and empty config-error/failed-unit outputs at
that checkpoint. It does not prove the visual after-image is fixed, physical keys
work on every monitor, portals work, custom services are ready, or complete
multi-desktop regression passed. No such finding is closed by this publication.

AGY bounded reviews of this publication were attempted but exhausted their token
budgets and made no edits. Commander inspection/tests are recorded; full
independent acceptance is not claimed. Earlier source reviews and eight repair
suites are retained in the private audit, with their stated limitations.

## Remaining safety boundaries and recovery

Path-based shell ancestry checks have a check/use race against hostile concurrent
writers. Complete arbitrary bootstrap rollback and every syscall failure remain
unproven. See [custom-service restore](CUSTOM-SERVICE-RESTORE.md).
Credential scanning is a guard for known patterns and approved paths, not proof
that every possible secret encoding can be recognized.

Preserve previous system generations and the named fallback. A Git revert can
undo published source changes without rewriting history, but any restore must
respect newer user edits and must not discard worktrees/indexes. Exact local
before-images, original index, and staged archive are retained privately. Do not
use a whole-repository reset or restore private runtime paths to publication.
