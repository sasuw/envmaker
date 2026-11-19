# shellcheck shell=bash
# Shared source-local selection; sourced by envmaker.sh.

#rules check (from rules dir, each script should return 0 or 1)
check_and_execute_rule() {
    local file_path="$1"
    local rule_name
    local rule_exit
    debugEcho "Starting check_and_execute_rule with file path ${file_path}"

    # Check if the file exists
    if [[ -f "$file_path" ]]; then
        [[ -x "$file_path" ]] || return 1
        rule_name=$(basename "${file_path}")
        debugEcho "We found a rule with name $rule_name, let's execute the rule script."

        # Execute the script
        if dft_run_external "$file_path" >/dev/null; then
            debugEcho "Rule script executed successfully with return value 0."
            if verbose_enabled; then
                echo "Rule $rule_name active"
            fi
            return 0 # Return true (0) on success
        else
            rule_exit=$?
            debugEcho "Rule script execution failed with exit code $rule_exit."
            debugEcho "Rule $rule_name not active"
            return 1 # Return false (1) on failure
        fi
    else
        debugEcho "We did not find a rule script with file path ${file_path}"
        return 2 # Return false (1) if the file doesn't exist
    fi
}

find_matching_directories() {
    # The base directory you want to search in
    local base_dir="$1"
    local dir
    local dir_name
    local result
    local dir_to_add
    local cmd_result
    local subdir
    local subdir_name

    directories=()

    if [[ ! -d "$base_dir" ]]; then
        echo "Dotfile parts directory not found: $base_dir"
        return 1
    fi

    # Loop through each subdirectory in the base directory
    for dir in "$base_dir"/*/; do
        [[ -d "$dir" ]] || continue
        dir_name=$(basename "$dir")

        set +e
        check_and_execute_rule "${rules_dir}/${dir_name}"
        result=$?
        set -e
        local dir_to_add="${base_dir}/${dir_name}"
        if [[ $result -eq 0 ]]; then
            debugEcho "Adding directory based on RULE: ${dir_name}"
            directories+=("$dir_to_add")
        elif [[ $result -eq 1 ]]; then
            debugEcho "Not adding directory based on RULE: ${dir_name}, also not checking further"
        else
            # Execute the directory name as a command and store the result
            debugEcho "Directory ${dir_name} is not rule-based."
            if command -v "$dir_name" >/dev/null 2>&1; then
                set +e
                cmd_result=$(dft_run_external "$dir_name" 2>/dev/null)
                set -e
            else
                cmd_result=""
            fi

            if [ -z "$cmd_result" ]; then
                #Here we have directories which can not be directly evaluated
                debugEcho "Directory ${dir_name} cannot be executed as a command, let's iterate the subdirectories of it."
                for subdir in "$base_dir/$dir_name"/*/; do
                    [[ -d "$subdir" ]] || continue
                    #directory name is not a command, let's check further if any subdir is an executable
                    subdir_name=$(basename "$subdir")
                    if command -v "$subdir_name" >/dev/null; then
                        debugEcho "Subdirectory ${subdir_name} found"
                        directories+=("$base_dir/$dir_name/$subdir_name")
                    else
                        debugEcho "Subdirectory ${subdir_name} not found"
                    fi
                done
            else
                #Here we have directories which can be directly evaluated as commands, e.g. "hostname"
                #TODO: refactor, ugly construct
                dir_to_add=$(find "$base_dir/$dir_name/" -maxdepth 1 -type d \( -name "$cmd_result*OR*" -o -name "*OR*$cmd_result" \) -print -quit)
                debugEcho "Checking OR-dir ${dir_to_add}"
                if [[ -n "$dir_to_add" && -d "$dir_to_add" ]]; then
                    debugEcho "Adding ${dir_to_add}"
                    directories+=("$dir_to_add")
                fi

                dir_to_add="$base_dir/$dir_name/$cmd_result"
                debugEcho "Checking dir ${dir_to_add}"
                if [ -d "$dir_to_add" ]; then
                    debugEcho "Adding ${dir_to_add}"
                    directories+=("$dir_to_add")
                fi
            fi
        fi
        debugEcho -e "--------------------------\n"
    done

    if [ -d "$dotfile_dir/common" ]; then
        directories+=("$dotfile_dir/common")
    fi
}

# Root-local interface. Bash dynamic scope keeps legacy discovery intact while
# each stack source receives its own rule context. Rules retain the caller cwd.
discover_source() {
    local dotfile_dir="$1"
    local dotfile_parts_dir="$1/parts"
    local rules_dir="$1/rules"
    local DOTFILES_DIR="$1"
    local DOTFILETRACKER_SOURCE_ID="$2"
    export DOTFILES_DIR DOTFILETRACKER_SOURCE_ID
    find_matching_directories "$dotfile_parts_dir"
}

# Freeze discovery once, preserving source order and separate Stow/package
# identities. These arrays are the input boundary for the later winner planner.
discover_stack_packages() {
    local i dir package_dir
    STACK_DIRECTORY_SOURCES=()
    STACK_DIRECTORY_PATHS=()
    STACK_PACKAGE_SOURCES=()
    STACK_PACKAGE_PATHS=()
    for ((i = 0; i < ${#DFT_SOURCE_IDS[@]}; i++)); do
        discover_source "${DFT_SOURCE_ROOTS[i]}" "${DFT_SOURCE_IDS[i]}" || return 1
        for dir in "${directories[@]+"${directories[@]}"}"; do
            STACK_DIRECTORY_SOURCES+=("${DFT_SOURCE_IDS[i]}")
            STACK_DIRECTORY_PATHS+=("$dir")
            for package_dir in "$dir"/*/; do
                [[ -d "$package_dir" ]] || continue
                STACK_PACKAGE_SOURCES+=("${DFT_SOURCE_IDS[i]}")
                STACK_PACKAGE_PATHS+=("${package_dir%/}")
            done
        done
    done
}

# Raw candidate inventory for a frozen selected package. NUL termination keeps
# spaces, delimiters and embedded newlines intact. find's default physical walk
# reports source symlinks as entries without descending into their targets.
# Ignore filtering, type validation and precedence belong to the next phase.
enumerate_source_entries() {
    find "$1" -mindepth 1 -print0
}

list_stack_directories() {
    local i
    discover_stack_packages || return 1
    printf 'Directories found for this system (source-qualified):\n\n'
    i=0
    while [[ ${STACK_DIRECTORY_PATHS[i]+present} ]]; do
        printf '    %s:%s\n' "${STACK_DIRECTORY_SOURCES[i]}" "${STACK_DIRECTORY_PATHS[i]}"
        i=$((i + 1))
    done
}
