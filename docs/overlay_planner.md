# Overlay planner reference

The planner resolves one source entry per home-relative file target.
It emits a deterministic read-only plan and owner explanations. Application and
migration use this selection through the guarded generation lifecycle.

## Commands

With the [ordered registry](source_registry.md) configured:

```bash
./envmaker.sh listdirs
./envmaker.sh plan
./envmaker.sh explain .gitconfig
./envmaker.sh --source generic="$HOME/dotfiles/generic" \
  --source personal="$HOME/dotfiles/personal" explain .config/tool/config
```

`listdirs` reports qualified selected directories. `plan` emits one JSON
document describing sources, selected packages, target winners, shadowed owners,
directory candidates, ignore policies and the matched Stow runtime. `explain`
emits a JSON object containing `target`, `selected`, `owner` and `shadowed`.
An unselected target has `selected: false`, `owner: null` and an empty shadowed
list. A directory target also reports `selected: false`, because only file
targets are planned. TARGET must be valid UTF-8 and a normalized home-relative path, without absolute paths,
`.` or `..` components, repeated separators or a trailing slash.

Source discovery executes once for each invocation. Debug, verbose and dry-run
diagnostics go to stderr for the JSON commands. A failed plan returns nonzero
and publishes no partial JSON. The planner reads source metadata and filtering
policy but never reads ordinary source-file contents into its output.

Applying a plan is described in the [generation and recovery reference](overlay_state.md).

Planning performs no Stow apply or simulation, target ownership reconciliation,
backup, generation publication or persistent state mutation. It is not an apply
preview that has passed those later checks. Trusted source rules and the
`hostname` selector can still have side effects during discovery, as with
`listdirs`. A part without a rule never runs its own name as a command; see
[source-local rules](source_registry.md) for the built-in `hostname`, `ostype`
and `application` groups.

## Precedence and selection

Each source's discovery and ignore policy runs independently. The key is the
home-relative target, even when package names or package paths differ.

| Candidates for a target                              | Selected owner                      |
| ---------------------------------------------------- | ----------------------------------- |
| Generic only                                         | Generic                             |
| Personal only                                        | Personal                            |
| Generic and later personal                           | Personal                            |
| Equal contents in both sources                       | Personal; contents are not compared |
| Generic changed, personal retains an older fork copy | Personal                            |
| Personal file removed or package inactive            | Generic, if still eligible          |
| Upper file ignored by its package policy             | Lower eligible candidate            |
| Two packages in the same source                      | Error with both owners              |

Removing an upper entry means inheritance, not suppression. File contents are
not merged. A complete fork remains a complete upper layer. Reordering sources
changes precedence; explicitly removing a source changes plan membership.
`execstow stow|restow` reconciles already installed links through the
[generation lifecycle](overlay_state.md#lifecycle).

## Ignore and resource policies

The planner loads the Stow executable at `/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow`
(see [prerequisites](prerequisites.md)) with its own Perl interpreter
and module setup, checking matching versions. It compiles frozen policy bytes
with that Stow module's `get_ignore_regexps_from_fh` and matches with its `ignore`
method. Directory ignores prune the whole subtree before priority resolution.
Effective precedence is package `.stow-local-ignore`, then home
`.stow-global-ignore`, then Stow defaults. An empty/comment-only local policy
therefore permits filenames that the default policy would ignore.

Each effective policy file is read once per plan. Its path and SHA-256 digest
are recorded. The package-root `.stow-local-ignore` is reserved metadata and
never becomes a target. Invalid regexes and unreadable/nonregular policies fail
with the package or policy location. Generation construction writes its own
comment-only `.stow-local-ignore` so selected entries are not filtered again.

Home and caller-directory `.stowrc` files may currently be absent, empty or
comment-only. Every non-comment option fails with its file and line number,
including filtering, adoption, target redirection, dotfile conversion, defer
and override options. The plan records the accepted resource-file digests.
The planner invokes the Stow module directly and does not call the CLI option
parser. Application uses the same controlled module path (`bin/stow_transition.pl`)
and never parses resource files automatically.

## Filesystem and conflict rules

Selected regular files and source symlinks resolving to regular files are
supported. The original symlink entry and link text stay in provenance; the
planner does not traverse directory symlinks. Broken links, link cycles,
directory links, special files, and selected package paths traversing symlinked
directories fail. Ignored entries never become candidates. Executable modes
are recorded without copying file contents.

Files and directories at the same target conflict regardless of source
priority. Directory candidates expose ancestor collisions even if an upper file
would otherwise win. Shared directories are permitted; same-source file
ambiguity is always an error with both owners.

This release uses a conservative portable target namespace: distinct target
spellings with the same Unicode NFC normalization and full case folding are
rejected on every platform, including case-sensitive Linux. This intentionally
also rejects some pairs that a particular host filesystem could distinguish.
It keeps a source stack from depending on case/normalization differences across
Linux, macOS and FreeBSD. Paths must be valid UTF-8. Spaces, delimiters and
embedded newlines pass through a NUL-delimited discovery stream and JSON string
escaping. The planner requires Perl 5.16 or newer for Unicode case folding.

## Plan schema

`schema_version: 1` with `kind: "overlay-plan"` describes a plan, not an
applied-generation manifest. It has no generation identity or active ownership claims.

| Field                               | Meaning                                                                                  |
| ----------------------------------- | ---------------------------------------------------------------------------------------- |
| `target_root`                       | Canonical home target; apply refuses a plan for another target                           |
| `sources`                           | Ordered IDs, canonical roots and `git.commit`, `git.dirty`                               |
| `packages`                          | `source_id`, `package_relative` and `ignore_policy` (`{file, sha256}` or `{builtin}`)    |
| `targets`                           | Sorted home-relative targets with selected `owner` and low-to-high `shadowed` owners     |
| `directories`                       | Sorted structural directory candidates and their owners                                  |
| `owner.source_id`                   | Source that provides the entry                                                           |
| `owner.package_relative`            | Package path relative to the source root                                                 |
| `owner.source_entry`                | Original absolute source entry, including original symlink entry                         |
| `owner.entry_type`, `owner.mode`    | Original entry type and permission bits                                                  |
| `owner.link_text`                   | Original source symlink text when applicable                                             |
| `stow`                              | Configured executable, interpreter, loaded module and version                            |
| `resource_files`, `resource_policy` | Accepted resource digests and `comment-only` policy                                      |
| `alias_policy`                      | `portable-casefold-nfc`                                                                  |
| `application_enabled`               | `true`; the guarded stack frontend is available, not evidence that this plan was applied |

Git provenance accepts uncommitted changes. Roots that are not the top level of a
Git worktree have null commit and dirty values. It does not clone, merge or update repositories. Git status runs
with optional index writes and fsmonitor disabled. Repeated planning with the
same inputs produces byte-identical JSON; no timestamps or temporary paths are
introduced. Apply revalidates membership, types and ownership, freezes a generation
manifest before simulating, and publishes `applied.json` only after the full
transition is verified.

## Targeted validation

```bash
env -u BASH_ENV -u ENV perl tests/overlay_planner_regression.pl
env -u BASH_ENV -u ENV bash tests/source_registry_regression.sh
```

Both suites need the [test prerequisites](testing.md), including Python 3 and
Stow at `/opt/stow-2.4.1`. Planner fixtures use temporary
home/config/state/data/cache paths. Crossed
presence, content and structural combinations include empty sets. Ignore tests
compare all nine local/global policy combinations against the configured real
Stow binary. `tests/envmaker_regression.sh` without arguments also runs both suites. Native macOS and FreeBSD verification remains outstanding.
