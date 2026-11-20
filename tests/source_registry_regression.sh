#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/fixture_lifecycle.sh
source "$REPO_ROOT/tests/fixture_lifecycle.sh"
fixture_suite envmaker-sources. "$@"

# shellcheck source=bin/source_registry.sh
source "$REPO_ROOT/bin/source_registry.sh"

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
contains() { [[ "$1" == *"$2"* ]] || fail "Expected '$2' in: $1"; }
reject() {
    local expected="$1" output
    shift
    if output=$("$@" 2>&1); then fail "Unexpected success: $*"; fi
    contains "$output" "$expected"
}
fixture() {
    export HOME="$TEST_ROOT/$1/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" TERM=dumb
    mkdir -p "$XDG_CONFIG_HOME/dotfiletracker"
    CONFIG="$XDG_CONFIG_HOME/dotfiletracker/config"
    GENERIC="$HOME/generic"
    PERSONAL="$HOME/personal space ü:=x"
    mkdir -p "$GENERIC/parts" "$GENERIC/common/a" "$PERSONAL/parts" "$PERSONAL/common/b"
}

test_registry_order_and_overrides() (
    fixture registry
    # shellcheck disable=SC2016
    printf '%s\n' '# low to high' 'source.generic="$HOME/generic"' \
        'source.personal="${HOME}/personal space ü:=x"' > "$CONFIG"
    dft_load_registry ''
    [[ "$DFT_MODE" == stack && "${DFT_SOURCE_IDS[*]}" == 'generic personal' ]] || fail 'config order'
    [[ "${DFT_SOURCE_ROOTS[1]}" == "$PERSONAL" ]] || fail 'quoted HOME expansion'
    dft_load_registry '' "personal=$PERSONAL" "generic=$GENERIC"
    [[ "${DFT_SOURCE_IDS[*]}" == 'personal generic' ]] || fail 'CLI replaces order'
    dft_load_registry '' "only=$GENERIC"
    [[ "${DFT_SOURCE_IDS[*]}" == only ]] || fail 'CLI replaces membership'
    dft_load_registry "$GENERIC"
    [[ "$DFT_MODE" == legacy && "$DFT_LEGACY_ROOT" == "$GENERIC" ]] || fail 'explicit legacy mode'
    reject 'Cannot combine' dft_load_registry "$GENERIC" "generic=$GENERIC"
    reject 'Cannot combine' bash "$REPO_ROOT/envmaker.sh" --dotfiles-dir "$GENERIC" --source "personal=$PERSONAL" listdirs
    reject 'Cannot combine' bash "$REPO_ROOT/envmaker.sh" --dotfiles-dir= --source "personal=$PERSONAL" listdirs
    reject 'Missing value' bash "$REPO_ROOT/envmaker.sh" --source
    reject 'Expected source' bash "$REPO_ROOT/envmaker.sh" --source= listdirs
    # Config is ignored by an explicit CLI registry, even if it is invalid.
    printf 'source.bad=/does/not/exist\n' > "$CONFIG"
    dft_load_registry '' "generic=$GENERIC"
    dft_load_registry "$GENERIC"
)

test_registry_legacy_aliases_and_data() (
    fixture legacy
    local_key=''
    for local_key in dotfiles_dir dotfile_dir ''; do
        if [[ -n "$local_key" ]]; then
            printf '%s="~/generic"\n' "$local_key" > "$CONFIG"
        else
            printf "'~/generic'\n" > "$CONFIG"
        fi
        dft_load_registry ''
        # shellcheck disable=SC2088
        [[ "$DFT_MODE" == legacy && "$DFT_LEGACY_ROOT" == '~/generic' ]] || fail 'legacy config syntax'
        output=$(bash "$REPO_ROOT/envmaker.sh" listdirs)
        contains "$output" "$GENERIC/common"
    done
    literal="$HOME/\$(touch marker)"
    mkdir -p "$literal/parts"
    printf 'source.literal="%s"\n' "$literal" > "$CONFIG"
    dft_load_registry ''
    [[ "${DFT_SOURCE_ROOTS[0]}" == "$literal" && ! -e marker ]] || fail 'config must be data'
    printf 'source.generic="~/generic"\n' > "$CONFIG"
    dft_load_registry ''
    [[ "${DFT_SOURCE_ROOTS[0]}" == "$GENERIC" ]] || fail 'stack tilde expansion'
    # Empty and unrelated-only configs must not create an implicit stack.
    printf '# empty\n' > "$CONFIG"
    reject '' dft_load_registry ''
    printf 'other=value\n' > "$CONFIG"
    reject '' dft_load_registry ''
)

