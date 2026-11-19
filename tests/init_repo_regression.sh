#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENVMAKER_SH="$REPO_ROOT/envmaker.sh"
# Passing runs release fixtures; failures retain the suite root for inspection.
# shellcheck source=tests/fixture_lifecycle.sh
source "$REPO_ROOT/tests/fixture_lifecycle.sh"
fixture_suite envmaker-init. "$@"
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state" XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export TERM=dumb
mkdir -p "$HOME"

fail() {
    printf 'ASSERTION FAILED: %s (fixtures: %s)\n' "$1" "$TEST_ROOT" >&2
    exit 1
}

expect_failure() {
    local expected="$1"
    local output
    shift
    if output=$(bash "$ENVMAKER_SH" "$@" 2>&1); then
        fail "command should fail: $*"
    fi
    [[ "$output" == *"$expected"* ]] || fail "missing diagnostic '$expected': $output"
}

test_init_creates_usable_repo_without_config() {
    local destination="$TEST_ROOT/nested/new dotfiles"
    local output
    local item

    bash "$ENVMAKER_SH" init "$destination"
    [[ -d "$destination/.git" ]] || fail 'init must create a Git repository'
    for item in README.md docs/getting_started.md common/.gitkeep parts/.gitkeep rules/.gitkeep; do
        cmp "$REPO_ROOT/templates/dotfiles/$item" "$destination/$item" || fail "template differs: $item"
    done
    [[ ! -e "$XDG_CONFIG_HOME/dotfiletracker/config" ]] || fail 'init must not create configuration'
    [[ -z "$(git -C "$destination" remote)" ]] || fail 'init must not add a remote'
    if git -C "$destination" rev-parse --verify HEAD >/dev/null 2>&1; then
        fail 'init must not commit files'
    fi
    output=$(bash "$ENVMAKER_SH" --dotfiles-dir "$destination" listdirs)
    [[ "$output" == *"$destination/common"* ]] || fail 'new common directory must be discoverable'
    output=$(bash "$ENVMAKER_SH" --dotfiles-dir "$destination" --yes --dry-run execstow stow)
    [[ "$output" == *'Would process 0 file(s) in 0 package(s)'* ]] || fail 'placeholders must not be stowed'

    # Also validate the documented package nesting with a real link in a fake home.
    mkdir -p "$destination/common/example/.config/example"
    printf 'example\n' >"$destination/common/example/.config/example/config"
    bash "$ENVMAKER_SH" --dotfiles-dir "$destination" --yes execstow stow
    [[ -L "$HOME/.config/example/config" ]] || fail 'documented package layout must link to the home'
    cmp "$destination/common/example/.config/example/config" "$HOME/.config/example/config" || fail 'link must resolve'
}

test_init_preserves_existing_git_and_config() {
    local destination="$TEST_ROOT/empty-clone"
    local configured="$TEST_ROOT/configured"

    mkdir -p "$configured" "$XDG_CONFIG_HOME/dotfiletracker"
    printf 'dotfiles_dir=%s\n' "$configured" >"$XDG_CONFIG_HOME/dotfiletracker/config"
    cp "$XDG_CONFIG_HOME/dotfiletracker/config" "$TEST_ROOT/config.before"
    git init --quiet "$destination"
    git -C "$destination" remote add origin https://example.invalid/dotfiles.git
    cp "$destination/.git/config" "$TEST_ROOT/git.before"
    bash "$ENVMAKER_SH" init "$destination"
    cmp "$TEST_ROOT/git.before" "$destination/.git/config" || fail 'existing Git config must remain unchanged'
    cmp "$TEST_ROOT/config.before" "$XDG_CONFIG_HOME/dotfiletracker/config" || fail 'default configuration must remain unchanged'
    [[ -z "$(find "$configured" -mindepth 1 -print -quit)" ]] || fail 'configured tree must remain unchanged'
    expect_failure 'empty except for .git' init "$destination"
}

