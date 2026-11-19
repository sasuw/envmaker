#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
REMOVE_KEYWORD_SH="${REPO_ROOT}/util/remove_function_keyword.sh"
# shellcheck source=tests/fixture_lifecycle.sh
source "$REPO_ROOT/tests/fixture_lifecycle.sh"
fixture_suite remove-function. "$@"
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "ASSERTION FAILED: $message"
        echo "Expected to find: $needle"
        echo "Actual output: $haystack"
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ASSERTION FAILED: $message"
        echo "Did not expect to find: $needle"
        echo "Actual output: $haystack"
        exit 1
    fi
}

new_test_environment() {
    local name="$1"
    local test_dir="${TEST_ROOT}/${name}"

    mkdir -p \
        "${test_dir}/home/.config/dotfiletracker" \
        "${test_dir}/home/dotfiles/parts/shell"
    # shellcheck disable=SC2016
    printf '%s\n' 'dotfiles_dir="$HOME/dotfiles"' \
        > "${test_dir}/home/.config/dotfiletracker/config"
    printf '%s\n' "$test_dir"
}

get_file_mode() {
    local path="$1"
    stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo "unknown"
}

test_configured_directory_default() {
    local test_dir
    local test_home
    local dotfiles_dir
    local target_file
    local output

    test_dir=$(new_test_environment "default-dir")
    test_home="${test_dir}/home"
    dotfiles_dir="${test_home}/dotfiles"
    target_file="${dotfiles_dir}/parts/shell/helpers.sh"

    cat <<'EOF' > "$target_file"
function helper_one {
    echo "one"
}
EOF

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" \
            bash "$REMOVE_KEYWORD_SH"
    )"

    assert_contains "$output" "Updated $target_file" "output should report file updated"
    assert_contains "$(<"$target_file")" "helper_one() {" "function keyword should be removed"
    [[ -f "${target_file}.orig" ]] || {
        echo "ASSERTION FAILED: backup file should be created"
        exit 1
    }
    assert_contains "$(<"${target_file}.orig")" "function helper_one {" "original should be in backup"
}

test_explicit_single_file() {
    local test_dir
    local test_home
    local file_a
    local file_b
    local output

    test_dir=$(new_test_environment "single-file")
    test_home="${test_dir}/home"
    file_a="${test_dir}/file_a.sh"
    file_b="${test_dir}/file_b.sh"

    echo "function func_a { echo a; }" > "$file_a"
    echo "function func_b { echo b; }" > "$file_b"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" \
            bash "$REMOVE_KEYWORD_SH" "$file_a"
    )"

    assert_contains "$output" "Updated $file_a" "output should report file_a updated"
    assert_not_contains "$output" "file_b" "file_b should not be mentioned"
    assert_contains "$(<"$file_a")" "func_a() { echo a; }" "file_a should be transformed"
    assert_contains "$(<"$file_b")" "function func_b { echo b; }" "file_b should be untouched"
}

test_explicit_directory_tree() {
    local test_dir
    local test_home
    local tree_dir
    local nested_file
    local output

    test_dir=$(new_test_environment "dir-tree")
    test_home="${test_dir}/home"
    tree_dir="${test_dir}/custom_tree"
    nested_file="${tree_dir}/sub/deep/script.zsh"

    mkdir -p "$(dirname "$nested_file")"
    cat <<'EOF' > "$nested_file"
function nested_func() {
    echo "nested"
}
EOF

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" \
            bash "$REMOVE_KEYWORD_SH" "$tree_dir"
    )"

    assert_contains "$output" "Updated $nested_file" "output should report nested file updated"
    assert_contains "$(<"$nested_file")" "nested_func() {" "nested function should be transformed"
}

