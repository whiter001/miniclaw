#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
oxfmt_entry="$repo_root/node_modules/oxfmt/bin/oxfmt"

fail() {
    # 输出错误并终止脚本。
    printf '%s\n' "$1" >&2
    exit 1
}

find_node() {
    # 查找可用于运行本地 oxfmt 的 Node 可执行文件。
    if [ -n "${NODE:-}" ] && [ -x "${NODE}" ]; then
        printf '%s\n' "$NODE"
        return 0
    fi

    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi

    for candidate in /opt/homebrew/bin/node /usr/local/bin/node /opt/homebrew/opt/node/bin/node; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

[ -f "$oxfmt_entry" ] || fail 'oxfmt is not installed in this repository; run `pnpm install`'

node_bin=$(find_node) || fail 'node is not available for repository-local oxfmt'

exec "$node_bin" "$oxfmt_entry" "$@"