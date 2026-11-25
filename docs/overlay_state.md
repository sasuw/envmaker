# Generation, locking and recovery reference

Stack operation uses immutable generations, one shared mutation guard,
journaled migration and recovery. This reference describes the lifecycle and
metadata. For operator steps, see the [migration how-to](migrate_overlay.md).

## Entry points

`envmaker.sh plan`, `explain` and `listdirs` are selection inspection commands.
`ls` reports applied generation ownership without rediscovery. Normal stack
`execstow stow|restow|delete`, `del`, `migrate --from ID` and explicit utility
destinations are available. There is no public bare `apply` alias.
The Perl backend exposes `apply`, `preview`, `migrate`, `inspect_applied`,
`preview_delete`, `delete_applied`, `recover` and `writer_guard`; isolated tests also call those APIs through a driver
that refuses a home outside its own marked `envmaker-state.*` temporary tree.
It is not an operator apply command. API roles are checked: an inspect object
cannot mutate through apply, deletion or recovery.

Legacy `execstow stow|restow|delete`, `del`, generated-completion writes, and both
shell-rewrite utilities now use the shared `TargetGuard` implementation. This
includes explicit legacy roots, explicit utility paths and `--no-stow` writes.
An active or unfinished stack operation blocks those legacy mutations rather
than letting an override bypass stack ownership. Legacy public dispatch accepts
only documented commands; internal helper names cannot bypass the guard.

Legacy dry-run paths check ownership without creating persistent guard/state
files. `del --dry-run` now preserves managed links after the existing confirmation
step; the previous implementation ignored that flag. Shell-rewrite previews place their temporary output in the scratch
filesystem instead of the source package. The backend overlay preview performs
selection and target checks, publishes no generation or journal, and explicitly
reports `stow_simulation: false`. It does not claim that the full Stow simulation
has run. Trusted discovery rules can still have side effects.

## Target-wide lock and state ownership

The canonical home reserves these paths, independent of every XDG setting:

- `.dotfiletracker-lock`: stable regular-file inode with a kernel `flock`.
- `.dotfiletracker-owner.json`: atomically replaced ownership/holder record.
- Other `.dotfiletracker-*` home targets are rejected to reserve metadata temps.

The lock file is never replaced, removed, or forcibly unlocked. The ownership
record binds the target to a canonical state directory and records its holder
PID/start time, protected status and unfinished operation identity. Lock files
must be owned by the current user, have one hard link, lack group/other write
permission and be opened without following a symlink. The held descriptor's
inode must still match the named lock.

Different `XDG_STATE_HOME` values cannot acquire independent locks on one home.
Active/pending ownership at another state directory fails with that recorded
location. An unavailable/redirected state directory, missing lock with retained
ownership, or lost ownership evidence fails closed. There is no automatic stale
lock deletion. Kernel lock acquisition proves previous holders released their
descriptors; recovery also refuses a journaled Stow PID still reported alive
when no exit status was recorded. PID reuse can cause a conservative refusal;
no process is killed automatically.

Legacy shell writers re-exec under the common guard. Internal Stow and nested
envmaker commands inherit its descriptor; each re-entry verifies flock, inode
and ownership rather than trusting an environment flag. Inheritance is enabled
only in the intended child after fork, preserving the parent's descriptor flags.
The parent keeps the lock until the command exits.
Hooks, discovery rules and the `hostname` selector use a child-local execution boundary
that removes `DFT_GUARD_FD` and closes the inherited lock descriptors. Shell
callers share a Bash subshell helper, preserving shell functions, builtins and
Bash execution of scripts without a shebang. Perl stack hooks close both the
original handoff descriptor and any verified duplicate before exec.
Closing a child copy never explicitly unlocks the shared
open-file description. Synchronous external execution therefore remains protected,
while background descendants cannot keep the lock after envmaker exits. A hook
that invokes envmaker receives no internal lock privilege and encounters ordinary
contention while its parent runs. Contention diagnostics mention an inherited
background descriptor as one possible cause; no forced unlock is provided.
The same guard protects generation application, deletion and recovery.
Every command entry selects inheritance through `TargetGuard::for_entry`.
Pre-dispatch detection, applied inspection and recovery therefore validate
the same inherited descriptor as writers. A nested preview retains the
parent's exclusive lock; it cannot downgrade it to a shared lock. Parent
completion rereads the latest ownership record before clearing its holder,
preserving a generation published by a nested completion reconciliation.

