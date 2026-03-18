module main

import os
import strconv

pub struct Config {
pub mut:
	home_dir                      string
	workspace                     string
	config_path                   string
	mcp_config_path               string
	api_key                       string
	api_url                       string
	model                         string
	temperature                   f64
	max_tokens                    int
	request_timeout               int
	enable_mcp                    bool
	mcp_base_path                 string
	mcp_resource_mode             string
	qq_app_id                     string
	qq_token                      string
	qq_app_secret                 string
	qq_api_base                   string
	qq_webhook_host               string
	qq_webhook_port               int
	qq_webhook_path               string
	qq_auth_callback_path         string
	qq_allow_users                string
	qq_allow_groups               string
	qq_processing_text            string
	max_tool_iterations           int
	memory_recent_days            int
	memory_recent_chars           int
	memory_summary_max_lines      int
	memory_summary_max_chars      int
	memory_daily_entry_max_chars  int
	memory_significance_threshold int
	memory_prune_keep_days        int
}

fn default_config() Config {
	// 生成内置默认配置。
	home_dir := os.join_path(os.home_dir(), '.miniclaw')
	return Config{
		home_dir:                      home_dir
		workspace:                     os.join_path(home_dir, 'workspace')
		config_path:                   os.join_path(os.home_dir(), '.config', 'miniclaw',
			'config')
		mcp_config_path:               os.join_path(os.home_dir(), '.config', 'miniclaw',
			'mcp.json')
		api_key:                       ''
		api_url:                       'https://api.minimaxi.com/anthropic'
		model:                         'MiniMax-M2.7'
		temperature:                   0.7
		max_tokens:                    8192
		request_timeout:               120
		enable_mcp:                    false
		mcp_base_path:                 ''
		mcp_resource_mode:             'url'
		qq_app_id:                     ''
		qq_token:                      ''
		qq_app_secret:                 ''
		qq_api_base:                   'https://api.sgroup.qq.com'
		qq_webhook_host:               '127.0.0.1'
		qq_webhook_port:               8080
		qq_webhook_path:               '/webhook/qq'
		qq_auth_callback_path:         '/qq-callback'
		qq_allow_users:                ''
		qq_allow_groups:               ''
		qq_processing_text:            '收到，处理中，请稍候。'
		max_tool_iterations:           100
		memory_recent_days:            2
		memory_recent_chars:           1600
		memory_summary_max_lines:      20
		memory_summary_max_chars:      2000
		memory_daily_entry_max_chars:  500
		memory_significance_threshold: 3
		memory_prune_keep_days:        14
	}
}

fn load_config() Config {
	// 加载本地配置文件并叠加环境变量覆盖。
	mut config := default_config()
	config.home_dir = expand_home_path(config.home_dir)
	config.workspace = expand_home_path(config.workspace)
	config.config_path = expand_home_path(config.config_path)
	config.mcp_config_path = expand_home_path(config.mcp_config_path)
	config.mcp_base_path = expand_home_path(config.mcp_base_path)

	if os.exists(config.config_path) {
		content := os.read_file(config.config_path) or { return config }
		config = parse_config_content(content, config)
	}

	apply_env_overrides(mut config)
	return config
}

fn parse_config_content(content string, base Config) Config {
	// 解析 key=value 形式的配置内容。
	mut config := base
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.len == 0 || trimmed.starts_with('#') {
			continue
		}
		eq_index := trimmed.index('=') or { continue }
		key := trimmed[..eq_index].trim_space()
		value := trimmed[eq_index + 1..].trim_space()
		apply_config_value(mut config, key, value)
	}
	config.home_dir = expand_home_path(config.home_dir)
	config.workspace = expand_home_path(config.workspace)
	config.config_path = expand_home_path(config.config_path)
	config.mcp_config_path = expand_home_path(config.mcp_config_path)
	config.mcp_base_path = expand_home_path(config.mcp_base_path)
	return config
}

