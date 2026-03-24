module main

import net.http
import os

fn test_normalize_weixin_base_path() {
	assert normalize_weixin_base_path('weixin') == '/weixin'
	assert normalize_weixin_base_path('/weixin/') == '/weixin'
	assert normalize_weixin_base_path('') == '/weixin'
}

fn test_weixin_endpoint_name() {
	assert weixin_endpoint_name('/weixin/getUpdates', '/weixin') == 'getupdates'
	assert weixin_endpoint_name('/weixin/sendMessage', 'weixin') == 'sendmessage'
	assert weixin_endpoint_name('/other/sendMessage', '/weixin') == ''
}

fn test_build_weixin_text_message_json_contains_text() {
	json := build_weixin_text_message_json('user-1', 'ctx-1', 'hello world')
	assert json.contains('"to_user_id":"user-1"')
	assert json.contains('"context_token":"ctx-1"')
	assert json.contains('hello world')
}

fn test_extract_weixin_send_message_payload_extracts_text() {
	payload := '{"msg":{"to_user_id":"user-1","context_token":"ctx-1","item_list":[{"type":1,"text_item":{"text":"hello"}}]}}'
	json := extract_weixin_send_message_payload(payload) or { panic(err) }
	assert json.contains('"to_user_id":"user-1"')
	assert json.contains('hello')
}

fn test_weixin_queue_and_drain_messages() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-weixin-queue')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
	}
	queue_weixin_text_message(config, 'user-1', 'ctx-1', 'queued hello') or { panic(err) }
	response := build_weixin_updates_response(config, '')
	assert response.contains('queued hello')
	assert response.contains('"get_updates_buf"')
	assert pop_weixin_pending_messages(config).len == 0
}

fn test_auto_reply_weixin_message_queues_response() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-weixin-autoreply')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
		api_key:   'placeholder'
	}
	reply := auto_reply_weixin_message(config, 'user-2', 'ctx-2', 'hello miniclaw') or {
		panic(err)
	}
	assert reply.len > 0
	updates := build_weixin_updates_response(config, '')
	assert updates.contains('user-2')
	assert updates.contains('"message_type":2')
}

fn test_parse_weixin_inbound_message_accepts_nested_msg() {
	message := parse_weixin_inbound_message('{"msg":{"from_user_id":"user-4","context_token":"ctx-4","item_list":[{"type":1,"text_item":{"text":"nested hello"}}]}}')
	assert message.from_user_id == 'user-4'
	assert message.context_token == 'ctx-4'
	assert message.text == 'nested hello'
}

fn test_parse_weixin_inbound_message_accepts_d_wrapper() {
	message := parse_weixin_inbound_message('{"d":{"from_user_id":"user-5","text":"wrapped hello"}}')
	assert message.from_user_id == 'user-5'
	assert message.text == 'wrapped hello'
}

fn test_parse_weixin_inbound_message_accepts_more_fields() {
	message := parse_weixin_inbound_message('{"msg":{"message_id":"msg-9","session_id":"sess-9","conversation_id":"conv-9","author":{"user_openid":"openid-9"},"to_user_id":"bot","item_list":[{"type":1,"text_item":{"text":"hello richer envelope"}}]}}')
	assert message.message_id == 'msg-9'
	assert message.session_id == 'sess-9'
	assert message.conversation_id == 'conv-9'
	assert message.from_user_id == 'openid-9'
	assert message.to_user_id == 'bot'
	assert resolve_weixin_sender_id(message) == 'openid-9'
	assert resolve_weixin_context_token(message) == 'sess-9'
}

fn test_weixin_ingest_http_endpoint_auto_replies() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-weixin-ingest')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	handler := WeixinGatewayHandler{
		config: Config{
			workspace:        workspace
			api_key:          'placeholder'
			weixin_base_path: '/weixin'
		}
	}
	response := handler.handle(http.Request{
		method: .post
		url:    '/weixin/ingest'
		data:   '{"msg":{"from_user_id":"user-3","context_token":"ctx-http","item_list":[{"type":1,"text_item":{"text":"hello from http"}}]}}'
	})
	assert response.status_code == 200
	assert response.body.contains('"ret":0')
	assert response.body.contains('MiniClaw 已收到')
	updates := build_weixin_updates_response(Config{ workspace: workspace }, '')
	assert updates.contains('user-3')
}
