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
