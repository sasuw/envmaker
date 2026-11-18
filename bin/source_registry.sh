# shellcheck shell=bash
# Shared data-only source registry. Sourced by envmaker and companion writers.
# Outputs: DFT_MODE, DFT_LEGACY_ROOT, DFT_SOURCE_IDS[], DFT_SOURCE_ROOTS[].
# This library does not change shell options, cwd, files, or persistent state.

dft_error() {
    printf 'dotfiletracker: %s\n' "$*" >&2
    return 1
}

dft_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

dft_unquote() {
    local value="$1"
    case "$value" in
        \"*\"|\'*\') value="${value:1:${#value}-2}" ;;
    esac
    printf '%s' "$value"
}

# These are literal config prefixes, expanded explicitly rather than by Bash.
# shellcheck disable=SC2016,SC2088
dft_expand_home() {
    case "$1" in
        '~'|'$HOME'|'${HOME}') printf '%s\n' "$HOME" ;;
        '~/'*) printf '%s/%s\n' "$HOME" "${1#'~/'}" ;;
        '$HOME/'*) printf '%s/%s\n' "$HOME" "${1#'$HOME/'}" ;;
        '${HOME}/'*) printf '%s/%s\n' "$HOME" "${1#'${HOME}/'}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Bracket ranges follow Bash's collation locale. Scope C to this builtin check
# only; discovery/rules and every caller retain their own locale.
dft_valid_source_id() {
    local LC_ALL=C
    local id_pattern='^[A-Za-z0-9][A-Za-z0-9_-]*$'
    [[ "$1" =~ $id_pattern ]]
}

dft_add_source() {
    local entry="$1" id root existing
    [[ "$entry" == *=* ]] || { dft_error 'Expected source ID=PATH'; return 1; }
    id=${entry%%=*}
    root=${entry#*=}
    dft_valid_source_id "$id" || { dft_error "Invalid source ID: $id"; return 1; }
    # Quoting is literal pairing only; there is no escaping or shell evaluation.
    case "$root" in
        \"*|\'*)
            case "$root" in
                \"*\"|\'*\') root=$(dft_unquote "$root") ;;
                *) dft_error "Unmatched source path quote for $id"; return 1 ;;
            esac
            ;;
    esac
    [[ -n "$root" ]] || { dft_error "Empty source path for $id"; return 1; }
    root=$(dft_expand_home "$root")
    [[ -d "$root" ]] || { dft_error "Source directory not found ($id): $root"; return 1; }
    root=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
    for existing in "${DFT_SOURCE_IDS[@]+"${DFT_SOURCE_IDS[@]}"}"; do
        [[ "$existing" != "$id" ]] || { dft_error "Duplicate source ID: $id"; return 1; }
    done
    for existing in "${DFT_SOURCE_ROOTS[@]+"${DFT_SOURCE_ROOTS[@]}"}"; do
        [[ ! "$existing" -ef "$root" ]] || { dft_error "Repeated physical source root ($id): $root"; return 1; }
    done
    DFT_SOURCE_IDS+=("$id")
    DFT_SOURCE_ROOTS+=("$root")
}