## Persistent layout

The canonical state directory is
`${XDG_STATE_HOME:-$HOME/.local/state}/dotfiletracker`. Its root must be private
to its owner (`0700`); existing nonprivate state is rejected rather than chmodded.
State/source overlap and targets inside source checkouts or the state/config
paths needed to run dotfiletracker are rejected before state creation.

```text
dotfiletracker/
  applied.json
  pending.json          # only while an operation is unfinished
  stow/generation_<32 lowercase hex digits>/
    .stow-local-ignore
    <relative target> -> relative path to original winning source entry
  manifests/generation_<32 lowercase hex digits>.json
  operations/<32 lowercase hex digits>/
    intent.json
    <run number>.stdout.log
    <run number>.stderr.log
    completed.json      # the archived pending.json
```

`<run number>` counts the Stow runs of one operation from 0.

Generated directories are real directories; file entries are relative symlinks
to original source entries, preserving live edits and original source symlinks.
The generated package contains only selected entries and comment-only local
ignore metadata, so Stow defaults are not applied a second time. Every generated
entry and the metadata are verified against the frozen manifest; extra entries,
redirected directories or replaced links fail before Stow can expand inventory.
Manifests and operation evidence stay outside the package. No automatic pruning
or copying source bytes occurs.

## Lifecycle

Apply callers provide the registered source roots as data before lock creation.
A source containing the home target is rejected before guard metadata can land
in that source. The backend checks that discovery returns exactly those roots,
then validates their state/source separation before creating state directories.

The backend acquires the target lock before invoking its discovery callback.
It validates the current source roots, winning entry types/modes/link text and
policy fingerprints. Home ownership uses recorded literal link text plus the
generation location, never dereferenced content equality. Existing managed
directory ancestors are checked by device/inode; symlinked ancestors and human
file/link/directory replacements are preserved with a conflict diagnostic.

Home link text follows Stow's target-root-relative construction, rather than
the shortest relative path. With default state, a link under `.local/bin`
therefore starts `../../.local/state/dotfiletracker/stow/`. The same construction
checks legacy direct/folded migration links, including source roots beneath
HOME next to their targets. Generated-to-source links remain ordinary relative
paths written and checked by the generator.

For a change, the backend records immutable operation intent, binds that intent
in the target ownership record, then publishes `pending.json`. This ordering
also covers a crash between ownership claim and pending-file publication.
It builds a fresh private generation without updating the active package,
freezes its manifest, and simulates old-generation deletion plus new-generation
installation in one controlled Stow module call. The call specifies the Stow
directory, canonical home target and `no-folding` option explicitly, and never
uses automatic CLI resource-file parsing.

After simulation, the backend rechecks generated inventory, source membership
and home ownership, journals the real command, and executes the same combined
transition. A launch barrier records the child's PID and command before that
child can modify home. Stdin is redirected from `/dev/null`; separate stdout/stderr logs, start/finish
times, decoded exit status and raw wait status are retained. Failed runs remain
failed, retain the pending journal, and never invoke hooks.

Verification checks intended literal home links and obsolete-link removal.
Source entry types are rechecked; already-frozen filtering is not reinterpreted
after a managed home ignore file transitions. Only then is `applied.json`
published by atomic rename. The pending record is archived as `completed.json`
and the ownership marker's intent is cleared. Ordinary file content stays live
by design. Files are synced before metadata rename; Stow itself is not a
filesystem transaction, and this is not a general power-loss/ACID guarantee.

