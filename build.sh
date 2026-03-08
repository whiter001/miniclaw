#!/bin/bash

set -e

find_cmd() {
    local name="$1"
    shift

    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi

    local candidate
    for candidate in "$@"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

v_bin="$(find_cmd v /opt/homebrew/bin/v /usr/local/bin/v "$HOME/bin/v" "$HOME/.local/bin/v")" || {
    echo "V compiler not found. Please install V from https://vlang.io/"
    exit 1
}

echo "Building MiniClaw..."
"$v_bin" -o miniclaw src/
echo "Build complete: ./miniclaw"