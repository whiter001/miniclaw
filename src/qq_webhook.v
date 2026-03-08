module main

import crypto.ed25519
import encoding.hex
import net.http
import os
import time

struct QqWebhookHandler {
	config Config
}

fn start_qq_webhook_server(config Config) ! {
	// 启动本地 QQ webhook HTTP 服务。
	mut server := &http.Server{
		addr:                 '${config.qq_webhook_host}:${config.qq_webhook_port}'
		handler:              QqWebhookHandler{
			config: config
		}
		read_timeout:         30 * time.second
		write_timeout:        30 * time.second
		show_startup_message: false
	}
	server.listen_and_serve()
}

fn (handler QqWebhookHandler) handle(req http.Request) http.Response {
	// 按请求路径和方法分发 webhook、验证和授权回调请求。
	request_path := request_path_only(req.url)
	if request_path == handler.config.qq_auth_callback_path {
		if req.method != .get {
			return qq_plain_response(.method_not_allowed, 'method not allowed')
		}
		return handle_qq_auth_callback(handler.config, req.url)
	}
	if request_path != handler.config.qq_webhook_path {
		return qq_plain_response(.not_found, 'not found')
	}
	if req.method != .post {
		return qq_plain_response(.method_not_allowed, 'method not allowed')
	}
	op := extract_json_int_value(req.data, 'op')
	if op == 13 {
		body := build_qq_validation_response(handler.config, req.data) or {
			return qq_json_response(.bad_request, '{"error":"${escape_json_string(err.msg())}"}')
		}
		append_qq_event_log(handler.config, 'validation', req.data) or {}
		return qq_json_response(.ok, body)
	}
	append_qq_event_log(handler.config, 'event', req.data) or {}
	spawn handle_qq_message_event_async(handler.config, req.data)
	return qq_json_response(.ok, '{"op":12}')
}

fn handle_qq_auth_callback(config Config, request_url string) http.Response {
	// 记录并返回 QQ 网页授权回调页面。
	query := extract_request_query(request_url)
	payload := '{"url":"${escape_json_string(request_url)}","query":"${escape_json_string(query)}"}'
	append_qq_event_log(config, 'auth_callback', payload) or {}
	body := '<!doctype html><html><head><meta charset="utf-8"><title>MiniClaw QQ Callback</title></head><body><h1>MiniClaw QQ Callback</h1><p>网页授权回调已到达。</p><pre>${escape_html(request_url)}</pre></body></html>'
	return qq_html_response(.ok, body)
}

fn request_path_only(request_url string) string {
	// 从 URL 中去掉查询串，仅保留路径部分。
	query_index := request_url.index('?') or { return request_url }
	return request_url[..query_index]
}

fn extract_request_query(request_url string) string {
	// 从 URL 中提取查询字符串。
	query_index := request_url.index('?') or { return '' }
	if query_index + 1 >= request_url.len {
		return ''
	}
	return request_url[query_index + 1..]
}

fn escape_html(value string) string {
	// 对 HTML 文本做最小转义。
	return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"',
		'&quot;')
}

fn handle_qq_message_event_async(config Config, payload string) {
	// 异步处理 QQ 消息事件，并在失败时补充日志。
	handle_qq_message_event(config, payload) or {
		append_qq_event_log(config, 'event_error', '{"error":"${escape_json_string(err.msg())}","raw":${payload}}') or {}
	}
}

fn handle_qq_message_event(config Config, payload string) ! {
	// 执行单条 QQ 消息事件的完整处理链路。
	target := extract_qq_reply_target(payload)
	if target.scene.len == 0 {
		return
	}
	if !is_qq_target_allowed(config, target) {
		append_qq_event_log(config, 'event_blocked', '{"scene":"${escape_json_string(target.scene)}","msg_id":"${escape_json_string(target.msg_id)}"}') or {}
		return
	}
	if !mark_qq_message_seen(config, target.msg_id)! {
		append_qq_event_log(config, 'event_duplicate', '{"scene":"${escape_json_string(target.scene)}","msg_id":"${escape_json_string(target.msg_id)}"}') or {}
		return
	}
	prompt := extract_qq_event_prompt(payload)
	if prompt.len == 0 {
		return
	}
	token := fetch_qq_access_token(config)!
	if config.qq_processing_text.trim_space().len > 0 {
		send_qq_reply(config, token.access_token, target, config.qq_processing_text, 1) or {
			append_qq_event_log(config, 'reply_placeholder_error', '{"scene":"${escape_json_string(target.scene)}","msg_id":"${escape_json_string(target.msg_id)}","error":"${escape_json_string(err.msg())}"}') or {}
		}
	}
	mut recorder := new_session_recorder(config)!
	response := run_minimax_agent_in_session(config, prompt, mut recorder) or {
		failure_message := build_qq_failure_message(err.msg())
		append_qq_agent_error_log(config, target, recorder.session_id, prompt, err.msg()) or {}
		send_qq_reply(config, token.access_token, target, failure_message, 2) or {}
		return err
	}
	_ := send_qq_reply(config, token.access_token, target, response, 2)!
	append_qq_event_log(config, 'reply_sent', '{"scene":"${escape_json_string(target.scene)}","msg_id":"${escape_json_string(target.msg_id)}","content":"${escape_json_string(response)}"}') or {}
}

