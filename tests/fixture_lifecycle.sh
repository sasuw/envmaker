# shellcheck shell=bash
# Shared bootstrap for Bash suites. The Python owner alone removes the root.
# Requires Python 3.9+; source this file, then call fixture_suite PREFIX "$@".
fixture_suite() {
  local prefix=$1
  shift
  if [[ ${DFT_FIXTURE_OWNER:-} != "$PPID" ]]; then
    exec python3 -B "${BASH_SOURCE[0]%/*}/fixture_lifecycle.py" \
      --prefix "$prefix" -- bash "${BASH_SOURCE[1]}" "$@"
  fi
  # shellcheck disable=SC2034 # Consumed by the sourcing suite.
  TEST_ROOT=${DFT_FIXTURE_ROOT:?}
}
