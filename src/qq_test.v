module main

import net.http
import os

fn test_csv_contains_value() {
	assert csv_contains_value('alpha,beta,gamma', 'beta')
	assert csv_contains_value('alpha, beta ,gamma', 'beta')
	assert !csv_contains_value('alpha,beta,gamma', 'delta')
}

fn test_is_qq_target_allowed() {
	config := Config{
		qq_allow_users:  'u-1,u-2'
		qq_allow_groups: 'g-1,g-2'
	}
	assert is_qq_target_allowed(config, QqReplyTarget{
		scene:  'c2c'
		openid: 'u-2'
	})
	assert !is_qq_target_allowed(config, QqReplyTarget{
		scene:  'c2c'
		openid: 'u-9'
	})
	assert is_qq_target_allowed(config, QqReplyTarget{
		scene:        'group'
		group_openid: 'g-1'
	})
	assert !is_qq_target_allowed(config, QqReplyTarget{
		scene:        'group'
		group_openid: 'g-9'
	})
}

fn test_mark_qq_message_seen() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-qq-seen')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
	}
	assert mark_qq_message_seen(config, 'msg-1') or { panic(err) }
	assert !(mark_qq_message_seen(config, 'msg-1') or { panic(err) })
	assert mark_qq_message_seen(config, 'msg-2') or { panic(err) }
}

fn test_extract_qq_reply_target_and_prompt_for_c2c() {
	openid_key := 'user_' + 'openid'
	payload := '{"t":"C2C_MESSAGE_CREATE","d":{"id":"msg-1","content":" hello ","author":{"' +
		openid_key + '":"user-1"}}}'
	target := extract_qq_reply_target(payload)
	assert target.scene == 'c2c'
	assert target.openid == 'user-1'
	assert target.msg_id == 'msg-1'
	assert extract_qq_event_prompt(payload) == 'hello'
}

fn test_extract_qq_reply_target_and_prompt_for_group() {
	payload := '{"t":"GROUP_AT_MESSAGE_CREATE","d":{"id":"msg-2","content":" ping ","group_openid":"group-1"}}'
	target := extract_qq_reply_target(payload)
	assert target.scene == 'group'
	assert target.group_openid == 'group-1'
	assert target.msg_id == 'msg-2'
	assert extract_qq_event_prompt(payload) == 'ping'
}

fn test_qq_webhook_get_rejected_for_message_path() {
	handler := QqWebhookHandler{
		config: Config{
			qq_webhook_path: '/webhook/qq'
		}
	}
	response := handler.handle(http.Request{
		method: .get
		url:    '/webhook/qq'
	})
	assert response.status_code == 405
	assert response.body == 'method not allowed'
}

fn test_qq_webhook_validation_returns_signature() {
	config := Config{
		qq_app_secret:   'secret-value'
		qq_webhook_path: '/webhook/qq'
	}
	handler := QqWebhookHandler{
		config: config
	}
	response := handler.handle(http.Request{
		method: .post
		url:    '/webhook/qq'
		data:   '{"op":13,"d":{"plain_token":"plain-token","event_ts":"1700000000"}}'
	})
	assert response.status_code == 200
	assert response.body.contains('"plain_token":"plain-token"')
	assert response.body.contains('"signature":"')
}

fn test_qq_auth_callback_renders_html() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-qq-auth-callback')
	os.mkdir_all(os.join_path(workspace, 'state')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	handler := QqWebhookHandler{
		config: Config{
			workspace:             workspace
			qq_auth_callback_path: '/qq-callback'
		}
	}
	response := handler.handle(http.Request{
		method: .get
		url:    '/qq-callback?code=abc'
	})
	assert response.status_code == 200
	assert response.body.contains('MiniClaw QQ Callback')
	assert response.body.contains('/qq-callback?code=abc')
}

fn test_build_tool_iteration_limit_error_contains_context() {
	err := build_tool_iteration_limit_error(8, 'need more workspace exploration', [
		ToolUse{
			name: 'list_dir'
		},
		ToolUse{
			name: 'read_file'
		},
	])
	assert err.contains(tool_iteration_error_prefix)
	assert err.contains('after 8 rounds')
	assert err.contains('list_dir, read_file')
	assert err.contains('need more workspace exploration')
}

fn test_build_qq_failure_message_for_iteration_limit() {
	message := build_qq_failure_message('tool iteration limit reached (after 8 rounds; last tools: exec)')
	assert message.contains('过多工具调用')
	assert message.contains('拆小一点')
}
