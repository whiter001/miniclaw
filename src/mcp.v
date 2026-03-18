module main

import os
import time

const default_mcp_request_timeout_ms = 30000
const understand_image_timeout_ms = 90000
const mcp_startup_timeout_ms = 60000
const mcp_startup_poll_interval_ms = 500

pub struct McpToolParam {
pub:
	name        string
	description string
	param_type  string
	required    bool
}

pub struct McpTool {
pub:
	name        string
	description string
	params      []McpToolParam
	raw_schema  string
}

@[heap]
pub struct McpServer {
pub mut:
	name         string
	command      string
	args         []string
	env          map[string]string
	process      &os.Process = unsafe { nil }
	request_id   int
	tools        []McpTool
	is_connected bool
}

pub struct McpManager {
pub mut:
	servers []&McpServer
}

pub struct McpServerConfig {
pub:
	name    string
	command string
	args    []string
	env     map[string]string
}

// 创建新的 MCP 管理器。
fn new_mcp_manager() McpManager {
	return McpManager{
		servers: []&McpServer{}
	}
}

// 向管理器注册一个 MCP stdio 服务。
fn (mut m McpManager) add_server(name string, command string, args []string, env map[string]string) {
	mut server := &McpServer{
		name:         name
		command:      command
		args:         args
		env:          env
		request_id:   0
		tools:        []McpTool{}
		is_connected: false
	}
	m.servers << server
}

// 启动管理器中的所有 MCP 服务。
fn (mut m McpManager) start_all() {
	for mut server in m.servers {
		start_mcp_server(mut server)
	}
}

// 停止管理器中的所有 MCP 服务。
fn (mut m McpManager) stop_all() {
	for mut server in m.servers {
		stop_mcp_server(mut server)
	}
}

// 返回所有已连接 MCP 服务暴露的工具。
fn (mut m McpManager) get_all_tools() []McpTool {
	mut all_tools := []McpTool{}
	for server in m.servers {
		if server.is_connected {
			all_tools << server.tools
		}
	}
	return all_tools
}

// 判断当前管理器中是否存在指定 MCP 工具。
fn (mut m McpManager) has_tool(tool_name string) bool {
	for server in m.servers {
		if !server.is_connected {
			continue
		}
		for tool in server.tools {
			if tool.name == tool_name {
				return true
			}
		}
	}
	return false
}

// 调用已发现的 MCP 工具。
fn (mut m McpManager) call_tool(tool_name string, arguments string) !string {
	for mut server in m.servers {
		if !server.is_connected {
			continue
		}
		for tool in server.tools {
			if tool.name == tool_name {
				return mcp_call_tool(mut server, tool_name, arguments)
			}
		}
	}
	return error('MCP tool "${tool_name}" not found')
}

// 初始化一次请求生命周期内的 MCP 运行时。
fn init_mcp_manager(config Config) McpManager {
	mut manager := new_mcp_manager()
	if !config.enable_mcp {
		return manager
	}
	manager.add_server('MiniMax', 'uvx', ['--native-tls', 'minimax-coding-plan-mcp', '-y'],
		build_builtin_mcp_env(config))
	for server_config in load_mcp_config(config) {
		manager.add_server(server_config.name, server_config.command, server_config.args,
			server_config.env)
	}
	manager.start_all()
	return manager
}

// 构造内置 MiniMax MCP 服务所需环境变量。
fn build_builtin_mcp_env(config Config) map[string]string {
	mut env := {
		'MINIMAX_API_KEY':  config.api_key
		'MINIMAX_API_HOST': derive_api_host(resolve_anthropic_messages_url(config.base_url))
	}
	base_path := effective_mcp_base_path(config)
	if base_path.len > 0 {
		os.mkdir_all(base_path) or {}
		env['MINIMAX_MCP_BASE_PATH'] = base_path
	}
	if config.mcp_resource_mode.trim_space().len > 0 {
		env['MINIMAX_API_RESOURCE_MODE'] = config.mcp_resource_mode.trim_space()
	}
	return env
}

