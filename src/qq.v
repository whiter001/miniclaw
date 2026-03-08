module main

import net.http
import os
import time

const qq_access_token_url = 'https://bots.qq.com/app/getAppAccessToken'

struct QqAccessToken {
mut:
	access_token string
	expires_in   int
	fetched_at   i64
}

struct QqBotProfile {
mut:
	id        string
	username  string
	avatar    string
	share_url string
}

struct QqReplyTarget {
mut:
	scene        string
	openid       string
	group_openid string
	msg_id       string
}

fn fetch_qq_access_token(config Config) !QqAccessToken {
	if config.qq_app_id.len == 0 || config.qq_app_secret.len == 0 {
		return error('qq_app_id or qq_app_secret is not configured')
	}
	body := '{"appId":"${escape_json_string(config.qq_app_id)}","clientSecret":"${escape_json_string(config.qq_app_secret)}"}'
	mut headers := http.new_header()
	headers.add(.content_type, 'application/json')
	mut request := http.Request{
		method:        .post
		url:           qq_access_token_url
		header:        headers
		data:          body
		read_timeout:  time.second * config.request_timeout
		write_timeout: 30 * time.second
	}
	response := request.do() or { return error('qq access token request failed: ${err.msg()}') }
	if response.status_code != 200 {
		return error('qq access token api error ${response.status_code}: ${response.body}')
	}
	token := decode_json_string(extract_json_string_value(response.body, 'access_token'))
	if token.len == 0 {
		return error('qq access token missing in response: ${response.body}')
	}
	return QqAccessToken{
		access_token: token
		expires_in:   extract_json_int_value(response.body, 'expires_in')
		fetched_at:   time.now().unix()
	}
}

fn fetch_qq_bot_profile(config Config, access_token string) !QqBotProfile {
	mut headers := http.new_header()
	headers.add(.authorization, 'QQBot ${access_token}')
	mut request := http.Request{
		method:       .get
		url:          config.qq_api_base + '/users/@me'
		header:       headers
		read_timeout: time.second * config.request_timeout
	}
	response := request.do() or { return error('qq profile request failed: ${err.msg()}') }
	if response.status_code != 200 {
		return error('qq profile api error ${response.status_code}: ${response.body}')
	}
	return QqBotProfile{
		id:        decode_json_string(extract_json_string_value(response.body, 'id'))
		username:  decode_json_string(extract_json_string_value(response.body, 'username'))
		avatar:    decode_json_string(extract_json_string_value(response.body, 'avatar'))
		share_url: decode_json_string(extract_json_string_value(response.body, 'share_url'))
	}
}

fn write_qq_gateway_state(config Config, token QqAccessToken, profile QqBotProfile) !string {
	state_path := os.join_path(config.workspace, 'state', 'qq_gateway_state.json')
	content := '{\n' +
		'  "fetched_at": "${escape_json_string(time.unix(token.fetched_at).str())}",\n' +
		'  "access_token": "${escape_json_string(token.access_token)}",\n' +
		'  "expires_in": ${token.expires_in},\n' + '  "profile": {\n' +
		'    "id": "${escape_json_string(profile.id)}",\n' +
		'    "username": "${escape_json_string(profile.username)}",\n' +
		'    "avatar": "${escape_json_string(profile.avatar)}",\n' +
		'    "share_url": "${escape_json_string(profile.share_url)}"\n' + '  }\n' + '}\n'
	os.write_file(state_path, content)!
	return state_path
}

fn send_qq_reply(config Config, access_token string, target QqReplyTarget, content string, msg_seq int) !string {
	trimmed_content := content.trim_space()
	if trimmed_content.len == 0 {
		return error('qq reply content is empty')
	}
	sequence := if msg_seq > 0 { msg_seq } else { 1 }
	mut url := ''
	mut body := ''
	if target.scene == 'c2c' {
		url = '${config.qq_api_base}/v2/users/${target.openid}/messages'
		body = '{"content":"${escape_json_string(trimmed_content)}","msg_type":0,"msg_id":"${escape_json_string(target.msg_id)}","msg_seq":${sequence}}'
	} else if target.scene == 'group' {
		url = '${config.qq_api_base}/v2/groups/${target.group_openid}/messages'
		body = '{"content":"${escape_json_string(trimmed_content)}","msg_type":0,"msg_id":"${escape_json_string(target.msg_id)}","msg_seq":${sequence}}'
	} else {
		return error('unsupported qq reply scene: ${target.scene}')
	}
	mut headers := http.new_header()
	headers.add(.authorization, 'QQBot ${access_token}')
	headers.add(.content_type, 'application/json')
	mut request := http.Request{
		method:        .post
		url:           url
		header:        headers
		data:          body
		read_timeout:  time.second * config.request_timeout
		write_timeout: 30 * time.second
	}
	response := request.do() or { return error('qq send message request failed: ${err.msg()}') }
	if response.status_code != 200 {
		return error('qq send message api error ${response.status_code}: ${response.body}')
	}
	return response.body
}

fn is_qq_target_allowed(config Config, target QqReplyTarget) bool {
	if target.scene == 'c2c' {
		if config.qq_allow_users.trim_space().len == 0 {
			return true
		}
		return csv_contains_value(config.qq_allow_users, target.openid)
	}
	if target.scene == 'group' {
		if config.qq_allow_groups.trim_space().len == 0 {
			return true
		}
		return csv_contains_value(config.qq_allow_groups, target.group_openid)
	}
	return false
}

fn csv_contains_value(csv string, value string) bool {
	needle := value.trim_space()
	if needle.len == 0 {
		return false
	}
	for item in csv.split(',') {
		if item.trim_space() == needle {
			return true
		}
	}
	return false
}

fn extract_qq_reply_target(payload string) QqReplyTarget {
	event_type := decode_json_string(extract_json_string_value(payload, 't'))
	d_object := extract_json_object_value(payload, 'd')
	msg_id := decode_json_string(extract_json_string_value(d_object, 'id'))
	if event_type == 'C2C_MESSAGE_CREATE' {
		author := extract_json_object_value(d_object, 'author')
		return QqReplyTarget{
			scene:  'c2c'
			openid: decode_json_string(extract_json_string_value(author, 'user_openid'))
			msg_id: msg_id
		}
	}
	if event_type == 'GROUP_AT_MESSAGE_CREATE' {
		return QqReplyTarget{
			scene:        'group'
			group_openid: decode_json_string(extract_json_string_value(d_object, 'group_openid'))
			msg_id:       msg_id
		}
	}
	return QqReplyTarget{}
}

fn extract_qq_event_prompt(payload string) string {
	d_object := extract_json_object_value(payload, 'd')
	return decode_json_string(extract_json_string_value(d_object, 'content')).trim_space()
}
