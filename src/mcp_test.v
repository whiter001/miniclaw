module main

// 验证 npx 类型的 MCP 配置会自动补 -y。
fn test_parse_mcp_config_npx_auto_inject_yes_flag() {
	content := '{"servers":{"playwright":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]}}}'
	configs := parse_mcp_config(content)
	assert configs.len == 1
	assert configs[0].args.len == 2
	assert configs[0].args[0] == '-y'
	assert configs[0].args[1] == '@playwright/mcp@latest'
}

// 验证已声明 yes 标志时不会重复注入。
fn test_parse_mcp_config_preserves_existing_yes_flag() {
	content := '{"servers":{"playwright":{"type":"stdio","command":"npx","args":["--yes","@playwright/mcp@latest"]}}}'
	configs := parse_mcp_config(content)
	assert configs.len == 1
	assert configs[0].args.len == 2
	assert configs[0].args[0] == '--yes'
	assert configs[0].args[1] == '@playwright/mcp@latest'
}

// 验证 MCP arguments 会尽量保留数字、布尔和字符串类型。
fn test_build_mcp_arguments_json_preserves_primitive_types() {
	args_json := build_mcp_arguments_json({
		'count':  '10'
		'enable': 'true'
		'query':  'hello'
	})
	assert args_json.contains('"count":10')
	assert args_json.contains('"enable":true')
	assert args_json.contains('"query":"hello"')
}

// 验证本地工具 schema 和 MCP 工具 schema 可以正确合并。
fn test_build_effective_tools_schema_json_appends_mcp_tools() {
	mut manager := new_mcp_manager()
	manager.servers << &McpServer{
		name:         'MiniMax'
		is_connected: true
		tools:        [
			McpTool{
				name:        'web_search'
				description: 'search web'
				raw_schema:  '{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}'
			},
		]
	}
	tools_json := build_effective_tools_schema_json(mut manager)
	assert tools_json.contains('"name":"list_dir"')
	assert tools_json.contains('"name":"web_search"')
}