test_init_dry_run_paths_and_help() {
    local output

    output=$(bash "$ENVMAKER_SH" --dry-run init "$TEST_ROOT/missing/target")
    [[ "$output" == *'Would initialize dotfiles repository'* ]] || fail 'dry-run must show its action'
    [[ ! -e "$TEST_ROOT/missing" ]] || fail 'dry-run must not create parent directories'
    mkdir -p "$TEST_ROOT/empty"
    bash "$ENVMAKER_SH" -n init "$TEST_ROOT/empty"
    [[ -z "$(find "$TEST_ROOT/empty" -mindepth 1 -print -quit)" ]] || fail 'dry-run must leave an existing directory empty'
    (
        cd "$TEST_ROOT"
        bash "$ENVMAKER_SH" init 'relative [repo]'
    )
    [[ -f "$TEST_ROOT/relative [repo]/README.md" ]] || fail 'relative paths with glob characters must work'
    # Pass a literal tilde to test envmaker's own expansion.
    # shellcheck disable=SC2088
    bash "$ENVMAKER_SH" init '~/tilde-repo'
    [[ -f "$HOME/tilde-repo/README.md" ]] || fail 'quoted tilde paths must expand'
    output=$(bash "$ENVMAKER_SH" init --help)
    [[ "$output" == *'Usage:'* ]] || fail 'init help must work'
    output=$(bash "$ENVMAKER_SH" --help)
    [[ "$output" == *'init PATH'* ]] || fail 'main help must list init'
}

test_init_rejects_invalid_and_occupied_destinations() {
    local mode
    local destination="$TEST_ROOT/occupied"

    expect_failure 'Usage:' init
    expect_failure 'Usage:' init ''
    expect_failure 'Usage:' init one two
    expect_failure 'Usage:' init --unknown
    expect_failure 'use PATH instead of --dotfiles-dir' --dotfiles-dir "$destination" init "$destination"
    mkdir -p "$destination" "$TEST_ROOT/bad-git/.git"
    printf 'keep me\n' >"$destination/.hidden"
    printf 'keep me\n' >"$TEST_ROOT/file"
    ln -s "$TEST_ROOT/empty" "$TEST_ROOT/link"
    ln -s "$TEST_ROOT/absent" "$TEST_ROOT/dangling"
    for mode in --yes --dry-run; do
        expect_failure 'empty except for .git' "$mode" init "$destination"
        expect_failure 'not a file or symlink' "$mode" init "$TEST_ROOT/file"
        expect_failure 'not a file or symlink' "$mode" init "$TEST_ROOT/link"
        expect_failure 'not a file or symlink' "$mode" init "$TEST_ROOT/dangling"
        expect_failure 'invalid Git repository' "$mode" init "$TEST_ROOT/bad-git"
    done
    [[ "$(cat "$destination/.hidden")" == 'keep me' ]] || fail 'hidden files must survive rejection'
    [[ ! -e "$destination/common" ]] || fail 'rejection must not partially scaffold'
    expect_failure '' init "$TEST_ROOT/file/child"
    [[ "$(cat "$TEST_ROOT/file")" == 'keep me' ]] || fail 'failed parent creation must preserve the file'
}

test_init_reports_git_failure() {
    local output

    mkdir -p "$TEST_ROOT/fake-bin"
    printf '#!/bin/sh\nexit 23\n' >"$TEST_ROOT/fake-bin/git"
    chmod +x "$TEST_ROOT/fake-bin/git"
    if output=$(PATH="$TEST_ROOT/fake-bin:$PATH" bash "$ENVMAKER_SH" init "$TEST_ROOT/git-fails" 2>&1); then
        fail 'Git failure must not report success'
    fi
    [[ "$output" != *'Initialized dotfiles repository'* ]] || fail 'Git failure must not print a success message'
    [[ "$output" == *'Git initialization failed'* ]] || fail 'Git failure must produce a diagnostic'
    [[ -f "$TEST_ROOT/git-fails/README.md" ]] || fail 'partial output must remain available for inspection'
}

test_init_creates_usable_repo_without_config
test_init_preserves_existing_git_and_config
test_init_dry_run_paths_and_help
test_init_rejects_invalid_and_occupied_destinations
test_init_reports_git_failure

printf 'init repository regression tests passed\n'
