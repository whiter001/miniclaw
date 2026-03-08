module main

import net.http
import os
import time

const tool_iteration_error_prefix = 'tool iteration limit reached'

fn call_minimax_text(config Config, prompt string) !string {
	// 发起一次纯文本 MiniMax 请求。
	if config.api_key.len == 0 {
		return error('MINICLAW_API_KEY is not configured')
	}
	body_json := build_minimax_request_json(config, prompt)
	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${config.api_key}')
	headers.add(.content_type, 'application/json')

	mut request := http.Request{
		method:        .post
		url:           config.api_url
		header:        headers
		data:          body_json
		read_timeout:  time.second * config.request_timeout
		write_timeout: 30 * time.second
	}

	response := request.do() or { return error('request failed: ${err.msg()}') }
	if response.status_code != 200 {
		return error('MiniMax API error ${response.status_code}: ${response.body}')
	}

	text := parse_anthropic_text_response(response.body)
	if text.len == 0 {
		return error('MiniMax returned an empty text response')
	}
	return text
}

fn run_minimax_agent(config Config, prompt string) !string {
	// 为单次请求创建会话记录器并运行 Agent。
	mut recorder := new_session_recorder(config)!
	recorder.append_message('message', 'user', prompt) or {}
	return run_minimax_agent_with_recorder(config, prompt, mut recorder)
}

fn run_minimax_agent_in_session(config Config, prompt string, mut recorder SessionRecorder) !string {
	// 在现有会话记录器上继续运行 Agent。
	recorder.append_message('message', 'user', prompt) or {}
	return run_minimax_agent_with_recorder(config, prompt, mut recorder)
}

fn run_minimax_agent_with_recorder(config Config, prompt string, mut recorder SessionRecorder) !string {
	// 执行带工具循环的 MiniMax Agent 主流程。
	mut messages := []AgentMessage{}
	messages << AgentMessage{
		role:    'user'
		content: prompt
	}
	mut iteration := 0
	mut last_assistant_text := ''
	mut last_tool_uses := []ToolUse{}
	for iteration < max_tool_iterations {
		body_json := build_minimax_agent_request_json(config, messages)
		response_body := send_minimax_request(config, body_json)!
		content_json := extract_content_array(response_body)
		text := extract_text_blocks(content_json).trim_space()
		tool_uses := extract_tool_use_blocks(content_json)
		last_assistant_text = text
		last_tool_uses = tool_uses.clone()
		messages << AgentMessage{
			role:         'assistant'
			content:      text
			content_json: content_json
		}
		if tool_uses.len == 0 {
			recorder.append_message('message', 'assistant', text) or {}
			return text
		}
		for tool in tool_uses {
			recorder.append_tool(tool, 'invoked', false) or {}
			tool_result := execute_tool(tool, config) or {
				recorder.append_tool(tool, 'Error: ${err.msg()}', true) or {}
				messages << build_tool_result_message(tool, 'Error: ${err.msg()}', true)
				continue
			}
			recorder.append_tool(tool, tool_result, false) or {}
			messages << build_tool_result_message(tool, tool_result, false)
		}
		iteration++
	}
	return error(build_tool_iteration_limit_error(iteration, last_assistant_text, last_tool_uses))
}

fn build_tool_iteration_limit_error(iteration int, assistant_text string, tool_uses []ToolUse) string {
	// 生成包含上下文的工具循环超限错误信息。
	mut details := []string{}
	details << 'after ${iteration} rounds'
	tool_names := summarize_tool_use_names(tool_uses)
	if tool_names.len > 0 {
		details << 'last tools: ${tool_names}'
	}
	text_preview := limit_error_preview(assistant_text)
	if text_preview.len > 0 {
		details << 'last assistant text: ${text_preview}'
	}
	return tool_iteration_error_prefix + ' (' + details.join('; ') + ')'
}

fn summarize_tool_use_names(tool_uses []ToolUse) string {
	// 汇总最近一轮工具调用名称，便于日志诊断。
	if tool_uses.len == 0 {
		return ''
	}
	mut names := []string{}
	for tool in tool_uses {
		if tool.name.len == 0 {
			continue
		}
		names << tool.name
		if names.len == 4 {
			break
		}
	}
	if names.len == 0 {
		return ''
	}
	mut summary := names.join(', ')
	if tool_uses.len > names.len {
		summary += ' +${tool_uses.len - names.len} more'
	}
	return summary
}

fn limit_error_preview(value string) string {
	// 截断错误上下文中的长文本，避免日志过长。
	preview := value.replace('\n', ' ').replace('\r', ' ').trim_space()
	if preview.len == 0 {
		return ''
	}
	if preview.len > 120 {
		return preview[..120] + '...'
	}
	return preview
}

