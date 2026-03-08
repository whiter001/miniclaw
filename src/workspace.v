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
	os.mkdir_all(config.home_dir)!
	os.mkdir_all(config.workspace)!
	for name in workspace_directories {
		os.mkdir_all(os.join_path(config.workspace, name))!
	}
	ensure_workspace_file(os.join_path(config.workspace, 'AGENTS.md'), '# MiniClaw Agent Guide\n')!
	ensure_workspace_file(os.join_path(config.workspace, 'USER.md'), '# User Preferences\n')!
	ensure_workspace_file(os.join_path(config.workspace, 'HEARTBEAT.md'), '# Periodic Tasks\n')!
}

fn ensure_workspace_file(path string, content string) ! {
	if os.exists(path) {
		return
	}
	os.write_file(path, content)!
}
