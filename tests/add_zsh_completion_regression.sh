#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
ADD_COMPLETION_SH="${REPO_ROOT}/util/add-zsh-completion.sh"
TEST_ROOT=$(mktemp -d)
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
        echo "ASSERTION FAILED: $message"
        echo "Expected to find: $needle"
        exit 1
    fi
}

new_test_environment() {
    local name="$1"
    local test_dir="${TEST_ROOT}/${name}"

    mkdir -p \
        "${test_dir}/home/.config/dotfiletracker" \
        "${test_dir}/home/dotfiles/parts/application"
    # This intentionally writes a literal variable for the script to expand.
    # shellcheck disable=SC2016
    printf '%s\n' 'dotfiles_dir="$HOME/dotfiles"' \
        > "${test_dir}/home/.config/dotfiletracker/config"
    printf '%s\n' "$test_dir"
}

write_fake_stow() {
    local fake_stow="$1"

    # The fake script expands these variables when it is executed.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'printf "cwd=%s\n" "$PWD" > "$STOW_LOG"' \
        'printf "arg=%s\n" "$@" >> "$STOW_LOG"' \
        > "$fake_stow"
    chmod +x "$fake_stow"
}

test_saves_exact_input_and_stows_completion_package() {
    local test_dir
    local test_home
    local dotfiles_dir
    local completion_file
    local expected_file
    local fake_stow
    local stow_log
    local stow_output
    local output

    test_dir=$(new_test_environment "save-and-stow")
    test_home="${test_dir}/home"
    dotfiles_dir="${test_home}/dotfiles"
    completion_file="${dotfiles_dir}/parts/application/exampletool/completions/.shellinclude/completions_exampletool.sh"
    expected_file="${test_dir}/expected"
    fake_stow="${test_dir}/stow"
    stow_log="${test_dir}/stow.log"
    printf '#compdef exampletool\n_complete_exampletool() { :; }\n' > "$expected_file"
    write_fake_stow "$fake_stow"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" \
            DOTFILETRACKER_STOW_EXEC="$fake_stow" \
            STOW_LOG="$stow_log" \
            bash "$ADD_COMPLETION_SH" exampletool < "$expected_file"
    )"

    cmp "$expected_file" "$completion_file"
    assert_contains "$output" "Saved Zsh completion: $completion_file" "the saved path should be reported"
    assert_contains "$output" "available to new Zsh sessions" "successful Stow should be reported"

    stow_output=$(<"$stow_log")
    assert_contains \
        "$stow_output" \
        "cwd=${dotfiles_dir}/parts/application/exampletool" \
        "Stow should run from the command package directory"
    assert_contains "$stow_output" "arg=--target=$test_home" "Stow should target the test home"
    assert_contains "$stow_output" "arg=--restow" "the completion package should be restowed"
    assert_contains "$stow_output" "arg=completions" "only the completions package should be restowed"
}

test_refuses_overwrite_without_force() {
    local test_dir
    local test_home
    local completion_file
    local output

    test_dir=$(new_test_environment "overwrite")
    test_home="${test_dir}/home"
    completion_file="${test_home}/dotfiles/parts/application/demo/completions/.shellinclude/completions_demo.sh"

    printf 'old completion\n' |
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$ADD_COMPLETION_SH" --no-stow demo >/dev/null

    if output="$(
        printf 'new completion\n' |
            HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$ADD_COMPLETION_SH" --no-stow demo 2>&1
    )"; then
        echo "ASSERTION FAILED: a different existing completion should require --force"
        exit 1
    fi

    assert_contains "$output" "use --force" "overwrite error should explain how to replace the file"
    [[ "$(<"$completion_file")" == "old completion" ]] || {
        echo "ASSERTION FAILED: refused overwrite should preserve the original completion"
        exit 1
    }

    printf 'new completion\n' |
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$ADD_COMPLETION_SH" --no-stow --force demo >/dev/null
    [[ "$(<"$completion_file")" == "new completion" ]] || {
        echo "ASSERTION FAILED: --force should replace the completion"
        exit 1
    }
}

test_rejects_empty_input_and_unsafe_command_name() {
    local test_dir
    local test_home
    local output

    test_dir=$(new_test_environment "invalid-input")
    test_home="${test_dir}/home"

    if output="$(HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$ADD_COMPLETION_SH" --no-stow empty </dev/null 2>&1)"; then
        echo "ASSERTION FAILED: empty completion input should fail"
        exit 1
    fi
    assert_contains "$output" "No completion content" "empty input should produce a clear error"

    if output="$(
        printf 'completion\n' |
            HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" bash "$ADD_COMPLETION_SH" --no-stow ../escape 2>&1
    )"; then
        echo "ASSERTION FAILED: a command name containing a path should fail"
        exit 1
    fi
    assert_contains "$output" "Invalid command name" "unsafe command names should produce a clear error"
    [[ ! -e "${test_home}/dotfiles/parts/escape" ]] || {
        echo "ASSERTION FAILED: unsafe command names must not write outside their package"
        exit 1
    }
}