fn send_minimax_request(config Config, body_json string) !string {
	// 先尝试用 V 的 HTTP 客户端请求 MiniMax，失败时再走 curl 兜底。
	if config.api_key.len == 0 {
		return error('MINICLAW_API_KEY is not configured')
	}
	mut headers := http.new_header()
	headers.add(.authorization, 'Bearer ${config.api_key}')
	headers.add(.content_type, 'application/json')

	mut request := http.Request{
		method:        .post
		url:           config.api_url
		header:        headers
		data:          body_json
		read_timeout:  time.second * config.request_timeout
		write_timeout: 30 * time.second
	}

	response := request.do() or {
		return send_minimax_request_via_curl(config, body_json) or {
			return error('request failed: ${err.msg()}')
		}
	}
	if response.status_code != 200 {
		return error('MiniMax API error ${response.status_code}: ${response.body}')
	}
	return response.body
}

fn send_minimax_request_via_curl(config Config, body_json string) !string {
	// 使用 curl 发送请求，规避部分环境下的 HTTP 客户端兼容问题。
	status_marker := '__MINICLAW_HTTP_STATUS__:'
	command := 'curl -sS --max-time ${config.request_timeout} -X POST ' +
		shell_quote(config.api_url) + ' -H ' +
		shell_quote('Authorization: Bearer ${config.api_key}') + ' -H ' +
		shell_quote('Content-Type: application/json') + ' --data ' + shell_quote(body_json) +
		' -w ' + shell_quote('\n${status_marker}%{http_code}')
	result := os.execute(command)
	if result.exit_code != 0 {
		return error('curl fallback failed with exit code ${result.exit_code}: ${result.output.trim_space()}')
	}
	output := result.output
	marker_index := output.last_index(status_marker) or {
		return error('curl fallback missing status marker')
	}
	body := output[..marker_index]
	status_code := output[marker_index + status_marker.len..].trim_space().int()
	if status_code != 200 {
		return error('MiniMax API error ${status_code}: ${body.trim_space()}')
	}
	return body.trim_space()
}

fn build_minimax_request_json(config Config, prompt string) string {
	// 构建单轮文本请求体。
	mut body_json := '{"model":"${escape_json_string(config.model)}","max_tokens":${config.max_tokens},"temperature":${config.temperature}'
	system_prompt := load_system_prompt(config)
	if system_prompt.len > 0 {
		body_json += ',"system":"${escape_json_string(system_prompt)}"'
	}
	escaped_prompt := escape_json_string(prompt)
	body_json += ',"messages":[{"role":"user","content":[{"type":"text","text":"${escaped_prompt}"}]}]}'
	return body_json
}

fn build_minimax_agent_request_json(config Config, messages []AgentMessage) string {
	// 构建包含工具声明和消息历史的 Agent 请求体。
	mut body_json := '{"model":"${escape_json_string(config.model)}","max_tokens":${config.max_tokens},"temperature":${config.temperature}'
	system_prompt := load_system_prompt(config)
	default_system := 'You are MiniClaw, a local AI agent. When you need workspace information, prefer using tools instead of guessing. Only access files inside the workspace.'
	effective_system := if system_prompt.len > 0 {
		default_system + '\n\n' + system_prompt
	} else {
		default_system
	}
	body_json += ',"system":"${escape_json_string(effective_system)}"'
	body_json += ',"tools":' + get_tools_schema_json()
	body_json += ',"messages":['
	for message in messages {
		if message.content_json.len > 0 {
			body_json += '{"role":"${message.role}","content":${message.content_json}},'
		} else {
			body_json += '{"role":"${message.role}","content":[{"type":"text","text":"${escape_json_string(message.content)}"}]},'
		}
	}
	if body_json.ends_with(',') {
		body_json = body_json[..body_json.len - 1]
	}
	body_json += ']}'
	return body_json
}

fn load_system_prompt(config Config) string {
	// 读取工作区中的 AGENTS.md 作为系统提示补充。
	agents_path := os.join_path(config.workspace, 'AGENTS.md')
	if os.exists(agents_path) {
		return os.read_file(agents_path) or { '' }
	}
	return ''
}

fn parse_anthropic_text_response(body string) string {
	// 从 Anthropic 兼容响应中提取最终文本内容。
	content_json := extract_content_array(body)
	if content_json.len > 0 {
		return extract_text_blocks(content_json).trim_space()
	}
	pattern := '"text":"'
	if index := body.index(pattern) {
		start := index + pattern.len
		end := find_json_string_terminator(body, start)
		if end > start {
			return decode_json_string(body[start..end]).trim_space()
		}
	}
	return ''
}
