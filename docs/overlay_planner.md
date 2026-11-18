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
list. TARGET must be a normalized home-relative path, without absolute paths,
`.` or `..` components, repeated separators or a trailing slash.

Source discovery executes once for each invocation. Debug, verbose and dry-run
diagnostics go to stderr for the JSON commands. A failed plan returns nonzero
and publishes no partial JSON. The planner reads source metadata and filtering
policy but never reads ordinary source-file contents into its output.

The phase-3 backend is described in the [generation and recovery reference](overlay_state.md).

Planning performs no Stow apply or simulation, target ownership reconciliation,
backup, generation publication or persistent state mutation. It is not an apply
preview that has passed those later checks. Trusted source rules and command
fallbacks can still have side effects during discovery, as with `listdirs`.

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
Reconciliation of already installed links is future generation work.

## Ignore and resource policies

The planner loads the configured Stow executable with its own Perl interpreter
and module setup, checking matching versions. It compiles frozen policy bytes
with that Stow module's `get_ignore_regexps_from_fh` and matches with its `ignore`
method. Directory ignores prune the whole subtree before priority resolution.
Effective precedence is package `.stow-local-ignore`, then home
`.stow-global-ignore`, then Stow defaults. An empty/comment-only local policy
therefore permits filenames that the default policy would ignore.

Each effective policy file is read once per plan. Its path and SHA-256 digest
are recorded. The package-root `.stow-local-ignore` is reserved metadata and
never becomes a target. Invalid regexes and unreadable/nonregular policies fail
with the package or policy location. Future generation construction must create
its own comment-only local ignore file so selected entries are not filtered
again.

Home and caller-directory `.stowrc` files may currently be absent, empty or
comment-only. Every non-comment option fails with its file and line number,
including filtering, adoption, target redirection, dotfile conversion, defer
and override options. The plan records the accepted resource-file digests.
The planner invokes the Stow module directly and does not call the CLI option
parser. Future application must use the same controlled module path and must
not reintroduce automatic resource-file parsing.

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

`schema_version: 1` describes an `overlay-plan`, not an applied-generation
manifest. It has no generation identity or active ownership claims.

| Field                               | Meaning                                                                                  |
| ----------------------------------- | ---------------------------------------------------------------------------------------- |
| `sources`                           | Ordered IDs, canonical roots, Git commit and dirty status                                |
| `packages`                          | Source ID, package-relative path and effective ignore policy                             |
| `targets`                           | Sorted home-relative targets with selected `owner` and low-to-high `shadowed` owners     |
| `directories`                       | Sorted structural directory candidates and their owners                                  |
| `owner.source_entry`                | Original absolute source entry, including original symlink entry                         |
| `owner.entry_type`, `owner.mode`    | Original entry type and permission bits                                                  |
| `owner.link_text`                   | Original source symlink text when applicable                                             |
| `stow`                              | Configured executable, interpreter, loaded module and version                            |
| `resource_files`, `resource_policy` | Accepted resource digests and `comment-only` policy                                      |
| `alias_policy`                      | `portable-casefold-nfc`                                                                  |
| `application_enabled`               | `true`; the guarded stack frontend is available, not evidence that this plan was applied |

Git provenance accepts uncommitted changes. Non-Git roots have null commit and
dirty values. It does not clone, merge or update repositories. Git status runs
with optional index writes and fsmonitor disabled. Repeated planning with the
same inputs produces byte-identical JSON; no timestamps or temporary paths are
introduced. A later apply must revalidate membership/types/ownership and publish
its own generation manifest only after the full transition succeeds.

## Targeted validation

```bash
env -u BASH_ENV -u ENV perl tests/overlay_planner_regression.pl
env -u BASH_ENV -u ENV bash tests/source_registry_regression.sh
```

Planner fixtures use temporary home/config/state/data/cache paths. Crossed
presence, content and structural combinations include empty sets. Ignore tests
compare all nine local/global policy combinations against the configured real
Stow binary. The full regression runner includes both suites for the final
phase-5 gate. Native macOS and FreeBSD verification remains outstanding.