// 计算实际使用的 MCP 输出目录。
fn effective_mcp_base_path(config Config) string {
	if config.mcp_base_path.trim_space().len > 0 {
		return config.mcp_base_path.trim_space()
	}
	return os.join_path(config.workspace, 'state', 'minimax-mcp')
}

// 从 API URL 中提取 host 根路径。
fn derive_api_host(api_url string) string {
	scheme_index := api_url.index('://') or { return api_url }
	path_index := api_url[scheme_index + 3..].index('/') or { return api_url }
	return api_url[..scheme_index + 3 + path_index]
}

// 生成追加到模型请求中的 MCP 工具 schema 片段。
fn get_mcp_tools_schema_json(tools []McpTool) string {
	if tools.len == 0 {
		return ''
	}
	mut result := ''
	for tool in tools {
		result += '{"name":"${escape_json_string(tool.name)}","description":"${escape_json_string(tool.description)}","input_schema":${tool.raw_schema}},'
	}
	if result.ends_with(',') {
		result = result[..result.len - 1]
	}
	return result
}

// 将本地工具和 MCP 工具合并成一个 tools 数组 JSON。
fn build_effective_tools_schema_json(mut mcp McpManager) string {
	local_tools := get_tools_schema_json()
	mcp_tools := get_mcp_tools_schema_json(mcp.get_all_tools())
	if mcp_tools.len == 0 {
		return local_tools
	}
	return local_tools[..local_tools.len - 1] + ',' + mcp_tools + ']'
}

// 把模型传来的工具输入编码成 MCP arguments JSON。
fn build_mcp_arguments_json(input map[string]string) string {
	mut parts := []string{}
	for key, value in input {
		parts << '"${escape_json_string(key)}":' + encode_mcp_argument_value(value)
	}
	return '{' + parts.join(',') + '}'
}

// 根据字符串内容尽量保留 MCP 参数原始类型。
fn encode_mcp_argument_value(value string) string {
	trimmed := value.trim_space()
	if trimmed == 'true' || trimmed == 'false' || trimmed == 'null' {
		return trimmed
	}
	if is_json_number_literal(trimmed) {
		return trimmed
	}
	if (trimmed.starts_with('{') && trimmed.ends_with('}'))
		|| (trimmed.starts_with('[') && trimmed.ends_with(']')) {
		return trimmed
	}
	return '"${escape_json_string(value)}"'
}

// 判断字符串是否可作为 JSON 数字字面量。
fn is_json_number_literal(value string) bool {
	if value.len == 0 {
		return false
	}
	mut index := 0
	mut has_digit := false
	mut has_dot := false
	if value[0] == `-` {
		index = 1
	}
	for index < value.len {
		ch := value[index]
		if ch >= `0` && ch <= `9` {
			has_digit = true
			index++
			continue
		}
		if ch == `.` && !has_dot {
			has_dot = true
			index++
			continue
		}
		return false
	}
	return has_digit
}

// 读取 ~/.config/miniclaw/mcp.json 中声明的额外 MCP 服务。
fn load_mcp_config(config Config) []McpServerConfig {
	if !os.exists(config.mcp_config_path) {
		return []
	}
	content := os.read_file(config.mcp_config_path) or { return [] }
	return parse_mcp_config(content)
}

