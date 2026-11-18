#!/usr/bin/env bash

function confirm_continue() {
    if [[ "${ASSUME_YES:-0}" == "1" || "${ASSUME_YES:-0}" == "true" || "${ASSUME_YES:-0}" == "yes" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        echo "envmaker.sh: confirmation required but stdin is not a TTY; pass --yes to continue" >&2
        exit 1
    fi

    while true; do
        read -r -n 1 -s -p "Do you wish to continue? (y/n): " yn
        echo  # Moves to a new line
        case $yn in
            [Yy]* ) echo "Continuing..."; break;;
            [Nn]* ) echo "Terminating..."; exit 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

function ostype() {
    if [ -n "$OSTYPE" ]; then
        case "$OSTYPE" in
            solaris*) echo "solaris" ;;
            darwin*)  echo "macos" ;;
            linux*)   echo "linux" ;;
            *bsd*)     echo "bsd" ;;
            msys*)    echo "windows" ;;
            cygwin*)  echo "windows" ;;
            *)        echo "unknown: $OSTYPE" ;;
        esac
    else
        # Fallback method for determining the OS type
        case "$(uname)" in
            SunOS)    echo "solaris" ;;
            Darwin)   echo "macos" ;;
            Linux)    echo "linux" ;;
            FreeBSD|OpenBSD|NetBSD)  echo "bsd" ;;
            CYGWIN*|MINGW*|MSYS*)    echo "windows" ;;
            *)        echo "unknown" ;;
        esac
    fi
}

function getCmdNameForCurrentPlatform() {
	local cmdname="$1"
	os_category=$(ostype)
	if [[ $os_category == linux ]]; then
		cmdname="$1"
	else
		#GNU version if available
		if command -v "g$1" &> /dev/null; then
			cmdname="g$1"
		fi
	fi
	echo "${cmdname}"
}

function source_all_sh_files_in_subdir_of_home(){
	local subdir=$1
	if [ -z "${subdir}" ]; then
	    echo "${subdir} is unset or set to an empty string"
	    return
	fi

	local subdir_complete="$HOME/$subdir"
	if [[ ! -d "$subdir_complete" ]]; then
		return
	fi

	source_all_sh_files_in_directory "${subdir_complete}"
}

function source_all_sh_files_in_directory(){
	local dir=$1
	if [ -z "${dir}" ]; then
	    echo "${dir} is unset or set to an empty string"
	    return
	fi

	for file in "$dir"/*; do
	  if [[ -f "$file" ]]; then
	    # shellcheck source=/dev/null
	    source "${file}"
	  fi
	done
}

function source_localenv_files(){
	local localenv_pc_dir=".localenv-$1-pc-${PC_NAME}"
	source_all_sh_files_in_subdir_of_home "${localenv_pc_dir}"

	local localenv_os_dir=".localenv-$1-os-${OS_CATEGORY}"
	source_all_sh_files_in_subdir_of_home "${localenv_os_dir}"
}

function source_localenv_non_interactive_files(){
	source_localenv_files "non-interactive"
}

function source_localenv_interactive_files(){
	source_localenv_files "interactive"
}

OS_CATEGORY=$(ostype)
PC_NAME=$(hostname)