# Explicit legacy root bypasses configuration. Repeated CLI sources replace it.
# Otherwise scan the entire config, including after a legacy value, to reject
# mixed registries instead of letting a writer silently choose one source.
dft_load_registry() {
    local legacy_override="$1"
    shift
    local config_file="${XDG_CONFIG_HOME:-"$HOME/.config"}/dotfiletracker/config"
    local line key value legacy_seen=0
    DFT_MODE=legacy
    DFT_LEGACY_ROOT=""
    DFT_SOURCE_IDS=()
    DFT_SOURCE_ROOTS=()
    if [[ -n "$legacy_override" ]]; then
        [[ $# -eq 0 ]] || { dft_error 'Cannot combine --source with --dotfiles-dir'; return 1; }
        DFT_LEGACY_ROOT="$legacy_override"
        return 0
    fi
    if [[ $# -gt 0 ]]; then
        for value in "$@"; do
            dft_add_source "$value" || return 1
        done
        DFT_MODE=stack
        return 0
    fi
    [[ -f "$config_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(dft_trim "$line")
        [[ -n "$line" && "$line" != \#* ]] || continue
        if [[ "$line" == *=* ]]; then
            key=$(dft_trim "${line%%=*}")
            value=$(dft_trim "${line#*=}")
            case "$key" in
                source.*)
                    dft_add_source "${key#source.}=$value" || return 1
                    ;;
                dotfiles_dir|dotfile_dir)
                    if [[ $legacy_seen -eq 0 ]]; then
                        DFT_LEGACY_ROOT=$(dft_unquote "$value")
                    fi
                    legacy_seen=1
                    ;;
            esac
        else
            if [[ $legacy_seen -eq 0 ]]; then
                DFT_LEGACY_ROOT=$(dft_unquote "$line")
            fi
            legacy_seen=1
        fi
    done < "$config_file"
    if [[ ${DFT_SOURCE_IDS[0]+present} ]]; then
        [[ $legacy_seen -eq 0 ]] || { dft_error "Cannot mix dotfiles_dir and source entries in $config_file"; return 1; }
        DFT_MODE=stack
    else
        [[ $legacy_seen -eq 1 ]] || return 2
    fi
}

# Legacy-only config readers must never silently select a stack write root.
dft_require_legacy() {
    [[ "$DFT_MODE" == legacy ]] || {
        dft_error 'Unsupported stack command; use execstow, migrate, ls, or recover'
        return 1
    }
}

dft_read_legacy_config() {
    dft_load_registry '' || return 1
    dft_require_legacy || return 1
    printf '%s\n' "$DFT_LEGACY_ROOT"
}

# Writers must choose a source explicitly, or supply explicit rewrite paths.
# Outputs DFT_WRITE_ROOT and the same registry used by normal reconciliation.
# shellcheck disable=SC2034
dft_write_destination() {
    local override="$1" source_id="$2" explicit_paths="$3" i
    DFT_WRITE_ROOT=""
    [[ -z "$override" || -z "$source_id" ]] || { dft_error 'Cannot combine --source with --dotfiles-dir'; return 1; }
    if [[ -n "$override" ]]; then
        dft_load_registry "$override" || return 1
        DFT_WRITE_ROOT=$(dft_expand_home "$override")
        return 0
    fi
    if [[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiletracker/config" && "$explicit_paths" == 1 && -z "$source_id" ]]; then
        DFT_MODE=legacy
        return 0
    fi
    dft_load_registry '' || return 1
    if [[ "$DFT_MODE" == legacy ]]; then
        [[ -z "$source_id" ]] || { dft_error '--source requires stack configuration'; return 1; }
        DFT_WRITE_ROOT=$(dft_expand_home "$DFT_LEGACY_ROOT")
        return 0
    fi
    if [[ -z "$source_id" ]]; then
        [[ "$explicit_paths" == 1 ]] || { dft_error 'Stack writes require --source ID or an explicit rewrite path'; return 1; }
        return 0
    fi
    [[ "$explicit_paths" == 0 ]] || { dft_error 'Use --source ID or explicit rewrite paths, not both'; return 1; }
    for ((i = 0; i < ${#DFT_SOURCE_IDS[@]}; i++)); do
        if [[ "${DFT_SOURCE_IDS[i]}" == "$source_id" ]]; then
            DFT_WRITE_ROOT=${DFT_SOURCE_ROOTS[i]}
            return 0
        fi
    done
    dft_error "Unknown destination source: $source_id"
}

dft_check_stack_enabled() {
    [[ "$DFT_MODE" == stack ]] || return 0
    local helper_dir
    helper_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    perl "$helper_dir/overlay_command.pl" - - enabled
}
