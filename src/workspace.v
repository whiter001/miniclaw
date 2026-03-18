module main

import os

const workspace_directories = [
	'sessions',
	'memory',
	'state',
	'cron',
	'skills',
]

fn ensure_workspace(config Config) ! {
	// 创建 MiniClaw 运行所需的工作区目录和说明文件。
	os.mkdir_all(config.home_dir)!
	os.mkdir_all(config.workspace)!
	for name in workspace_directories {
		os.mkdir_all(os.join_path(config.workspace, name))!
	}
	ensure_workspace_file(os.join_path(config.workspace, 'AGENTS.md'), '# MiniClaw Agent Guide\n')!
	ensure_workspace_file(os.join_path(config.workspace, 'USER.md'), '# User Preferences\n')!
	ensure_workspace_file(os.join_path(config.workspace, 'HEARTBEAT.md'), '# Periodic Tasks\n')!
	memory_store_for_workspace(config.workspace).ensure_defaults()!
}

fn ensure_workspace_file(path string, content string) ! {
	// 仅在文件不存在时写入默认内容。
	if os.exists(path) {
		return
	}
	os.write_file(path, content)!
}
