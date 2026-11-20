# How to add and apply dotfiles

This guide lets a human add dotfiles and apply them with an existing
dotfiletracker checkout and its pinned GNU Stow installation.

## Add files

The initial layout is:

```text
dotfiles/
├── common/    # always selected; contains Stow package directories
├── parts/     # optional packages
└── rules/     # executable selection rules for parts
```

For example, a human can add `common/example/.config/example/config` to manage
`~/.config/example/config`. Here `example/` is a Stow package directory, and
its contents mirror paths relative to `$HOME`.

Optional application directories go under `parts/application/<command>/`;
dotfiletracker selects them when that command is installed. Their immediate
subdirectories are Stow packages too. For example,
`parts/application/git/appconfig/.gitconfig` manages `~/.gitconfig`.

Executable `rules/<part-name>` scripts override automatic selection for that
whole part: exit status 0 includes it, and 1 skips it. Machine-specific
settings belong under `parts/hostname/<hostname>/`, and OS-specific settings
under `parts/ostype/<os>/`. Any other part needs a rule: without one it is
never selected.

The `.gitkeep` files preserve the empty directories in Git. They sit outside
the Stow package directories and are not linked into `$HOME`.

## Preview and apply

From this dotfiles repository, a human sets the existing dotfiletracker
checkout path and previews the selected files:

```bash
DOTFILETRACKER_REPO=/path/to/dotfiletracker
bash "$DOTFILETRACKER_REPO/envmaker.sh" --dotfiles-dir "$PWD" listdirs
bash "$DOTFILETRACKER_REPO/envmaker.sh" --dotfiles-dir "$PWD" --yes --dry-run execstow stow
```

The explicit `--dotfiles-dir` override leaves the configured default dotfiles
repository unchanged. The empty initial tree has no dotfiles to link.

After checking the preview, a human applies the files with:

```bash
bash "$DOTFILETRACKER_REPO/envmaker.sh" --dotfiles-dir "$PWD" --yes execstow stow
```

Later, a human runs the same preview and apply commands with `restow` instead
of `stow` after adding or removing files. All selected files target the current
`$HOME`; choosing another repository does not create an isolated home or
automatically unlink files managed by the previous repository. Keep target
paths distinct when using both repositories in the same home. The wrapper
backs up conflicting files before linking.

Secrets stay outside Git. Use the wrapper for linking rather than raw Stow.

## Apply generic and personal sources together

A human can register two existing checkouts in
`${XDG_CONFIG_HOME:-$HOME/.config}/dotfiletracker/config`, lowest priority first:

```text
source.generic="~/dotfiles/generic"
source.personal="~/dotfiles/personal"
```

A human chooses either these entries or `dotfiles_dir`; mixing them is rejected.
A full fork is a full upper layer: personal wins even when its copy is unchanged
or identical. Removing a personal file restores generic inheritance. Package
names need not match. Rules and hooks remain local to each source.

For an initially unlinked home, a human previews and applies the stack:

```bash
bash "$DOTFILETRACKER_REPO/envmaker.sh" --dry-run execstow restow
bash "$DOTFILETRACKER_REPO/envmaker.sh" execstow restow
bash "$DOTFILETRACKER_REPO/envmaker.sh" explain .gitconfig
```

Existing direct/folded Stow links require explicit migration, not normal apply:

```bash
bash "$DOTFILETRACKER_REPO/envmaker.sh" --dry-run migrate --from generic
bash "$DOTFILETRACKER_REPO/envmaker.sh" --yes migrate --from generic
```

The `--from` ID names the source that owns the old links. A human reviews the
preview before execution. Migration refuses unrelated links and retains rollback
evidence. Its unlink/relink switch is not atomic. After failure, a human inspects
`recover inspect` and chooses `recover resume` or `recover restore`.
The full procedure and refusal recovery paths are in
`docs/migrate_overlay.md` of the dotfiletracker checkout.

Stack utilities require an explicit destination, for example
`util/add-zsh-completion.sh --source personal COMMAND` or
`util/remove_function_keyword.sh --source personal`. No source is selected
implicitly for writes. Editing a home link edits its current winner; use source
paths when choosing which checkout to change.