fn apply_config_value(mut config Config, key string, value string) {
	// 将单个配置项应用到配置对象上。
	match key {
		'home_dir' {
			config.home_dir = value
		}
		'workspace' {
			config.workspace = value
		}
		'mcp_config_path' {
			config.mcp_config_path = value
		}
		'api_key' {
			config.api_key = value
		}
		'api_url' {
			config.api_url = value
		}
		'model' {
			config.model = value
		}
		'temperature' {
			if parsed := strconv.atof64(value) {
				config.temperature = parsed
			}
		}
		'max_tokens' {
			if parsed := strconv.atoi(value) {
				config.max_tokens = parsed
			}
		}
		'request_timeout' {
			if parsed := strconv.atoi(value) {
				config.request_timeout = parsed
			}
		}
		'max_tool_iterations' {
			if parsed := strconv.atoi(value) {
				if parsed >= 10 && parsed <= 1000 {
					config.max_tool_iterations = parsed
				}
			}
		}
		'memory_recent_days' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 {
					config.memory_recent_days = parsed
				}
			}
		}
		'memory_recent_chars' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 {
					config.memory_recent_chars = parsed
				}
			}
		}
		'memory_summary_max_lines' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 {
					config.memory_summary_max_lines = parsed
				}
			}
		}
		'memory_summary_max_chars' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 {
					config.memory_summary_max_chars = parsed
				}
			}
		}
		'memory_daily_entry_max_chars' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 {
					config.memory_daily_entry_max_chars = parsed
				}
			}
		}
		'memory_significance_threshold' {
			if parsed := strconv.atoi(value) {
				if parsed > 0 {
					config.memory_significance_threshold = parsed
				}
			}
		}
		'memory_prune_keep_days' {
			if parsed := strconv.atoi(value) {
				if parsed >= 0 {
					config.memory_prune_keep_days = parsed
				}
			}
		}
		'enable_mcp' {
			config.enable_mcp = value == 'true' || value == '1'
		}
		'mcp_base_path' {
			config.mcp_base_path = value
		}
		'mcp_resource_mode' {
			config.mcp_resource_mode = value
		}
		'qq_app_id' {
			config.qq_app_id = value
		}
		'qq_token' {
			config.qq_token = value
		}
		'qq_app_secret' {
			config.qq_app_secret = value
		}
		'qq_api_base' {
			config.qq_api_base = value
		}
		'qq_webhook_host' {
			config.qq_webhook_host = value
		}
		'qq_webhook_port' {
			if parsed := strconv.atoi(value) {
				config.qq_webhook_port = parsed
			}
		}
		'qq_webhook_path' {
			config.qq_webhook_path = value
		}
		'qq_auth_callback_path' {
			config.qq_auth_callback_path = value
		}
		'qq_allow_users' {
			config.qq_allow_users = value
		}
		'qq_allow_groups' {
			config.qq_allow_groups = value
		}
		'qq_processing_text' {
			config.qq_processing_text = value
		}
		else {}
	}
}

