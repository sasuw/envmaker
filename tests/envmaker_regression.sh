#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd -P
)"
ENVMAKER_SH="${REPO_ROOT}/envmaker.sh"
REGRESSION_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/envmaker-legacy.XXXXXX")
trap 'rm -rf "${REGRESSION_ROOT:?}"' EXIT
export HOME="$REGRESSION_ROOT/home"
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "ASSERTION FAILED: $message"
        echo "Did not expect to find: $needle"
        exit 1
    fi
}

fail() {
    echo "ASSERTION FAILED: $1"
    exit 1
}

write_dotfiles_config() {
    local test_home="$1"
    local dotfiles_dir="$2"

    mkdir -p "${test_home}/.config/dotfiletracker"
    printf 'dotfiles_dir=%s\n' "$dotfiles_dir" > "${test_home}/.config/dotfiletracker/config"
}

test_debug_does_not_imply_dry_run() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts/ostype/linux"
    mkdir -p "${dotfiles_dir}/parts/ostype/macos"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" -d listdirs
    )"

    assert_contains "$output" "Debug mode on" "debug output should be enabled"
    assert_not_contains \
        "$output" \
        "Running in dry run mode, no real changes are made." \
        "--debug alone must not announce dry-run mode"
}

test_config_file_sets_dotfiles_directory() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${test_home}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common"
    mkdir -p "${test_home}/.config/dotfiletracker"
    printf '%s\n' 'dotfiles_dir="$HOME/dotfiles"' > "${test_home}/.config/dotfiletracker/config"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" listdirs
    )"

    assert_contains "$output" "${dotfiles_dir}/common" "listdirs should use the configured dotfiles directory and expand HOME"
}

test_dotfiles_directory_argument_is_required_without_config() {
    local tmpdir
    local test_home
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    mkdir -p "$test_home"

    if output="$(HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" listdirs 2>&1)"; then
        echo "ASSERTION FAILED: listdirs should fail without config or --dotfiles-dir"
        exit 1
    fi

    assert_contains "$output" "Dotfiles directory is not configured." "missing config should produce a clear error"
    assert_contains "$output" "--dotfiles-dir PATH" "missing config error should mention the argument fallback"
}

test_dotfiles_directory_argument_sets_dotfiles_directory() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/argument-dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --dotfiles-dir "$dotfiles_dir" listdirs
    )"

    assert_contains "$output" "${dotfiles_dir}/common" "listdirs should use --dotfiles-dir when no config exists"
}

test_backup_scan_recursively_checks_nested_package_files() {
    local tmpdir
    local test_home
    local workdir
    local helper_source
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    workdir="${tmpdir}/packages"
    helper_source="${tmpdir}/backup_helpers.sh"

    mkdir -p "$test_home/.m2" "$workdir/shellpkg" "$workdir/mvn/settings/.m2"
    printf 'existing shell rc\n' > "$test_home/.zshrc"
    printf 'existing m2 settings\n' > "$test_home/.m2/settings.xml"
    printf 'package shell rc\n' > "$workdir/shellpkg/.zshrc"
    printf 'package m2 settings\n' > "$workdir/mvn/settings/.m2/settings.xml"
    printf '# ignored by stow\n' > "$workdir/mvn/settings/.stow-local-ignore"

    sed -n '/^BACKUP_CONFLICTS_FOUND=0$/,/^DEBUG_MODE=0$/p' "$ENVMAKER_SH" | sed '$d' > "$helper_source"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" WORKDIR="$workdir" HELPER_SOURCE="$helper_source" bash <<'EOF'
set -euo pipefail

source "$HELPER_SOURCE"

bold=""
boldend=""
DRY_RUN=1

cd "$WORKDIR"

top_output_file="$(mktemp)"
nested_output_file="$(mktemp)"
trap 'rm -f "$top_output_file" "$nested_output_file"' EXIT

BACKUP_CONFLICTS_FOUND=0
backup_conflicting_targets_for_package shellpkg > "$top_output_file"
printf 'top_conflicts=%s\n' "$BACKUP_CONFLICTS_FOUND"
cat "$top_output_file"

BACKUP_CONFLICTS_FOUND=0
backup_conflicting_targets_for_package "mvn/settings" > "$nested_output_file"
printf 'nested_conflicts=%s\n' "$BACKUP_CONFLICTS_FOUND"
cat "$nested_output_file"
EOF
    )"

    assert_contains "$output" "top_conflicts=1" "top-level conflicts should still be detected"
    assert_contains "$output" ".zshrc" "top-level backup output should mention the conflicting file"
    assert_contains "$output" "nested_conflicts=1" "nested package files must trigger backup scanning"
    assert_contains "$output" ".m2/settings.xml" "nested conflicts must be announced for backup"
    [[ -f "$test_home/.m2/settings.xml" ]] || {
        echo "ASSERTION FAILED: dry run must not move the conflicting file"
        exit 1
    }
    [[ ! -e "$test_home/.m2/settings.xml.orig" ]] || {
        echo "ASSERTION FAILED: dry run must not create a backup file"
        exit 1
    }

    # Perform a real backup run to verify nested file is moved
    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" WORKDIR="$workdir" HELPER_SOURCE="$helper_source" bash <<'EOF'
