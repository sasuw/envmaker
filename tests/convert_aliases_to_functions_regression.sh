#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(
    CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &&
        pwd
) || exit 1
CONVERT_ALIASES_SH="${REPO_ROOT}/util/convert_aliases_to_functions.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/convert-aliases-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'ASSERTION FAILED: %s\nExpected to find: %s\nActual output: %s\n' \
            "$message" "$needle" "$haystack" >&2
        exit 1
    fi
}

assert_file_equals() {
    local expected="$1"
    local target_file="$2"
    local message="$3"

    if [[ "$(<"$target_file")" != "$expected" ]]; then
        printf 'ASSERTION FAILED: %s\nExpected: %s\nActual: %s\n' \
            "$message" "$expected" "$(<"$target_file")" >&2
        exit 1
    fi
}

new_test_environment() {
    local name="$1"
    local test_dir="${TEST_ROOT}/${name}"

    mkdir -p \
        "${test_dir}/home/.config/dotfiletracker" \
        "${test_dir}/home/dotfiles/parts/shell" \
        "${test_dir}/home/dotfiles/docs" \
        "${test_dir}/home/dotfiles/parts/application/ranger"
    # shellcheck disable=SC2016
    printf '%s\n' 'dotfiles_dir="$HOME/dotfiles"' \
        >"${test_dir}/home/.config/dotfiletracker/config"
    printf '%s\n' "$test_dir"
}

get_file_mode() {
    local target_file="$1"

    stat -c '%a' "$target_file" 2>/dev/null || stat -f '%Lp' "$target_file" 2>/dev/null || printf 'unknown\n'
}

test_zsh_alias_variants() {
    local test_dir
    local target_file
    local output
    local result

    test_dir=$(new_test_environment "zsh-variants")
    target_file="${test_dir}/aliases.zsh"
    cat <<'EOF' >"$target_file"
#!/usr/bin/env zsh
alias greet='printf "hello %s\n"'
alias field="awk '{print \$1}'"
alias plain=printf
alias intended_unquoted=git log --oneline
alias ls='ls -la'
alias ,gs='git status' # status
alias anonymous='(){printf "%s\n" "$1";}'
  alias indented="printf \"%s\\n\""
EOF
    printf '%s \n' "alias trailing='printf trailing'" >>"$target_file"

    output=$(bash "$CONVERT_ALIASES_SH" "$target_file")
    result=$(<"$target_file")

    assert_contains "$output" "Updated $target_file" "converted file should be reported"
    assert_contains "$result" 'function greet() { printf "hello %s\n" "$@"; }' "single-quoted body should be converted"
    # shellcheck disable=SC2016
    assert_contains "$result" 'function field() { awk '\''{print $1}'\'' "$@"; }' "double-quote escapes should be decoded"
    assert_contains "$result" 'function plain() { printf "$@"; }' "unquoted alias should be converted"
    assert_contains "$result" 'function trailing() { printf trailing "$@"; }' "trailing whitespace alias should be converted"
    assert_contains "$result" 'function intended_unquoted() { git log --oneline "$@"; }' "intended unquoted command lines should be converted"
    assert_contains "$result" 'function ls() { command ls -la "$@"; }' "self-named command should bypass the function"
    assert_contains "$result" 'function ,gs() { git status "$@"; } # status' "Zsh punctuation and comments should be preserved"
    # shellcheck disable=SC2016
    assert_contains "$result" 'function anonymous() {printf "%s\n" "$1";}' "anonymous function alias should be unwrapped"
    assert_contains "$result" '  function indented() { printf "%s\n" "$@"; }' "indentation and escaped quotes should be preserved"
    [[ "$(tail -n 1 "$target_file")" == 'function trailing() { printf trailing "$@"; }' ]] || {
        printf 'ASSERTION FAILED: converted line should not retain trailing whitespace\n' >&2
        exit 1
    }
    zsh -n "$target_file"
}

test_portable_profile_function_and_arguments() {
    local test_dir
    local target_file
    local output

    test_dir=$(new_test_environment "portable-profile")
    target_file="${test_dir}/.profile"
    cat <<'EOF' >"$target_file"
alias greeting='printf "hello:%s\n"'
EOF

    bash "$CONVERT_ALIASES_SH" "$target_file" >/dev/null
    assert_contains "$(<"$target_file")" 'greeting() { printf "hello:%s\n" "$@"; }' "profiles should use portable function syntax"
    sh -n "$target_file"
    output=$(sh -c '. "$1"; greeting world' sh "$target_file")
    [[ "$output" == "hello:world" ]] || {
        printf 'ASSERTION FAILED: converted function should forward arguments\nActual output: %s\n' "$output" >&2
        exit 1
    }
}