fn build_qq_failure_message(error_message string) string {
	// 按错误类型生成更易理解的 QQ 降级提示文案。
	if error_message.contains(tool_iteration_error_prefix) {
		return '这个问题触发了过多工具调用，我没能在限定步数内完成。请把问题拆小一点，或直接说明要查看的文件、目录或命令。'
	}
	return '处理失败，请稍后重试。'
}

fn append_qq_agent_error_log(config Config, target QqReplyTarget, session_id string, prompt string, error_message string) ! {
	// 记录 Agent 处理失败时的诊断日志。
	kind := if error_message.contains(tool_iteration_error_prefix) {
		'event_tool_iteration_limit'
	} else {
		'event_error'
	}
	payload := '{"scene":"${escape_json_string(target.scene)}","msg_id":"${escape_json_string(target.msg_id)}","session_id":"${escape_json_string(session_id)}","prompt":"${escape_json_string(limit_error_preview(prompt))}","error":"${escape_json_string(error_message)}"}'
	append_qq_event_log(config, kind, payload)!
}

fn mark_qq_message_seen(config Config, msg_id string) !bool {
	// 用消息 ID 去重，避免重复回复同一事件。
	trimmed_id := msg_id.trim_space()
	if trimmed_id.len == 0 {
		return true
	}
	path := os.join_path(config.workspace, 'state', 'qq_seen_message_ids.txt')
	existing := if os.exists(path) { os.read_file(path) or { '' } } else { '' }
	for line in existing.split_into_lines() {
		if line.trim_space() == trimmed_id {
			return false
		}
	}
	os.write_file(path, existing + trimmed_id + '\n')!
	return true
}

fn build_qq_validation_response(config Config, payload string) !string {
	// 构建 QQ 平台回调验证所需的签名响应。
	d_object := extract_json_object_value(payload, 'd')
	plain_token := decode_json_string(extract_json_string_value(d_object, 'plain_token'))
	event_ts := decode_json_string(extract_json_string_value(d_object, 'event_ts'))
	if plain_token.len == 0 || event_ts.len == 0 {
		return error('invalid validation payload')
	}
	signature := sign_qq_validation(config.qq_app_secret, event_ts, plain_token)!
	return '{"plain_token":"${escape_json_string(plain_token)}","signature":"${signature}"}'
}

fn sign_qq_validation(secret string, event_ts string, plain_token string) !string {
	// 使用 QQ 约定的私钥派生方式生成校验签名。
	if secret.len == 0 {
		return error('qq_app_secret is empty')
	}
	mut seed := secret
	for seed.len < ed25519.seed_size {
		seed += secret
	}
	seed = seed[..ed25519.seed_size]
	private_key := ed25519.new_key_from_seed(seed.bytes())
	signature := ed25519.sign(private_key, (event_ts + plain_token).bytes())!
	return hex.encode(signature)
}

fn append_qq_event_log(config Config, kind string, payload string) ! {
	// 追加一条 QQ webhook 事件日志到本地 JSONL 文件。
	log_path := os.join_path(config.workspace, 'state', 'qq_webhook_events.jsonl')
	existing := if os.exists(log_path) { os.read_file(log_path) or { '' } } else { '' }
	line := '{"ts":"${escape_json_string(time.now().str())}","kind":"${escape_json_string(kind)}","payload":${payload}}\n'
	os.write_file(log_path, existing + line)!
}

fn qq_json_response(status http.Status, body string) http.Response {
	// 构造 JSON HTTP 响应。
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	mut response := http.Response{
		header: header
		body:   body
	}
	response.set_status(status)
	return response
}

fn qq_plain_response(status http.Status, body string) http.Response {
	// 构造纯文本 HTTP 响应。
	mut response := http.Response{
		body: body
	}
	response.set_status(status)
	return response
}

fn qq_html_response(status http.Status, body string) http.Response {
	// 构造 HTML HTTP 响应。
	mut header := http.new_header()
	header.add(.content_type, 'text/html; charset=utf-8')
	mut response := http.Response{
		header: header
		body:   body
	}
	response.set_status(status)
	return response
}
