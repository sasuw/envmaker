# How to add and apply dotfiles

This guide shows how to add dotfiles to this repository and link them into
your home directory with an existing envmaker checkout and its GNU Stow
installation.

## Add files

The initial layout is:

```text
dotfiles/
├── common/    # always selected; contains Stow package directories
├── parts/     # optional packages
└── rules/     # executable selection rules for parts
```

For example, add `common/example/.config/example/config` to manage
`~/.config/example/config`. Here `example/` is a Stow package directory, and
its contents mirror paths relative to `$HOME`.

Optional application directories go under `parts/application/<command>/`;
envmaker selects them when that command is installed. Their immediate
subdirectories are Stow packages too. For example,
`parts/application/git/appconfig/.gitconfig` manages `~/.gitconfig`.

An executable `rules/<part-name>` script overrides automatic selection for
that whole part: exit status 0 includes it, and any other status skips it. A
rule file that is not executable also skips its part. Machine-specific
settings belong under `parts/hostname/<hostname>/`, and OS-specific settings
under `parts/ostype/<os>/`. Any other part needs a rule: without one it is
never selected.

The `.gitkeep` files preserve the empty directories in Git. They sit outside
the Stow package directories and are not linked into `$HOME`.

## Preview and apply

From this dotfiles repository, set the path of your envmaker checkout and
preview the selected files:

```bash
ENVMAKER_DIR=/path/to/envmaker
bash "$ENVMAKER_DIR/envmaker.sh" --dotfiles-dir "$PWD" listdirs
bash "$ENVMAKER_DIR/envmaker.sh" --dotfiles-dir "$PWD" --yes --dry-run execstow stow
```

The explicit `--dotfiles-dir` option leaves your configured default dotfiles
repository unchanged. The empty initial tree has no dotfiles to link.

When the preview looks right, apply the files:

```bash
bash "$ENVMAKER_DIR/envmaker.sh" --dotfiles-dir "$PWD" --yes execstow stow
```

After adding or removing files later, run the same preview and apply commands
with `restow` instead of `stow`. All selected files target the current
`$HOME`; choosing another repository does not create a separate home or
unlink files managed by the previous repository. Keep target paths distinct
when you use both repositories in the same home. envmaker backs up conflicting
files before linking.

Keep secrets out of Git. Use envmaker for linking rather than running Stow
directly.

## Apply generic and personal sources together

You can register two existing checkouts in
`${XDG_CONFIG_HOME:-$HOME/.config}/dotfiletracker/config`, lowest priority
first:

```text
source.generic="~/dotfiles/generic"
source.personal="~/dotfiles/personal"
```

Use either these entries or `dotfiles_dir`; mixing them is rejected. A full
fork is a full upper layer: personal wins even when its copy is unchanged or
identical. Removing a personal file restores the generic one. Package names
need not match. Rules and hooks remain local to each source.

For a home directory without existing links, preview and apply the stack:

```bash
bash "$ENVMAKER_DIR/envmaker.sh" --dry-run execstow restow
bash "$ENVMAKER_DIR/envmaker.sh" execstow restow
bash "$ENVMAKER_DIR/envmaker.sh" explain .gitconfig
```

Existing direct or folded Stow links need an explicit migration, not a normal
apply:

```bash
bash "$ENVMAKER_DIR/envmaker.sh" --dry-run migrate --from generic
bash "$ENVMAKER_DIR/envmaker.sh" --yes migrate --from generic
```

The `--from` ID names the source that owns the old links. Review the preview
before running the migration. Migration refuses unrelated links and keeps
rollback evidence. Its unlink/relink switch is not atomic. After a failure,
run `recover inspect`, then choose `recover resume` or `recover restore`.
The full procedure and the ways out of each refusal are in
`docs/migrate_overlay.md` of the envmaker checkout.

Stack utilities need an explicit destination, for example
`util/add-zsh-completion.sh --source personal COMMAND` or
`util/remove_function_keyword.sh --source personal`. No source is selected
implicitly for writes. Editing a file through its home link edits the current
winner; use source paths when you want to choose which checkout to change.
