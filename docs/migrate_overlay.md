# How to migrate to an ordered overlay and recover failures

This guide switches a home directory that already has direct Stow links to a
generic/personal stack, without rewriting either checkout. It assumes trusted
source trees, the pinned Stow installation from the
[prerequisites](prerequisites.md), and an envmaker checkout.

## Register and preview

1. Keep both checkouts at stable paths. envmaker never clones, updates or
   merges Git repositories. Ordinary uncommitted source edits are supported.
2. Replace the single-repository `dotfiles_dir` setting in
   `${XDG_CONFIG_HOME:-$HOME/.config}/dotfiletracker/config` with ordered entries:

   ```text
   source.generic="~/dotfiles/generic"
   source.personal="~/dotfiles/personal"
   ```

   Repeated `--source ID=PATH` options can instead replace the configured list
   for one run. `--dotfiles-dir` selects single-repository operation and cannot
   be combined with that list.

3. Review discovery and target ownership:

   ```bash
   ./envmaker.sh listdirs
   ./envmaker.sh plan
   ./envmaker.sh explain .gitconfig
   ./envmaker.sh --dry-run migrate --from generic
   ```

   `--from` names the registered source that owns the old direct/folded links;
   it need not be called `generic`. Migration accepts only exact relative Stow
   link texts into selected packages of that source. A link with equal content,
   an absolute link or a link to another file does not qualify. A normal first
   stack apply never adopts existing links. The preview lists original link
   texts, folded paths and the selected overlay plan as JSON.

The precedence contract is whole-file `generic < personal`:

| Candidates                                              | Result                                                                                        |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Generic only                                            | Generic owner                                                                                 |
| Personal only                                           | Personal owner                                                                                |
| Both, with different or equal bytes                     | Personal owner                                                                                |
| Generic updated beneath an unchanged personal fork copy | Personal still owns the file                                                                  |
| Personal entry removed, ignored or inactive             | Generic reappears if selected                                                                 |
| Removed from both or a source explicitly removed        | Next apply removes obsolete owned links                                                       |
| Registered root unavailable                             | Apply and `recover resume` fail; deletion, `recover inspect` and `recover restore` still work |

Package names do not set priority. A complete fork overrides every matching
target even when its copy has never been edited. Removing an upper file means
inheritance; there are no suppression markers or content merges. One source's
inactive rules do not deactivate another source. Hooks in both trees run, even
with identical filenames.

## Execute and verify

After reviewing the preview, run:

```bash
./envmaker.sh --yes migrate --from generic
./envmaker.sh ls
./envmaker.sh explain .gitconfig
```

Migration acquires the shared target lock, discovers once, validates ownership,
builds the new generation and journals exact original links before unlinking.
It then simulates and applies Stow against the cleared targets, verifies the
links, publishes applied state and runs the source hooks with action `stow`.
The unlink/relink gap is not atomic. A failure after unlink retains the
operation and requires explicit recovery; failure does not imply that the
original links are still installed.

Preview creates no home links, persistent generations, backups or applied
state. It reports `stow_simulation: false`: the full Stow simulation runs only
after generation construction during execution. Trusted rules and the
`hostname` selector may still have their own side effects during preview.

After migration, use the ordinary reconciliation command:

```bash
./envmaker.sh --dry-run execstow restow
./envmaker.sh execstow restow
```

`stow` also reconciles, with confirmation. `restow` skips confirmation. Source
edits remain live through relative generated links. A home edit reaches its
current winning source; there is no copy-on-write. Editors that replace a home
link can break ownership. envmaker preserves such replacements and reports a
conflict instead of overwriting them.

## Recover an interrupted operation

Keep `HOME` and `XDG_STATE_HOME` at their original values and inspect:

```bash
./envmaker.sh recover inspect
```

The JSON shows the actual phase, last completed checkpoint, old/new receipts,
original migration inventory, and the paths and statuses of the retained
subprocess logs. After inspection, choose one action:

```bash
./envmaker.sh recover resume
./envmaker.sh recover restore
```

`resume` finishes the recorded new generation and requires its source inputs.
`restore` reinstates the old generation, or the exact original direct/folded
migration links. Restore can operate with missing checkouts; links may dangle
until those checkouts return. Recovery never adopts unrelated entries, kills
processes or force-clears locks. A live recorded process or a replaced entry
causes refusal. Recovery does not run hooks. For a completed migration, its
archived journal remains evidence; `recover` acts only on unfinished operations.
To return to single-repository operation after completion, delete the applied
generation, then stow the old tree again with `--dotfiles-dir`.

If an older version stopped after Stow with a conflict under `.local/bin` or
`.local/share`, update envmaker and use the same `recover inspect` and
`recover resume` or `recover restore` commands. Recovery recognizes the old
shortest-path receipt encoding while checking Stow's actual link text. Keep
the journal, generation directories and home links intact; there is no need to
edit metadata or shorten link paths.

## Resolve a refusal

- **An unrelated link or regular home file.** Keep or move that entry
  yourself, then preview again. Source priority never authorizes overwriting it.
- **A folded link contains ignored or inactive entries.** Use the original
  single-repository configuration and `execstow restow` to unfold it, inspect
  all remaining entries and repeat the migration preview. Ignored direct links
  are left alone; newly selected conflicting targets still fail normal
  ownership checks.
- **The target already has an applied stack generation.** `migrate` only
  converts homes with direct Stow links. Reconcile with `execstow restow`
  instead, or remove the stack links with `--yes del` before migrating again.
  Migration is also refused while an operation is unfinished; recover it first.
- **A managed file must become a directory ancestor.** Run
  `./envmaker.sh --yes del` to remove the retained generation first, then
  preview and apply the new structure. For direct links, restore the old source
  layout, run `--dotfiles-dir OLD_ROOT --yes execstow delete`, then change the
  source layout and preview the stack. No forced structural replacement is
  provided. The explicit deletion path is tested.
- **An alternate XDG state path or missing ownership evidence.** Restore the
  recorded state location and inspect recovery. Never delete the reserved
  `.dotfiletracker-lock` inode or `.dotfiletracker-owner.json` to get past a
  failure.

## Inspect, delete and choose utility destinations

`./envmaker.sh ls` prints JSON with the applied generation, any pending
operation and the recorded targets with their source-qualified owners and
literal-link ownership. `./envmaker.sh --yes --dry-run del` previews deletion;
`./envmaker.sh --yes del` or `--yes execstow delete` removes only recorded owned
links. Deletion is refused as a whole if any recorded target was replaced.
These commands do not rediscover packages and work with missing source
checkouts. Generations and operation evidence remain retained.

Name a destination for source writes:

```bash
cat completions.txt | ./util/add-zsh-completion.sh --source personal COMMAND
./util/remove_function_keyword.sh --source personal --dry-run
./util/convert_aliases_to_functions.sh --source personal --dry-run
```

Shell rewrites also accept explicit source paths. Managed HOME links and state
or configuration paths are refused as destinations. Completion writes reconcile
through envmaker; source-local rules must select their package. `--no-stow`
saves only, while still taking the shared lock and checking ownership. A saved
source edit stays saved if later reconciliation fails; the error identifies
that boundary. Rewrites preserve backups and content edits remain live.

For exact state schema and constraints, consult the
[generation reference](overlay_state.md) and [planner reference](overlay_planner.md).
