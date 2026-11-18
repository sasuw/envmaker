#!/usr/bin/env bash

set -euo pipefail
ORIGINAL_ARGS=("$@")

# shellcheck source=bin/source_registry.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/source_registry.sh"
# shellcheck source=bin/mutation_guard.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/mutation_guard.sh"

usage() {
    cat <<'EOF'
Usage: add-zsh-completion.sh [options] COMMAND

Read a Zsh completion script from standard input, save it in the configured
dotfiles repository, and make it available through GNU Stow.

Options:
  --dotfiles-dir PATH  Override the directory from dotfiletracker/config
  --source ID          Write to this configured stack source, then reconcile
  -n, --dry-run        Preview the destination without writing or running hooks
  --force              Replace an existing completion with different content
  --no-stow            Save the completion without running GNU Stow
  -h, --help           Show this help

Examples:
  exampletool completion zsh | ./util/add-zsh-completion.sh exampletool
  cat completions.txt | ./util/add-zsh-completion.sh exampletool
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

strip_optional_quotes() {
    local value="$1"

    if [[ ${#value} -ge 2 && "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

expand_home_path() {
    local path="$1"
    local tilde_prefix="~"
    local home_variable="\$HOME"
    local braced_home_variable="\${HOME}"

    case "$path" in
        "$tilde_prefix")
            printf '%s\n' "$HOME"
            ;;
        "$tilde_prefix/"*)
            printf '%s/%s\n' "$HOME" "${path#"$tilde_prefix"/}"
            ;;
        "$home_variable")
            printf '%s\n' "$HOME"
            ;;
        "$home_variable/"*)
            printf '%s/%s\n' "$HOME" "${path#"$home_variable"/}"
            ;;
        "$braced_home_variable")
            printf '%s\n' "$HOME"
            ;;
        "$braced_home_variable/"*)
            printf '%s/%s\n' "$HOME" "${path#"$braced_home_variable"/}"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

read_dotfiles_dir_from_config() {
    dft_read_legacy_config
}

force=0
run_stow=1
dotfiles_dir=""
source_id=""
dry_run=0

while (($# > 0)); do
    case "$1" in
        --source)
            (($# >= 2)) || fail 'Missing value for --source'
            source_id=$2
            shift 2
            ;;
        --source=*) source_id=${1#*=}; shift ;;
        -n|--dry-run) dry_run=1; shift ;;
        --dotfiles-dir|--dotfile-dir)
            shift
            (($# > 0)) || fail "Missing value for --dotfiles-dir"
            dotfiles_dir="$1"
            shift
            ;;
        --dotfiles-dir=*|--dotfile-dir=*)
            dotfiles_dir="${1#*=}"
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        --no-stow)
            run_stow=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

(($# == 1)) || {
    usage >&2
    exit 1
}

command_name="$1"
if [[ ! "$command_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    fail "Invalid command name '$command_name'. Use letters, numbers, dot, underscore, plus, or hyphen."
fi

config_file="${XDG_CONFIG_HOME:-"$HOME/.config"}/dotfiletracker/config"
dft_write_destination "$dotfiles_dir" "$source_id" 0 || exit 1
dotfiles_dir=$DFT_WRITE_ROOT

dotfiles_dir=$(expand_home_path "$(strip_optional_quotes "$(trim_whitespace "$dotfiles_dir")")")
[[ -n "$dotfiles_dir" ]] || fail "Dotfiles directory is empty"
[[ -d "$dotfiles_dir/parts/application" ]] ||
    fail "Dotfiles application directory not found: $dotfiles_dir/parts/application"

completion_package_dir="$dotfiles_dir/parts/application/$command_name/completions"
completion_dir="$completion_package_dir/.shellinclude"
completion_file="$completion_dir/completions_${command_name}.sh"

stow_exec="${DOTFILETRACKER_STOW_EXEC:-"/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow"}"
if [[ $run_stow -eq 1 && ! -x "$stow_exec" ]]; then
    fail "Stow executable not found or not executable: $stow_exec"
fi

DFT_WRITE_TARGETS=("$completion_file")
dft_guard_legacy_entry "$dry_run" "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/add-zsh-completion.sh" "${ORIGINAL_ARGS[@]}"
dft_check_stack_enabled || exit 1

input_file=$(mktemp "${TMPDIR:-/tmp}/dotfiletracker-completion.XXXXXX")
destination_tmp=""
cleanup() {
    rm -f "$input_file"
    if [[ -n "$destination_tmp" ]]; then
        rm -f "$destination_tmp"
    fi
}
trap cleanup EXIT

cat > "$input_file"
[[ -s "$input_file" ]] || fail "No completion content received on standard input"

completion_changed=1
if [[ -f "$completion_file" ]]; then
    if cmp -s "$input_file" "$completion_file"; then
        completion_changed=0
    elif [[ $force -eq 0 ]]; then
        fail "Completion already exists with different content: $completion_file (use --force to replace it)"
    fi
fi

if [[ $completion_changed -eq 1 ]]; then
    if [[ $dry_run -eq 1 ]]; then
        printf 'Would save Zsh completion: %s; reconciliation has not run.\n' "$completion_file"
        exit 0
    fi
    mkdir -p "$completion_dir"
    destination_tmp=$(mktemp "$completion_dir/.completions_${command_name}.sh.XXXXXX")
    cp "$input_file" "$destination_tmp"
    chmod 0644 "$destination_tmp"
    mv "$destination_tmp" "$completion_file"
    destination_tmp=""
    echo "Saved Zsh completion: $completion_file"
else
    echo "Zsh completion is already up to date: $completion_file"
fi

if [[ $run_stow -eq 1 ]]; then
    if [[ $dry_run -eq 1 ]]; then
        printf 'Would reconcile completions; no links were changed.\n'
    elif [[ "$DFT_MODE" == stack ]]; then
        if ! bash "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/envmaker.sh" execstow restow; then
            fail 'The completion was saved, but overlay reconciliation failed; inspect retained state before retrying'
        fi
    elif ! (
        cd "$dotfiles_dir/parts/application/$command_name"
        "$stow_exec" --verbose=0 --target="$HOME" --restow completions
    ); then
        fail "The completion was saved, but GNU Stow could not link it into $HOME"
    fi
    if [[ $dry_run -eq 0 ]]; then
        echo "Completion is available to new Zsh sessions through $HOME/.shellinclude."
    fi
else
    echo "Skipped GNU Stow; run envmaker.sh execstow restow before loading the completion."
fi
