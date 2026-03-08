module main

import os

// 最大工具迭代次数 (10-1000, 默认100)
// 可通过 config 中的 max_tool_iterations 或环境变量 MINICLAW_MAX_TOOL_ITERATIONS 配置
const max_tool_iterations = 100
const max_exec_output_chars = 12000

const blocked_exec_patterns = [
	'rm -rf',
	'rmdir /s',
	'del /f',
	'mkfs',
	'format ',
	'dd if=',
	'shutdown',
	'reboot',
	'poweroff',
	':(){ :|:& };:',
]

struct ToolUse {
mut:
	id    string
	name  string
	input map[string]string
}

struct AgentMessage {
mut:
	role         string
	content      string
	content_json string
}

fn get_tools_schema_json() string {
	// 返回提供给模型的工具声明 JSON。
	return '[{"name":"list_dir","description":"List files and directories inside the workspace. Use this before reading files when you need to explore.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Relative path inside the workspace. Use . for the workspace root."}},"required":[]}},{"name":"read_file","description":"Read a UTF-8 text file from the workspace.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path inside the workspace."},"start_line":{"type":"string","description":"Optional 1-based start line."},"end_line":{"type":"string","description":"Optional 1-based end line."}},"required":["path"]}},{"name":"write_file","description":"Write a UTF-8 text file inside the workspace. This replaces the full file content.","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path inside the workspace."},"content":{"type":"string","description":"Full file content to write."}},"required":["path","content"]}},{"name":"exec","description":"Run a shell command with the workspace as the current working directory. Dangerous destructive commands are blocked.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run."}},"required":["command"]}},{"name":"grep_search","description":"Search for text or regex inside workspace files.","input_schema":{"type":"object","properties":{"query":{"type":"string","description":"Search pattern."},"path":{"type":"string","description":"Optional relative directory or file path inside the workspace."},"is_regexp":{"type":"string","description":"Set to true to treat query as regular expression."}},"required":["query"]}}]'
}

fn execute_tool(tool ToolUse, config Config) !string {
	// 根据工具名称分派到对应实现。
	return match tool.name {
		'list_dir' { tool_list_dir(tool, config) }
		'read_file' { tool_read_file(tool, config) }
		'write_file' { tool_write_file(tool, config) }
		'exec' { tool_exec(tool, config) }
		'grep_search' { tool_grep_search(tool, config) }
		else { error('unsupported tool: ${tool.name}') }
	}
}

fn tool_list_dir(tool ToolUse, config Config) !string {
	// 列出工作区内目录的直接子项。
	rel_path := first_non_empty([
		tool.input['path'] or { '' },
		tool.input['dir'] or { '' },
		'.',
	])
	resolved := resolve_workspace_path(config.workspace, rel_path)!
	if !os.is_dir(resolved) {
		return error('not a directory: ${rel_path}')
	}
	entries := os.ls(resolved) or { return error('failed to list directory: ${err.msg()}') }
	mut lines := []string{}
	for entry in entries.sorted() {
		full_path := os.join_path(resolved, entry)
		if os.is_dir(full_path) {
			lines << '${entry}/'
		} else {
			lines << entry
		}
	}
	return lines.join('\n')
}

fn tool_read_file(tool ToolUse, config Config) !string {
	// 读取工作区内文本文件，可选按行截取。
	rel_path := first_non_empty([
		tool.input['path'] or { '' },
		tool.input['filePath'] or { '' },
	])
	if rel_path.len == 0 {
		return error('path is required')
	}
	resolved := resolve_workspace_path(config.workspace, rel_path)!
	if !os.is_file(resolved) {
		return error('not a file: ${rel_path}')
	}
	content := os.read_file(resolved) or { return error('failed to read file: ${err.msg()}') }
	start_line := parse_optional_positive_int(tool.input['start_line'] or {
		tool.input['startLine'] or { '' }
	})
	end_line := parse_optional_positive_int(tool.input['end_line'] or {
		tool.input['endLine'] or { '' }
	})
	if start_line == 0 && end_line == 0 {
		return content
	}
	lines := content.split_into_lines()
	start := if start_line > 0 { start_line } else { 1 }
	end := if end_line > 0 { end_line } else { lines.len }
	if start > end || start > lines.len {
		return ''
	}
	safe_end := if end > lines.len { lines.len } else { end }
	return lines[start - 1..safe_end].join('\n')
}

fn tool_write_file(tool ToolUse, config Config) !string {
	// 把完整内容写入工作区内目标文件。
	rel_path := first_non_empty([
		tool.input['path'] or { '' },
		tool.input['filePath'] or { '' },
	])
	content := tool.input['content'] or { '' }
	if rel_path.len == 0 {
		return error('path is required')
	}
	resolved := resolve_workspace_path(config.workspace, rel_path)!
	parent_dir := os.dir(resolved)
	if parent_dir.len > 0 {
		os.mkdir_all(parent_dir) or {
			return error('failed to create parent directory: ${err.msg()}')
		}
	}
	os.write_file(resolved, content) or { return error('failed to write file: ${err.msg()}') }
	return 'wrote ${rel_path} (${content.len} chars)'
}