fn apply_env_overrides(mut config Config) {
	// 用环境变量覆盖配置文件中的对应字段。
	if value := os.getenv_opt('MINICLAW_HOME') {
		config.home_dir = expand_home_path(value)
	}
	if value := os.getenv_opt('MINICLAW_WORKSPACE') {
		config.workspace = expand_home_path(value)
	}
	if value := os.getenv_opt('MINICLAW_MCP_CONFIG_PATH') {
		config.mcp_config_path = expand_home_path(value)
	}
	if value := os.getenv_opt('MINICLAW_API_KEY') {
		config.api_key = value
	}
	if value := os.getenv_opt('MINICLAW_API_URL') {
		config.api_url = value
	}
	if value := os.getenv_opt('MINICLAW_MODEL') {
		config.model = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_APP_ID') {
		config.qq_app_id = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_TOKEN') {
		config.qq_token = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_APP_SECRET') {
		config.qq_app_secret = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_API_BASE') {
		config.qq_api_base = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_WEBHOOK_HOST') {
		config.qq_webhook_host = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_WEBHOOK_PORT') {
		if parsed := strconv.atoi(value) {
			config.qq_webhook_port = parsed
		}
	}
	if value := os.getenv_opt('MINICLAW_QQ_WEBHOOK_PATH') {
		config.qq_webhook_path = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_AUTH_CALLBACK_PATH') {
		config.qq_auth_callback_path = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_ALLOW_USERS') {
		config.qq_allow_users = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_ALLOW_GROUPS') {
		config.qq_allow_groups = value
	}
	if value := os.getenv_opt('MINICLAW_QQ_PROCESSING_TEXT') {
		config.qq_processing_text = value
	}
	if value := os.getenv_opt('MINICLAW_TEMPERATURE') {
		if parsed := strconv.atof64(value) {
			config.temperature = parsed
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_RECENT_DAYS') {
		if parsed := strconv.atoi(value) {
			if parsed > 0 {
				config.memory_recent_days = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_RECENT_CHARS') {
		if parsed := strconv.atoi(value) {
			if parsed > 0 {
				config.memory_recent_chars = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_SUMMARY_MAX_LINES') {
		if parsed := strconv.atoi(value) {
			if parsed > 0 {
				config.memory_summary_max_lines = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_SUMMARY_MAX_CHARS') {
		if parsed := strconv.atoi(value) {
			if parsed > 0 {
				config.memory_summary_max_chars = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_DAILY_ENTRY_MAX_CHARS') {
		if parsed := strconv.atoi(value) {
			if parsed > 0 {
				config.memory_daily_entry_max_chars = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_SIGNIFICANCE_THRESHOLD') {
		if parsed := strconv.atoi(value) {
			if parsed > 0 {
				config.memory_significance_threshold = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MEMORY_PRUNE_KEEP_DAYS') {
		if parsed := strconv.atoi(value) {
			if parsed >= 0 {
				config.memory_prune_keep_days = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_MAX_TOKENS') {
		if parsed := strconv.atoi(value) {
			config.max_tokens = parsed
		}
	}
	if value := os.getenv_opt('MINICLAW_REQUEST_TIMEOUT') {
		if parsed := strconv.atoi(value) {
			config.request_timeout = parsed
		}
	}
	if value := os.getenv_opt('MINICLAW_MAX_TOOL_ITERATIONS') {
		if parsed := strconv.atoi(value) {
			if parsed >= 10 && parsed <= 1000 {
				config.max_tool_iterations = parsed
			}
		}
	}
	if value := os.getenv_opt('MINICLAW_ENABLE_MCP') {
		config.enable_mcp = value == 'true' || value == '1'
	}
	if value := os.getenv_opt('MINICLAW_MCP_BASE_PATH') {
		config.mcp_base_path = expand_home_path(value)
	}
	if value := os.getenv_opt('MINICLAW_MCP_RESOURCE_MODE') {
		config.mcp_resource_mode = value
	}
	config.home_dir = expand_home_path(config.home_dir)
	config.workspace = expand_home_path(config.workspace)
	config.config_path = expand_home_path(config.config_path)
	config.mcp_config_path = expand_home_path(config.mcp_config_path)
	config.mcp_base_path = expand_home_path(config.mcp_base_path)
}

fn ensure_config_parent_dir(config_path string) ! {
	// 确保配置文件的父目录已经存在。
	parent_dir := os.dir(config_path)
	if parent_dir.len == 0 {
		return
	}
	os.mkdir_all(parent_dir)!
}

fn write_default_config(config Config) ! {
	// 把默认配置写入本地配置文件。
	ensure_config_parent_dir(config.config_path)!
	default_content :=
		['# MiniClaw config', 'home_dir=${config.home_dir}', 'workspace=${config.workspace}', 'mcp_config_path=${config.mcp_config_path}', 'api_key=', 'api_url=${config.api_url}', 'model=${config.model}', 'temperature=${config.temperature}', 'max_tokens=${config.max_tokens}', 'request_timeout=${config.request_timeout}', 'enable_mcp=${config.enable_mcp}', 'mcp_base_path=${config.mcp_base_path}', 'mcp_resource_mode=${config.mcp_resource_mode}', 'qq_app_id=', 'qq_token=', 'qq_app_secret=', 'qq_api_base=${config.qq_api_base}', 'qq_webhook_host=${config.qq_webhook_host}', 'qq_webhook_port=${config.qq_webhook_port}', 'qq_webhook_path=${config.qq_webhook_path}', 'qq_auth_callback_path=${config.qq_auth_callback_path}', 'qq_allow_users=${config.qq_allow_users}', 'qq_allow_groups=${config.qq_allow_groups}', 'qq_processing_text=${config.qq_processing_text}', 'memory_recent_days=${config.memory_recent_days}', 'memory_recent_chars=${config.memory_recent_chars}', 'memory_summary_max_lines=${config.memory_summary_max_lines}', 'memory_summary_max_chars=${config.memory_summary_max_chars}', 'memory_daily_entry_max_chars=${config.memory_daily_entry_max_chars}', 'memory_significance_threshold=${config.memory_significance_threshold}', 'memory_prune_keep_days=${config.memory_prune_keep_days}'].join('\n') +
		'\n'
	os.write_file(config.config_path, default_content)!
}

fn expand_home_path(path string) string {
	// 把以 ~ 开头的路径展开为用户目录。
	if path.starts_with('~/') {
		return os.join_path(os.home_dir(), path[2..])
	}
	if path == '~' {
		return os.home_dir()
	}
	return path
}