test_registry_rejects_ambiguous_inputs() (
    fixture invalid
    for id in '' ../bad 'two words' 'a.b' 'a:b' '-bad' 'ü' 'aü' 'üa' 'a_é' '١' $'a\n'; do
        reject 'Invalid source ID' dft_load_registry '' "$id=$GENERIC"
    done
    for id in generic G2 personal_1 personal-2; do
        dft_load_registry '' "$id=$GENERIC"
    done
    reject 'Duplicate source ID' dft_load_registry '' "same=$GENERIC" "same=$PERSONAL"
    ln -s "$GENERIC" "$HOME/alias"
    for root in "$GENERIC" "$GENERIC/../generic" "$HOME/alias"; do
        reject 'Repeated physical' dft_load_registry '' "a=$GENERIC" "b=$root"
    done
    reject 'Empty source path' dft_load_registry '' 'generic='
    reject 'Unmatched source path quote' dft_load_registry '' 'generic="broken'
    reject 'Source directory not found' dft_load_registry '' "absent=$HOME/absent"
    for order in before after; do
        for key in dotfiles_dir dotfile_dir raw; do
            if [[ "$key" == raw ]]; then legacy="$GENERIC"; else legacy="$key=$GENERIC"; fi
            if [[ "$order" == before ]]; then
                printf '%s\nsource.generic=%s\n' "$legacy" "$GENERIC" > "$CONFIG"
            else
                printf 'source.generic=%s\n%s\n' "$GENERIC" "$legacy" > "$CONFIG"
            fi
            reject 'Cannot mix' dft_load_registry ''
            # All config-based writers use the same parser and fail before writing.
            for utility in add-zsh-completion remove_function_keyword convert_aliases_to_functions; do
                if [[ "$utility" == add-zsh-completion ]]; then
                    reject 'Cannot mix' bash "$REPO_ROOT/util/$utility.sh" --no-stow demo </dev/null
                else
                    reject 'Cannot mix' bash "$REPO_ROOT/util/$utility.sh"
                fi
            done
        done
    done
)