// 解析 MCP 配置文件内容。
fn parse_mcp_config(content string) []McpServerConfig {
	mut configs := []McpServerConfig{}
	servers_key_idx := content.index('"servers"') or { return configs }
	mut brace_pos := servers_key_idx + '"servers"'.len
	for brace_pos < content.len && content[brace_pos] in [u8(` `), `\t`, `\n`, `\r`] {
		brace_pos++
	}
	if brace_pos >= content.len || content[brace_pos] != `:` {
		return configs
	}
	brace_pos++
	for brace_pos < content.len && content[brace_pos] in [u8(` `), `\t`, `\n`, `\r`] {
		brace_pos++
	}
	if brace_pos >= content.len || content[brace_pos] != `{` {
		return configs
	}
	servers_start := brace_pos
	servers_end := find_matching_bracket(content, servers_start)
	if servers_end <= servers_start {
		return configs
	}
	servers_content := content[servers_start..servers_end + 1]
	mut pos := 1
	for pos < servers_content.len {
		for pos < servers_content.len && servers_content[pos] in [u8(` `), `,`, `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= servers_content.len || servers_content[pos] == `}` {
			break
		}
		if servers_content[pos] != `"` {
			pos++
			continue
		}
		pos++
		mut name_end := pos
		for name_end < servers_content.len && servers_content[name_end] != `"` {
			name_end++
		}
		server_name := servers_content[pos..name_end]
		pos = name_end + 1
		for pos < servers_content.len && servers_content[pos] in [u8(`:`), ` `, `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= servers_content.len || servers_content[pos] != `{` {
			continue
		}
		obj_end := find_matching_bracket(servers_content, pos)
		if obj_end <= pos {
			break
		}
		block := servers_content[pos..obj_end + 1]
		command := extract_json_string_value(block, 'command')
		server_type := extract_json_string_value(block, 'type')
		if server_type != 'stdio' || command.len == 0 {
			pos = obj_end + 1
			continue
		}
		mut args := []string{}
		if args_start := find_json_array(block, '"args"') {
			arr_end := find_matching_bracket(block, args_start)
			if arr_end > args_start {
				args_content := block[args_start + 1..arr_end]
				mut apos := 0
				for apos < args_content.len {
					if args_content[apos] == `"` {
						apos++
						mut aend := apos
						for aend < args_content.len && args_content[aend] != `"` {
							aend++
						}
						if aend > apos {
							args << args_content[apos..aend]
						}
						apos = aend + 1
					} else {
						apos++
					}
				}
			}
		}
		command_base := os.base(command).to_lower()
		if command_base == 'npx' || command_base == 'npx.cmd' {
			mut has_yes_flag := false
			for arg in args {
				if arg == '-y' || arg == '--yes' {
					has_yes_flag = true
					break
				}
			}
			if !has_yes_flag {
				args.insert(0, '-y')
			}
		}
		mut env := map[string]string{}
		if env_start := find_json_object(block, '"env"') {
			env_end := find_matching_bracket(block, env_start)
			if env_end > env_start {
				env = parse_json_string_object(block[env_start..env_end + 1])
			}
		}
		configs << McpServerConfig{
			name:    server_name
			command: command
			args:    args
			env:     env
		}
		pos = obj_end + 1
	}
	return configs
}

// 查找 JSON 键后面的数组起点。
fn find_json_array(block string, key string) ?int {
	key_idx := block.index(key) or { return none }
	mut pos := key_idx + key.len
	for pos < block.len && block[pos] in [u8(` `), `\t`, `\n`, `\r`] {
		pos++
	}
	if pos >= block.len || block[pos] != `:` {
		return none
	}
	pos++
	for pos < block.len && block[pos] in [u8(` `), `\t`, `\n`, `\r`] {
		pos++
	}
	if pos >= block.len || block[pos] != `[` {
		return none
	}
	return pos
}

// 查找 JSON 键后面的对象起点。
fn find_json_object(block string, key string) ?int {
	key_idx := block.index(key) or { return none }
	mut pos := key_idx + key.len
	for pos < block.len && block[pos] in [u8(` `), `\t`, `\n`, `\r`] {
		pos++
	}
	if pos >= block.len || block[pos] != `:` {
		return none
	}
	pos++
	for pos < block.len && block[pos] in [u8(` `), `\t`, `\n`, `\r`] {
		pos++
	}
	if pos >= block.len || block[pos] != `{` {
		return none
	}
	return pos
}