test_stack_source_destination_and_reconciliation() (
    local test_dir="$TEST_ROOT/stack"
    export HOME="$test_dir/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
    local generic="$test_dir/generic" personal="$test_dir/personal" output
    local relative='parts/application/printf/completions/.shellinclude/completions_printf.sh'
    mkdir -p "$XDG_CONFIG_HOME/dotfiletracker" "$generic/parts/application" "$personal/parts/application"
    printf 'source.generic=%s\nsource.personal=%s\n' "$generic" "$personal" > "$XDG_CONFIG_HOME/dotfiletracker/config"
    printf '#compdef printf\n_complete_printf() { :; }\n' > "$test_dir/input"
    if output=$(bash "$ADD_COMPLETION_SH" --no-stow printf < "$test_dir/input" 2>&1); then
        echo 'ASSERTION FAILED: stack completion requires a named source'
        exit 1
    fi
    assert_contains "$output" 'require --source' 'missing source is explicit'
    bash "$ADD_COMPLETION_SH" --source personal --dry-run printf < "$test_dir/input" >/dev/null
    [[ ! -e "$personal/$relative" && ! -e "$HOME/.dotfiletracker-lock" && ! -e "$XDG_STATE_HOME" ]]
    bash "$ADD_COMPLETION_SH" --source personal printf < "$test_dir/input" > "$test_dir/first.log"
    cmp "$test_dir/input" "$personal/$relative"
    cmp "$test_dir/input" "$HOME/.shellinclude/completions_printf.sh"
    [[ ! -e "$generic/$relative" && -L "$HOME/.shellinclude/completions_printf.sh" ]]
    if output=$(XDG_STATE_HOME="$test_dir/other-state" bash "$ADD_COMPLETION_SH" --dotfiles-dir "$generic" --no-stow printf < "$test_dir/input" 2>&1); then
        echo 'ASSERTION FAILED: nested completion reconciliation must retain stack ownership'
        exit 1
    fi
    assert_contains "$output" 'Stack owns this target' 'outer writer preserves nested apply ownership against legacy override'
    if output=$(XDG_STATE_HOME="$test_dir/other-state" bash "$ADD_COMPLETION_SH" --source generic --no-stow printf < "$test_dir/input" 2>&1); then
        echo 'ASSERTION FAILED: alternate state must not bypass nested published ownership'
        exit 1
    fi
    assert_contains "$output" 'different stack state' 'published ownership survives outer guard completion'
    # A lower-source write must reconcile the stack, preserving personal priority.
    printf '#compdef printf\n# lower version\n' > "$test_dir/lower"
    bash "$ADD_COMPLETION_SH" --source generic printf < "$test_dir/lower" > "$test_dir/lower.log"
    cmp "$test_dir/lower" "$generic/$relative"
    cmp "$test_dir/input" "$HOME/.shellinclude/completions_printf.sh"
    # no-stow still uses the same ownership preflight and lock.
    printf '#compdef printf\n# saved only\n' > "$test_dir/next"
    bash "$ADD_COMPLETION_SH" --source personal --no-stow --force printf < "$test_dir/next" >/dev/null
    cmp "$test_dir/next" "$personal/$relative"
    if output=$(bash "$ADD_COMPLETION_SH" --source missing --no-stow printf < "$test_dir/input" 2>&1); then
        echo 'ASSERTION FAILED: unknown destination source must fail'
        exit 1
    fi
    assert_contains "$output" 'Unknown destination source' 'unknown source refusal'
    mkdir -p "$test_dir/outside/completions/.shellinclude"
    ln -s "$test_dir/outside" "$personal/parts/application/true"
    if output=$(bash "$ADD_COMPLETION_SH" --source personal --no-stow true < "$test_dir/input" 2>&1); then
        echo 'ASSERTION FAILED: completion destination must stay inside its selected source'
        exit 1
    fi
    assert_contains "$output" 'escaped its selected source' 'source ancestor symlink escape is refused'
    [[ ! -e "$test_dir/outside/completions/.shellinclude/completions_true.sh" ]]
    # A replacement target blocks writing even with --no-stow and --force.
    mv "$HOME/.shellinclude/completions_printf.sh" "$test_dir/original-link"
    printf 'human replacement\n' > "$HOME/.shellinclude/completions_printf.sh"
    if output=$(bash "$ADD_COMPLETION_SH" --source personal --no-stow --force printf < "$test_dir/input" 2>&1); then
        echo 'ASSERTION FAILED: completion writer must preserve replaced home targets'
        exit 1
    fi
    assert_contains "$output" 'preserving replacement' 'completion uses lifecycle ownership preflight'
    cmp "$test_dir/next" "$personal/$relative"
)

test_saves_exact_input_and_stows_completion_package
test_refuses_overwrite_without_force
test_rejects_empty_input_and_unsafe_command_name
test_stack_source_destination_and_reconciliation

echo "add-zsh-completion regression tests passed"
