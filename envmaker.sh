#!/usr/bin/env bash

set -e
set -o functrace
real_lineno=0
last_lineno=0

function handle_error {
    local retval=$?
    local line=${last_lineno:-$1}
    echo "Failed at $line: $BASH_COMMAND"
    echo "Trace: " "$@"
    exit $retval
}
if (( ${BASH_VERSION%%.*} <= 3 )) || [[ ${BASH_VERSION%.*} = 4.0 ]]; then
        trap '[[ $FUNCNAME = handle_error ]] || { last_lineno=$real_lineno; real_lineno=$LINENO; }' DEBUG
fi
trap 'handle_error $LINENO ${BASH_LINENO[@]}' ERR

usage() {
    cat <<'EOF'
Usage: ./envmaker.sh [--debug|-d] [--verbose|-v] [--dry-run|-n] [--yes|-y|--batch|-b] [--dotfiles-dir PATH | --source ID=PATH ...] <function> [args...]

Dotfiles directory:
  Read from $XDG_CONFIG_HOME/dotfiletracker/config, or
  ~/.config/dotfiletracker/config when XDG_CONFIG_HOME is not set.
  The config may contain dotfiles_dir=/path/to/dotfiles, or just the path.
  If no config file exists, pass --dotfiles-dir PATH.
  init PATH does not read this config or require --dotfiles-dir.

Options:
  --yes, -y, --batch, -b  Skip interactive confirmation prompts
  --dry-run, -n           Simulate actions without making changes
  --debug, -d             Enable debug output
  --verbose, -v           Show discovery/processing output (rule matches,
                          package list, stow invocations) that normal mode
                          keeps quiet
  --dotfiles-dir PATH     Override dotfiles repository directory (legacy mode)
  --source ID=PATH        Ordered sources, lowest priority first; replaces config
                          source.ID=PATH entries. Later sources win whole files.
  --help, -h              Show this help

Functions:
  init PATH                 Initialize a fresh dotfiles Git repository
  listdirs
  plan                      Read-only stack winner plan (JSON)
  explain TARGET            Selected/shadowed stack owners (JSON)
  execstow stow|restow|delete
  del
  migrate --from SOURCE_ID   Migrate exact direct/folded links; preview with -n
  recover inspect|resume|restore  Recover a recorded pending operation
  ls
EOF
}