// 启动单个 MCP 子进程并完成初始化。
fn start_mcp_server(mut server McpServer) {
	cmd := os.find_abs_path_of_executable(server.command) or { return }
	mut proc := build_mcp_process(server, cmd)
	proc.run()
	if !proc.is_alive() {
		return
	}
	server.process = proc
	if !wait_for_mcp_server_ready(mut server) {
		stop_mcp_server(mut server)
		return
	}
	server.is_connected = true
}

fn build_mcp_process(server McpServer, command_path string) &os.Process {
	mut proc := os.new_process(command_path)
	// MCP 启动链会经由 uvx 再拉起 python 子进程，需要独立进程组才能一并清理。
	proc.use_pgroup = true
	proc.set_args(server.args)
	proc.set_redirect_stdio()
	if server.env.len > 0 {
		mut full_env := os.environ()
		for key, value in server.env {
			full_env[key] = value
		}
		proc.set_environment(full_env)
	}
	return proc
}

// 在限定时间内等待 MCP 服务完成初始化并返回工具列表。
fn wait_for_mcp_server_ready(mut server McpServer) bool {
	mut elapsed_ms := 0
	for elapsed_ms <= mcp_startup_timeout_ms {
		if server.process == unsafe { nil } || !server.process.is_alive() {
			return false
		}
		if !mcp_initialize(mut server) {
			time.sleep(mcp_startup_poll_interval_ms * time.millisecond)
			elapsed_ms += mcp_startup_poll_interval_ms
			continue
		}
		tools := mcp_list_tools_with_timeout(mut server, default_mcp_request_timeout_ms) or {
			time.sleep(mcp_startup_poll_interval_ms * time.millisecond)
			elapsed_ms += mcp_startup_poll_interval_ms
			continue
		}
		server.tools = tools
		return true
	}
	return false
}

// 停止并清理单个 MCP 子进程。
fn stop_mcp_server(mut server McpServer) {
	if server.process == unsafe { nil } {
		server.is_connected = false
		return
	}
	if server.process.is_alive() {
		server.process.signal_pgkill()
		server.process.wait()
	}
	server.process.close()
	server.process = unsafe { nil }
	server.tools = []McpTool{}
	server.is_connected = false
}

// 返回不同 MCP 工具的超时时间。
fn mcp_tool_timeout_ms(tool_name string) int {
	return if tool_name == 'understand_image' {
		understand_image_timeout_ms
	} else {
		default_mcp_request_timeout_ms
	}
}

// 将超时时间转换为轮询次数。
fn mcp_timeout_poll_attempts(timeout_ms int) int {
	if timeout_ms <= 0 {
		return 1
	}
	return (timeout_ms + 99) / 100
}

// 发送带超时的 JSON-RPC 请求。
fn mcp_send_request_with_timeout(mut server McpServer, method string, params string, timeout_ms int) !string {
	server.request_id++
	id := server.request_id
	mut request := '{"jsonrpc":"2.0","id":${id},"method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'
	server.process.stdin_write(request)
	return mcp_read_response(mut server, id, timeout_ms)
}

// 发送 JSON-RPC 通知消息。
fn mcp_send_notification(mut server McpServer, method string, params string) {
	mut request := '{"jsonrpc":"2.0","method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'
	server.process.stdin_write(request)
}

