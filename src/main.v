module main

import os

const version = 'v0.1.0'

fn main() {
	// 解析命令行并分发到对应子命令。
	args := os.args[1..]
	if args.len == 0 {
		print_help()
		return
	}

	if args[0] == '--help' || args[0] == '-h' {
		print_help()
		return
	}
	if args[0] == '--version' {
		println(version)
		return
	}

	config := load_config()
	command := args[0]
	command_args := if args.len > 1 { args[1..] } else { []string{} }
	mut effective_config := config
	apply_command_config_overrides(mut effective_config, command_args)

	exit(match command {
		'onboard' {
			run_onboard(effective_config)
		}
		'status' {
			run_status(effective_config)
		}
		'gateway' {
			run_gateway(effective_config, command_args)
		}
		'agent' {
			run_agent(effective_config, command_args)
		}
		'memory' {
			run_memory(effective_config, command_args)
		}
		else {
			eprintln('unknown command: ${command}')
			print_help()
			1
		}
	})
}

fn apply_command_config_overrides(mut config Config, args []string) {
	// 处理命令行中的临时配置覆盖参数。
	mut index := 0
	for index < args.len {
		if args[index] == '--workspace' && index + 1 < args.len {
			config.workspace = expand_home_path(args[index + 1])
			index += 2
			continue
		}
		if args[index] == '--mcp' {
			config.enable_mcp = true
			index++
			continue
		}
		if args[index] == '--webhook-port' && index + 1 < args.len {
			config.qq_webhook_port = args[index + 1].int()
			index += 2
			continue
		}
		index++
	}
}

fn print_help() {
	// 输出命令行帮助信息。
	println('MiniClaw ${version}')
	println('')
	println('Usage:')
	println('  miniclaw onboard              Initialize config and workspace')
	println('  miniclaw status               Show current configuration status')
	println('  miniclaw gateway [--once] [--webhook-port PORT]   Start QQ gateway bootstrap or webhook server')
	println('  miniclaw agent [-p PROMPT] [--workspace PATH] [--mcp]    Run agent')
	println('  miniclaw memory [show|set|append|today|summarize|compact|prune|clear]    Manage memory files')
	println('  miniclaw --version            Show version')
	println('')
	println('Environment variables:')
	println('  MINICLAW_HOME')
	println('  MINICLAW_WORKSPACE')
	println('  MINICLAW_MCP_CONFIG_PATH')
	println('  MINICLAW_API_KEY')
	println('  ANTHROPIC_BASE_URL')
	println('  MINICLAW_API_URL (legacy alias)')
	println('  MINICLAW_MODEL')
	println('  MINICLAW_ENABLE_MCP')
	println('  MINICLAW_MCP_BASE_PATH')
	println('  MINICLAW_MCP_RESOURCE_MODE')
	println('  MINICLAW_QQ_APP_ID')
	println('  MINICLAW_QQ_APP_SECRET')
}