test_default_directory_only_processes_shell_sources() {
    local test_dir
    local test_home
    local shell_file
    local documentation_file
    local application_config

    test_dir=$(new_test_environment "default-directory")
    test_home="${test_dir}/home"
    shell_file="${test_home}/dotfiles/parts/shell/aliases.zsh"
    documentation_file="${test_home}/dotfiles/docs/example.md"
    application_config="${test_home}/dotfiles/parts/application/ranger/rc.conf"
    printf '%s\n' "alias short='printf short'" >"$shell_file"
    printf '%s\n' "alias example='documentation only'" >"$documentation_file"
    printf '%s\n' 'alias q quit' >"$application_config"

    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$CONVERT_ALIASES_SH" >/dev/null

    assert_contains "$(<"$shell_file")" 'function short()' "configured shell source should be converted"
    assert_file_equals "alias example='documentation only'" "$documentation_file" "Markdown examples should not be converted"
    assert_file_equals 'alias q quit' "$application_config" "application-specific alias syntax should not be converted"
}

test_unsupported_aliases_warn_and_remain_unchanged() {
    local test_dir
    local target_file
    local original_content
    local output

    test_dir=$(new_test_environment "unsupported")
    target_file="${test_dir}/unsupported.zsh"
    cat <<'EOF' >"$target_file"
alias "dynamic_${theme}"='apply-theme'
alias -g PIPE='|'
alias first=one second=two
alias empty=''
alias reload='source ~/.zshrc'
alias dot_reload='. ~/.profile'
EOF
    original_content=$(<"$target_file")

    output=$(bash "$CONVERT_ALIASES_SH" "$target_file" 2>&1)

    assert_contains "$output" "dynamic or quoted alias names are not supported" "dynamic names should warn"
    assert_contains "$output" "alias options are not supported" "alias options should warn"
    assert_contains "$output" "multiple alias declarations are not supported" "multiple declarations should warn"
    assert_contains "$output" "empty alias values are not supported" "empty values should warn"
    assert_contains "$output" "aliases that source files cannot preserve top-level shell scope as functions" "source aliases should warn"
    assert_contains "$output" "No alias declarations needed conversion." "unchanged input should be reported"
    assert_file_equals "$original_content" "$target_file" "unsupported aliases should stay unchanged"
    [[ ! -e "${target_file}.orig" ]] || {
        printf 'ASSERTION FAILED: unchanged file should not have a backup\n' >&2
        exit 1
    }
}

test_dry_run_backups_and_mode_preservation() {
    local test_dir
    local target_file
    local original_content
    local initial_mode
    local output

    test_dir=$(new_test_environment "dry-run-backup-mode")
    target_file="${test_dir}/aliases.zsh"
    printf '%s\n' "alias checked='printf checked'" >"$target_file"
    chmod 754 "$target_file"
    original_content=$(<"$target_file")
    initial_mode=$(get_file_mode "$target_file")

    output=$(bash "$CONVERT_ALIASES_SH" --dry-run "$target_file")
    assert_contains "$output" "Would update $target_file" "dry run should report a pending update"
    assert_file_equals "$original_content" "$target_file" "dry run should not modify content"
    [[ ! -e "${target_file}.orig" ]] || {
        printf 'ASSERTION FAILED: dry run should not create a backup\n' >&2
        exit 1
    }

    bash "$CONVERT_ALIASES_SH" "$target_file" >/dev/null
    [[ -f "${target_file}.orig" ]] || {
        printf 'ASSERTION FAILED: conversion should create a backup\n' >&2
        exit 1
    }
    [[ "$(get_file_mode "$target_file")" == "$initial_mode" ]] || {
        printf 'ASSERTION FAILED: conversion should preserve the file mode\n' >&2
        exit 1
    }
}

test_zsh_alias_variants
test_portable_profile_function_and_arguments
test_default_directory_only_processes_shell_sources
test_unsupported_aliases_warn_and_remain_unchanged
test_dry_run_backups_and_mode_preservation

printf 'convert_aliases_to_functions regression tests passed\n'
