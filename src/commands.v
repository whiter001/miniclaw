module main

import os

fn run_onboard(config Config) int {
	mut created_config := false
	// 初始化本地配置和工作区目录。
	if !os.exists(config.config_path) {
		write_default_config(config) or {
			eprintln('failed to write config: ${err.msg()}')
			return 1
		}
		created_config = true
	}
	ensure_workspace(config) or {
		eprintln('failed to initialize workspace: ${err.msg()}')
		return 1
	}
	println('MiniClaw onboard complete.')
	if created_config {
		println('config: ${config.config_path}')
	} else {
		println('config already exists: ${config.config_path}')
	}
	println('workspace: ${config.workspace}')
	return 0
}

fn run_status(config Config) int {
	// 输出当前配置和工作区状态摘要。
	println('MiniClaw status')
	println('version: ${version}')
	println('config: ${config.config_path}')
	println('mcp config: ${config.mcp_config_path}')
	println('home: ${config.home_dir}')
	println('workspace: ${config.workspace}')
	println('api configured: ${config.api_key.len > 0}')
	println('mcp enabled: ${config.enable_mcp}')
	println('qq configured: ${config.qq_app_id.len > 0 && config.qq_app_secret.len > 0}')
	println('qq token configured: ${config.qq_token.len > 0}')
	println('qq webhook: http://${config.qq_webhook_host}:${config.qq_webhook_port}${config.qq_webhook_path}')
	println('qq auth callback: http://${config.qq_webhook_host}:${config.qq_webhook_port}${config.qq_auth_callback_path}')
	println('qq allow users: ${config.qq_allow_users}')
	println('qq allow groups: ${config.qq_allow_groups}')
	println('workspace ready: ${os.exists(config.workspace)}')
	return 0
}

fn run_gateway(config Config, args []string) int {
	// 完成 QQ 网关引导，并在需要时启动本地 webhook 服务。
	if ensure_runtime_ready(config) != 0 {
		return 1
	}
	if config.qq_app_id.len == 0 || config.qq_app_secret.len == 0 {
		eprintln('QQ gateway is not configured yet.')
		eprintln('set qq_app_id and qq_app_secret in ~/.config/miniclaw/config before enabling QQ integration.')
		return 1
	}
	token := fetch_qq_access_token(config) or {
		eprintln(err.msg())
		return 1
	}
	profile := fetch_qq_bot_profile(config, token.access_token) or {
		eprintln(err.msg())
		return 1
	}
	state_path := write_qq_gateway_state(config, token, profile) or {
		eprintln('failed to persist qq gateway state: ${err.msg()}')
		return 1
	}
	println('QQ gateway bootstrap ok.')
	println('bot id: ${profile.id}')
	println('bot name: ${profile.username}')
	println('state: ${state_path}')
	if has_flag(args, '--once') {
		println('bootstrap-only mode finished.')
		return 0
	}
	println('starting local webhook server on http://${config.qq_webhook_host}:${config.qq_webhook_port}${config.qq_webhook_path}')
	println('next step: bind this handler to a public HTTPS address or tunnel for QQ callback verification.')
	start_qq_webhook_server(config) or {
		eprintln(err.msg())
		return 1
	}
	return 0
}

fn run_agent(config Config, args []string) int {
	// 运行单次或交互式 Agent 对话。
	if ensure_runtime_ready(config) != 0 {
		return 1
	}
	prompt := parse_prompt_arg(args)
	if prompt.len > 0 {
		mut recorder := new_session_recorder(config) or {
			eprintln('failed to create session recorder: ${err.msg()}')
			return 1
		}
		response := run_minimax_agent_in_session(config, prompt, mut recorder) or {
			eprintln(err.msg())
			return 1
		}
		println(response)
		return 0
	}
	if config.api_key.len == 0 {
		eprintln('MINICLAW_API_KEY is not configured.')
		eprintln('set it in ~/.config/miniclaw/config or export MINICLAW_API_KEY.')
		return 1
	}
	println('MiniClaw interactive mode. Type exit to quit.')
	mut recorder := new_session_recorder(config) or {
		eprintln('failed to create session recorder: ${err.msg()}')
		return 1
	}
	for {
		input := os.input('> ').trim_space()
		if input.len == 0 {
			continue
		}
		if input == 'exit' || input == 'quit' {
			break
		}
		response := run_minimax_agent_in_session(config, input, mut recorder) or {
			eprintln(err.msg())
			continue
		}
		println(response)
	}
	return 0
}

