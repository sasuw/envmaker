# Public scan policy reference

Contributors run `python3 -I scripts/scan_public.py --root .` before a commit.
The gate checks filenames, hidden files, UTF-8 text files and symlink text
and runs gitleaks 8.16.0. Scanner failures, missing reports, unsupported binaries
and findings fail the gate. Only safe rule IDs,
filenames and line numbers are printed; matched values and diagnostics are
withheld.

Before export, a private term check rejects case-insensitive substrings in file
and directory names, contents and symlink text. Its term list and enforcement
remain private and are not included in this repository or public CI.

The supported scanner is upstream 8.16.0. Release binaries report `8.16.0`.
CI uses `go install github.com/zricethezav/gitleaks/v8@v8.16.0`; that build
omits the release version string. For such builds, the runner requires Go on
`PATH` and verifies `go version -m` on the scanner executable: both the main
package and main module must be `github.com/zricethezav/gitleaks/v8`, and the
main module version must be `v8.16.0`, without module replacements. Missing,
development or mismatched metadata fails; dependency versions alone do not
qualify. No version-string override is used. The runner also accepts one
reviewed Ubuntu 8.16.0 package binary by SHA-256. Python isolated mode prevents
local modules and Python startup hooks from replacing the standard library.

Gitleaks uses `cwd=root` and `--source .`; a parent's name cannot suppress
coverage. The gate refuses nested Git directories and default-skipped path
classes, including `vendor`, `node_modules`, `package-lock.json`, `go.mod`,
`go.sum`, and suffixes such as `.svg`, `.pdf`, `.zip` and `.bin`, in any case.
`policy/gitleaks.toml` is accepted only with exact reviewed bytes, since gitleaks
skips its own configuration. Alternative ignore/config files are refused.
Symlink text and the relative filename namespace also receive stdin secret
scans. Secret matches in names are reported as `<filenames>`, withholding the
matched filename itself.

`AGENTS.md` must exactly equal `.public-agent-template.md`. The root `.git`
administrative directory is excluded from filesystem walking. This command
scans the current tree; it does not establish history, metadata, rights or
publication approval. Release review must separately scan the proposed public
history, identities and refs before publication. No private release inventory
or receipt belongs in this repository.

To run the retained checks locally, a contributor provides the Stow 2.4.1
executable/module pair from `docs/prerequisites.md` and these commands on `PATH`:

- Interpreters and lint: `bash`, `sh`, `zsh`, `perl`, `python3`, `shellcheck`.
- Text and traversal: `awk`, `grep`, `sed`, `find`, `xargs`, `cmp`, `tail`.
- Files and paths: `basename`, `cat`, `chmod`, `cp`, `dirname`, `ln`, `mkdir`,
  `mktemp`, `mv`, `readlink`, `rm`, `rmdir`, `stat`.
- Runtime context and helpers: `env`, `git`, `hostname`, `tput`, `true`, `uname`.

`check_public.sh` checks this complete list before syntax or runtime tests,
including external `true` used by Perl helpers, and checks the pinned Stow path.
Zsh validates converted aliases; POSIX AWK (including `mawk`) supports the
conversion and legacy package summaries. GNU AWK extensions are not required.
`tput` is optional for envmaker itself but included in the check environment.
Perl core modules include `Test::More` for the planner and state suites; no CPAN
installation is needed. The separate scan command also needs gitleaks, and Go
when validating a `go install` scanner build as described above.

On the disposable Ubuntu 24.04 CI runner, the workflow explicitly installs
`bash`, `ca-certificates`, `coreutils`, `curl`, `dash`, `diffutils`, `findutils`,
`git`, `grep`, `gzip`, `hostname`, `make`, `mawk`, `ncurses-bin`, `perl`,
`python3`, `sed`, `shellcheck`, `tar` and `zsh`. `dash` supplies `sh`, `mawk`
supplies `awk`, `diffutils` supplies `cmp`, and `ncurses-bin` supplies `tput`.
`coreutils` supplies the file/path commands, `tail`, `env`, `true` and `uname`;
`findutils` supplies `find` and `xargs`. Go comes from the hosted runner image.
`curl`, `ca-certificates`, `tar`, `gzip` and `make` support CI prerequisite
setup; local checks do not download or build prerequisites.

A contributor then runs:

```bash
python3 -I scripts/scan_public.py --root .
env -u BASH_ENV -u ENV bash scripts/check_public.sh
```

CI builds the pinned Stow release only on its disposable hosted runner. It
never requires a private token. Local checks never run installers, containers
or privileged commands. macOS and FreeBSD runtime validation remains unverified.