test_transformation_variants_and_unchanged_content() {
    local test_dir
    local test_home
    local target_file
    local output

    test_dir=$(new_test_environment "variants")
    test_home="${test_dir}/home"
    target_file="${test_dir}/variants.sh"

    cat <<'EOF' > "$target_file"
function func_brace {
    echo 1
}

  function func_parens_brace() {
    echo 2
}

function func_space_parens () { # inline comment
    echo 3
}

function func_oneline { return 0; }
function func_oneline_parens() { return 0; }

function func_separate_brace
{
    echo 4
}

# function comment_func {
#     echo "comment"
# }

echo "function string_func {"

already_native() {
    echo 5
}

function=variable_assign
EOF

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" \
            bash "$REMOVE_KEYWORD_SH" "$target_file"
    )"

    assert_contains "$output" "Updated $target_file" "output should report file updated"

    local result
    result="$(<"$target_file")"

    assert_contains "$result" "func_brace() {" "func_brace transformed"
    assert_contains "$result" "  func_parens_brace() {" "func_parens_brace transformed preserving indent"
    assert_contains "$result" "func_space_parens() { # inline comment" "func_space_parens transformed preserving comment"
    assert_contains "$result" "func_oneline() { return 0; }" "func_oneline transformed"
    assert_contains "$result" "func_oneline_parens() { return 0; }" "func_oneline_parens transformed"
    assert_contains "$result" "func_separate_brace()" "func_separate_brace transformed"
    assert_contains "$result" "# function comment_func {" "comment line preserved unchanged"
    assert_contains "$result" 'echo "function string_func {"' "string line preserved unchanged"
    assert_contains "$result" "already_native() {" "already native preserved unchanged"
    assert_contains "$result" "function=variable_assign" "variable assignment preserved unchanged"
}

test_dry_run_does_not_modify_files_or_create_backups() {
    local test_dir
    local test_home
    local target_file
    local original_content
    local output

    test_dir=$(new_test_environment "dry-run")
    test_home="${test_dir}/home"
    target_file="${test_dir}/dryrun.sh"

    cat <<'EOF' > "$target_file"
function dry_run_func {
    echo "test"
}
EOF
    original_content="$(<"$target_file")"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" \
            bash "$REMOVE_KEYWORD_SH" -n "$target_file"
    )"

    assert_contains "$output" "Would update $target_file" "dry run should report would update"
    [[ "$(<"$target_file")" == "$original_content" ]] || {
        echo "ASSERTION FAILED: dry run must not modify target file"
        exit 1
    }
    [[ ! -e "${target_file}.orig" ]] || {
        echo "ASSERTION FAILED: dry run must not create backup file"
        exit 1
    }
}

test_mode_preservation_and_incremental_backups() {
    local test_dir
    local test_home
    local target_file
    local initial_mode
    local final_mode

    test_dir=$(new_test_environment "mode-and-backups")
    test_home="${test_dir}/home"
    target_file="${test_dir}/script_with_mode.sh"

    echo "function first_func { echo 1; }" > "$target_file"
    chmod 754 "$target_file"
    initial_mode=$(get_file_mode "$target_file")

    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$REMOVE_KEYWORD_SH" "$target_file"

    final_mode=$(get_file_mode "$target_file")
    [[ "$final_mode" == "$initial_mode" ]] || {
        echo "ASSERTION FAILED: file mode should be preserved ($initial_mode vs $final_mode)"
        exit 1
    }
    [[ -f "${target_file}.orig" ]] || {
        echo "ASSERTION FAILED: first backup .orig should exist"
        exit 1
    }

    # Introduce another function keyword to trigger a second update
    echo "function second_func { echo 2; }" >> "$target_file"
    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$REMOVE_KEYWORD_SH" "$target_file"

    [[ -f "${target_file}.orig.1" ]] || {
        echo "ASSERTION FAILED: second backup .orig.1 should exist"
        exit 1
    }
}

test_configured_directory_default
test_explicit_single_file
test_explicit_directory_tree
test_transformation_variants_and_unchanged_content
test_dry_run_does_not_modify_files_or_create_backups
test_mode_preservation_and_incremental_backups

echo "remove_function_keyword regression tests passed"
