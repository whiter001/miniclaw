#!/bin/sh

set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

staged_files=$(git diff --cached --name-only --diff-filter=ACMR)

if [ -z "$staged_files" ]; then
    exit 0
fi

has_command() {
    command -v "$1" >/dev/null 2>&1
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

contains_secret_value() {
    grep -Eq '((api_key|qq_token|qq_app_secret)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9._-]{8,}["'"'"']?)|(["'"'"'](api_key|qq_token|qq_app_secret)["'"'"'][[:space:]]*:[[:space:]]*["'"'"'][A-Za-z0-9._-]{8,}["'"'"'])'
}

contains_sensitive_identifier_value() {
    grep -Eq '((access_token|user_openid|union_openid|openid)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9._-]{6,}["'"'"']?)|(["'"'"'](access_token|user_openid|union_openid|openid)["'"'"'][[:space:]]*:[[:space:]]*["'"'"'][A-Za-z0-9._-]{6,}["'"'"'])'
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
    v_files=''
    for path in $staged_files; do
        case "$path" in
            *.v)
                v_files="$v_files $path"
                ;;
        esac
    done

    if [ -n "$v_files" ]; then
        has_command v || fail 'pre-commit blocked: `v` not found for V formatting'
        # shellcheck disable=SC2086
        v fmt -w $v_files
        # shellcheck disable=SC2086
        git add $v_files
    fi
}

format_md_files() {
    md_files=''
    for path in $staged_files; do
        case "$path" in
            *.md)
                md_files="$md_files $path"
                ;;
        esac
    done

    if [ -n "$md_files" ]; then
        has_command oxfmt || fail 'pre-commit blocked: `oxfmt` not found for Markdown formatting'
        for path in $md_files; do
            oxfmt "$path"
            git add "$path"
        done
    fi
}

check_blocked_paths() {
    for path in $staged_files; do
        if block_path "$path"; then
            fail "pre-commit blocked: sensitive or runtime file staged: $path"
        fi
    done
}

check_staged_content() {
    for path in $staged_files; do
        blob=$(git show ":$path" 2>/dev/null || true)
        [ -n "$blob" ] || continue

        printf '%s' "$blob" | contains_secret_value && \
            fail "pre-commit blocked: secret-like config value detected in $path"

        printf '%s' "$blob" | contains_sensitive_identifier_value && \
            fail "pre-commit blocked: sensitive identifier content detected in $path"
    done
}

format_v_files
format_md_files
check_blocked_paths
check_staged_content

exit 0
