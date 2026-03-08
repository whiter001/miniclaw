#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

has_command() {
    command -v "$1" >/dev/null 2>&1
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

contains_secret_value() {
    grep -Eq '((api_key|qq_token|qq_app_secret)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9._-]{8,}["'"'"']?)|(["'"'"'](api_key|qq_token|qq_app_secret)["'"'"'][[:space:]]*:[[:space:]]*["'"'"'][A-Za-z0-9._-]{8,}["'"'"'])' "$1"
}

contains_sensitive_identifier_value() {
    grep -Eq '((access_token|user_openid|union_openid|openid)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9._-]{6,}["'"'"']?)|(["'"'"'](access_token|user_openid|union_openid|openid)["'"'"'][[:space:]]*:[[:space:]]*["'"'"'][A-Za-z0-9._-]{6,}["'"'"'])' "$1"
}

block_path() {
    case "$1" in
        sessions/*|state/*|memory/*|cron/*|skills/*|*.jsonl|tmp-tool-test.txt|102862145.json|USER.md|HEARTBEAT.md)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

format_v_files() {
    has_command v || fail 'release check failed: `v` not found'
    v_files=$(git ls-files '*.v')
    [ -z "$v_files" ] || v fmt -w $v_files
}

format_md_files() {
    has_command oxfmt || fail 'release check failed: `oxfmt` not found'
    md_files=$(git ls-files '*.md')
    if [ -n "$md_files" ]; then
        for path in $md_files; do
            oxfmt "$path"
        done
    fi
}

check_tracked_blocked_paths() {
    tracked_files=$(git ls-files)
    for path in $tracked_files; do
        if block_path "$path"; then
            fail "release check failed: sensitive or runtime file is tracked: $path"
        fi
    done
}

check_worktree_blocked_paths() {
    worktree_files=$(git status --short | awk '{print $2}')
    for path in $worktree_files; do
        if block_path "$path"; then
            fail "release check failed: sensitive or runtime file present in worktree changes: $path"
        fi
    done
}

scan_sensitive_content() {
    tracked_files=$(git ls-files)
    for path in $tracked_files; do
        case "$path" in
            *.v|*.md|*.sh|v.mod|.gitignore|AGENTS.md)
                if contains_secret_value "$path"; then
                    fail "release check failed: secret-like config value detected in $path"
                fi
                if contains_sensitive_identifier_value "$path"; then
                    fail "release check failed: sensitive identifier content detected in $path"
                fi
                ;;
        esac
    done
}

run_build_and_tests() {
    ./build.sh
    v test src
}

printf '%s\n' '==> Formatting V files'
format_v_files

printf '%s\n' '==> Formatting Markdown files'
format_md_files

printf '%s\n' '==> Checking blocked paths'
check_tracked_blocked_paths
check_worktree_blocked_paths

printf '%s\n' '==> Scanning for sensitive content'
scan_sensitive_content

printf '%s\n' '==> Running build and tests'
run_build_and_tests

printf '%s\n' 'release check passed'
