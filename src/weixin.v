module main

import net.http
import os
import time

struct WeixinGatewayHandler {
	config Config
}

const weixin_pending_messages_file = 'weixin_pending_messages.jsonl'
const weixin_inbound_messages_file = 'weixin_inbound_messages.jsonl'

fn start_weixin_gateway_server(config Config) ! {
	// 启动最小可用的 Weixin 后端协议 HTTP 服务。
	mut server := &http.Server{
		addr:                 '${config.weixin_host}:${config.weixin_port}'
		handler:              WeixinGatewayHandler{
			config: config
		}
		read_timeout:         30 * time.second
		write_timeout:        30 * time.second
		show_startup_message: false
	}
	server.listen_and_serve()
}

fn (handler WeixinGatewayHandler) handle(req http.Request) http.Response {
	// 按 MiniClaw 的 Weixin 后端协议分发请求。
	request_path := request_path_only(req.url)
	base_path := normalize_weixin_base_path(handler.config.weixin_base_path)
	if !request_path.starts_with(base_path) {
		return weixin_json_response(.not_found, '{"ret":-1,"errmsg":"not found"}')
	}
	if req.method != .post {
		return weixin_json_response(.method_not_allowed, '{"ret":-1,"errmsg":"method not allowed"}')
	}
	endpoint := weixin_endpoint_name(request_path, base_path)
	append_weixin_event_log(handler.config, endpoint, req.data) or {}
	match endpoint {
		'getupdates' {
			cursor := decode_json_string(extract_json_string_value(req.data, 'get_updates_buf'))
			return weixin_json_response(.ok, build_weixin_updates_response(handler.config,
				cursor))
		}
		'sendmessage' {
			message_json := extract_weixin_send_message_payload(req.data) or {
				return weixin_json_response(.bad_request, '{"ret":-1,"errmsg":"${escape_json_string(err.msg())}"}')
			}
			append_weixin_pending_message(handler.config, message_json) or {
				return weixin_json_response(.internal_server_error, '{"ret":-1,"errmsg":"${escape_json_string(err.msg())}"}')
			}
			return weixin_json_response(.ok, '{"ret":0}')
		}
		'getuploadurl' {
			return weixin_json_response(.ok, '{"upload_param":"","thumb_upload_param":""}')
		}
		'getconfig' {
			return weixin_json_response(.ok, '{"ret":0,"typing_ticket":"placeholder-typing-ticket"}')
		}
		'sendtyping' {
			return weixin_json_response(.ok, '{"ret":0}')
		}
		'ingest' {
			response := auto_reply_weixin_request(handler.config, req.data) or {
				return weixin_json_response(.bad_request, '{"ret":-1,"errmsg":"${escape_json_string(err.msg())}"}')
			}
			return weixin_json_response(.ok, '{"ret":0,"reply":"${escape_json_string(response)}"}')
		}
		else {
			return weixin_json_response(.not_found, '{"ret":-1,"errmsg":"unknown endpoint"}')
		}
	}
}

fn normalize_weixin_base_path(base_path string) string {
	// 确保基础路径统一为以 / 开头的形式。
	mut path := base_path.trim_space()
	if path.len == 0 {
		return '/weixin'
	}
	if !path.starts_with('/') {
		path = '/' + path
	}
	if path.ends_with('/') && path.len > 1 {
		path = path[..path.len - 1]
	}
	return path
}

fn weixin_base_url(config Config, base_path string) string {
	return 'http://${config.weixin_host}:${config.weixin_port}${base_path}'
}

fn weixin_endpoint_url(config Config, base_path string, endpoint string) string {
	return '${weixin_base_url(config, base_path)}/${endpoint}'
}

fn weixin_endpoint_name(request_path string, base_path string) string {
	// 从请求路径中提取协议端点名。
	base := normalize_weixin_base_path(base_path)
	if request_path.len <= base.len + 1 {
		return ''
	}
	if !request_path.starts_with(base + '/') {
		return ''
	}
	return request_path[base.len + 1..].to_lower()
}

fn queue_weixin_text_message(config Config, to_user_id string, context_token string, text string) !string {
	// 将待发送消息写入本地队列，供 getUpdates 拉取。
	trimmed_to_user_id := to_user_id.trim_space()
	trimmed_text := text.trim_space()
	if trimmed_to_user_id.len == 0 {
		return error('to_user_id is empty')
	}
	if trimmed_text.len == 0 {
		return error('message text is empty')
	}
	message_json := build_weixin_text_message_json(trimmed_to_user_id, context_token.trim_space(),
		trimmed_text)
	append_weixin_pending_message(config, message_json)!
	return message_json
}