test_source_id_ascii_and_locale_scope() (
    fixture ascii-id
    local alnum=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
    local char i source_locale="${LC_ALL-}" locale_was_set="${LC_ALL+x}"
    for ((i = 0; i < ${#alnum}; i++)); do
        char=${alnum:i:1}
        dft_valid_source_id "$char" || fail "ASCII first character rejected: $char"
        dft_valid_source_id "a${char}_-" || fail "ASCII suffix character rejected: $char"
    done
    for char in 'ü' 'é' 'Ö' '١' ':' '/' ' ' $'\n'; do
        reject '' dft_valid_source_id "$char"
        reject '' dft_valid_source_id "a${char}Z"
    done
    reject '' dft_valid_source_id ''
    reject '' dft_valid_source_id '_start'
    reject '' dft_valid_source_id '-start'
    dft_load_registry '' "valid_A-9=$GENERIC"
    [[ "${LC_ALL-}" == "$source_locale" && "${LC_ALL+x}" == "$locale_was_set" ]] || fail 'ID validation leaked LC_ALL into the caller'
)

# Write a recording tripwire command: it logs its name and prints `choice`, so
# the former name-executing fallback would also have selected parts/<name>/choice.
# Callers run in their own fixture subshell; PATH and TRIPWIRE_LOG stay there.
tripwire() {
    local name
    export TRIPWIRE_LOG="$HOME/tripwire.log" PATH="$HOME/bin:$PATH"
    mkdir -p "$HOME/bin"
    for name in "$@"; do
        # shellcheck disable=SC2016 # Expanded by the tripwire at run time.
        printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$TRIPWIRE_LOG"\nprintf "choice\\n"\n' "$name" > "$HOME/bin/$name"
        chmod +x "$HOME/bin/$name"
    done
}

test_source_local_discovery_combinations() (
    fixture discovery
    export DISCOVERY_LOG="$HOME/rules.log"
    mkdir -p "$HOME/caller"
    # dft_fixture_part is an ordinary part; hostname is a built-in selector group.
    tripwire dft_fixture_part
    printf '#!/bin/sh\nprintf "choice\\n"\n' > "$HOME/bin/hostname"
    chmod +x "$HOME/bin/hostname"
    cd "$HOME/caller"
    for part in dft_fixture_part hostname; do
        # Cross every rule status in the lower source with every upper status.
        for lower in active inactive missing nonexec; do
            for upper in active inactive missing nonexec; do
                : > "$DISCOVERY_LOG"
                : > "$TRIPWIRE_LOG"
                for source_id in generic personal; do
                    if [[ "$source_id" == generic ]]; then root="$GENERIC"; state="$lower"; else root="$PERSONAL"; state="$upper"; fi
                    mkdir -p "$root/parts/$part/choice/pkg" "$root/rules"
                    rule="$root/rules/$part"
                    # A missing and a non-regular rule both reach the ruleless
                    # fallback. A directory at the rule path tests the non-regular variant.
                    if [[ "$state" == missing ]]; then
                        if [[ -f "$rule" ]]; then mv "$rule" "$rule.saved"; fi
                        mkdir -p "$rule"
                    else
                        if [[ -d "$rule" ]]; then rmdir "$rule"; fi
                        result=1
                        [[ "$state" != active ]] || result=0
                        # The fixture expands its own rule context at runtime.
                        # shellcheck disable=SC2016
                        printf '#!/bin/sh\nprintf "%%s|%%s|%%s\\n" "$DOTFILES_DIR" "$DOTFILETRACKER_SOURCE_ID" "$PWD" >> "$DISCOVERY_LOG"\nexit %s\n' "$result" > "$rule"
                        chmod 0644 "$rule"
                        [[ "$state" == nonexec ]] || chmod +x "$rule"
                    fi
                done
                printf 'source.generic=%s\nsource.personal="%s"\n' "$GENERIC" "$PERSONAL" > "$CONFIG"
                output=$(bash "$REPO_ROOT/envmaker.sh" listdirs)
                contains "$output" "generic:$GENERIC/common"
                contains "$output" "personal:$PERSONAL/common"
                for source_id in generic personal; do
                    if [[ "$source_id" == generic ]]; then root="$GENERIC"; state="$lower"; else root="$PERSONAL"; state="$upper"; fi
                    case "$state:$part" in
                        active:*) contains "$output" "$source_id:$root/parts/$part"$'\n' ;;
                        missing:hostname) contains "$output" "$source_id:$root/parts/hostname/choice" ;;
                        *) [[ "$output" != *"$source_id:$root/parts/"* ]] || fail "$state $part must stay inactive" ;;
                    esac
                    count=$(grep -Fc "$root|$source_id|$PWD" "$DISCOVERY_LOG" || true)
                    case "$state" in
                        active|inactive) [[ "$count" == 1 ]] || fail 'rule must run once in source context with caller cwd' ;;
                        *) [[ "$count" == 0 ]] || fail 'fallback/nonexec must not execute rule' ;;
                    esac
                done
                [[ ! -s "$TRIPWIRE_LOG" ]] || fail "ruleless part name executed: $(cat "$TRIPWIRE_LOG")"
            done
        done
        # A genuinely absent regular rule also reaches the fallback.
        mv "$PERSONAL/rules/$part" "$PERSONAL/rules/saved"
        output=$(bash "$REPO_ROOT/envmaker.sh" listdirs)
        if [[ "$part" == hostname ]]; then
            contains "$output" "personal:$PERSONAL/parts/hostname/choice"
        else
            [[ "$output" != *"personal:$PERSONAL/parts/"* ]] || fail 'absent rule must leave an ordinary part inactive'
        fi
        [[ ! -s "$TRIPWIRE_LOG" ]] || fail "ruleless part name executed: $(cat "$TRIPWIRE_LOG")"
        mv "$PERSONAL/rules/saved" "$PERSONAL/rules/$part"
    done
)

