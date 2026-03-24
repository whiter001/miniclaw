module main

import os
import time

const channels_login_state_file = 'channels_login_state.json'
const channels_login_events_file = 'channels_login_events.jsonl'

fn run_channels(config Config, args []string) int {
	// 处理 MiniClaw 的 channels 兼容入口。
	ensure_workspace(config) or {
		eprintln('failed to prepare workspace: ${err.msg()}')
		return 1
	}
	if args.len == 0 {
		eprintln('usage: miniclaw channels [status|login --channel openclaw-weixin]')
		return 1
	}
	match args[0] {
		'status' {
			return run_channels_status(config)
		}
		'login' {
			return run_channels_login(config, args[1..])
		}
		else {
			eprintln('unknown channels command: ${args[0]}')
			eprintln('supported: status, login')
			return 1
		}
	}
}

fn run_channels_status(config Config) int {
	// 输出当前 channels 登录状态摘要。
	state_path := os.join_path(config.workspace, 'state', channels_login_state_file)
	if !os.exists(state_path) {
		println('channels status: not started')
		println('channel: openclaw-weixin')
		println('state file: ${state_path}')
		return 0
	}
	state_json := os.read_file(state_path) or {
		eprintln('failed to read channels login state: ${err.msg()}')
		return 1
	}
	channel := decode_json_string(extract_json_string_value(state_json, 'channel'))
	status := decode_json_string(extract_json_string_value(state_json, 'status'))
	detail := decode_json_string(extract_json_string_value(state_json, 'detail'))
	ts := decode_json_string(extract_json_string_value(state_json, 'ts'))
	println('channels status: ${if status.len > 0 { status } else { 'unknown' }}')
	println('channel: ${if channel.len > 0 { channel } else { 'openclaw-weixin' }}')
	println('detail: ${detail}')
	println('updated at: ${ts}')
	println('state file: ${state_path}')
	return 0
}

fn run_channels_login(config Config, args []string) int {
	// 先把 `channels login` 接到 openclaw-weixin 登录流。
	channel := parse_named_arg(args, '--channel')
	resolved_channel := if channel.len > 0 { channel } else { parse_channels_login_target(args) }
	if resolved_channel.len == 0 {
		eprintln('usage: miniclaw channels login --channel openclaw-weixin')
		return 1
	}
	if resolved_channel != 'openclaw-weixin' {
		eprintln('unsupported channel: ${resolved_channel}')
		eprintln('supported channel: openclaw-weixin')
		return 1
	}
	append_channels_login_event(config, resolved_channel, 'requested', 'login flow requested') or {}
	write_channels_login_state(config, resolved_channel, 'requested', 'login flow requested') or {}
	openclaw_command := os.find_abs_path_of_executable('openclaw') or {
		append_channels_login_event(config, resolved_channel, 'missing_dependency', 'openclaw not found in PATH') or {}
		write_channels_login_state(config, resolved_channel, 'missing_dependency', 'openclaw not found in PATH') or {}
		eprintln('openclaw not found in PATH.')
		eprintln('install OpenClaw first, then run:')
		eprintln('  openclaw plugins install "@tencent-weixin/openclaw-weixin"')
		eprintln('  openclaw config set plugins.entries.openclaw-weixin.enabled true')
		eprintln('  openclaw channels login --channel openclaw-weixin')
		return 1
	}
	mut proc := os.new_process(openclaw_command)
	proc.use_pgroup = true
	proc.set_args(build_openclaw_weixin_login_args())
	proc.set_redirect_stdio()
	append_channels_login_event(config, resolved_channel, 'starting', 'launching openclaw login process') or {}
	write_channels_login_state(config, resolved_channel, 'starting', 'launching openclaw login process') or {}
	proc.run()
	if !proc.is_alive() {
		proc.close()
		append_channels_login_event(config, resolved_channel, 'failed_to_start', 'openclaw exited before login flow started') or {}
		write_channels_login_state(config, resolved_channel, 'failed_to_start', 'openclaw exited before login flow started') or {}
		eprintln('openclaw exited before the login flow could start.')
		return 1
	}
	append_channels_login_event(config, resolved_channel, 'awaiting_scan', 'qr code should now be visible in terminal') or {}
	write_channels_login_state(config, resolved_channel, 'awaiting_scan', 'qr code should now be visible in terminal') or {}
	println('OpenClaw Weixin login started. Scan the QR code shown by openclaw in the terminal.')
	proc.wait()
	proc.close()
	append_channels_login_event(config, resolved_channel, 'finished', 'openclaw login process ended') or {}
	write_channels_login_state(config, resolved_channel, 'finished', 'openclaw login process ended') or {}
	return 0
}

fn parse_channels_login_target(args []string) string {
	// 兼容 `miniclaw channels login openclaw-weixin` 这类简写。
	for arg in args {
		if arg.len == 0 || arg.starts_with('-') {
			continue
		}
		return arg
	}
	return ''
}

fn build_openclaw_weixin_login_args() []string {
	// 只保留 login 所需的最小参数集合。
	return ['channels', 'login', '--channel', 'openclaw-weixin']
}

fn append_channels_login_event(config Config, channel string, status string, detail string) ! {
	// 记录 channels 登录过程中的关键事件。
	log_path := os.join_path(config.workspace, 'state', channels_login_events_file)
	existing := if os.exists(log_path) { os.read_file(log_path) or { '' } } else { '' }
	line := '{"ts":"${escape_json_string(time.now().str())}","channel":"${escape_json_string(channel)}","status":"${escape_json_string(status)}","detail":"${escape_json_string(detail)}"}\n'
	os.write_file(log_path, existing + line)!
}

fn write_channels_login_state(config Config, channel string, status string, detail string) ! {
	// 记录最新的 channels 登录状态，方便后续查看本地登录流程。
	state_path := os.join_path(config.workspace, 'state', channels_login_state_file)
	state_json := '{"ts":"${escape_json_string(time.now().str())}","channel":"${escape_json_string(channel)}","status":"${escape_json_string(status)}","detail":"${escape_json_string(detail)}"}'
	os.write_file(state_path, state_json)!
}
