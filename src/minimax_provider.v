module main

import net.http
import os
import time

fn call_minimax_text(config Config, prompt string) !string {
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
	mut recorder := new_session_recorder(config)!
	recorder.append_message('message', 'user', prompt) or {}
	return run_minimax_agent_with_recorder(config, prompt, mut recorder)
}

fn run_minimax_agent_in_session(config Config, prompt string, mut recorder SessionRecorder) !string {
	recorder.append_message('message', 'user', prompt) or {}
	return run_minimax_agent_with_recorder(config, prompt, mut recorder)
}

fn run_minimax_agent_with_recorder(config Config, prompt string, mut recorder SessionRecorder) !string {
	mut messages := []AgentMessage{}
	messages << AgentMessage{
		role:    'user'
		content: prompt
	}
	mut iteration := 0
	for iteration < max_tool_iterations {
		body_json := build_minimax_agent_request_json(config, messages)
		response_body := send_minimax_request(config, body_json)!
		content_json := extract_content_array(response_body)
		text := extract_text_blocks(content_json).trim_space()
		tool_uses := extract_tool_use_blocks(content_json)
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
	return error('tool iteration limit reached')
}

fn send_minimax_request(config Config, body_json string) !string {
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
	agents_path := os.join_path(config.workspace, 'AGENTS.md')
	if os.exists(agents_path) {
		return os.read_file(agents_path) or { '' }
	}
	return ''
}

fn parse_anthropic_text_response(body string) string {
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