set -euo pipefail

source "$HELPER_SOURCE"

bold=""
boldend=""
DRY_RUN=0

cd "$WORKDIR"

BACKUP_CONFLICTS_FOUND=0
backup_conflicting_targets_for_package "mvn/settings" >/dev/null
[[ "$BACKUP_CONFLICTS_FOUND" -eq 1 ]] || exit 1
EOF

    [[ -f "$test_home/.m2/settings.xml.orig" ]] || {
        echo "ASSERTION FAILED: real run must move conflicting nested file to .orig"
        exit 1
    }
    [[ "$(<"$test_home/.m2/settings.xml.orig")" == "existing m2 settings" ]] || {
        echo "ASSERTION FAILED: backup file content must match original"
        exit 1
    }
    [[ ! -f "$test_home/.m2/settings.xml" ]] || {
        echo "ASSERTION FAILED: original conflicting path must no longer be a regular file"
        exit 1
    }
}

test_restow_preserves_files_reached_through_folded_directory_symlinks() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local package_file
    local target_file
    local stow_bin
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    package_file="${dotfiles_dir}/common/foldedpkg/.config/foldedapp/config.toml"
    target_file="${test_home}/.config/foldedapp/config.toml"
    stow_bin="/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow"

    mkdir -p "${dotfiles_dir}/parts" "$(dirname "$package_file")"
    printf 'package config contents\n' > "$package_file"

    # $HOME/.config already real (as it would be once other packages are
    # stowed there), so real Stow folds only the next level down:
    # .config/foldedapp becomes a symlink straight into the package instead
    # of a real directory containing a per-file symlink. Bootstrapped with
    # the real stow binary directly, bypassing envmaker's own "stow" mkdir
    # pre-pass (which forces every directory in the package tree real and
    # would prevent folding) -- this reproduces the folded precondition the
    # way it actually accumulates in production, where only "restow" runs
    # against a package after its first stow.
    mkdir -p "${test_home}/.config"
    (cd "${dotfiles_dir}/common" && HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" "$stow_bin" --target="$test_home" --stow foldedpkg)

    [[ -L "${test_home}/.config/foldedapp" ]] || {
        echo "ASSERTION FAILED: precondition setup must create a folded directory symlink"
        exit 1
    }
    [[ "$target_file" -ef "$package_file" ]] || {
        echo "ASSERTION FAILED: precondition setup must make the target resolve to the package file"
        exit 1
    }

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --dotfiles-dir "$dotfiles_dir" --debug --yes execstow restow </dev/null
    )"

    assert_contains "$output" "--restow" "restow must actually run stow rather than skip it"
    assert_not_contains "$output" "Skipping Stow simulation" "restow must not be skipped for an already-folded target"
    assert_not_contains "$output" "Backing up existing file ${target_file}" "an already-stowed file reached through a folded directory symlink must not be treated as a conflict"

    [[ -f "$package_file" ]] || {
        echo "ASSERTION FAILED: package file must still exist after restow"
        exit 1
    }
    [[ "$(<"$package_file")" == "package config contents" ]] || {
        echo "ASSERTION FAILED: package file contents must be unchanged after restow"
        exit 1
    }
    [[ ! -e "${package_file}.orig" ]] || {
        echo "ASSERTION FAILED: restow must not create a .orig backup inside the package"
        exit 1
    }
    [[ "$target_file" -ef "$package_file" ]] || {
        echo "ASSERTION FAILED: target must still resolve to the package file after restow"
        exit 1
    }
}

