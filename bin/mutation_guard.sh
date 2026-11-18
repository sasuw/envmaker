# shellcheck shell=bash
# Re-exec once under the common target guard; the inherited descriptor is
# verified with flock/inode/ownership checks, never trusted as an env bypass.
dft_guard_legacy_entry() {
    local preview="$1" program="$2" helper_dir guard_mode=legacy
    local root guard_args=()
    shift 2
    helper_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    [[ "$preview" == 0 ]] || guard_mode=legacy-preview
    if [[ "${DFT_MODE:-legacy}" == stack ]]; then
        guard_mode=writer
        [[ "$preview" == 0 ]] || guard_mode=writer-preview
        for root in "${DFT_SOURCE_ROOTS[@]+"${DFT_SOURCE_ROOTS[@]}"}"; do
            guard_args+=(--source-root "$root")
        done
        if [[ -n "${DFT_WRITE_ROOT:-}" ]]; then
            guard_args+=(--write-root "$DFT_WRITE_ROOT" --write-target "$DFT_WRITE_ROOT")
        fi
        for root in "${DFT_WRITE_TARGETS[@]+"${DFT_WRITE_TARGETS[@]}"}"; do
            guard_args+=(--write-target "$root")
        done
    fi
    if [[ -n "${DFT_GUARD_FD:-}" ]]; then
        perl "$helper_dir/mutation_guard.pl" verify "$guard_mode" "${guard_args[@]+"${guard_args[@]}"}" || return 1
    else
        # run/verify of a preview without an existing lock needs no recursion:
        # the child receives an empty descriptor, so the parent marks only the
        # read-only path after performing the same ownership check.
        if [[ "$guard_mode" == *-preview ]]; then
            perl "$helper_dir/mutation_guard.pl" run "$guard_mode" "${guard_args[@]+"${guard_args[@]}"}" -- true || return 1
            return 0
        fi
        perl "$helper_dir/mutation_guard.pl" run "$guard_mode" "${guard_args[@]+"${guard_args[@]}"}" -- bash "$program" "$@"
        exit $?
    fi
}
