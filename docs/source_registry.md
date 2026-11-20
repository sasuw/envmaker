# Source registry reference

The source registry selects legacy single-root operation or an ordered overlay.
It is shared by envmaker and its companion writers. For migration steps, see
[How to migrate to an ordered overlay and recover failures](migrate_overlay.md).

## Configuration

The registry uses `${XDG_CONFIG_HOME:-$HOME/.config}/dotfiletracker/config`.
An ordered registry looks like this:

```text
# Lowest priority first; highest priority last.
source.generic="~/dotfiles/generic"
source.personal="~/dotfiles/personal"
```

Source IDs match the ASCII alphabet `[A-Za-z0-9][A-Za-z0-9_-]*` in every locale.
Validation does not change the caller's locale or the locale used by rules.
IDs are case-sensitive. Duplicate IDs and repeated physical roots, including
symlink aliases, are rejected.
Every registered directory must exist before discovery starts.

Configuration is data. Blank lines and lines beginning with `#` are ignored.
Whitespace surrounding keys and values is trimmed. Matching single or double
quotes delimit a path, preserving spaces inside the quotes. There is no shell
evaluation, escape processing or inline comment syntax. Only a leading `~`,
`$HOME` or `${HOME}`, alone or followed by `/`, expands to the current home.
Other variable references and command substitutions remain literal path text.
Relative paths resolve from the caller's working directory.

The legacy `dotfiles_dir=PATH`, `dotfile_dir=PATH`, and bare-path forms remain
supported. Combining any legacy form with source entries in the same config
fails, regardless of their order. Unrelated setting keys are ignored, as before.

## Invocation overrides

Repeated `--source ID=PATH` arguments replace the entire configured list in
argument order. The `--source=ID=PATH` spelling is also accepted:

```bash
./envmaker.sh --source generic="$HOME/dotfiles/generic" \
  --source personal="$HOME/dotfiles/personal" listdirs
```

`--dotfiles-dir PATH` (alias `--dotfile-dir`) explicitly selects legacy mode
and bypasses the configured registry. It cannot be combined with `--source`.
`init PATH` ignores configuration and remains available when registered roots
are missing; it rejects `--source` arguments.

## Discovery

`listdirs` discovers every source independently and prints `ID:ABSOLUTE_PATH`
records in source order. The immediate child directories of each selected
directory are Stow packages; their paths do not determine overlay priority.
The planner resolves priority by home target, not package name. See the
[overlay planner reference](overlay_planner.md) for precedence, ignore behavior,
conflicts, the portable target namespace and JSON output.

Rules run once per source discovery, in the caller's working directory, with
`DOTFILES_DIR` set to the physical source root and `DOTFILETRACKER_SOURCE_ID`
set to its ID. A successful executable rule selects its source's part; any
nonzero result makes that part inactive. A non-executable regular rule is also
inactive. A missing or non-regular rule uses the built-in fallback, which
knows only three part names:

- `parts/hostname/<host>` is selected by the output of the `hostname` command;
- `parts/ostype/<os>` is selected by the output of the built-in `ostype` function;
- `parts/application/<command>` is selected when `command -v <command>`
  finds the command; neither `application` nor `<command>` is executed.

A `<value>*OR*` or `*OR*<value>` sibling is selected with the value's own
directory. An empty or failed value, `.`, `..`, or a value with `/`, a newline
or a glob character selects nothing. Every other part without a regular rule is
inactive: discovery never executes its name and never scans its subdirectories.
One source's inactive rule never disables a part in another source.

Rules and the `hostname` selector are trusted executable inputs. They can have side
effects even during inspection or dry-run; the wrapper does not sandbox them.
Apply and migration discover under the shared target lock. Recorded-generation
inspection, deletion and recovery bypass source parsing/discovery when the target
ownership record exists, so unavailable sources do not block those operations.

## Shared interfaces

`bin/source_registry.sh` supplies one data-only parser to envmaker and all
configuration-based utility writers. `bin/discovery.sh` retains selected
directories and package paths in parallel arrays, with separate source IDs.
`enumerate_source_entries PACKAGE` emits a raw NUL-delimited inventory including
directories and symlinks, without following directory symlinks. Ignore filtering,
entry validation and winner resolution are implemented by the phase-2 Perl
planner. This raw inventory interface remains available for lower-level tooling.

`bin/stow_bridge.sh` probes the configured Stow executable's own Perl interpreter
and module setup, without guessing a Perl-version directory. The read-only probe
checks CLI/module versions and returns JSON containing executable, interpreter,
module and version. Absolute Perl shebangs and `/usr/bin/env perl` are supported;
other interpreter forms fail with a diagnostic. The configured default remains
`/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow`.

Stack dispatch accepts `listdirs`, `plan`, `explain TARGET`, `ls`,
`execstow stow|restow|delete`, `del`, `migrate --from ID` and
`recover inspect|resume|restore`. `stow`, `delete`, `del` and real migration retain
confirmation; `restow` skips it. Noninteractive confirmation needs `--yes`.
`ls` is JSON with recorded owners and an `owned` flag based on literal links
and ancestor identity. `pending` reports unfinished operations.

Writers accept `--source ID` (an existing registry ID, not `ID=PATH`). Shell
rewrite utilities also accept explicit paths instead of a named source.
The shared target lock and ownership preflight apply to every writer, including
`--no-stow`, explicit paths and legacy root overrides. An unfinished operation
blocks utility writes. A legacy override cannot bypass an active stack.
Completion writes reconcile the stack with the same held lock; source-local
selection still decides whether the completion package is active.

## Targeted checks

Run the source registry cases without the full gate:

```bash
env -u BASH_ENV -u ENV bash tests/source_registry_regression.sh
```

Both that runner and `tests/envmaker_regression.sh` accept individual `test_`
function names. No arguments to the latter runs the full gate and includes the
registry, planner, lifecycle and utility suites.
Fixtures set home and every XDG config/state/data/cache directory to temporary
paths. Linux runtime results do not establish native macOS or FreeBSD support.
