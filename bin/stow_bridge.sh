# shellcheck shell=bash
# Locate Stow through its own interpreter and library setup, not a Perl-version
# directory guessed from the development host. No Stow actions run here.
dft_stow_run() {
    local stow_exec="${1:-/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow}"
    local helper="$2"
    shift 2
    local shebang perl_exec helper_dir
    [[ -x "$stow_exec" ]] || {
        dft_error "Stow executable not found: $stow_exec"
        return 1
    }
    IFS= read -r shebang <"$stow_exec" || return 1
    case "$shebang" in
    '#!/usr/bin/env perl') perl_exec=perl ;;
    '#!'/*/perl) perl_exec=${shebang#'#!'} ;;
    *)
        dft_error "Unsupported Stow interpreter in $stow_exec: $shebang"
        return 1
        ;;
    esac
    helper_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    "$perl_exec" "$helper_dir/$helper" "$stow_exec" "${STOW_VERSION:-2.4.1}" "$@"
}

dft_stow_module_info() {
    dft_stow_run "${1:-/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow}" stow_probe.pl
}

# NUL-delimited records preserve every path character through the Bash/Perl
# boundary. Discovery is completed once before serializing its frozen arrays.
dft_emit_selected_packages() {
    local i
    printf 'registry-v1\0'
    for ((i = 0; i < ${#DFT_SOURCE_IDS[@]}; i++)); do
        printf 'source\0%s\0%s\0' "${DFT_SOURCE_IDS[i]}" "${DFT_SOURCE_ROOTS[i]}"
    done
    i=0
    while [[ ${STACK_PACKAGE_PATHS[i]+present} ]]; do
        printf 'package\0%s\0%s\0' "${STACK_PACKAGE_SOURCES[i]}" "${STACK_PACKAGE_PATHS[i]}"
        i=$((i + 1))
    done
    printf 'end\0'
}

dft_overlay_plan() {
    # Discovery presentation goes to stderr so stdout remains a JSON document.
    discover_stack_packages >&2 || return 1
    dft_emit_selected_packages | dft_stow_run "/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow" overlay_plan.pl "$@"
}

dft_overlay_command() {
    local action="$1" preview="$2" command="$3" from="$4" i
    local registry=()
    if [[ "$action" == apply || "$action" == migrate ]]; then
        for ((i = 0; i < ${#DFT_SOURCE_IDS[@]}; i++)); do
            registry+=("${DFT_SOURCE_IDS[i]}" "${DFT_SOURCE_ROOTS[i]}")
        done
    fi
    DFT_OVERLAY_VERBOSE="${VERBOSE_MODE:-0}" DFT_OVERLAY_DEBUG="${DEBUG_MODE:-0}" \
        dft_stow_run "/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow" overlay_command.pl \
        "$action" "$preview" "$command" "$from" "${registry[@]+"${registry[@]}"}"
}