test_restow_unfolds_directory_symlink_owned_by_another_part() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local owner_file
    local other_file
    local shared_dir
    local stow_bin
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    owner_file="${dotfiles_dir}/common/ownerpkg/.config/environment.d/90-owner.conf"
    other_file="${dotfiles_dir}/parts/role/otherpkg/.config/environment.d/89-other.conf"
    shared_dir="${test_home}/.config/environment.d"
    stow_bin="/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow"

    mkdir -p "$(dirname "$owner_file")" "$(dirname "$other_file")" "${dotfiles_dir}/rules"
    printf 'owner\n' > "$owner_file"
    printf 'other\n' > "$other_file"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dotfiles_dir}/rules/role"
    chmod +x "${dotfiles_dir}/rules/role"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    # common/ is its own Stow directory and is processed after parts/role,
    # so its folded link is foreign to the role part when that is stowed --
    # a cross-package folded-directory ownership case.
    mkdir -p "${test_home}/.config"
    (cd "${dotfiles_dir}/common" && HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" "$stow_bin" --target="$test_home" --stow ownerpkg)
    [[ -L "$shared_dir" ]] || fail "precondition setup must fold .config/environment.d into the common part"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes --dry-run execstow restow </dev/null 2>&1
    )" || fail "dry-run restow must succeed when another part owns a folded directory (output: ${output})"
    assert_contains "$output" "Would unfold directory symlink ${shared_dir}" "dry-run must announce the unfold"
    assert_not_contains "$output" "not owned by stow" "dry-run must not run into the Stow conflict"
    [[ -L "$shared_dir" ]] || fail "dry-run must leave the folded symlink in place"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow restow </dev/null 2>&1
    )" || fail "restow must succeed when another part owns a folded directory (output: ${output})"
    assert_contains "$output" "Unfolding directory symlink ${shared_dir}" "a real run must report the unfold"
    assert_not_contains "$output" "not owned by stow" "restow must not hit the Stow conflict"

    [[ -d "$shared_dir" && ! -L "$shared_dir" ]] || fail "the shared directory must become a real directory"
    [[ "${shared_dir}/90-owner.conf" -ef "$owner_file" ]] || fail "the owning part's file must stay linked"
    [[ "${shared_dir}/89-other.conf" -ef "$other_file" ]] || fail "the other part's file must be linked"
    [[ "$(readlink "${shared_dir}/90-owner.conf")" != /* ]] || fail "unfolded entries must use relative links like Stow"

    # A second restow must be a no-op that Stow accepts as its own links.
    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow restow </dev/null 2>&1
    )" || fail "a second restow must succeed (output: ${output})"
    assert_not_contains "$output" "Unfolding" "nothing is left to unfold on the second run"
    assert_not_contains "$output" "changed)" "the second restow must not change links"
}

test_restow_does_not_fold_new_directories() {
    local tmpdir
    local test_home
    local dotfiles_dir

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/newpkg/.config/newapp" "${test_home}/.config"
    printf 'new\n' > "${dotfiles_dir}/common/newpkg/.config/newapp/config"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    # restow, unlike stow, does not pre-create target directories, so
    # without --no-folding Stow would link .config/newapp as one symlink.
    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow restow >/dev/null </dev/null

    [[ -d "${test_home}/.config/newapp" && ! -L "${test_home}/.config/newapp" ]] \
        || fail "restow must create a real directory instead of folding it"
    [[ -L "${test_home}/.config/newapp/config" ]] || fail "restow must link the file itself"
}

test_non_interactive_without_yes_aborts_with_error() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts/ostype/linux/pkg1" "${dotfiles_dir}/common/basepkg"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    if output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --dry-run execstow stow </dev/null 2>&1
    )"; then
        echo "ASSERTION FAILED: non-interactive execstow without --yes should fail"
        exit 1
    fi

    assert_contains \
        "$output" \
        "envmaker.sh: confirmation required but stdin is not a TTY; pass --yes to continue" \
        "non-interactive confirmation without --yes should output actionable stderr message"
}

test_non_interactive_with_yes_and_batch_flags() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local flag
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts/ostype/linux/pkg1" "${dotfiles_dir}/common/basepkg"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    for flag in "--yes" "-y" "--batch" "-b"; do
        output="$(
            HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --dry-run "$flag" execstow stow </dev/null
        )"
        assert_contains "$output" "Dotfiles to process:" "execstow with $flag should process packages"
        assert_contains "$output" "Simulating stow" "execstow with $flag should simulate stow in dry-run mode"
    done

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" ASSUME_YES=1 TERM=dumb bash "$ENVMAKER_SH" --dry-run execstow stow </dev/null
    )"
    assert_contains "$output" "Dotfiles to process:" "execstow with ASSUME_YES=1 should process packages"
    assert_contains "$output" "Simulating stow" "execstow with ASSUME_YES=1 should simulate stow in dry-run mode"
}

test_restow_reports_only_changes() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    # Establish the baseline: a real (non-dry-run) stow.
    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow >/dev/null </dev/null

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow restow </dev/null
    )"
    assert_not_contains "$output" "Dotfiles to process:" "restowing an already-synced tree must not print the discovery table in normal mode"
    assert_not_contains "$output" "with command" "restowing an already-synced tree must not print the per-package stow announcement in normal mode"
    assert_contains "$output" "Processed 1 file(s) in 1 package(s) across 1 directory." "normal mode must still show a summary of what was processed, even with no changes"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --debug --yes execstow restow </dev/null
    )"
    assert_contains "$output" "Dotfiles to process:" "--debug must keep showing the discovery table"
    assert_contains "$output" "with command" "--debug must keep showing the per-package stow announcement"
    assert_contains "$output" "Processed 1 file(s) in 1 package(s) across 1 directory." "--debug must still show the processed-files summary"
}

test_verbose_flag_restores_full_output() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow >/dev/null </dev/null

    # Without --verbose, a normal restow on an already-synced tree stays quiet.
    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow restow </dev/null
    )"
    assert_not_contains "$output" "Dotfiles to process:" "restow without --verbose must not print the discovery table"
    assert_not_contains "$output" "with command" "restow without --verbose must not print the per-package stow announcement"

    # --verbose and its short form -v both restore the pre-quiet-mode output.
    for flag in "--verbose" "-v"; do
        output="$(
            HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" "$flag" --yes execstow restow </dev/null
        )"
        assert_contains "$output" "Dotfiles to process:" "$flag must show the discovery table"
        assert_contains "$output" "with command" "$flag must show the per-package stow announcement"
        assert_contains "$output" "Processed 1 file(s) in 1 package(s) across 1 directory." "$flag must still show the processed-files summary"
    done
}

test_stow_reports_linked_files_in_normal_mode() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow </dev/null
    )"
    assert_contains "$output" "Linked ${test_home}/.testrc" "fresh stow must report the newly linked target in normal mode"
    assert_contains "$output" "Processed 1 file(s) in 1 package(s) across 1 directory (1 changed)." "fresh stow summary must count the real change"
}

test_restow_reports_no_changes_for_synced_tree() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow >/dev/null </dev/null

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow restow </dev/null
    )"
    assert_not_contains "$output" "Linked " "no-op restow must not report Linked lines"
    assert_not_contains "$output" "Unlinked " "no-op restow must not report Unlinked lines"
    assert_not_contains "$output" "Relinked " "no-op restow must not report Relinked lines"
    assert_not_contains "$output" "changed)" "no-op restow summary must not claim changes"
    assert_contains "$output" "Processed 1 file(s) in 1 package(s) across 1 directory." "no-op restow must still show the plain summary line"
}

test_delete_reports_unlinked_files() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow >/dev/null </dev/null

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow delete </dev/null
    )"
    assert_contains "$output" "Unlinked ${test_home}/.testrc" "delete must report the removed target in normal mode"
    assert_contains "$output" "Processed 1 file(s) in 1 package(s) across 1 directory (1 changed)." "delete summary must count the real change"
    [[ ! -e "${test_home}/.testrc" && ! -L "${test_home}/.testrc" ]] || {
        echo "ASSERTION FAILED: delete must actually remove the target symlink"
        exit 1
    }
}

test_report_link_changes_flags_unlink_outside_delete_and_detects_relink() {
    local tmpdir
    local helper_source
    local before_file
    local after_file
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    helper_source="${tmpdir}/report_link_changes.sh"
    before_file="${tmpdir}/before"
    after_file="${tmpdir}/after"

    sed -n '/^report_link_changes() {$/,/^}$/p' "$ENVMAKER_SH" > "$helper_source"

    # /home/user/.stale was linked before and unexpectedly unlinked by a
    # non-delete run; /home/user/.moved was linked to pkgA's entry before and
    # now resolves to pkgB's entry (a relink); /home/user/.same is unchanged.
    printf '/home/user/.stale\tlinked:/dotfiles/pkgA/.stale\n' > "$before_file"
    printf '/home/user/.moved\tlinked:/dotfiles/pkgA/.moved\n' >> "$before_file"
    printf '/home/user/.same\tlinked:/dotfiles/pkgA/.same\n' >> "$before_file"

    printf '/home/user/.stale\tunlinked\n' > "$after_file"
    printf '/home/user/.moved\tlinked:/dotfiles/pkgB/.moved\n' >> "$after_file"
    printf '/home/user/.same\tlinked:/dotfiles/pkgA/.same\n' >> "$after_file"

    output="$(
        bash -c '
            set -euo pipefail
            source "$1"
            bold=""
            boldend=""
            changed_file_count=0
            report_link_changes "$2" "$3" "restow"
            echo "changed_file_count=${changed_file_count}"
        ' _ "$helper_source" "$before_file" "$after_file"
    )"

    assert_contains "$output" "Unlinked /home/user/.stale (unexpected outside delete)" \
        "an unlink outside 'delete' must be flagged as unexpected"
    assert_contains "$output" "Relinked /home/user/.moved" \
        "a target resolving to a different package entry must be reported as Relinked"
    assert_not_contains "$output" ".same" \
        "an unchanged target must not be reported"
    assert_contains "$output" "changed_file_count=2" \
        "only the two real changes must be counted"
}

test_restow_never_prompts_for_confirmation() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow >/dev/null </dev/null

    # Unlike stow/delete, restow must proceed without --yes even on a
    # non-TTY stdin: the interactive `restow` shell alias runs this with no
    # flags, and a confirmation prompt with nothing to confirm against
    # (the discovery table is hidden in normal mode) is just blind noise.
    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" execstow restow </dev/null 2>&1
    )"
    assert_not_contains "$output" "Do you wish to continue?" "restow must not prompt for confirmation"
    assert_not_contains "$output" "confirmation required but stdin is not a TTY" "restow must not require --yes on non-TTY stdin"
}

test_confirm_continue_helper_directly() {
    local helper_source="${REPO_ROOT}/bin/common.sh"
    local output

    output="$(
        ASSUME_YES=1 bash -c "source '$helper_source'; confirm_continue" </dev/null 2>&1
    )"
    if [[ -n "$output" ]]; then
        echo "ASSERTION FAILED: ASSUME_YES=1 confirm_continue should return silently"
        echo "Got output: $output"
        exit 1
    fi

    if output="$(
        bash -c "source '$helper_source'; confirm_continue" </dev/null 2>&1
    )"; then
        echo "ASSERTION FAILED: confirm_continue without TTY should fail"
        exit 1
    fi
    assert_contains \
        "$output" \
        "envmaker.sh: confirmation required but stdin is not a TTY; pass --yes to continue" \
        "confirm_continue should output actionable error on non-TTY"
}

test_post_stow_hooks_run_after_real_stow_only() {
    local tmpdir test_home dotfiles_dir hooks_dir marker output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    hooks_dir="${dotfiles_dir}/hooks/post-stow.d"
    marker="${tmpdir}/hook_ran"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg" "$hooks_dir"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s %%s\\n" "$1" "$DOTFILES_DIR" >> "%s"\n' "$marker"
        printf 'echo "hook says hello"\n'
    } > "${hooks_dir}/10-probe"
    chmod +x "${hooks_dir}/10-probe"

    # A non-executable file in the hook directory must be ignored, not run.
    printf '#!/usr/bin/env bash\ntouch "%s.bad"\n' "$marker" > "${hooks_dir}/20-not-executable"
    chmod -x "${hooks_dir}/20-not-executable"

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes --dry-run execstow stow </dev/null
    )"
    if [[ -e "$marker" ]]; then
        fail "post-stow hooks must not run in dry-run"
    fi

    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow </dev/null
    )"
    assert_contains "$output" "hook says hello" "a real stow must run the post-stow hook"
    assert_contains "$(cat "$marker")" "stow ${dotfiles_dir}" "the hook receives the stow command and DOTFILES_DIR"
    if [[ -e "${marker}.bad" ]]; then
        fail "a non-executable file in hooks/post-stow.d must not be run"
    fi
}

test_failing_post_stow_hook_warns_but_preserves_stow_status() {
    local tmpdir test_home dotfiles_dir hooks_dir output status

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    hooks_dir="${dotfiles_dir}/hooks/post-stow.d"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common/basepkg" "$hooks_dir"
    printf 'test content\n' > "${dotfiles_dir}/common/basepkg/.testrc"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    printf '#!/usr/bin/env bash\necho "something is wrong" >&2\nexit 3\n' > "${hooks_dir}/10-fails"
    chmod +x "${hooks_dir}/10-fails"

    status=0
    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes execstow stow </dev/null 2>&1
    )" || status=$?

    # Stow itself succeeded; a hook's opinion must not turn that into a failure.
    if [[ $status -ne 0 ]]; then
        fail "a failing post-stow hook must not change envmaker's exit status (got ${status})"
    fi
    assert_contains "$output" "Warning: post-stow hook 10-fails reported a problem (exit 3)." "a failing hook must be reported"
    assert_contains "$output" "Linked ${test_home}/.testrc" "the stow result must still be reported"
}

test_del_non_interactive_without_and_with_yes() {
    local tmpdir
    local test_home
    local dotfiles_dir
    local target_link
    local output

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    test_home="${tmpdir}/home"
    dotfiles_dir="${tmpdir}/dotfiles"
    mkdir -p "${dotfiles_dir}/parts" "${dotfiles_dir}/common" "$test_home"
    write_dotfiles_config "$test_home" "$dotfiles_dir"

    # Create a managed symlink pointing into dotfiles_dir
    target_link="${test_home}/.testrc"
    ln -s "${dotfiles_dir}/common/.testrc" "$target_link"

    # Without --yes, del must fail on non-TTY
    if output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" del </dev/null 2>&1
    )"; then
        echo "ASSERTION FAILED: non-interactive del without --yes should fail"
        exit 1
    fi
    assert_contains \
        "$output" \
        "envmaker.sh: confirmation required but stdin is not a TTY; pass --yes to continue" \
        "del without --yes should abort with TTY error"
    [[ -L "$target_link" ]] || {
        echo "ASSERTION FAILED: failed del must not delete symlinks"
        exit 1
    }

    # With --yes, del must proceed and remove the symlink
    output="$(
        HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" XDG_DATA_HOME="$test_home/.local/share" XDG_CACHE_HOME="$test_home/.cache" TERM=dumb bash "$ENVMAKER_SH" --yes del </dev/null
    )"
    assert_contains "$output" "Links to remove:" "del should list links to remove"
    [[ ! -e "$target_link" && ! -L "$target_link" ]] || {
        echo "ASSERTION FAILED: successful del should remove the symlink"
        exit 1
    }
}

if [[ $# -gt 0 ]]; then
    if [[ "$1" == --help || "$1" == -h ]]; then
        printf 'Usage: bash tests/envmaker_regression.sh [test_function ...]\nNo arguments runs the full regression gate.\n'
        exit 0
    fi
    for test_case in "$@"; do
        case "$test_case" in
            test_*) declare -F "$test_case" >/dev/null || fail "Unknown test: $test_case" ;;
            *) fail "Expected a test_ function: $test_case" ;;
        esac
        "$test_case"
        printf 'PASS %s\n' "$test_case"
    done
    exit 0
fi

test_debug_does_not_imply_dry_run
test_config_file_sets_dotfiles_directory
test_dotfiles_directory_argument_is_required_without_config
test_dotfiles_directory_argument_sets_dotfiles_directory
test_backup_scan_recursively_checks_nested_package_files
test_restow_preserves_files_reached_through_folded_directory_symlinks
test_restow_unfolds_directory_symlink_owned_by_another_part
test_restow_does_not_fold_new_directories
test_non_interactive_without_yes_aborts_with_error
test_non_interactive_with_yes_and_batch_flags
test_restow_reports_only_changes
test_verbose_flag_restores_full_output
test_stow_reports_linked_files_in_normal_mode
test_restow_reports_no_changes_for_synced_tree
test_delete_reports_unlinked_files
test_report_link_changes_flags_unlink_outside_delete_and_detects_relink
test_restow_never_prompts_for_confirmation
test_confirm_continue_helper_directly
test_del_non_interactive_without_and_with_yes
test_post_stow_hooks_run_after_real_stow_only
test_failing_post_stow_hook_warns_but_preserves_stow_status

bash "${REPO_ROOT}/tests/source_registry_regression.sh"
perl "${REPO_ROOT}/tests/overlay_planner_regression.pl"
perl "${REPO_ROOT}/tests/overlay_state_regression.pl"
bash "${REPO_ROOT}/tests/init_repo_regression.sh"
bash "${REPO_ROOT}/tests/add_zsh_completion_regression.sh"
bash "${REPO_ROOT}/tests/remove_function_keyword_regression.sh"
bash "${REPO_ROOT}/tests/convert_aliases_to_functions_regression.sh"

echo "envmaker regression tests passed"
