#!/usr/bin/env bash

set -euo pipefail
ORIGINAL_ARGS=("$@")

SCRIPT_DIR=$(
    CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
        pwd
) || exit 1
# shellcheck source=util/rewrite_shell_files_common.sh
source "${SCRIPT_DIR}/rewrite_shell_files_common.sh"

usage() {
    cat <<'EOF'
Usage: remove_function_keyword.sh [options] [TARGET ...]

Rewrite Zsh/Bash function definitions by removing the `function` keyword,
converting `function name { ... }` or `function name() { ... }` to `name() { ... }`.

Options:
  --dotfiles-dir PATH  Override the directory from dotfiletracker/config
  --source ID          Rewrite only this configured stack source
  -n, --dry-run        Show what files would be modified without changing them
  -h, --help           Show this help

Targets:
  If no target is specified, the configured dotfiles directory is processed.
  Positional targets can be individual files or directory trees.

Limitation:
  Matching is line-based for syntactic function declarations. Function definitions
  inside multiline heredocs or strings are not parsed and should be adjusted manually.
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

dry_run=0
dotfiles_dir=""
source_id=""
targets=()
files_changed=0

while (($# > 0)); do
    case "$1" in
        --source)
            (($# >= 2)) || fail 'Missing value for --source'
            source_id=$2
            shift 2
            ;;
        --source=*) source_id=${1#*=}; shift ;;
        --dotfiles-dir | --dotfile-dir)
            shift
            (($# > 0)) || fail "Missing value for --dotfiles-dir"
            dotfiles_dir="$1"
            shift
            ;;
        --dotfiles-dir=* | --dotfile-dir=*)
            dotfiles_dir="${1#*=}"
            shift
            ;;
        -n | --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            while (($# > 0)); do
                targets+=("$1")
                shift
            done
            break
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            targets+=("$1")
            shift
            ;;
    esac
done

rewrite_file() {
    local target_file="$1"
    local target_dir
    local tmp_file
    local backup_path

    [[ -f "$target_file" || -L "$target_file" ]] || return 0
    [[ -r "$target_file" ]] || return 0

    target_dir="$(dirname "$target_file")"
    if [[ $dry_run -eq 1 ]]; then
        tmp_file=$(mktemp "${TMPDIR:-/tmp}/dotfiletracker-rfk.XXXXXX")
    else
        tmp_file=$(mktemp "${target_dir}/.rfk.XXXXXX")
    fi

    sed -E "
      s/^([[:space:]]*)function[[:space:]]+([a-zA-Z0-9_.:?-]+)[[:space:]]*(\([[:space:]]*\))?[[:space:]]*$/\1\2()/;
      t;
      s/^([[:space:]]*)function[[:space:]]+([a-zA-Z0-9_.:?-]+)[[:space:]]*(\([[:space:]]*\))?[[:space:]]*(\{.*)$/\1\2() \4/;
      t;
      s/^([[:space:]]*)function[[:space:]]+([a-zA-Z0-9_.:?-]+)[[:space:]]*(\([[:space:]]*\))?[[:space:]]+(.*)$/\1\2() \4/
    " "$target_file" >"$tmp_file"

    if cmp -s "$target_file" "$tmp_file"; then
        rm -f "$tmp_file"
        return 0
    fi

    ((files_changed += 1))
    backup_path=$(dotfiletracker_next_backup_path "$target_file")

    if [[ $dry_run -eq 1 ]]; then
        echo "Would update $target_file (backup: $backup_path)"
        rm -f "$tmp_file"
    else
        dotfiletracker_preserve_file_mode "$target_file" "$tmp_file"
        cp -p "$target_file" "$backup_path"
        mv -f "$tmp_file" "$target_file"
        echo "Updated $target_file (backup: $backup_path)"
    fi
}

process_directory() {
    local dir="$1"
    local entry

    while IFS= read -r -d '' entry; do
        if [[ -f "$entry" ]] && grep -Iq . "$entry" 2>/dev/null; then
            rewrite_file "$entry"
        fi
    done < <(find "$dir" -type f ! -path '*/.git/*' ! -name '*.orig' ! -name '*.orig.*' ! -name '*.bak' ! -name '*.swp' ! -name '*~' -print0)
}

# Explicit paths and legacy root overrides obey the same target ownership guard.
explicit_paths=0
[[ ${#targets[@]} -eq 0 ]] || explicit_paths=1
dft_write_destination "$dotfiles_dir" "$source_id" "$explicit_paths" || exit 1
DFT_WRITE_TARGETS=("${targets[@]+"${targets[@]}"}")
dft_guard_legacy_entry "$dry_run" "${SCRIPT_DIR}/remove_function_keyword.sh" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
dft_check_stack_enabled || exit 1

if ((${#targets[@]} == 0)); then
    dotfiles_dir=$DFT_WRITE_ROOT

    dotfiles_dir=$(dotfiletracker_expand_home_path "$(dotfiletracker_strip_optional_quotes "$(dotfiletracker_trim_whitespace "$dotfiles_dir")")")
    [[ -n "$dotfiles_dir" ]] || fail "Dotfiles directory is empty"
    [[ -d "$dotfiles_dir" ]] || fail "Dotfiles directory not found: $dotfiles_dir"

    process_directory "$dotfiles_dir"
else
    for target in "${targets[@]}"; do
        if [[ -d "$target" ]]; then
            process_directory "$target"
        elif [[ -f "$target" || -L "$target" ]]; then
            rewrite_file "$target"
        else
            fail "Target not found: $target"
        fi
    done
fi
