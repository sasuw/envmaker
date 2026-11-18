#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Usage: read_source_roots.sh\nTest helper: emit registered source roots as NUL-delimited data without discovery.\n'
    exit 0
fi
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=bin/source_registry.sh
source "$script_dir/bin/source_registry.sh"
dft_load_registry ''
[[ "$DFT_MODE" == stack ]] || exit 1
printf '%s\0' "${DFT_SOURCE_ROOTS[@]}"