// 从 MCP 服务 stdout 读取指定请求的响应。
fn mcp_read_response(mut server McpServer, expected_id int, timeout_ms int) !string {
	mut line_buffer := ''
	mut attempts := 0
	max_attempts := mcp_timeout_poll_attempts(timeout_ms)
	for attempts < max_attempts {
		if server.process.is_pending(.stdout) {
			if chunk := server.process.pipe_read(.stdout) {
				line_buffer += chunk
				for {
					nl := line_buffer.index('\n') or { break }
					line := line_buffer[..nl].trim_space()
					line_buffer = if nl + 1 < line_buffer.len { line_buffer[nl + 1..] } else { '' }
					if line.len == 0 {
						continue
					}
					if line.contains('"method":"roots/list"') {
						if id_pos := line.index('"id":') {
							mut pos := id_pos + 5
							for pos < line.len && line[pos] in [u8(` `), `\t`] {
								pos++
							}
							mut end := pos
							for end < line.len && line[end] >= `0` && line[end] <= `9` {
								end++
							}
							if end > pos {
								server.process.stdin_write('{"jsonrpc":"2.0","id":${line[pos..end]},"result":{"roots":[]}}\n')
							}
						}
						continue
					}
					id_match := line.contains('"id":${expected_id},')
						|| line.contains('"id":${expected_id}}')
						|| line.contains('"id": ${expected_id},')
						|| line.contains('"id": ${expected_id}}')
					if id_match && (line.contains('"result"') || line.contains('"error"')) {
						return line
					}
				}
				continue
			}
		}
		time.sleep(100 * time.millisecond)
		attempts++
	}
	return error('MCP response timeout for request ${expected_id}')
}

// 执行 MCP 初始化握手。
fn mcp_initialize(mut server McpServer) bool {
	params := '{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"miniclaw","version":"${version}"}}'
	response := mcp_send_request_with_timeout(mut server, 'initialize', params, 60000) or {
		return false
	}
	if response.contains('"id"') && !response.contains('"error"') {
		mcp_send_notification(mut server, 'notifications/initialized', '{}')
		return true
	}
	return false
}

// 获取 MCP 服务暴露的工具列表。
fn mcp_list_tools(mut server McpServer) {
	server.tools = mcp_list_tools_with_timeout(mut server, 5000) or { return }
}

// 获取 MCP 服务暴露的工具列表，并允许调用方指定等待时间。
fn mcp_list_tools_with_timeout(mut server McpServer, timeout_ms int) ![]McpTool {
	response := mcp_send_request_with_timeout(mut server, 'tools/list', '{}', timeout_ms)!
	return parse_mcp_tools(response)
}

// 调用单个 MCP 工具。
fn mcp_call_tool(mut server McpServer, tool_name string, arguments string) !string {
	params := '{"name":"${escape_json_string(tool_name)}","arguments":${arguments}}'
	response := mcp_send_request_with_timeout(mut server, 'tools/call', params, mcp_tool_timeout_ms(tool_name)) or {
		return error('MCP 调用失败: ${err}')
	}
	return parse_mcp_call_result(response)
}

// 解析 tools/list 返回的工具定义。
fn parse_mcp_tools(response string) []McpTool {
	mut tools := []McpTool{}
	result_key := '"tools":['
	result_idx := response.index(result_key) or { return tools }
	arr_start := result_idx + result_key.len - 1
	arr_end := find_matching_bracket(response, arr_start)
	if arr_end <= arr_start {
		return tools
	}
	arr_content := response[arr_start..arr_end + 1]
	mut search_pos := 1
	for search_pos < arr_content.len {
		remaining := arr_content[search_pos..]
		obj_start := remaining.index('{') or { break }
		abs_start := search_pos + obj_start
		obj_end := find_matching_bracket(arr_content, abs_start)
		if obj_end <= abs_start {
			break
		}
		block := arr_content[abs_start..obj_end + 1]
		name := decode_json_string(extract_json_string_value(block, 'name'))
		description := decode_json_string(extract_json_string_value(block, 'description'))
		mut raw_schema := '{}'
		if schema_idx := block.index('"inputSchema":') {
			mut schema_start := schema_idx + 14
			for schema_start < block.len && block[schema_start] in [u8(` `), `\t`, `\n`, `\r`] {
				schema_start++
			}
			if schema_start < block.len && block[schema_start] == `{` {
				schema_end := find_matching_bracket(block, schema_start)
				if schema_end > schema_start {
					raw_schema = block[schema_start..schema_end + 1]
				}
			}
		}
		if name.len > 0 {
			tools << McpTool{
				name:        name
				description: description
				params:      parse_mcp_tool_params(raw_schema)
				raw_schema:  raw_schema
			}
		}
		search_pos = obj_end + 1
	}
	return tools
}

