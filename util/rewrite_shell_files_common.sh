# shellcheck shell=bash
# shellcheck source=bin/source_registry.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/source_registry.sh"
# shellcheck source=bin/mutation_guard.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/mutation_guard.sh"

dotfiletracker_trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

dotfiletracker_strip_optional_quotes() {
    local value="$1"

    if [[ ${#value} -ge 2 && "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

dotfiletracker_expand_home_path() {
    local file_path="$1"
    local tilde_prefix="~"
    local home_variable="\$HOME"
    local braced_home_variable="\${HOME}"

    case "$file_path" in
        "$tilde_prefix")
            printf '%s\n' "$HOME"
            ;;
        "$tilde_prefix/"*)
            printf '%s/%s\n' "$HOME" "${file_path#"$tilde_prefix"/}"
            ;;
        "$home_variable")
            printf '%s\n' "$HOME"
            ;;
        "$home_variable/"*)
            printf '%s/%s\n' "$HOME" "${file_path#"$home_variable"/}"
            ;;
        "$braced_home_variable")
            printf '%s\n' "$HOME"
            ;;
        "$braced_home_variable/"*)
            printf '%s/%s\n' "$HOME" "${file_path#"$braced_home_variable"/}"
            ;;
        *)
            printf '%s\n' "$file_path"
            ;;
    esac
}

dotfiletracker_read_dotfiles_dir_from_config() {
    dft_read_legacy_config
}

dotfiletracker_next_backup_path() {
    local original_path="$1"
    local backup_path="${original_path}.orig"
    local suffix=1

    while [[ -e "$backup_path" || -L "$backup_path" ]]; do
        backup_path="${original_path}.orig.${suffix}"
        suffix=$((suffix + 1))
    done

    printf '%s\n' "$backup_path"
}

dotfiletracker_preserve_file_mode() {
    local source_file="$1"
    local destination_file="$2"
    local file_mode

    if chmod --reference="$source_file" "$destination_file" 2>/dev/null; then
        return 0
    fi

    file_mode=$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '0644\n')
    chmod "$file_mode" "$destination_file"
}

dotfiletracker_is_shell_source_file() {
    local target_file="$1"
    local base_name
    local first_line=""

    base_name=${target_file##*/}
    case "$base_name" in
        *.sh | *.bash | *.zsh | .bashrc | .bash_profile | .bash_login | .profile | .zshrc | .zprofile | .zshenv | .zlogin | .zlogout)
            return 0
            ;;
    esac

    IFS= read -r first_line <"$target_file" || true
    case "$first_line" in
        '#!'*'/sh' | '#!'*' sh' | '#!'*'/sh '* | '#!'*' sh '* | \
            '#!'*'/bash' | '#!'*' bash' | '#!'*'/bash '* | '#!'*' bash '* | \
            '#!'*'/zsh' | '#!'*' zsh' | '#!'*'/zsh '* | '#!'*' zsh '*)
            return 0
            ;;
    esac

    return 1
}

dotfiletracker_is_zsh_source_file() {
    local target_file="$1"
    local base_name
    local first_line=""

    base_name=${target_file##*/}
    case "$target_file" in
        */.shellinclude/* | */.localenv-interactive-*/*)
            return 0
            ;;
    esac
    case "$base_name" in
        *.zsh | .zshrc | .zprofile | .zshenv | .zlogin | .zlogout)
            return 0
            ;;
    esac

    IFS= read -r first_line <"$target_file" || true
    [[ "$first_line" == '#!'*zsh* ]]
}