fn run_memory(config Config, args []string) int {
	// 管理工作区内的长期记忆和日记。
	if ensure_runtime_ready(config) != 0 {
		return 1
	}
	memory_settings := memory_settings_from_config(config)
	store := memory_store_for_workspace(config.workspace)
	if args.len == 0 || args[0] == 'show' {
		content := store.context_with_settings(memory_settings)
		if content.len == 0 {
			println('(memory is empty)')
			return 0
		}
		println(content)
		return 0
	}
	match args[0] {
		'set' {
			content := parse_prompt_arg(args[1..])
			if content.len == 0 {
				eprintln('usage: miniclaw memory set -p "content"')
				return 1
			}
			store.write_long_term(content) or {
				eprintln('failed to update memory: ${err.msg()}')
				return 1
			}
			println('memory updated: ${os.join_path(config.workspace, 'memory', 'MEMORY.md')}')
			return 0
		}
		'append' {
			content := parse_prompt_arg(args[1..])
			if content.len == 0 {
				eprintln('usage: miniclaw memory append -p "content"')
				return 1
			}
			store.append_long_term(content) or {
				eprintln('failed to append memory: ${err.msg()}')
				return 1
			}
			println('memory appended: ${os.join_path(config.workspace, 'memory', 'MEMORY.md')}')
			return 0
		}
		'today' {
			content := parse_prompt_arg(args[1..])
			if content.len == 0 {
				eprintln('usage: miniclaw memory today -p "content"')
				return 1
			}
			store.append_today(content) or {
				eprintln('failed to append daily note: ${err.msg()}')
				return 1
			}
			println('daily note updated: ${store.today_file()}')
			return 0
		}
		'clear' {
			store.write_long_term('# Memory\n\n') or {
				eprintln('failed to clear memory: ${err.msg()}')
				return 1
			}
			store.write_summary('# Summary\n\n') or {
				eprintln('failed to clear summary: ${err.msg()}')
				return 1
			}
			println('memory cleared: ${os.join_path(config.workspace, 'memory', 'MEMORY.md')}')
			return 0
		}
		'summarize' {
			mut days := parse_optional_positive_int_args(args[1..])
			if days == 0 {
				days = memory_settings.recent_days
			}
			summary := store.summarize_recent_notes_with_settings(days, memory_settings) or {
				eprintln('failed to summarize memory: ${err.msg()}')
				return 1
			}
			if summary.len == 0 {
				println('(no recent notes to summarize)')
				return 0
			}
			store.write_summary('# Summary\n\n' + summary + '\n') or {
				eprintln('failed to write summary: ${err.msg()}')
				return 1
			}
			println('summary updated: ${os.join_path(config.workspace, 'memory', 'SUMMARY.md')}')
			return 0
		}
		'compact' {
			store.compact_long_term() or {
				eprintln('failed to compact memory: ${err.msg()}')
				return 1
			}
			println('memory compacted: ${os.join_path(config.workspace, 'memory', 'MEMORY.md')}')
			return 0
		}
		'prune' {
			mut keep_days := parse_optional_positive_int_args(args[1..])
			if keep_days == 0 {
				keep_days = memory_settings.prune_keep_days
			}
			removed := store.prune_daily_notes(keep_days) or {
				eprintln('failed to prune daily notes: ${err.msg()}')
				return 1
			}
			println('pruned ${removed} daily note(s), kept last ${keep_days} day(s)')
			return 0
		}
		else {
			eprintln('unknown memory command: ${args[0]}')
			eprintln('usage: miniclaw memory [show|set|append|today|summarize|compact|prune|clear]')
			return 1
		}
	}
}

fn ensure_runtime_ready(config Config) int {
	// 检查配置文件和工作区是否已经准备就绪。
	if !os.exists(config.config_path) {
		eprintln('config not found: ${config.config_path}')
		eprintln('run `miniclaw onboard` first.')
		return 1
	}
	ensure_workspace(config) or {
		eprintln('failed to prepare workspace: ${err.msg()}')
		return 1
	}
	return 0
}

fn parse_prompt_arg(args []string) string {
	// 从命令行参数中提取 prompt 内容。
	mut index := 0
	for index < args.len {
		arg := args[index]
		if arg == '-p' || arg == '--prompt' {
			if index + 1 < args.len {
				return args[index + 1]
			}
		}
		index++
	}
	return ''
}

fn has_flag(args []string, flag string) bool {
	// 判断命令行参数中是否包含指定开关。
	for arg in args {
		if arg == flag {
			return true
		}
	}
	return false
}

fn parse_optional_positive_int_args(args []string) int {
	for arg in args {
		parsed := arg.int()
		if parsed > 0 {
			return parsed
		}
	}
	return 0
}
