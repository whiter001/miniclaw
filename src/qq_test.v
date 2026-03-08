module main

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