fn auto_reply_weixin_message(config Config, from_user_id string, context_token string, text string) !string {
	// 执行“收到一句话 -> MiniClaw 回复 -> 排队发送”的最小闭环。
	trimmed_from_user_id := from_user_id.trim_space()
	trimmed_text := text.trim_space()
	if trimmed_from_user_id.len == 0 {
		return error('from_user_id is empty')
	}
	if trimmed_text.len == 0 {
		return error('message text is empty')
	}
	append_weixin_inbound_message(config, trimmed_from_user_id, context_token.trim_space(),
		trimmed_text)!
	mut recorder := new_session_recorder(config)!
	response := if config.api_key == 'placeholder' {
		'MiniClaw 已收到：${trimmed_text}'
	} else {
		run_minimax_agent_in_session(config, trimmed_text, mut recorder)!
	}
	queue_weixin_text_message(config, trimmed_from_user_id, recorder.session_id, response)!
	return response
}

fn auto_reply_weixin_request(config Config, request_body string) !string {
	// 从 HTTP 请求体中提取 inbound 消息并自动回复。
	inbound := parse_weixin_inbound_message(request_body)
	from_user_id := resolve_weixin_sender_id(inbound)
	context_token := resolve_weixin_context_token(inbound)
	text := inbound.text
	if from_user_id.len == 0 || text.len == 0 {
		return error('missing from_user_id or text')
	}
	return auto_reply_weixin_message(config, from_user_id, context_token, text)
}

struct WeixinInboundMessage {
	message_id      string
	session_id      string
	conversation_id string
	from_user_id    string
	to_user_id      string
	context_token   string
	message_type    int
	text            string
}

fn parse_weixin_inbound_message(request_body string) WeixinInboundMessage {
	// 兼容顶层、msg 和 d 三种输入包裹，尽量贴近真实 Weixin 消息结构。
	mut candidate := request_body
	for key in ['msg', 'd', 'message', 'payload'] {
		object_value := extract_json_object_value(request_body, key)
		if object_value.len > 0 {
			candidate = object_value
			break
		}
	}
	message_id := decode_json_string(extract_json_string_value(candidate, 'message_id'))
	session_id := decode_json_string(extract_json_string_value(candidate, 'session_id'))
	conversation_id := decode_json_string(extract_json_string_value(candidate, 'conversation_id'))
	message_type := extract_json_int_value(candidate, 'message_type')
	mut from_user_id := decode_json_string(extract_json_string_value(candidate, 'from_user_id'))
	to_user_id := decode_json_string(extract_json_string_value(candidate, 'to_user_id'))
	context_token := decode_json_string(extract_json_string_value(candidate, 'context_token'))
	mut text := decode_json_string(extract_json_string_value(candidate, 'text'))
	if text.len == 0 {
		item_list_json := extract_json_object_value(candidate, 'item_list')
		text = extract_weixin_text_from_item_list(item_list_json)
	}
	if text.len == 0 {
		content_json := extract_json_object_value(candidate, 'content')
		if content_json.len > 0 {
			text = decode_json_string(extract_json_string_value(content_json, 'text'))
		}
	}
	author_json := extract_json_object_value(candidate, 'author')
	if from_user_id.len == 0 && author_json.len > 0 {
		from_user_id = first_non_empty([
			decode_json_string(extract_json_string_value(author_json, 'user_openid')),
			decode_json_string(extract_json_string_value(author_json, 'openid')),
			decode_json_string(extract_json_string_value(author_json, 'id')),
		])
	}
	sender_json := extract_json_object_value(candidate, 'sender')
	if from_user_id.len == 0 && sender_json.len > 0 {
		from_user_id = weixin_first_non_empty([
			decode_json_string(extract_json_string_value(sender_json, 'user_openid')),
			decode_json_string(extract_json_string_value(sender_json, 'openid')),
			decode_json_string(extract_json_string_value(sender_json, 'id')),
		])
	}
	if from_user_id.len == 0 {
		from_user_id = weixin_first_non_empty([
			decode_json_string(extract_json_string_value(candidate, 'sender_id')),
			decode_json_string(extract_json_string_value(candidate, 'openid')),
		])
	}
	return WeixinInboundMessage{
		message_id:      message_id
		session_id:      session_id
		conversation_id: conversation_id
		from_user_id:    from_user_id
		to_user_id:      to_user_id
		context_token:   context_token
		message_type:    message_type
		text:            text
	}
}

fn build_weixin_text_message_json(to_user_id string, context_token string, text string) string {
	// 构造最小文本消息结构。
	create_time_ms := time.now().unix() * 1000
	session_key := resolve_weixin_context_token(WeixinInboundMessage{
		from_user_id:  to_user_id
		to_user_id:    to_user_id
		context_token: context_token
	})
	mut parts := []string{}
	parts << '"seq":1'
	parts << '"message_id":${time.now().unix()}'
	parts << '"from_user_id":"bot"'
	parts << '"to_user_id":"${escape_json_string(to_user_id)}"'
	parts << '"create_time_ms":${create_time_ms}'
	parts << '"session_id":"${escape_json_string(session_key)}"'
	parts << '"message_type":2'
	parts << '"message_state":2'
	parts << '"item_list":[{"type":1,"text_item":{"text":"${escape_json_string(text)}"}}]'
	if context_token.trim_space().len > 0 {
		parts << '"context_token":"${escape_json_string(context_token)}"'
	}
	return '{' + parts.join(',') + '}'
}