init_repo() {
    local destination
    local existing_entry
    local template_dir="${script_dir}/templates/dotfiles"
    local dependency
    local part

    if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
        printf '%s\n' 'Usage: ./envmaker.sh [--dry-run|-n] init PATH' \
            'Create common/, parts/, rules/, and setup documentation in a new or empty Git repository.' \
            'Existing destinations may contain only .git. No home links or configuration are changed.'
        return 0
    fi
    if [[ $# -ne 1 || -z "$1" || "$1" == -* || -n "$DOTFILES_DIR_ARG" ]]; then
        printf '%s\n' 'Usage: ./envmaker.sh [--dry-run|-n] init PATH (use PATH instead of --dotfiles-dir)' >&2
        return 1
    fi
    for dependency in git find mkdir cp; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            printf 'envmaker.sh: init requires %s\n' "$dependency" >&2
            return 1
        fi
    done

    destination=$(expand_home_path "$1")
    # Prefix relative paths so utility arguments cannot be interpreted as options.
    [[ "$destination" == /* ]] || destination="$PWD/$destination"
    if [[ -L "$destination" || ( -e "$destination" && ! -d "$destination" ) ]]; then
        printf 'envmaker.sh: init destination must be a directory, not a file or symlink: %s\n' "$destination" >&2
        return 1
    fi
    if [[ -d "$destination" ]]; then
        existing_entry=$(find "$destination" -mindepth 1 -maxdepth 1 ! -name .git -print -quit) || return 1
        if [[ -n "$existing_entry" ]]; then
            printf 'envmaker.sh: init destination must be empty except for .git: %s\n' "$destination" >&2
            return 1
        fi
    fi
    if [[ -e "$destination/.git" || -L "$destination/.git" ]]; then
        if ! git -C "$destination" rev-parse --git-dir >/dev/null 2>&1; then
            printf 'envmaker.sh: invalid Git repository: %s\n' "$destination" >&2
            return 1
        fi
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'Would initialize dotfiles repository at %s (common/, parts/, rules/, README.md, docs/getting_started.md).\n' "$destination"
        return 0
    fi

    mkdir -p "$destination/common" "$destination/parts" "$destination/rules" "$destination/docs" || return 1
    cp "$template_dir/README.md" "$destination/README.md" || return 1
    cp "$template_dir/docs/getting_started.md" "$destination/docs/getting_started.md" || return 1
    for part in common parts rules; do
        cp "$template_dir/$part/.gitkeep" "$destination/$part/.gitkeep" || return 1
    done
    if [[ ! -e "$destination/.git" ]]; then
        if ! git init --quiet "$destination"; then
            printf 'envmaker.sh: Git initialization failed: %s\n' "$destination" >&2
            return 1
        fi
    fi
    printf 'Initialized dotfiles repository at %s\n' "$destination"
}

debugEcho() {
	if [[ $DEBUG_MODE -eq 1 ]]; then
		echo "$1"
	fi
}

# Discovery/processing output (rule matches, package listing, stow
# invocations) that normal mode keeps quiet, but --debug, --verbose, and
# --dry-run all restore -- --dry-run because its whole point is preview.
verbose_enabled() {
	[[ $DEBUG_MODE -eq 1 || $VERBOSE_MODE -eq 1 || $DRY_RUN -eq 1 ]]
}

resolve_path() {
    local path="$1"
    local dir_path
    local base_name

    if [[ -d "$path" ]]; then
        (
            cd "$path" >/dev/null 2>&1
            pwd -P
        )
        return
    fi

    dir_path=$(dirname "$path")
    base_name=$(basename "$path")
    (
        cd "$dir_path" >/dev/null 2>&1
        printf '%s/%s\n' "$(pwd -P)" "$base_name"
    )
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

    case "$path" in
        "~")
            printf '%s\n' "$HOME"
            ;;
        "~/"*)
            printf '%s/%s\n' "$HOME" "${path#"~/"}"
            ;;
        '$HOME')
            printf '%s\n' "$HOME"
            ;;
        '$HOME/'*)
            printf '%s/%s\n' "$HOME" "${path#'$HOME/'}"
            ;;
        '${HOME}')
            printf '%s\n' "$HOME"
            ;;
        '${HOME}/'*)
            printf '%s/%s\n' "$HOME" "${path#'${HOME}/'}"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

dotfiletracker_config_path() {
    printf '%s/dotfiletracker/config\n' "${XDG_CONFIG_HOME:-"$HOME/.config"}"
}

read_dotfiles_dir_from_config() {
    dft_read_legacy_config
}

configure_dotfile_dir() {
    local dotfiles_dir_arg="$1"
    local config_file
    local configured_dir

    config_file=$(dotfiletracker_config_path)

    if [[ -n "$dotfiles_dir_arg" ]]; then
        configured_dir="$dotfiles_dir_arg"
    else
        if ! configured_dir=$(read_dotfiles_dir_from_config "$config_file"); then
            echo "Dotfiles directory is not configured."
            echo "Create $config_file with dotfiles_dir=/path/to/dotfiles, or pass --dotfiles-dir PATH."
            exit 1
        fi
    fi

    configured_dir=$(expand_home_path "$configured_dir")
    if [[ -z "$configured_dir" ]]; then
        echo "Dotfiles directory is empty."
        echo "Set dotfiles_dir in $config_file, or pass --dotfiles-dir PATH."
        exit 1
    fi

    dotfile_dir=$(resolve_path "$configured_dir")
    dotfile_parts_dir="$dotfile_dir/parts"
    rules_dir="${dotfile_dir}/rules"
}

resolve_symlink_target() {
    local link_path="$1"
    local target

    target=$(readlink "$link_path") || return 1
    if [[ "$target" != /* ]]; then
        target="$(dirname "$link_path")/$target"
    fi

    resolve_path "$target"
}

list_stowed_links() {
    local maxdepth="${1:-4}"
    local link_path
    local resolved_target

    while IFS= read -r -d '' link_path; do
        resolved_target=$(resolve_symlink_target "$link_path") || continue
        if [[ "$resolved_target" == "$dotfile_dir" || "$resolved_target" == "$dotfile_dir/"* ]]; then
            printf '%s\n' "$link_path"
        fi
    done < <(find "$HOME" -maxdepth "$maxdepth" -type l -print0 2>/dev/null)
}

BACKUP_CONFLICTS_FOUND=0

next_backup_path() {
	local original_path="$1"
	local backup_path="${original_path}.orig"
	local suffix=1

	while [[ -e "$backup_path" || -L "$backup_path" ]]; do
		backup_path="${original_path}.orig.${suffix}"
		((suffix++))
	done

	printf '%s\n' "$backup_path"
}

backup_conflicting_targets_for_package() {
	local package_name="$1"
	local package_entry
	local relative_target_path
	local target_path
	local target_parent_path
	local package_parent_path
	local backup_path

	while IFS= read -r -d '' package_entry; do
		if [[ "${package_entry##*/}" == ".stow-local-ignore" ]]; then
			continue
		fi

		relative_target_path="${package_entry#./"$package_name"/}"
		target_path="$HOME/$relative_target_path"

		# Stow folds a directory into a single symlink when nothing else lives
		# there, so a nested target path can resolve back through that symlink
		# into the package itself. That is an already-stowed file, not a
		# conflict; without this check it gets treated as one and moved to
		# target_path.orig, deleting it from the repo.
		target_parent_path="${target_path%/*}"
		package_parent_path="${package_entry%/*}"
		if [[ "${target_path##*/}" == "${package_entry##*/}" \
			&& "$target_parent_path" -ef "$package_parent_path" ]]; then
			continue
		fi

		if [[ -e "$target_path" && ! -L "$target_path" && ! -d "$target_path" ]]; then
			((BACKUP_CONFLICTS_FOUND += 1))
			backup_path=$(next_backup_path "$target_path")
			if [[ $DRY_RUN -eq 0 ]]; then
				echo "Backing up existing file ${bold}${target_path}${boldend} to ${bold}${backup_path}${boldend}"
			else
				echo "Would back up existing file ${bold}${target_path}${boldend} to ${bold}${backup_path}${boldend}"
			fi
			if [[ $DRY_RUN -eq 0 ]]; then
				mv "$target_path" "$backup_path"
			fi
		fi
	done < <(find "./$package_name" -mindepth 1 ! -type d -print0)
}

backup_conflicting_targets() {
	local package_name

	for package_name in "$@"; do
		backup_conflicting_targets_for_package "$package_name"
	done
}

FOLDED_LINKS_FOUND=0

# Stow folds a target directory into one symlink when a single package uses
# it, and can unfold only a link that belongs to the Stow directory of the
# current call. envmaker runs one Stow call per part, so a directory folded
# into one part blocks every other part that needs it with "existing target
# is not owned by stow" (cross-package directory ownership). Unfold such a link
# the way Stow itself would: a real directory holding one relative symlink
# per entry, so the owning part's files stay linked and Stow still sees
# them as its own. Links into the current Stow directory are left to Stow,
# which unfolds those itself.
unfold_foreign_directory_symlinks_for_package() {
	local package_name="$1"
	local stow_dir="$2"
	local package_dir_entry
	local target_path
	local link_dest
	local resolved_target
	local source_entry
	local entry_name

	while IFS= read -r -d '' package_dir_entry; do
		target_path="$HOME/${package_dir_entry#./"$package_name"/}"
		[[ -L "$target_path" && -d "$target_path" ]] || continue
		resolved_target=$(resolve_symlink_target "$target_path") || continue
		[[ "$resolved_target" == "$dotfile_dir/"* ]] || continue
		[[ "$resolved_target" != "$stow_dir/"* ]] || continue

		((FOLDED_LINKS_FOUND += 1))
		if [[ $DRY_RUN -eq 1 ]]; then
			echo "Would unfold directory symlink ${bold}${target_path}${boldend} (owned by ${resolved_target}) into a real directory"
			continue
		fi
		echo "Unfolding directory symlink ${bold}${target_path}${boldend} (owned by ${resolved_target}) into a real directory"
		link_dest=$(readlink "$target_path")
		rm "$target_path"
		mkdir "$target_path"
		while IFS= read -r -d '' source_entry; do
			entry_name="${source_entry##*/}"
			if [[ "$link_dest" == /* ]]; then
				ln -s "$link_dest/$entry_name" "$target_path/$entry_name"
			else
				# One level deeper than the folded link, so one more "../".
				ln -s "../$link_dest/$entry_name" "$target_path/$entry_name"
			fi
		done < <(find "$resolved_target" -mindepth 1 -maxdepth 1 -print0)
	done < <(find "./$package_name" -mindepth 1 -type d -print0)
}

unfold_foreign_directory_symlinks() {
	local stow_dir="$1"
	local package_name

	shift
	for package_name in "$@"; do
		unfold_foreign_directory_symlinks_for_package "$package_name" "$stow_dir"
	done
}

# True when the target path currently resolves (through symlinks, including
# folded directory symlinks) to exactly this package entry. -ef compares the
# physical inode, so folding depth does not matter.
target_matches_package_entry() {
	local target_path="$1"
	local package_entry="$2"

	[[ -e "$target_path" && "$target_path" -ef "$package_entry" ]]
}

snapshot_link_states() {
	local snapshot_file="$1"
	local package_name
	local package_entry
	local relative_target_path
	local target_path
	local snapshot_lines=""

	shift
	for package_name in "$@"; do
		while IFS= read -r -d '' package_entry; do
			# Cheap ".stow-local-ignore" leaf check (avoids forking basename
			# per file, which dominated runtime on large trees).
			if [[ "$package_entry" == */.stow-local-ignore ]]; then
				continue
			fi
			relative_target_path="${package_entry#./"$package_name"/}"
			target_path="$HOME/$relative_target_path"
			if target_matches_package_entry "$target_path" "$package_entry"; then
				# The package-entry path itself is a stable, unique identity
				# for the "which package file is this linked to" comparison,
				# since both snapshots are taken from the same working
				# directory -- no need to canonicalize it (that forked
				# dirname/basename/pwd per file and dominated runtime on
				# large trees).
				snapshot_lines+="${target_path}"$'\t'"linked:${package_entry}"$'\n'
			else
				snapshot_lines+="${target_path}"$'\t'"unlinked"$'\n'
			fi
		done < <(find "./$package_name" -mindepth 1 ! -type d -print0)
	done
	printf '%s' "$snapshot_lines" > "$snapshot_file"
}

report_link_changes() {
	local before_file="$1"
	local after_file="$2"
	local stowcmd="$3"
	local target_path
	local before_state
	local after_target_path
	local after_state
	local after_target_paths=()
	local after_states=()
	local i
	local matched_after_state

	# Read the after-snapshot into parallel arrays once, then look each
	# before-snapshot target up by linear scan. Avoids forking awk (or any
	# other external process) to do the before/after join; a linear scan is
	# fine because both snapshots enumerate the same small per-directory
	# package file set, not the whole tree.
	while IFS=$'\t' read -r after_target_path after_state; do
		after_target_paths+=("$after_target_path")
		after_states+=("$after_state")
	done < "$after_file"

	while IFS=$'\t' read -r target_path before_state; do
		matched_after_state=""
		for ((i = 0; i < ${#after_target_paths[@]}; i++)); do
			if [[ "${after_target_paths[i]}" == "$target_path" ]]; then
				matched_after_state="${after_states[i]}"
				break
			fi
		done
		[[ -n "$matched_after_state" ]] || matched_after_state="$before_state"

		if [[ "$before_state" == "$matched_after_state" ]]; then
			continue
		fi
		if [[ "$matched_after_state" == "unlinked" ]]; then
			if [[ "$stowcmd" == "delete" ]]; then
				echo "Unlinked ${bold}${target_path}${boldend}"
			else
				echo "Unlinked ${bold}${target_path}${boldend} (unexpected outside delete)"
			fi
		elif [[ "$before_state" == "unlinked" ]]; then
			echo "Linked ${bold}${target_path}${boldend}"
		else
			echo "Relinked ${bold}${target_path}${boldend}"
		fi
		changed_file_count=$((changed_file_count + 1))
	done < "$before_file"
}

DEBUG_MODE=0
VERBOSE_MODE=0
DRY_RUN=0
ASSUME_YES="${ASSUME_YES:-0}"
ORIGINAL_ARGS=("$@")
DOTFILES_DIR_ARG=""
DOTFILES_DIR_GIVEN=0
SOURCE_ARGS=()

while (($# > 0)); do
    case "$1" in
        --debug|-d)
            DEBUG_MODE=1
            shift
            ;;
        --verbose|-v)
            VERBOSE_MODE=1
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=1
            shift
            ;;
        --yes|-y|--batch|-b)
            ASSUME_YES=1
            shift
            ;;
        --source)
            shift
            if (($# == 0)); then
                printf 'Missing value for --source ID=PATH\n' >&2
                exit 1
            fi
            SOURCE_ARGS+=("$1")
            shift
            ;;
        --source=*)
            SOURCE_ARGS+=("${1#*=}")
            shift
            ;;
        --dotfiles-dir|--dotfile-dir)
            DOTFILES_DIR_GIVEN=1
            shift
            if (($# == 0)); then
                echo "Missing value for --dotfiles-dir"
                usage
                exit 1
            fi
            DOTFILES_DIR_ARG="$1"
            shift
            ;;
        --dotfiles-dir=*|--dotfile-dir=*)
            DOTFILES_DIR_GIVEN=1
            DOTFILES_DIR_ARG="${1#*=}"
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
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $DOTFILES_DIR_GIVEN -eq 1 && ${#SOURCE_ARGS[@]} -gt 0 ]]; then
    printf 'Cannot combine --source with --dotfiles-dir\n' >&2
    exit 1
fi

announce_modes() {
    if [[ $DEBUG_MODE -eq 1 ]]; then echo "Debug mode on"; fi
    if [[ $DRY_RUN -eq 1 ]]; then echo "Running in dry run mode, no real changes are made."; fi
    return 0
}

if [[ "${1:-}" == plan || "${1:-}" == explain || "${1:-}" == recover || "${1:-}" == migrate || "${1:-}" == ls ]]; then
    announce_modes >&2
elif [[ "${1:-}" != execstow && "${1:-}" != del ]]; then
    announce_modes
fi

if (($# == 0)); then
    usage
    exit 1
fi

script_dir=$(resolve_path "$(dirname "${BASH_SOURCE[0]}")")

if [[ "$1" == init ]]; then
    if [[ ${#SOURCE_ARGS[@]} -gt 0 ]]; then
        printf 'init PATH does not accept --source\n' >&2
        exit 1
    fi
    shift
    init_repo "$@"
    exit $?
fi

# Recovery uses recorded state and never requires available source checkouts.
if [[ "$1" == recover ]]; then
    shift
    if [[ $DRY_RUN -eq 1 && "${1:-}" != inspect ]]; then
        printf 'Recovery resume/restore does not accept --dry-run; use recover inspect for a read-only report.\n' >&2
        exit 1
    fi
    recovery_rc=0
    if [[ "${1:-}" == inspect || "${1:-}" == --help || "${1:-}" == -h || $# -eq 0 ]]; then
        perl "${script_dir}/bin/overlay_recover.pl" - - "$@" || recovery_rc=$?
    else
        source "${script_dir}/bin/source_registry.sh"
        source "${script_dir}/bin/stow_bridge.sh"
        dft_stow_run "/opt/stow-${STOW_VERSION:-2.4.1}/bin/stow" overlay_recover.pl "$@" || recovery_rc=$?
    fi
    exit "$recovery_rc"
fi

source "${script_dir}/bin/common.sh"
source "${script_dir}/bin/source_registry.sh"
source "${script_dir}/bin/discovery.sh"
source "${script_dir}/bin/stow_bridge.sh"
source "${script_dir}/bin/mutation_guard.sh"

stack_command() {
    case "$1" in
        ls)
            [[ $# -eq 1 ]] || { printf 'Usage: ls\n' >&2; return 1; }
            perl "${script_dir}/bin/overlay_command.pl" - - ls 1 - -
            ;;
        del|execstow)
            local action=delete stowcmd=delete
            if [[ "$1" == execstow ]]; then
                [[ $# -eq 2 ]] || { printf 'Usage: execstow stow|restow|delete\n' >&2; return 1; }
                stowcmd=$2
                case "$stowcmd" in
                    stow|restow) action=apply ;;
                    delete) ;;
                    *) printf 'Usage: execstow stow|restow|delete\n' >&2; return 1 ;;
                esac
            else
                [[ $# -eq 1 ]] || { printf 'Usage: del\n' >&2; return 1; }
            fi
            [[ "$stowcmd" == restow ]] || confirm_continue
            dft_overlay_command "$action" "$DRY_RUN" "$stowcmd" -
            ;;
        migrate)
            [[ $# -eq 3 && "$2" == --from && -n "$3" ]] || { printf 'Usage: migrate --from SOURCE_ID\n' >&2; return 1; }
            [[ $DRY_RUN -eq 1 ]] || confirm_continue
            dft_overlay_command migrate "$DRY_RUN" stow "$3"
            ;;
        *) dft_require_legacy; return 1 ;;
    esac
}

# Recorded inspection/deletion must not parse or discover absent sources.
if [[ $DOTFILES_DIR_GIVEN -eq 0 && ( "$1" == ls || "$1" == del || ( "$1" == execstow && "${2:-}" == delete ) ) ]]; then
    detected=0
    perl "${script_dir}/bin/overlay_command.pl" - - detect || detected=$?
    if [[ $detected -eq 0 ]]; then
        stack_command "$@"
        exit $?
    elif [[ $detected -ne 1 ]]; then
        exit "$detected"
    fi
fi
if ! dft_load_registry "$DOTFILES_DIR_ARG" "${SOURCE_ARGS[@]}"; then
    printf 'Dotfiles directory is not configured.\nCreate %s with dotfiles_dir=/path/to/dotfiles, or pass --dotfiles-dir PATH.\n' "$(dotfiletracker_config_path)" >&2
    exit 1
fi
if [[ "$DFT_MODE" == stack ]]; then
    # Public stack commands only; internal legacy helpers cannot be dispatched.
    if [[ "$1" == listdirs ]]; then
        [[ $# -eq 1 ]] || { printf 'Usage: listdirs\n' >&2; exit 1; }
        list_stack_directories
        exit $?
    fi
    if [[ "$1" == plan || "$1" == explain ]]; then
        if dft_overlay_plan "$@"; then
            exit 0
        else
            exit $?
        fi
    fi
    stack_command "$@"
    exit $?
fi
configure_dotfile_dir "$DFT_LEGACY_ROOT"

bold=""
boldend=""
if [[ -n "${TERM:-}" ]] && command -v tput >/dev/null 2>&1; then
	bold=$(tput bold 2>/dev/null || true)
	boldend=$(tput sgr0 2>/dev/null || true)
fi

#removes stowed links from $HOME
function del(){
	local links_to_remove=()
	local link_path

	while IFS= read -r link_path; do
		links_to_remove+=("$link_path")
	done < <(list_stowed_links 4)

	echo -e "Links to remove:\n"
	printf '%s\n' "${links_to_remove[@]}"
	echo ""
	if [[ ${#links_to_remove[@]} -eq 0 ]]; then
		echo "No links managed by ${dotfile_dir} were found."
		return 0
	fi
	confirm_continue
	echo ""
	if [[ $DRY_RUN -eq 1 ]]; then
		printf 'Would remove %s managed link(s); no links were changed.\n' "${#links_to_remove[@]}"
		return 0
	fi
	printf '%s\0' "${links_to_remove[@]}" | xargs -0 rm
}

declare -a directories=()

function listdirs(){
	find_matching_directories "$dotfile_parts_dir"
    echo -e "Directories found for this system:\n"
    for dir in "${directories[@]}"; do
	    if [ -d "$dir" ]; then
	        echo -e "\t${dir}"
	    else
	        echo -e "\t(cannot process directory $dir as it does not exist)"
	    fi
	done
}

#stows links from common and parts
function execstow(){
	local stowcmd=$1 #stow, delete or restow
	local dry_run_info_string="(but we are in dry-run mode)"
	local dirs_to_process_file
	local dir
	local package_dir
	local package_name
	local packages
	local stow_args
	local relative_dir
	local stow_verbosity
	local stow_verb
	local stow_version
	local stow_exec
	local dirtostow
	local cwd
	local stow_command_display
	local skip_stow_execution=0
	local processed_dir_count=0
	local processed_package_count=0
	local processed_file_count=0
	local changed_file_count=0
	local package_file_count
	local summary_verb
	local summary_dir_word
	local changed_note
	local before_link_states_file
	local after_link_states_file

	if [ -z "$stowcmd" ]; then
		echo "You need to specify the stow command: e.g. stow, delete or restow"
		exit 1
	fi

	if [[ "$stowcmd" != "stow" && "$stowcmd" != "restow" && "$stowcmd" != "delete" ]]; then
		echo "Unsupported stow command: $stowcmd"
		exit 1
	fi

	find_matching_directories "$dotfile_parts_dir"

	# Step 2: Loop through the array of directories
    debugEcho "Directories to process:"
    dirs_to_process_file="$(mktemp)"

	for dir in "${directories[@]}"; do
	    if [ -d "$dir" ]; then
	        echo -e "\t${dir}" >> "${dirs_to_process_file}"
	        debugEcho -e "\t${dir}"
	    else
	        echo -e "\t(cannot process directory $dir as it does not exist)"
	    fi
	done

	if verbose_enabled; then
		echo -e '\nDotfiles to process:\n'
		awk 'BEGIN { FS="/" } { print $(NF-1),$NF }' "${dirs_to_process_file}" | awk '{ if (!seen[$1]++) order[++n]=$1; items[$1]=(items[$1]?items[$1]", ":"")$2 } END{ for(i=1;i<=n;i++) print order[i]": "items[order[i]] }'
		echo ""
	fi
	# restow only ever adjusts already-backed-up conflicts and re-links
	# existing packages, so confirming it interactively on every run is
	# just noise -- unlike stow/delete, which need explicit consent since
	# they create or remove links for the first time.
	if [[ "$stowcmd" != "restow" ]]; then
		confirm_continue
		echo ""
	fi
	for dir in "${directories[@]}"; do
	    cd "$dir"
			packages=()
			while IFS= read -r -d '' package_dir; do
				package_name=$(basename "$package_dir")
				packages+=("$package_name")
			done < <(find "." -mindepth 1 -maxdepth 1 -type d -print0)

			if [[ ${#packages[@]} -eq 0 ]]; then
			echo "Nothing to stow found here at $dir"
			continue
		fi

		processed_dir_count=$((processed_dir_count + 1))
		processed_package_count=$((processed_package_count + ${#packages[@]}))
		for package_name in "${packages[@]}"; do
			package_file_count=0
			while IFS= read -r -d ''; do
				package_file_count=$((package_file_count + 1))
			done < <(find "./$package_name" -mindepth 1 ! -type d -print0)
			processed_file_count=$((processed_file_count + package_file_count))
		done

		if [[ $stowcmd == "stow" ]]; then
			while IFS= read -r relative_dir; do
				[[ -n "$relative_dir" ]] || continue
				if [[ $DRY_RUN -eq 0 ]]; then
					mkdir -p "$HOME/$relative_dir"
				elif [[ $DEBUG_MODE -eq 1 ]]; then
					echo "Would execute ${bold}mkdir -p \"$HOME/$relative_dir\"${boldend} ${dry_run_info_string}"
				fi
			done < <(find "." -mindepth 2 -type d | sed 's,^[^/]*/[^/]*/,,' )
		fi

		if [[ $stowcmd == "stow" || $stowcmd == "restow" ]]; then
			FOLDED_LINKS_FOUND=0
			unfold_foreign_directory_symlinks "$(pwd -P)" "${packages[@]}"
			BACKUP_CONFLICTS_FOUND=0
			backup_conflicting_targets "${packages[@]}"
			if [[ $DRY_RUN -eq 1 && $((BACKUP_CONFLICTS_FOUND + FOLDED_LINKS_FOUND)) -gt 0 ]]; then
				skip_stow_execution=1
			else
				skip_stow_execution=0
			fi
		else
			skip_stow_execution=0
		fi

		stow_verbosity=0
		if [[ $DEBUG_MODE -eq 1 ]]; then
			stow_verbosity=1
		fi

		stow_verb="Stowing"
		if [[ $DRY_RUN -eq 1 ]]; then
			stow_verb="Simulating stow ${dry_run_info_string}"
		fi
		
		stow_version="${STOW_VERSION:-2.4.1}"
		stow_exec="/opt/stow-$stow_version/bin/stow"
		if [[ ! -x "$stow_exec" ]]; then
			echo "Stow executable not found or not executable: $stow_exec"
			exit 1
		fi

		dirtostow="$(basename "$dir")"
		cwd=$(pwd)
		# --no-folding: every part is its own Stow directory, and a directory
		# folded into one part blocks all others that need it because of
		# cross-package ownership. Real directories with per-file links
		# can be shared.
		stow_args=( "--verbose=$stow_verbosity" "--no-folding" "--target=$HOME" )
		stow_command_display="${stow_exec} --verbose=${stow_verbosity} --no-folding --target=\"$HOME\""
		if [[ $DRY_RUN -eq 1 && $skip_stow_execution -eq 0 ]]; then
			stow_args+=( "--simulate" )
			stow_command_display="${stow_command_display} --simulate"
		fi
		stow_args+=( "--$stowcmd" )
		stow_command_display="${stow_command_display} --${stowcmd}"
		for package_name in "${packages[@]}"; do
			stow_args+=( "$package_name" )
			stow_command_display="${stow_command_display} ${package_name}"
		done

		if verbose_enabled; then
			echo "${stow_verb} ${bold}${dirtostow}${boldend} in ${bold}${cwd}${boldend} with command ${bold}${stow_command_display}${boldend}"
		fi
		if [[ $DRY_RUN -eq 1 && $skip_stow_execution -eq 1 ]]; then
			echo "Skipping Stow simulation because dry-run keeps conflicting files and folded directory symlinks in place; a real run resolves them first."
		else
			# Real-change reporting: diff link state before and
			# after Stow. Skipped in dry-run (nothing changes on disk) and in
			# debug mode (Stow's own --verbose=1 trace already shows it).
			if [[ $DRY_RUN -eq 0 && $DEBUG_MODE -eq 0 ]]; then
				before_link_states_file="$(mktemp)"
				snapshot_link_states "$before_link_states_file" "${packages[@]}"
			fi
			"$stow_exec" "${stow_args[@]}"
			if [[ $DRY_RUN -eq 0 && $DEBUG_MODE -eq 0 ]]; then
				after_link_states_file="$(mktemp)"
				snapshot_link_states "$after_link_states_file" "${packages[@]}"
				report_link_changes "$before_link_states_file" "$after_link_states_file" "$stowcmd"
				rm -f "$before_link_states_file" "$after_link_states_file"
			fi
		fi
	done

	summary_verb="Processed"
	if [[ $DRY_RUN -eq 1 ]]; then
		summary_verb="Would process"
	fi
	summary_dir_word="directory"
	[[ $processed_dir_count -eq 1 ]] || summary_dir_word="directories"
	changed_note=""
	if [[ $DRY_RUN -eq 0 && $changed_file_count -gt 0 ]]; then
		changed_note=" (${changed_file_count} changed)"
	fi
	echo "${summary_verb} ${processed_file_count} file(s) in ${processed_package_count} package(s) across ${processed_dir_count} ${summary_dir_word}${changed_note}."

	rm -f "${dirs_to_process_file}"

	run_post_stow_hooks "$stowcmd"
}

# Runs the dotfiles tree's own post-stow hooks, if it has any.
#
# envmaker is a generic Stow wrapper and stays policy-neutral: it knows only
# that a dotfiles tree may ship executables under hooks/post-stow.d/, and runs
# them after a real stow/restow has changed links. What they check is the
# dotfiles repo's business -- for example, a dependency check hook that
# runs after the links have been applied.
#
# Contract:
#   - Location: $dotfile_dir/hooks/post-stow.d/*, executable files only.
#   - Ordering: lexical, so a NN- prefix can sequence them.
#   - Argument: the stow command that just ran (stow|restow).
#   - Environment: DOTFILES_DIR is exported for the hook's convenience.
#   - Timing: after the links are in place, never in dry-run -- a hook is meant
#     to observe the state stow just produced, and in dry-run there is none.
#   - Exit status: reported as a warning and otherwise ignored. Stow has
#     already run; failing the wrapper afterwards would report a link operation
#     as failed when it in fact succeeded, and rolling back a completed restow
#     is worse than warning about it.
function run_post_stow_hooks(){
	local stowcmd=$1
	local hooks_dir="${dotfile_dir}/hooks/post-stow.d"
	local hook hook_status

	[[ "$stowcmd" == "stow" || "$stowcmd" == "restow" ]] || return 0
	[[ $DRY_RUN -eq 0 ]] || return 0
	[[ -d "$hooks_dir" ]] || return 0

	for hook in "$hooks_dir"/*; do
		[[ -f "$hook" && -x "$hook" ]] || continue
		hook_status=0
		DOTFILES_DIR="$dotfile_dir" dft_run_external "$hook" "$stowcmd" || hook_status=$?
		if [[ $hook_status -ne 0 ]]; then
			echo "Warning: post-stow hook ${hook##*/} reported a problem (exit ${hook_status})." >&2
		fi
	done

	return 0
}

#lists stowed links in $HOME
function ls(){
	echo -e "Symlinks to dotfiles:\n"
	list_stowed_links 2
}

# Extract the function name from the first argument
function_name=$1

# Remove the first argument and keep the rest
shift

# Public dispatch only: internal helpers cannot bypass the shared mutation guard.
case "$function_name" in
    execstow|del)
        dft_guard_legacy_entry "$DRY_RUN" "${script_dir}/envmaker.sh" "${ORIGINAL_ARGS[@]}"
        announce_modes
        "$function_name" "$@"
        ;;
    listdirs|ls) "$function_name" "$@" ;;
    *)
        echo "Error: Function '$function_name' not found"
        usage
        exit 1
        ;;
esac