# Discovery never executes the name of a ruleless
# part. Only parts/hostname and parts/ostype run their built-in selector, and
# parts/application checks child names with `command -v` only.
test_ruleless_parts_never_execute() (
    fixture tripwire
    mkdir -p "$HOME/caller"
    tripwire unruled dirrule application demoapp
    cd "$HOME/caller"
    for root in "$GENERIC" "$PERSONAL"; do
        mkdir -p "$root/rules/dirrule"
        # unruled and dirrule are tripwires on PATH; scanonly is not a command,
        # so the old fallback scanned its children with command -v.
        for part in unruled dirrule scanonly; do
            # parts/<part>/demoapp would be selected by a child command -v scan,
            # parts/<part>/choice by executing <part>, parts/<part> by a rule.
            for child in demoapp choice pkg; do
                mkdir -p "$root/parts/$part/$child/pkg"
                printf '%s\n' "$part" > "$root/parts/$part/$child/pkg/.$part-$child"
            done
        done
        mkdir -p "$root/parts/application/demoapp/pkg" "$root/parts/application/absent-command-dft33/pkg"
    done
    printf 'demoapp\n' > "$PERSONAL/parts/application/demoapp/pkg/.demoapp-file"
    printf 'absent\n' > "$PERSONAL/parts/application/absent-command-dft33/pkg/.absent-file"
    for mode in legacy stack; do
        if [[ "$mode" == legacy ]]; then
            printf 'dotfiles_dir=%s\n' "$PERSONAL" > "$CONFIG"
            prefix=''
            commands=(listdirs '--dry-run execstow restow')
        else
            printf 'source.generic=%s\nsource.personal="%s"\n' "$GENERIC" "$PERSONAL" > "$CONFIG"
            prefix='personal:'
            commands=(listdirs plan 'explain .demoapp-file' '--dry-run execstow restow')
        fi
        for command in "${commands[@]}"; do
            : > "$TRIPWIRE_LOG"
            read -r -a argv <<< "$command"
            output=$(bash "$REPO_ROOT/envmaker.sh" "${argv[@]}" 2>&1) || fail "$mode $command failed: $output"
            [[ ! -s "$TRIPWIRE_LOG" ]] || fail "$mode $command executed: $(tr '\n' ' ' < "$TRIPWIRE_LOG")"
            for part in unruled dirrule scanonly; do
                [[ "$output" != *"/parts/$part"* ]] || fail "$mode $command selected ruleless part $part: $output"
            done
            [[ "$output" != *absent-command-dft33* ]] || fail "$mode $command selected an absent application"
            case "$command" in
                listdirs) contains "$output" "$prefix$PERSONAL/parts/application/demoapp" ;;
                plan) contains "$output" "$PERSONAL/parts/application/demoapp/pkg" ;;
                explain*) contains "$output" '"source_id":"personal"' ;;
            esac
        done
    done
    [[ ! -e "$HOME/.demoapp-file" && ! -e "$XDG_STATE_HOME" ]] || fail 'dry runs must not change the fixture home'
)

