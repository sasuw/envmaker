# envmaker

envmaker discovers packages in separate dotfiles repositories and uses GNU Stow
to link them into `$HOME`. It supports one repository or an ordered stack where
personal files override generic files by their home-relative target path.

This is a release candidate. No public version is published yet. After a
reviewed release is published, a human can install from the intended location:

```bash
git clone https://github.com/sasuw/envmaker.git "$HOME/envmaker"
cd "$HOME/envmaker"
# A human selects the reviewed release commit before running code.
git checkout --detach RELEASE_COMMIT
```

`RELEASE_COMMIT` is a placeholder until publication. Never substitute an
unreviewed branch for the release commit. This project contains the installer
wrapper, not the dotfiles. Example public dotfiles belong in a separate checkout
from `https://github.com/sasuw/dotfiles` after that repository is released.

## Prerequisites

- Bash, Git and standard Unix utilities (`find`, `sort`, `readlink`, `mktemp`).
- Perl 5.16 or newer and its core modules, including `JSON::PP` and `Unicode::Normalize`.
- GNU Stow 2.4.1 at `/opt/stow-2.4.1/bin/stow`, including its matching Perl modules.

A human must complete the [Stow installation step](docs/prerequisites.md)
before applying dotfiles. Installing under `/opt` requires administrator
privileges. The wrapper does not install prerequisites. Old package-installing
and Perl-building helpers are not included. Native macOS and FreeBSD runtime
support has not been verified; Linux results do not establish it.

## One dotfiles repository

A human creates a new tree or uses an existing trusted checkout:

```bash
bash "$HOME/envmaker/envmaker.sh" init "$HOME/dotfiles"
# Add common/example/.config/example/config inside the new checkout.
bash "$HOME/envmaker/envmaker.sh" --dotfiles-dir "$HOME/dotfiles" listdirs
bash "$HOME/envmaker/envmaker.sh" --dotfiles-dir "$HOME/dotfiles" --yes --dry-run execstow stow
bash "$HOME/envmaker/envmaker.sh" --dotfiles-dir "$HOME/dotfiles" --yes execstow stow
bash "$HOME/envmaker/envmaker.sh" --dotfiles-dir "$HOME/dotfiles" execstow restow
```

Each immediate directory under `common/` is a Stow package. Its contents mirror
home-relative paths. Optional packages use `parts/application/<command>/<package>/`.
An executable `rules/<part-name>` can decide selection. Without a rule, only
`parts/hostname/<host>`, `parts/ostype/<os>` and `parts/application/<command>`
are evaluated; any other part is inactive and its name is never executed. See the generated
`docs/getting_started.md` for the layout. `init` refuses a populated directory
and creates no links or configuration.

For a persistent single root, a human creates
`${XDG_CONFIG_HOME:-$HOME/.config}/dotfiletracker/config` containing:

```text
dotfiles_dir="~/dotfiles"
```

`--dotfiles-dir` overrides that config for one invocation. Legacy operation
backs up conflicts with numbered `.orig` names. A human inspects those backups
before removing them. A human previews `--yes --dry-run execstow delete`, then
uses `--yes execstow delete` to unlink the selected packages; `--yes del` removes
links into that root. Keep source trees available for legacy deletion.

## Generic and personal stack

A human registers existing trusted checkouts in the same config, in ascending
priority order, instead of `dotfiles_dir`:

```text
source.generic="~/dotfiles/generic"
source.personal="~/dotfiles/personal"
```

Later sources win whole files, regardless of package name or whether bytes
differ. A full personal fork overrides every matching generic file. Removing
the upper file restores the lower file on the next apply.

For an initially unlinked target, a human runs:

```bash
bash "$HOME/envmaker/envmaker.sh" plan
bash "$HOME/envmaker/envmaker.sh" --dry-run execstow restow
bash "$HOME/envmaker/envmaker.sh" execstow restow
bash "$HOME/envmaker/envmaker.sh" explain .config/example/config
bash "$HOME/envmaker/envmaker.sh" ls
```

Repeated `--source ID=PATH` flags replace the config list for that invocation.
Stack mode refuses unmanaged files, unrelated links and replaced managed
entries. It does not apply legacy conflict backups. A human can preview
`--yes --dry-run execstow delete`, then unlink recorded owned links with
`--yes execstow delete` or `--yes del`, even if a source is unavailable.

Existing direct or folded Stow links need explicit migration. A human follows
[migration and recovery](docs/migrate_overlay.md), starting with
`--dry-run migrate --from generic`, then `--yes migrate --from generic`.
After an interrupted operation, a human runs `recover inspect` and chooses
`recover resume` or `recover restore`. The switch is not atomic.

## Ownership and executable inputs

Rules and the `hostname` selector execute during discovery, including preview.
Dry-run suppresses wrapper mutations; it does not sandbox those programs.
Hooks run source by source after successful Stow/restow; their failures warn
without undoing the completed link operation. Register only trusted trees.

Editing through a home link edits its winning source. Editors that replace
links may create conflicts. Utility writers require `--source ID` in stack
mode, or explicit source file paths for rewrite utilities. This also applies to
completion imports using `--no-stow`.

Configuration uses `XDG_CONFIG_HOME`; persistent ownership/journal state uses
`${XDG_STATE_HOME:-$HOME/.local/state}/dotfiletracker`. Generation evidence is
retained without automatic pruning. See the [registry](docs/source_registry.md),
[planner](docs/overlay_planner.md) and [state/recovery](docs/overlay_state.md)
references for exact formats, lock scope and conflict handling.

## Development checks

Contributors run `python3 -I scripts/scan_public.py --root .` with the pinned
gitleaks version, then `bash scripts/check_public.sh`. The latter runs syntax,
ShellCheck, the retained runtime suites and an isolated install smoke test.
All checks fail on tool errors. See [scan policy](docs/public_scan.md).
The release process also requires a private pre-export term check of file and
directory names, contents and symlink text. The term list remains private.
The check prerequisites include Zsh for alias-conversion validation, POSIX AWK
and the Unix tools listed in that reference; they exceed the installer runtime
prerequisites above. CI installs the check and Stow build packages explicitly.

The project uses the [MIT license](LICENSE). GNU Stow and other separately
installed prerequisites retain their own licenses.
