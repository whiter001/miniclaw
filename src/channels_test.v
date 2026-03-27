module main

import os

fn test_parse_channels_login_target_accepts_positional_channel() {
	assert parse_channels_login_target(['weixin']) == 'weixin'
	assert parse_channels_login_target(['--channel', 'weixin']) == 'weixin'
	assert parse_channels_login_target(['--help']) == ''
}

fn test_build_channels_login_session_is_local_only() {
	session := build_channels_login_session('weixin')
	assert session.channel == 'weixin'
	assert session.session_id.starts_with('WX-')
	assert session.pairing_url.contains('miniclaw://weixin/login')
}

fn test_write_channels_login_qr_svg_writes_image_file() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-channels-qr-svg')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
	}
	session := build_channels_login_session('weixin')
	svg_path := write_channels_login_qr_svg(config, session) or { panic(err) }
	assert os.exists(svg_path)
	svg_content := os.read_file(svg_path) or { '' }
	assert svg_content.contains('<svg')
	assert svg_content.contains('MiniClaw Weixin login pairing code')
	assert svg_content.contains('session:')
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
	append_channels_login_event(config, 'weixin', 'requested', 'login flow requested') or {
		panic(err)
	}
	write_channels_login_state(config, 'weixin', 'awaiting_scan', 'local pairing code displayed') or {
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
	os.write_file(state_path, '{"ts":"2026-03-24T00:00:00Z","channel":"weixin","status":"awaiting_scan","detail":"qr ready"}') or {
		panic(err)
	}
	assert run_channels_status(config) == 0
}