# The hostname/ostype selector value names one child of its group. An empty,
# failed or unsafe value selects nothing, never a path outside the group.
test_selector_value_failure_model() (
    fixture selector-values
    mkdir -p "$HOME/bin" "$HOME/caller"
    cd "$HOME/caller"
    for child in choice other_OR_choice '*' '?' '[c]hoice' 'a\b'; do
        mkdir -p "$GENERIC/parts/hostname/$child/pkg"
    done
    mkdir -p "$GENERIC/parts/hostname/choice/x/pkg"
    printf 'source.generic=%s\n' "$GENERIC" > "$CONFIG"
    for value in valid '' . .. '../hostname' 'choice/x' $'choice\nx' '*' '?' '[c]hoice' 'a\b' failed; do
        if [[ "$value" == valid ]]; then
            printf '#!/bin/sh\nprintf "choice\\n"\n' > "$HOME/bin/hostname"
        elif [[ "$value" == failed ]]; then
            printf '#!/bin/sh\nprintf "choice\\n"\nexit 3\n' > "$HOME/bin/hostname"
        else
            # shellcheck disable=SC2016 # Expanded by the fake hostname.
            printf '#!/bin/sh\nprintf "%%s\\n" "$SELECTOR_VALUE"\n' > "$HOME/bin/hostname"
        fi
        chmod +x "$HOME/bin/hostname"
        output=$(SELECTOR_VALUE="$value" PATH="$HOME/bin:$PATH" selector_discovery) || fail "discovery failed for $(printf '%q' "$value")"
        output+=$'\n'$(SELECTOR_VALUE="$value" PATH="$HOME/bin:$PATH" bash "$REPO_ROOT/envmaker.sh" listdirs) \
            || fail "listdirs failed for $(printf '%q' "$value")"
        contains "$output" "generic:$GENERIC/common"
        if [[ "$value" == valid ]]; then
            contains "$output" "generic:$GENERIC/parts/hostname/choice"$'\n'
            contains "$output" "generic:$GENERIC/parts/hostname/other_OR_choice"$'\n'
            [[ $(grep -c '/parts/' <<< "$output") == 4 ]] || fail "valid selector selected extra directories: $output"
        else
            [[ "$output" != *"/parts"* ]] || fail "selector value $(printf '%q' "$value") selected: $output"
        fi
    done
)

selector_discovery() (
    # shellcheck source=bin/discovery.sh
    source "$REPO_ROOT/bin/discovery.sh"
    # shellcheck source=bin/mutation_guard.sh
    source "$REPO_ROOT/bin/mutation_guard.sh"
    debugEcho() { :; }
    verbose_enabled() { return 1; }
    dft_load_registry '' "generic=$GENERIC"
    discover_stack_packages
    printf 'generic:%s\n' "${STACK_DIRECTORY_PATHS[@]}"
)

test_stack_public_dispatch() (
    fixture gate
    mkdir -p "$PERSONAL/parts/application"
    printf 'function keep { :; }\n' > "$GENERIC/common/a/keep.sh"
    printf "alias keep='printf keep'\n" > "$PERSONAL/common/b/aliases.sh"
    printf 'source.generic=%s\nsource.personal="%s"\n' "$GENERIC" "$PERSONAL" > "$CONFIG"
    bash "$REPO_ROOT/envmaker.sh" --dry-run execstow restow >/dev/null
    for action in apply backup_conflicting_targets configure_dotfile_dir dft_require_legacy dft_stow_run dft_overlay_plan; do
        reject 'Unsupported stack command' bash "$REPO_ROOT/envmaker.sh" --yes "$action"
    done
    reject 'Usage: migrate' bash "$REPO_ROOT/envmaker.sh" migrate
    bash "$REPO_ROOT/envmaker.sh" ls >/dev/null
    reject 'Usage:' bash "$REPO_ROOT/envmaker.sh" recover
    for utility in add-zsh-completion remove_function_keyword convert_aliases_to_functions; do
        if [[ "$utility" == add-zsh-completion ]]; then
            reject 'Stack writes require --source' bash "$REPO_ROOT/util/$utility.sh" --no-stow demo </dev/null
        else
            reject 'Stack writes require --source' bash "$REPO_ROOT/util/$utility.sh"
        fi
    done
    [[ ! -e "$XDG_STATE_HOME" && ! -e "$HOME/.shellinclude" ]] || fail 'gate must not create persistent state'
    [[ $(cat "$GENERIC/common/a/keep.sh") == 'function keep { :; }' ]] || fail 'gate must preserve source functions'
    [[ $(cat "$PERSONAL/common/b/aliases.sh") == "alias keep='printf keep'" ]] || fail 'gate must preserve source aliases'
    [[ ! -e "$GENERIC/common/a/keep.sh.orig" && ! -e "$PERSONAL/common/b/aliases.sh.orig" ]] || fail 'gate must not create backups'
    # init remains independent even if the configured sources are unavailable.
    printf 'source.generic=/unavailable\n' > "$CONFIG"
    bash "$REPO_ROOT/envmaker.sh" init "$HOME/new-repo"
    [[ -d "$HOME/new-repo/.git" ]] || fail 'init must not load registry'
    reject 'does not accept --source' bash "$REPO_ROOT/envmaker.sh" --source "a=$GENERIC" init "$HOME/other-repo"
)

