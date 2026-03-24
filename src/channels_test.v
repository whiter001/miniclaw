module main

import os

fn test_parse_channels_login_target_accepts_positional_channel() {
	assert parse_channels_login_target(['openclaw-weixin']) == 'openclaw-weixin'
	assert parse_channels_login_target(['--channel', 'openclaw-weixin']) == 'openclaw-weixin'
	assert parse_channels_login_target(['--help']) == ''
}

fn test_build_openclaw_weixin_login_args_normalizes_login_command() {
	args := build_openclaw_weixin_login_args()
	assert args == ['channels', 'login', '--channel', 'openclaw-weixin']
}

fn test_channels_login_state_helpers_write_files() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-channels-login')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
	}
	append_channels_login_event(config, 'openclaw-weixin', 'requested', 'login flow requested') or {
		panic(err)
	}
	write_channels_login_state(config, 'openclaw-weixin', 'awaiting_scan', 'qr code should now be visible in terminal') or {
		panic(err)
	}
	state_path := os.join_path(workspace, 'state', channels_login_state_file)
	log_path := os.join_path(workspace, 'state', channels_login_events_file)
	assert os.exists(state_path)
	assert os.exists(log_path)
	assert (os.read_file(state_path) or { '' }).contains('awaiting_scan')
	assert (os.read_file(log_path) or { '' }).contains('requested')
}

fn test_run_channels_status_reads_state_file() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-channels-status')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
	}
	state_path := os.join_path(workspace, 'state', channels_login_state_file)
	os.write_file(state_path, '{"ts":"2026-03-24T00:00:00Z","channel":"openclaw-weixin","status":"awaiting_scan","detail":"qr ready"}') or {
		panic(err)
	}
	assert run_channels_status(config) == 0
}
