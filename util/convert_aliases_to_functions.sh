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
Usage: convert_aliases_to_functions.sh [options] [TARGET ...]

Convert static shell alias assignments to functions. Normal alias bodies receive
`"$@"`; aliases implemented as anonymous functions keep their existing bodies.

Options:
  --dotfiles-dir PATH  Override the directory from dotfiletracker/config
  --source ID          Rewrite only this configured stack source
  -n, --dry-run        Show what files would be modified without changing them
  -h, --help           Show this help

Targets:
  If no target is specified, shell source files in the configured dotfiles
  directory are processed. Positional targets can be files or directory trees.

Limitations:
  Only one-line, static `alias name=value` declarations are converted. Dynamic
  names, alias options, and multiple declarations on one line are left unchanged
  with a warning.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

dry_run=0
dotfiles_dir=""
source_id=""
files_changed=0
targets=()
active_tmp_file=""

cleanup() {
    if [[ -n "$active_tmp_file" ]]; then
        rm -f "$active_tmp_file"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
                targets[${#targets[@]}]="$1"
                shift
            done
            break
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            targets[${#targets[@]}]="$1"
            shift
            ;;
    esac
done

rewrite_aliases() {
    local target_file="$1"
    local use_function_keyword="$2"

    awk -v source_file="$target_file" -v use_function_keyword="$use_function_keyword" '
        function warn(reason) {
            printf "Warning: %s:%d: %s; leaving alias unchanged\n", source_file, NR, reason > "/dev/stderr"
        }

        function trim(value) {
            sub(/^[ \t]+/, "", value)
            sub(/[ \t]+$/, "", value)
            return value
        }

        function decode_shell_word(word,    character, decoded, index_value, next_character, quote) {
            decoded = ""
            quote = ""

            for (index_value = 1; index_value <= length(word); index_value++) {
                character = substr(word, index_value, 1)

                if (quote == "single") {
                    if (character == "\047") {
                        quote = ""
                    } else {
                        decoded = decoded character
                    }
                } else if (quote == "double") {
                    if (character == "\"") {
                        quote = ""
                    } else if (character == "\\" && index_value < length(word)) {
                        next_character = substr(word, index_value + 1, 1)
                        if (next_character == "$" || next_character == "`" || next_character == "\"" || next_character == "\\") {
                            decoded = decoded next_character
                            index_value++
                        } else {
                            decoded = decoded character
                        }
                    } else {
                        decoded = decoded character
                    }
                } else if (character == "\047") {
                    quote = "single"
                } else if (character == "\"") {
                    quote = "double"
                } else if (character == "\\" && index_value < length(word)) {
                    decoded = decoded substr(word, index_value + 1, 1)
                    index_value++
                } else {
                    decoded = decoded character
                }
            }

            return decoded
        }

        function transform_alias(line,    body, character, comment, declaration, equals_at, first_token, index_value, indent, name, quote, raw_body, remainder, rhs, rhs_word, trimmed_body, word_end) {
            match(line, /^[ \t]*/)
            indent = substr(line, 1, RLENGTH)
            remainder = substr(line, RLENGTH + 1)

            if (remainder !~ /^alias[ \t]+/) {
                return line
            }
            sub(/^alias[ \t]+/, "", remainder)

            if (remainder ~ /^-/) {
                warn("alias options are not supported")
                return line
            }
            if (remainder ~ /^[\047\"]/) {
                warn("dynamic or quoted alias names are not supported")
                return line
            }

            equals_at = index(remainder, "=")
            if (equals_at == 0) {
                return line
            }
            name = substr(remainder, 1, equals_at - 1)
            if (name ~ /[ \t]/ || name == "") {
                return line
            }
            if (use_function_keyword && name !~ /^[A-Za-z0-9_.,:+?@%-]+$/) {
                warn("alias name cannot be represented safely as a Zsh function")
                return line
            }
            if (!use_function_keyword && name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                warn("alias name is not a portable function name")
                return line
            }

            rhs = substr(remainder, equals_at + 1)
            quote = ""
            word_end = length(rhs)
            for (index_value = 1; index_value <= length(rhs); index_value++) {
                character = substr(rhs, index_value, 1)
                if (quote == "single") {
                    if (character == "\047") {
                        quote = ""
                    }
                } else if (quote == "double") {
                    if (character == "\\") {
                        index_value++
                    } else if (character == "\"") {
                        quote = ""
                    }
                } else if (character == "\047") {
                    quote = "single"
                } else if (character == "\"") {
                    quote = "double"
                } else if (character == "\\") {
                    index_value++
                } else if (character == " " || character == "\t") {
                    word_end = index_value - 1
                    break
                }
            }

            if (quote != "") {
                warn("unterminated quoted alias value")
                return line
            }

            rhs_word = substr(rhs, 1, word_end)
            comment = substr(rhs, word_end + 1)
            if (trim(comment) == "") {
                comment = ""
            } else if (trim(comment) !~ /^#/) {
                if (trim(comment) ~ /^[A-Za-z0-9_.,:+?@%-]+=/) {
                    warn("multiple alias declarations are not supported")
                    return line
                }
                if (substr(rhs, 1, 1) == "\047" || substr(rhs, 1, 1) == "\"") {
                    warn("trailing shell code after a quoted alias value is not supported")
                    return line
                }
                rhs_word = rhs
                comment = ""
                raw_body = 1
            }

            if (raw_body) {
                body = rhs_word
            } else {
                body = decode_shell_word(rhs_word)
            }
            trimmed_body = trim(body)
            if (trimmed_body == "") {
                warn("empty alias values are not supported")
                return line
            }

            if (use_function_keyword) {
                declaration = "function " name "()"
            } else {
                declaration = name "()"
            }

            if (trimmed_body ~ /^\(\)[ \t]*\{/ && trimmed_body ~ /\}[ \t]*$/) {
                sub(/^\(\)[ \t]*\{/, "", trimmed_body)
                sub(/\}[ \t]*$/, "", trimmed_body)
                return indent declaration " {" trimmed_body "}" comment
            }

            first_token = trimmed_body
            sub(/[ \t;|&<>()].*$/, "", first_token)
            if (first_token == "source" || first_token == ".") {
                warn("aliases that source files cannot preserve top-level shell scope as functions")
                return line
            }
            if (first_token == name) {
                body = "command " body
            }

            return indent declaration " { " body " \"$@\"; }" comment
        }

        {
            print transform_alias($0)
        }
    ' "$target_file"
}

rewrite_file() {
    local target_file="$1"
    local target_dir
    local backup_path
    local use_function_keyword=0

    [[ -f "$target_file" || -L "$target_file" ]] || return 0
    [[ -r "$target_file" ]] || return 0
    grep -Eq "^[[:space:]]*alias[[:space:]]+([^[:space:]=]+=|[\"']|-)" "$target_file" || return 0

    if dotfiletracker_is_zsh_source_file "$target_file"; then
        use_function_keyword=1
    fi

    target_dir=$(dirname "$target_file")
    if [[ $dry_run -eq 1 ]]; then
        active_tmp_file=$(mktemp "${TMPDIR:-/tmp}/dotfiletracker-catf.XXXXXX")
    else
        active_tmp_file=$(mktemp "${target_dir}/.catf.XXXXXX")
    fi
    if ! rewrite_aliases "$target_file" "$use_function_keyword" >"$active_tmp_file"; then
        fail "Could not convert aliases in $target_file"
    fi

    if cmp -s "$target_file" "$active_tmp_file"; then
        rm -f "$active_tmp_file"
        active_tmp_file=""
        return 0
    fi

    files_changed=$((files_changed + 1))
    backup_path=$(dotfiletracker_next_backup_path "$target_file")

    if [[ $dry_run -eq 1 ]]; then
        printf 'Would update %s (backup: %s)\n' "$target_file" "$backup_path"
        rm -f "$active_tmp_file"
    else
        dotfiletracker_preserve_file_mode "$target_file" "$active_tmp_file"
        cp -p "$target_file" "$backup_path"
        mv -f "$active_tmp_file" "$target_file"
        printf 'Updated %s (backup: %s)\n' "$target_file" "$backup_path"
    fi
    active_tmp_file=""
}

process_directory() {
    local directory="$1"
    local entry

    while IFS= read -r -d '' entry; do
        if [[ -f "$entry" ]] && dotfiletracker_is_shell_source_file "$entry" && grep -Iq . "$entry" 2>/dev/null; then
            rewrite_file "$entry"
        fi
    done < <(find "$directory" -type f ! -path '*/.git/*' ! -name '*.orig' ! -name '*.orig.*' ! -name '*.bak' ! -name '*.swp' ! -name '*~' -print0)
}

# Explicit paths and legacy root overrides obey the same target ownership guard.
explicit_paths=0
[[ ${#targets[@]} -eq 0 ]] || explicit_paths=1
dft_write_destination "$dotfiles_dir" "$source_id" "$explicit_paths" || exit 1
DFT_WRITE_TARGETS=("${targets[@]+"${targets[@]}"}")
dft_guard_legacy_entry "$dry_run" "${SCRIPT_DIR}/convert_aliases_to_functions.sh" "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}"
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

if [[ $files_changed -eq 0 ]]; then
    printf 'No alias declarations needed conversion.\n'
fi