test_write_destinations() (
    fixture destinations
    printf 'source.generic=%s\nsource.personal="%s"\n' "$GENERIC" "$PERSONAL" > "$CONFIG"
    for source_id in generic personal; do
        dft_write_destination '' "$source_id" 0
        [[ "$DFT_MODE" == stack ]] || fail 'stack writer mode'
        if [[ "$source_id" == generic ]]; then
            [[ "$DFT_WRITE_ROOT" == "$GENERIC" ]] || fail 'generic destination'
        else
            [[ "$DFT_WRITE_ROOT" == "$PERSONAL" ]] || fail 'personal destination'
        fi
    done
    reject 'Stack writes require' dft_write_destination '' '' 0
    reject 'Unknown destination source' dft_write_destination '' unknown 0
    reject 'Cannot combine' dft_write_destination "$GENERIC" personal 0
    reject 'not both' dft_write_destination '' personal 1
    dft_write_destination '' '' 1
    [[ "$DFT_MODE" == stack && -z "$DFT_WRITE_ROOT" ]] || fail 'explicit paths retain stack ownership checks'
)

test_raw_candidate_inventory() (
    fixture inventory
    # shellcheck source=bin/discovery.sh
    source "$REPO_ROOT/bin/discovery.sh"
    # Discovery helpers use these presentation callbacks from envmaker.
    debugEcho() { :; }
    verbose_enabled() { return 1; }
    dft_load_registry '' "generic=$GENERIC" "personal=$PERSONAL"
    discover_stack_packages
    [[ "${STACK_PACKAGE_SOURCES[*]}" == 'generic personal' ]] || fail 'package source identities must retain order'
    [[ "${STACK_PACKAGE_PATHS[0]}" == "$GENERIC/common/a" && "${STACK_PACKAGE_PATHS[1]}" == "$PERSONAL/common/b" ]] || fail 'distinct package paths must remain distinct'
    mkdir -p "$HOME/empty/parts"
    dft_load_registry '' "empty=$HOME/empty"
    discover_stack_packages
    [[ ${#STACK_PACKAGE_PATHS[@]} -eq 0 && ${#STACK_DIRECTORY_PATHS[@]} -eq 0 ]] || fail 'empty selected sets must be supported'
    package="$PERSONAL/common/different-name"
    mkdir -p "$package/.config" "$HOME/external"
    printf 'owned\n' > "$package/.config/value ü:=x"
    printf 'outside\n' > "$HOME/external/must-not-be-enumerated"
    ln -s "$HOME/external" "$package/external-link"
    ln -s '.config/value ü:=x' "$package/regular-link"
    newline_name=$'line\nbreak'
    printf 'newline\n' > "$package/$newline_name"
    enumerate_source_entries "$package" > "$HOME/entries"
    count=0
    while IFS= read -r -d '' entry; do
        [[ "$entry" != *must-not-be-enumerated ]] || fail 'must not follow directory symlinks'
        count=$((count + 1))
    done < "$HOME/entries"
    [[ $count -eq 5 ]] || fail "expected directory, file and symlink entries, got $count"
    [[ $(cat "$HOME/external/must-not-be-enumerated") == outside ]] || fail 'source inventory is read-only'
)

test_stow_module_discovery() (
    fixture stow
    stow_version=${STOW_VERSION:-2.4.1}
    stow_exec="/opt/stow-$stow_version/bin/stow"
    # shellcheck source=bin/stow_bridge.sh
    source "$REPO_ROOT/bin/stow_bridge.sh"
    output=$(dft_stow_module_info)
    contains "$output" "\"version\":\"$stow_version\""
    contains "$output" 'Stow.pm'
    ln -s "$stow_exec" "$HOME/stow alias"
    [[ "$(dft_stow_module_info "$HOME/stow alias")" == "$output" ]] || fail 'symlinked Stow must load same module'
    STOW_VERSION=0.0 reject 'version mismatch' dft_stow_module_info "$stow_exec"
    # Relocated installation with a nonstandard module directory and env Perl.
    # This tests interpreter/module resolution independently of the host layout.
    mkdir -p "$HOME/install/bin" "$HOME/install/unusual-modules"
    # shellcheck disable=SC2016
    printf 'package Stow; our $VERSION = "2.4.1"; 1;\n' > "$HOME/install/unusual-modules/Stow.pm"
    cat > "$HOME/install/bin/stow" <<'PERL'
#!/usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/../unusual-modules";
use Stow;
sub main { print "stow (GNU Stow) version $Stow::VERSION\n"; }
main() unless caller();
PERL
    chmod +x "$HOME/install/bin/stow"
    output=$(STOW_VERSION=2.4.1 dft_stow_module_info "$HOME/install/bin/stow")
    contains "$output" "$HOME/install/unusual-modules/Stow.pm"
    [[ ! -e "$XDG_STATE_HOME" ]] || fail 'probe must not create applied state'
)

test_hostname_called_only_for_parts_hostname() (
    fixture hostname-calls
    mkdir -p "$HOME/bin" "$HOME/caller"
    cd "$HOME/caller"
    export HOSTNAME_CALL_LOG="$HOME/hostname-calls.log"
    # shellcheck disable=SC2016 # Expanded by the fake hostname at run time.
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "called\n" >> "$HOSTNAME_CALL_LOG"' \
        'if [ "${HOSTNAME_PRINT:-1}" = 1 ]; then printf "choice\n"; fi' \
        'exit "${HOSTNAME_RC:-0}"' > "$HOME/bin/hostname"
    chmod +x "$HOME/bin/hostname"
    export PATH="$HOME/bin:$PATH"

    # Sources without parts/hostname: 0 hostname calls in stack and legacy modes.
    printf 'source.generic=%s\nsource.personal="%s"\n' "$GENERIC" "$PERSONAL" > "$CONFIG"
    : > "$HOSTNAME_CALL_LOG"
    output=$(bash "$REPO_ROOT/envmaker.sh" listdirs)
    contains "$output" "generic:$GENERIC/common"
    contains "$output" "personal:$PERSONAL/common"
    [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq 0 ]] || fail "expected 0 hostname calls without parts/hostname, got $(wc -l < "$HOSTNAME_CALL_LOG")"

    : > "$HOSTNAME_CALL_LOG"
    output=$(bash "$REPO_ROOT/envmaker.sh" --dotfiles-dir "$GENERIC" listdirs)
    contains "$output" "$GENERIC/common"
    [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq 0 ]] || fail "expected 0 hostname calls in legacy mode without parts/hostname, got $(wc -l < "$HOSTNAME_CALL_LOG")"

    # One source with parts/hostname: 1 hostname call in stack and legacy modes.
    mkdir -p "$GENERIC/parts/hostname/choice/pkg"
    : > "$HOSTNAME_CALL_LOG"
    output=$(bash "$REPO_ROOT/envmaker.sh" listdirs)
    contains "$output" "generic:$GENERIC/parts/hostname/choice"
    [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq 1 ]] || fail "expected 1 hostname call with one source, got $(wc -l < "$HOSTNAME_CALL_LOG")"

    : > "$HOSTNAME_CALL_LOG"
    output=$(bash "$REPO_ROOT/envmaker.sh" --dotfiles-dir "$GENERIC" listdirs)
    contains "$output" "$GENERIC/parts/hostname/choice"
    [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq 1 ]] || fail "expected 1 hostname call in legacy mode, got $(wc -l < "$HOSTNAME_CALL_LOG")"

    # Two sources with parts/hostname: 1 hostname call per such source.
    mkdir -p "$PERSONAL/parts/hostname/choice/pkg"
    : > "$HOSTNAME_CALL_LOG"
    output=$(bash "$REPO_ROOT/envmaker.sh" listdirs)
    contains "$output" "generic:$GENERIC/parts/hostname/choice"
    contains "$output" "personal:$PERSONAL/parts/hostname/choice"
    [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq 2 ]] || fail "expected 2 hostname calls with two sources, got $(wc -l < "$HOSTNAME_CALL_LOG")"

    # Failing fake (exit 3) and missing-like fake (exit 127) leave listdirs at exit 0
    # with common listed and no parts/hostname/* selected.
    for mode in stack legacy; do
        local args=(listdirs)
        [[ "$mode" == stack ]] || args=(--dotfiles-dir "$GENERIC" listdirs)
        local expected_calls=2
        [[ "$mode" == stack ]] || expected_calls=1

        : > "$HOSTNAME_CALL_LOG"
        output=$(HOSTNAME_PRINT=1 HOSTNAME_RC=3 bash "$REPO_ROOT/envmaker.sh" "${args[@]}") || fail "$mode listdirs failed when hostname exited 3"
        contains "$output" "$GENERIC/common"
        [[ "$output" != *"/parts/hostname"* ]] || fail "$mode failing hostname (exit 3) selected parts/hostname: $output"
        [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq $expected_calls ]] || fail "$mode expected $expected_calls calls on exit 3, got $(wc -l < "$HOSTNAME_CALL_LOG")"

        : > "$HOSTNAME_CALL_LOG"
        output=$(HOSTNAME_PRINT=0 HOSTNAME_RC=127 bash "$REPO_ROOT/envmaker.sh" "${args[@]}") || fail "$mode listdirs failed when hostname exited 127"
        contains "$output" "$GENERIC/common"
        [[ "$output" != *"/parts/hostname"* ]] || fail "$mode missing-like hostname (exit 127) selected parts/hostname: $output"
        [[ $(wc -l < "$HOSTNAME_CALL_LOG") -eq $expected_calls ]] || fail "$mode expected $expected_calls calls on exit 127, got $(wc -l < "$HOSTNAME_CALL_LOG")"
    done
)

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
    printf 'Usage: bash tests/source_registry_regression.sh [test_function ...]\n'
    exit 0
fi
if [[ $# -eq 0 ]]; then
    set -- test_registry_order_and_overrides test_registry_legacy_aliases_and_data \
        test_registry_rejects_ambiguous_inputs test_source_local_discovery_combinations \
        test_ruleless_parts_never_execute test_selector_value_failure_model \
        test_stack_public_dispatch test_write_destinations test_raw_candidate_inventory test_stow_module_discovery \
        test_source_id_ascii_and_locale_scope test_hostname_called_only_for_parts_hostname
fi
for test_case in "$@"; do
    case "$test_case" in test_*) declare -F "$test_case" >/dev/null || fail "Unknown test: $test_case" ;; *) fail "Invalid test: $test_case" ;; esac
    "$test_case"
    printf 'PASS %s\n' "$test_case"
done