// 解析 MCP 工具的 inputSchema 参数定义。
fn parse_mcp_tool_params(schema_json string) []McpToolParam {
	mut params := []McpToolParam{}
	props_key := '"properties":{'
	props_idx := schema_json.index(props_key) or { return params }
	props_start := props_idx + props_key.len - 1
	props_end := find_matching_bracket(schema_json, props_start)
	if props_end <= props_start {
		return params
	}
	props_content := schema_json[props_start..props_end + 1]
	mut required_params := []string{}
	if req_idx := schema_json.index('"required":[') {
		req_start := req_idx + 12
		req_end := find_matching_bracket(schema_json, req_start - 1)
		if req_end > req_start {
			req_content := schema_json[req_start..req_end]
			mut pos := 0
			for pos < req_content.len {
				if req_content[pos] == `"` {
					pos++
					mut end := pos
					for end < req_content.len && req_content[end] != `"` {
						end++
					}
					if end > pos {
						required_params << req_content[pos..end]
					}
					pos = end + 1
				} else {
					pos++
				}
			}
		}
	}
	mut search_pos := 1
	for search_pos < props_content.len {
		remaining := props_content[search_pos..]
		key_start := remaining.index('"') or { break }
		abs_key_start := search_pos + key_start + 1
		mut key_end := abs_key_start
		for key_end < props_content.len && props_content[key_end] != `"` {
			key_end++
		}
		if key_end >= props_content.len {
			break
		}
		param_name := props_content[abs_key_start..key_end]
		after_key := props_content[key_end + 1..]
		obj_rel_start := after_key.index('{') or {
			search_pos = key_end + 1
			continue
		}
		abs_obj_start := key_end + 1 + obj_rel_start
		obj_end := find_matching_bracket(props_content, abs_obj_start)
		if obj_end <= abs_obj_start {
			search_pos = abs_obj_start + 1
			continue
		}
		prop_block := props_content[abs_obj_start..obj_end + 1]
		params << McpToolParam{
			name:        param_name
			description: decode_json_string(extract_json_string_value(prop_block, 'description'))
			param_type:  decode_json_string(extract_json_string_value(prop_block, 'type'))
			required:    param_name in required_params
		}
		search_pos = obj_end + 1
	}
	return params
}

// 解析 tools/call 的返回内容。
fn parse_mcp_call_result(response string) !string {
	if !response.contains('"result"') {
		if response.contains('"error"') {
			err_msg := decode_json_string(extract_json_string_value(response, 'message'))
			if err_msg.len > 0 {
				return error('MCP Error: ${err_msg}')
			}
			return error('MCP Error response: ${response}')
		}
		return error('MCP 响应无效: ${response}')
	}
	mut text_result := ''
	content_key := '"content":['
	if content_idx := response.index(content_key) {
		arr_start := content_idx + content_key.len - 1
		arr_end := find_matching_bracket(response, arr_start)
		if arr_end > arr_start {
			content_arr := response[arr_start..arr_end + 1]
			mut pos := 0
			for pos < content_arr.len {
				remaining := content_arr[pos..]
				if type_idx := remaining.index('"type":"text"') {
					abs_pos := pos + type_idx
					after_type := content_arr[abs_pos..]
					if text_idx := after_type.index('"text":"') {
						value_start := abs_pos + text_idx + 8
						end := find_json_string_terminator(content_arr, value_start)
						if end > value_start {
							text_result += decode_json_string(content_arr[value_start..end])
							pos = end + 1
							continue
						}
					}
					pos = abs_pos + 13
				} else {
					break
				}
			}
		}
	}
	if text_result.len > 0 {
		return text_result
	}
	text_val := decode_json_string(extract_json_string_value(response, 'text'))
	if text_val.len > 0 {
		return text_val
	}
	return '(empty result)'
}
