#!/bin/sh

set -eu

fail() {
    # 输出错误并终止脚本。
    printf '%s\n' "$1" >&2
    exit 1
}

command -v npx >/dev/null 2>&1 || fail 'npx is required to run oxfmt'

exec npx --yes oxfmt@latest "$@"