fn append_weixin_pending_message(config Config, message_json string) ! {
	// 追加一条待发送消息到本地队列。
	queue_path := os.join_path(config.workspace, 'state', weixin_pending_messages_file)
	existing := if os.exists(queue_path) { os.read_file(queue_path) or { '' } } else { '' }
	os.write_file(queue_path, existing + message_json + '\n')!
}

fn append_weixin_inbound_message(config Config, from_user_id string, context_token string, text string) ! {
	// 记录微信 inbound 消息，便于排查自动回复链路。
	log_path := os.join_path(config.workspace, 'state', weixin_inbound_messages_file)
	existing := if os.exists(log_path) { os.read_file(log_path) or { '' } } else { '' }
	line := '{"ts":"${escape_json_string(time.now().str())}","from_user_id":"${escape_json_string(from_user_id)}","context_token":"${escape_json_string(context_token)}","text":"${escape_json_string(text)}"}\n'
	os.write_file(log_path, existing + line)!
}

fn pop_weixin_pending_messages(config Config) []string {
	// 一次性取出并清空待发送队列。
	queue_path := os.join_path(config.workspace, 'state', weixin_pending_messages_file)
	if !os.exists(queue_path) {
		return []string{}
	}
	content := os.read_file(queue_path) or { return []string{} }
	mut messages := []string{}
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.len > 0 {
			messages << trimmed
		}
	}
	os.write_file(queue_path, '') or {}
	return messages
}

fn build_weixin_updates_response(config Config, cursor string) string {
	// 将待发送队列转换为 getUpdates 的返回值。
	messages := pop_weixin_pending_messages(config)
	if messages.len == 0 {
		return '{"ret":0,"msgs":[],"get_updates_buf":"${escape_json_string(cursor)}","longpolling_timeout_ms":35000}'
	}
	return '{"ret":0,"msgs":[' + messages.join(',') +
		'],"get_updates_buf":"${escape_json_string(time.now().unix().str())}","longpolling_timeout_ms":35000}'
}

fn extract_weixin_send_message_payload(request_body string) !string {
	// 从 sendMessage 请求中提取文本内容。
	msg_json := extract_json_object_value(request_body, 'msg')
	if msg_json.len == 0 {
		return error('missing msg object')
	}
	to_user_id := decode_json_string(extract_json_string_value(msg_json, 'to_user_id'))
	context_token := decode_json_string(extract_json_string_value(msg_json, 'context_token'))
	item_list_json := extract_json_object_value(msg_json, 'item_list')
	mut text := extract_weixin_text_from_item_list(item_list_json)
	if text.len == 0 {
		text = decode_json_string(extract_json_string_value(msg_json, 'text'))
	}
	if to_user_id.len == 0 || text.len == 0 {
		return error('missing to_user_id or text content')
	}
	return build_weixin_text_message_json(to_user_id, context_token, text)
}

fn resolve_weixin_sender_id(inbound WeixinInboundMessage) string {
	// 按常见优先级选择发送者标识。
	return weixin_first_non_empty([inbound.from_user_id, inbound.to_user_id])
}

fn resolve_weixin_context_token(inbound WeixinInboundMessage) string {
	// 按更稳定的消息上下文优先级选择会话键。
	return weixin_first_non_empty([inbound.context_token, inbound.session_id, inbound.conversation_id,
		inbound.message_id, inbound.from_user_id, inbound.to_user_id])
}

fn weixin_first_non_empty(values []string) string {
	for value in values {
		trimmed := value.trim_space()
		if trimmed.len > 0 {
			return trimmed
		}
	}
	return ''
}

fn extract_weixin_text_from_item_list(item_list_json string) string {
	// 从 item_list 数组里提取第一个文本项。
	if item_list_json.len == 0 {
		return ''
	}
	mut index := 0
	for index < item_list_json.len {
		if item_list_json[index] != `{` {
			index++
			continue
		}
		block_end := find_matching_bracket(item_list_json, index)
		if block_end <= index {
			break
		}
		block := item_list_json[index..block_end + 1]
		text_item := extract_json_object_value(block, 'text_item')
		if text_item.len > 0 {
			text := decode_json_string(extract_json_string_value(text_item, 'text'))
			if text.len > 0 {
				return text
			}
		}
		index = block_end + 1
	}
	return ''
}

fn append_weixin_event_log(config Config, kind string, payload string) ! {
	// 追加 Weixin 协议请求日志，便于后续接入真实消息流时排查。
	log_path := os.join_path(config.workspace, 'state', 'weixin_gateway_events.jsonl')
	existing := if os.exists(log_path) { os.read_file(log_path) or { '' } } else { '' }
	line := '{"ts":"${escape_json_string(time.now().str())}","kind":"${escape_json_string(kind)}","payload":${payload}}\n'
	os.write_file(log_path, existing + line)!
}

fn weixin_json_response(status http.Status, body string) http.Response {
	// 构造 Weixin 协议 JSON 响应。
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	mut response := http.Response{
		header: header
		body:   body
	}
	response.set_status(status)
	return response
}
