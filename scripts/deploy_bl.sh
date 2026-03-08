#!/bin/bash

set -euo pipefail

host="${MINICLAW_DEPLOY_HOST:-bl}"
remote_user="${MINICLAW_REMOTE_USER:-root}"
remote_home="${MINICLAW_REMOTE_HOME:-/root}"
remote_repo="${MINICLAW_REMOTE_REPO:-/bl/project/miniclaw/repo}"
remote_config="${MINICLAW_REMOTE_CONFIG:-$remote_home/.config/miniclaw/config}"
remote_service="${MINICLAW_REMOTE_SERVICE:-miniclaw-gateway}"
service_memory_high="${MINICLAW_SERVICE_MEMORY_HIGH:-96M}"
service_memory_max="${MINICLAW_SERVICE_MEMORY_MAX:-128M}"
service_cpu_quota="${MINICLAW_SERVICE_CPU_QUOTA:-50%}"
service_tasks_max="${MINICLAW_SERVICE_TASKS_MAX:-64}"
v_archive="${MINICLAW_V_ARCHIVE:-/tmp/v-master.zip}"
deploy_workspace="${MINICLAW_DEPLOY_WORKSPACE:-$PWD}"

log() {
    printf '[deploy] %s\n' "$*"
}

fail() {
    printf '[deploy] error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

run_ssh() {
    ssh "${remote_user}@${host}" "$@"
}

sync_repo() {
    log "syncing repository to $host:$remote_repo"
    COPYFILE_DISABLE=1 tar \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='sessions' \
        --exclude='miniclaw' \
        --exclude='tmp-tool-test.txt' \
        --exclude='._*' \
        -czf - . | run_ssh "mkdir -p '$remote_repo' && find '$remote_repo' -name '._*' -delete && cd '$remote_repo' && tar xzf - && find . -name '._*' -delete"
}

upgrade_vlang_if_needed() {
    if [ ! -f "$v_archive" ]; then
        log "v archive not found at $v_archive, skipping remote V upgrade"
        return
    fi

    log "uploading V archive $v_archive"
    scp "$v_archive" "${remote_user}@${host}:/tmp/v-master.zip"

    log "upgrading remote V using /tmp/v-master.zip"
    run_ssh "set -e
stamp=\
\$(date +%Y%m%d-%H%M%S)
rm -rf '$remote_home/v-master'
unzip -q -o /tmp/v-master.zip -d '$remote_home'
if [ -d '$remote_home/v/vc' ]; then
    cp -a '$remote_home/v/vc' '$remote_home/v-master/'
fi
mkdir -p '$remote_home/v-master/thirdparty'
if [ -d '$remote_home/v/thirdparty/tcc' ]; then
    cp -a '$remote_home/v/thirdparty/tcc' '$remote_home/v-master/thirdparty/'
fi
cd '$remote_home/v-master'
if ! make local=1 >/tmp/miniclaw-v-build.log 2>&1; then
    tail -n 80 /tmp/miniclaw-v-build.log >&2
    exit 1
fi
tail -n 20 /tmp/miniclaw-v-build.log
if [ -d '$remote_home/v' ]; then
    mv '$remote_home/v' '$remote_home/v.backup-'\$stamp
fi
mv '$remote_home/v-master' '$remote_home/v'
ln -sfn '$remote_home/v/v' /usr/local/bin/v
/usr/local/bin/v version"
}

ensure_remote_uvx() {
    log "ensuring uv and uvx are available on remote host"
    run_ssh "set -e
if ! command -v uvx >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
if [ -x '$remote_home/.local/bin/uvx' ] && [ ! -x /usr/local/bin/uvx ]; then
    ln -sfn '$remote_home/.local/bin/uvx' /usr/local/bin/uvx
fi
if [ -x '$remote_home/.local/bin/uv' ] && [ ! -x /usr/local/bin/uv ]; then
    ln -sfn '$remote_home/.local/bin/uv' /usr/local/bin/uv
fi
command -v uvx"
}

enable_remote_mcp() {
    log "enabling built-in MCP in remote config"
    run_ssh "set -e
config='$remote_config'
mkdir -p \"\$(dirname \"\$config\")\"
touch \"\$config\"
grep -q '^enable_mcp=' \"\$config\" && sed -i 's/^enable_mcp=.*/enable_mcp=true/' \"\$config\" || printf '\nenable_mcp=true\n' >> \"\$config\"
grep -q '^mcp_resource_mode=' \"\$config\" || printf 'mcp_resource_mode=url\n' >> \"\$config\"
grep -q '^mcp_config_path=' \"\$config\" || printf 'mcp_config_path=$remote_home/.config/miniclaw/mcp.json\n' >> \"\$config\"
grep -E '^(enable_mcp|mcp_resource_mode|mcp_config_path)=' \"\$config\""
}

apply_remote_service_limits() {
    log "applying systemd resource limits for $remote_service"
    run_ssh "set -e
override_dir='/etc/systemd/system/$remote_service.service.d'
mkdir -p \"\$override_dir\"
cat > \"\$override_dir/override.conf\" <<'EOF'
[Service]
MemoryHigh=$service_memory_high
MemoryMax=$service_memory_max
CPUQuota=$service_cpu_quota
TasksMax=$service_tasks_max
EOF
systemctl daemon-reload
systemctl show '$remote_service' -p MemoryHigh -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax"
}

rebuild_remote_binary() {
    log "building MiniClaw on remote host"
    run_ssh "set -e
cd '$remote_repo'
./build.sh
systemctl restart '$remote_service'
systemctl is-active '$remote_service'"
}

verify_remote_web_search() {
    log "verifying remote web_search MCP tool"
    run_ssh "set -e
timeout 120s '$remote_repo/miniclaw' agent --workspace '$remote_repo' --mcp -p '请务必使用 web_search 工具搜索 MiniMax MCP guide，并只输出四个汉字：验证通过。' > /tmp/miniclaw-mcp-websearch.out 2>&1
grep -qx '验证通过' /tmp/miniclaw-mcp-websearch.out
latest=\$(ls -t '$remote_repo'/sessions | head -n 1)
grep -q '\"tool_name\":\"web_search\"' '$remote_repo/sessions/'\"\$latest\""
}

verify_remote_understand_image() {
    log "verifying remote understand_image MCP tool"
    run_ssh "set -e
timeout 120s '$remote_repo/miniclaw' agent --workspace '$remote_repo' --mcp -p '请务必使用 understand_image 工具分析这张图片：https://httpbin.org/image/png 。只用四个汉字输出：图像可用。' > /tmp/miniclaw-mcp-image.out 2>&1
grep -qx '图像可用' /tmp/miniclaw-mcp-image.out
latest=\$(ls -t '$remote_repo'/sessions | head -n 1)
grep -q '\"tool_name\":\"understand_image\"' '$remote_repo/sessions/'\"\$latest\""
}

main() {
    require_cmd ssh
    require_cmd scp
    require_cmd tar
    require_cmd unzip

    cd "$deploy_workspace"
    log "starting deploy to $host"
    sync_repo
    upgrade_vlang_if_needed
    ensure_remote_uvx
    enable_remote_mcp
    apply_remote_service_limits
    rebuild_remote_binary
    verify_remote_web_search
    verify_remote_understand_image
    log "deploy completed successfully"
}

main "$@"