An unchanged selected target/owner/type/mode/link map and verified links is a
link no-op; changes only to shadowed candidates do not rebuild it. Empty
effective plans remove old owned links without inventing an empty generation.
Deletion uses the retained applied manifest, works with unavailable checkouts,
and leaves an empty applied receipt. Old/new generations and logs are retained.
A receipt records the directory identities of its active targets. After deleting
a generation, those identities are released so another migration can unfold a
restored legacy link. Ancestor identities that older receipts recorded for
retired targets are ignored: only ancestors of the receipt's active targets and
the `parents_before` directories of a pending operation are checked.

## Recovery commands

Recovery ignores the source registry and works even when configured source
roots are unavailable. HOME and XDG state must identify the recorded target and
state directory; a mismatch fails with the actual owning location.

```bash
./envmaker.sh recover inspect
./envmaker.sh recover resume
./envmaker.sh recover restore
```

`inspect` is read-only and prints the recorded operation as JSON. It can read
the durable intent when pending publication never completed, or the completed
record when publication succeeded but ownership-marker finalization did not.
It does not need a Stow installation or source discovery. When the lock file
exists, `inspect` takes a shared lock, so it fails with "Target lock is held by
another operation" while a writer runs; it creates nothing when the lock file
is missing. Use it for a read-only recovery report; `--dry-run recover resume|restore` is rejected without mutation.

`resume` finishes the recorded new generation. An unfinished build is resumed
only through matching generated entries and validated recorded source inputs.
`restore` reinstalls the old recorded generation and can operate while source
checkouts are unavailable. It preserves unrelated files and may restore dangling
home links until the original checkouts return. Unexpected generated metadata
or replacement home entries cause refusal rather than adoption or overwriting.

Recovery also accepts receipts from versions that incorrectly recorded shortest
home paths (with the default state directory: targets under `.local`). It recognizes only that exact previous encoding
of the same recorded generation and still requires the actual home link to
have Stow's literal text. Successful recovery publishes corrected receipt text.
A shortened replacement home link is preserved as a conflict even when it
resolves to the same generation. No manual state-file editing is needed.

Both mutations acquire the same target guard, inspect actual links, and accept
only the recorded old/new link texts. One simulation deletes both possible
generation inventories and installs the requested generation; the same combined
operation is then applied, verified and published. Partial links and the
“Stow completed, applied state not published” case are reconciled explicitly.
For an interrupted migration, recovery first removes recorded legacy links that
are still present, then unstows the new generation in a separate
simulate-then-apply step. Only then does `resume` run the normal transition or
`restore` re-create the original links.
No failed apply is automatically rerun. Recovery retains operation evidence and
does not delete a generation, clear a live lock or signal a process.

## Journal and receipt schema

`pending.json` and `operations/ID/intent.json` use schema version 1:

| Field                      | Meaning                                                                   |
| -------------------------- | ------------------------------------------------------------------------- |
| `id`, `pid`, `started`     | Operation identity, initiating PID and epoch start time                   |
| `target_root`, `state_dir` | Canonical target/state binding                                            |
| `old`, `new`               | Previous and intended applied receipts                                    |
| `plan`                     | Frozen selection/provenance and filtering inputs                          |
| `parents_before`           | Existing home ancestor device/inode identities                            |
| `phase`, `last_completed`  | Current phase and last successful checkpoint                              |
| `runs`                     | Exact commands, PIDs, explicit options, streams, times and statuses       |
| `migration`                | Optional original source ID and exact direct/folded legacy link inventory |

Successful checkpoints are `validated`, `built`, `simulated`, `stow-complete`,
`verified` and `published`. Running/failure phases include `building`,
`simulating`, `applying`, `simulation-failed` and `stow-failed`. Migration adds
`migration-unlinking` and `migration-unlinked`, and recovery of a migration adds
`migration-reconciling`. A nonzero Stow
run never advances the last completed checkpoint to success.

