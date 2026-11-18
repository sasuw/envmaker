#!/usr/bin/env bash
set -euo pipefail

case ${1-} in
  -h|--help) printf 'Usage: bash scripts/check_public.sh\nRun syntax, lint and isolated runtime checks; prerequisites must exist.\n'; exit 0 ;;
  '') ;;
  *) printf 'Unexpected argument\n' >&2; exit 2 ;;
esac
# Keep this closure in sync with the CI packages and docs/public_scan.md.
# Include tools called by runtime helpers, nested suites and their fixtures.
for tool in awk basename bash cat chmod cmp cp dirname env find git grep \
  hostname ln mkdir mktemp mv perl python3 readlink rm rmdir sed sh shellcheck \
  stat tail tput true uname xargs zsh; do
  # Perl also execs true directly, so a shell builtin is not sufficient.
  type -P "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 1; }
done
[[ -x /opt/stow-2.4.1/bin/stow ]] || { printf 'Missing dependency: /opt/stow-2.4.1/bin/stow\n' >&2; exit 1; }
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$script_dir/.."
# The explicit CI checkout is the public tree. Never run this against private history.
while IFS= read -r -d '' file; do
  case $file in
    *.sh) bash -n "$file" ;;
    bin/*.pl|bin/*.pm) perl -I bin -c "$file" ;;
  esac
done < <(find bin util tests scripts -type f -print0)
bash -n envmaker.sh
# Legacy helpers have their own style; new release-facing shell stays lint-clean.
shellcheck scripts/check_public.sh
python3 -I tests/public_smoke.py
env -u BASH_ENV -u ENV bash tests/envmaker_regression.sh
