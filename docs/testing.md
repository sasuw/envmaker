# Regression fixture lifecycle

Contributors need Bash, Perl, the documented GNU Stow installation, and Python
3.9 or newer to run the regression suites. Production commands do not require
Python. Test cleanup requires descriptor-relative open, stat, unlink and rmdir,
descriptor-based scandir, and no-follow directory opens on the host platform.
Unsupported interpreters or platforms retain and name the allocated root and
fail before running a suite; deletion never falls back to filesystem paths.

## Running suites

From the repository root, run the suites without startup-file injection:

```bash
env -u BASH_ENV -u ENV bash tests/init_repo_regression.sh
env -u BASH_ENV -u ENV bash tests/envmaker_regression.sh test_backup_scan_recursively_checks_nested_package_files
python3 -I tests/fixture_lifecycle_test.py
```

The main regression suite accepts named test functions. With no arguments it
also runs the other Bash suites, the Perl overlay suites, and the lifecycle
regressions. `scripts/check_public.sh` runs `tests/public_smoke.py` and then
`tests/envmaker_regression.sh`.

## Cleanup and diagnosis

Each suite allocates a fresh private root beneath `TMPDIR` (or the platform's
temporary directory). The owner process puts nested temporary allocations under
that root. A passing suite releases its root. A failed suite keeps its root and
prints `Fixtures retained: ABSOLUTE_PATH` to stderr, including assertion errors,
early command errors, and catchable interruptions. Expected command failures
inside a passing test do not retain fixtures. SIGKILL cannot run cleanup.

`tests/fixture_lifecycle.py` owns allocation and deletion for every test language.
Bash and Perl suites re-execute under that owner through small bootstrap
adapters. Nested shells cannot release their parent's root. Python test cases
also use `FixtureTestCase` or the `Fixture` context manager, so discovery runs
retain failed cases even without the command-line suite owner.
Python suites resolve the lifecycle helper relative to their own file under
direct execution, isolated mode and `unittest` module/discovery execution.
Re-execution preserves the caller's Python isolation flags for both the owner
and its suite child.

Cleanup checks the held directory identity, allocating process, user ownership,
and canonical parent before deleting. Empty, unexpected, replaced and symlinked
roots are refused. Deletion stays relative to an open parent descriptor and does
not follow symlinks inside the root. A cleanup refusal or error produces a
nonzero result and names the retained path. No prefix scan or historical fixture
cleanup is provided. Fixtures must not be concurrently renamed during teardown.

To inspect a new run's cleanup without deleting its fixtures, run:

```bash
python3 -B tests/fixture_lifecycle.py --dry-run -- bash tests/init_repo_regression.sh
```

The command still runs the suite. It then validates and names the new owned root
without deleting it. It cannot adopt an arbitrary existing directory for cleanup.
The `DFT_FIXTURE_FAULT=early` negative control retains a root with status 23 before
starting the child. `DFT_FIXTURE_FAULT=assertion` changes a passing child result to
status 1 and retains the root. The runner removes that variable from the child
environment, so negative controls do not propagate into nested suites.