An applied receipt records `generation` (or null), `target_root`, `state_dir`,
the canonical manifest digest `manifest_sha256`, literal home `links`, and the
verified `ancestors` of its active targets.
Generation manifests retain the plan plus their generation identity. A receipt
or manifest mismatch fails closed. Intent and completion records bridge crashes
between atomic metadata publications; they are not user-editable configuration.

## Validation and limitations

```bash
env -u BASH_ENV -u ENV perl tests/overlay_state_regression.pl
```

The suite uses marked temporary homes with all XDG paths isolated. It covers
real Stow generations, no-op and deletion, live/Unicode/link entries, protected
paths, replaced targets/ancestors, actual Stow conflict logs, durable intent,
resume/restore across injected build/transition/verification/publication failures
and a hard process stop after Stow. Shared-guard tests exercise every legacy
writer, explicit overrides and alternate state directories. A pipe-barrier lock
fixture includes a removed-guard negative control. Setting `DFT_TEST_REVERSE=1`
runs the order-sensitive cases in reverse order. Descriptive subtest names may be supplied to run a selection.
External-boundary cases cross stack/legacy and nested entry with hooks, rules
and the `hostname` selector. FIFO readiness/release handshakes prove synchronous
exclusion and immediate reuse while detached descendants remain alive. An old
leak negative control retains both the original and verified descriptors. A
separate case retains the lock in an internal mutator after its parent exits.
These detached-process fixtures require Linux child-subreaper support for PID
reaping and explicitly skip elsewhere; their lock assertions use independent
writers rather than relying on descriptor-directory inspection.

Migration requires an explicit originating source ID. Only exact relative
Stow link texts for selected entries from that source qualify. A folded
directory must expose only selected source entries; unselected descendants
are refused instead of silently dropped. Source bytes are never rewritten.
The migration journal records original link texts and folded-directory paths
before unlinking. Execution builds the generation first, unlinks those verified
legacy links, then simulates and applies the generation. A failure after unlink
leaves an explicit recovery task: resume completes the generation; restore
unstows recorded generated links and reinstates exact original links. Original
links can be restored without source checkouts. Migration and its preview are
refused when the target already has an applied stack generation or an
unfinished operation. The temporary unlink gap is
not an atomic switch. No automatic rollback hides a failed command.

`inspect_applied` reports each recorded owner and literal-link ownership,
including deep or dangling links without source discovery. `preview_delete`
checks the recorded inventory without modifying it. Source hooks run after a
successful `execstow stow|restow` (also after a verified link no-op, which
publishes nothing) and after a successful `migrate` (with action `stow`), in
low-to-high source priority and lexical filename order. The hook
receives the Stow action, `DOTFILES_DIR` and `DOTFILETRACKER_SOURCE_ID`.
Duplicate hook basenames run in both sources; failures only warn. Previews,
deletion, recovery and failed applications do not run hooks.

Utility destination parsing is shared: `--source ID` selects one registered
source; shell rewrites also allow explicit paths. No implicit stack write root
is chosen. All writers retain TargetGuard and validate existing generation
ownership before writing, including explicit paths and completion `--no-stow`.
Completion writes reconcile through envmaker while retaining the same lock.
Managed HOME/control paths are refused as rewrite destinations.

File-to-directory ancestor transitions remain explicit refusals. For an
applied stack, `del` removes only the retained generation, after which a fresh
apply can install the new structure. For legacy links, restore the old source
layout and use legacy `execstow delete` before changing it and applying the
stack. Preserve and inspect any human replacement first; no forced overwrite
is provided. These paths are tested with temporary homes.

Native macOS and FreeBSD verification remains outstanding. Linux results do
not establish native portability on those platforms.