fn tool_exec(tool ToolUse, config Config) !string {
	// 在工作区内执行 shell 命令，并做危险命令拦截。
	command := first_non_empty([
		tool.input['command'] or { '' },
		tool.input['cmd'] or { '' },
	])
	if command.len == 0 {
		return error('command is required')
	}
	if is_blocked_command(command) {
		return error('command blocked by safety guard')
	}
	quoted_workspace := shell_quote(config.workspace)
	mut result := os.execute('cd ${quoted_workspace} && ${command}')
	mut output := result.output.trim_space()
	if output.len == 0 {
		output = '(no output)'
	}
	if output.len > max_exec_output_chars {
		output = output[..max_exec_output_chars] + '\n... (truncated)'
	}
	if result.exit_code != 0 {
		return error('exit code ${result.exit_code}: ${output}')
	}
	return output
}

fn tool_grep_search(tool ToolUse, config Config) !string {
	// 在工作区内执行文本或正则搜索。
	query := first_non_empty([
		tool.input['query'] or { '' },
		tool.input['pattern'] or { '' },
	])
	if query.len == 0 {
		return error('query is required')
	}
	rel_path := first_non_empty([
		tool.input['path'] or { '' },
		'.',
	])
	root := resolve_workspace_path(config.workspace, rel_path)!
	use_regexp := (tool.input['is_regexp'] or { tool.input['isRegexp'] or { 'false' } }).to_lower() == 'true'
	pattern_flag := if use_regexp { '-e' } else { '-F -e' }
	quoted_query := shell_quote(query)
	quoted_root := shell_quote(root)
	result := os.execute('if command -v rg >/dev/null 2>&1; then rg -n --no-heading --color never ${pattern_flag} ${quoted_query} ${quoted_root}; else grep -R -n ${if use_regexp {
		'-E'
	} else {
		'-F'
	}} ${quoted_query} ${quoted_root}; fi')
	output := result.output.trim_space()
	if output.len == 0 {
		if result.exit_code <= 1 {
			return '(no matches)'
		}
		return error('search failed with exit code ${result.exit_code}')
	}
	mut lines := output.split_into_lines()
	for index, line in lines {
		if line.starts_with(root) {
			lines[index] = relative_to_workspace(config.workspace, line.all_after(root +
				os.path_separator.str()))
		}
	}
	if lines.len > 50 {
		return lines[..50].join('\n') + '\n... (truncated)'
	}
	return lines.join('\n')
}

fn resolve_workspace_path(workspace string, rel_path string) !string {
	// 将相对路径解析为工作区内的安全绝对路径。
	base := os.real_path(workspace)
	mut target := if rel_path == '.' || rel_path.len == 0 {
		base
	} else {
		os.join_path(base, rel_path)
	}
	target = os.norm_path(target)
	if target != base && !target.starts_with(base + os.path_separator.str()) {
		return error('path escapes workspace: ${rel_path}')
	}
	return target
}

fn relative_to_workspace(workspace string, file_path string) string {
	// 将绝对路径转换为相对工作区路径。
	base := os.norm_path(workspace)
	normalized := os.norm_path(file_path)
	if normalized == base {
		return '.'
	}
	if normalized.starts_with(base + os.path_separator.str()) {
		return normalized[base.len + 1..]
	}
	return normalized
}

fn is_blocked_command(command string) bool {
	// 判断命令是否命中危险命令黑名单。
	normalized := command.to_lower()
	for pattern in blocked_exec_patterns {
		if normalized.contains(pattern) {
			return true
		}
	}
	return false
}

fn shell_quote(value string) string {
	// 对 shell 参数进行单引号转义。
	return "'" + value.replace("'", "'\\''") + "'"
}

fn parse_optional_positive_int(value string) int {
	// 解析可选的正整数参数，不合法时返回 0。
	if value.len == 0 {
		return 0
	}
	parsed := value.int()
	if parsed > 0 {
		return parsed
	}
	return 0
}

fn first_non_empty(values []string) string {
	// 返回第一个非空字符串值。
	for value in values {
		if value.trim_space().len > 0 {
			return value.trim_space()
		}
	}
	return ''
}

fn build_tool_result_message(tool ToolUse, result string, is_error bool) AgentMessage {
	// 将工具执行结果封装为回灌模型的消息块。
	escaped_result := escape_json_string(result)
	mut block := '{"type":"tool_result","tool_use_id":"${escape_json_string(tool.id)}","content":"${escaped_result}"'
	if is_error {
		block += ',"is_error":true'
	}
	block += '}'
	return AgentMessage{
		role:         'user'
		content_json: '[' + block + ']'
	}
}
