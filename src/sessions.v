module main

import os
import time

struct SessionRecorder {
mut:
	session_id string
	file_path  string
}

fn new_session_recorder(config Config) !SessionRecorder {
	// 为当前会话创建新的 JSONL 记录器。
	session_id := time.now().format_ss_milli().replace(':', '-').replace(' ', '_')
	file_path := os.join_path(config.workspace, 'sessions', 'session-' + session_id + '.jsonl')
	if !os.exists(os.dir(file_path)) {
		os.mkdir_all(os.dir(file_path))!
	}
	os.write_file(file_path, '')!
	return SessionRecorder{
		session_id: session_id
		file_path:  file_path
	}
}

fn (mut recorder SessionRecorder) append_message(kind string, role string, content string) ! {
	// 追加一条普通消息记录。
	line := '{"ts":"${escape_json_string(time.now().str())}","kind":"${escape_json_string(kind)}","role":"${escape_json_string(role)}","content":"${escape_json_string(content)}"}\n'
	append_session_line(recorder.file_path, line)!
}

fn (mut recorder SessionRecorder) append_tool(tool ToolUse, result string, is_error bool) ! {
	// 追加一条工具调用结果记录。
	line := '{"ts":"${escape_json_string(time.now().str())}","kind":"tool","tool_name":"${escape_json_string(tool.name)}","tool_id":"${escape_json_string(tool.id)}","is_error":${if is_error {
		'true'
	} else {
		'false'
	}},"content":"${escape_json_string(result)}"}\n'
	append_session_line(recorder.file_path, line)!
}

fn append_session_line(file_path string, line string) ! {
	// 把单行内容追加写入会话文件。
	existing := if os.exists(file_path) { os.read_file(file_path) or { '' } } else { '' }
	os.write_file(file_path, existing + line)!
}
