module main

fn test_parse_config_content_applies_memory_settings() {
	base := default_config()
	content := '
memory_recent_days=4
memory_recent_chars=2500
memory_summary_max_lines=11
memory_summary_max_chars=3333
memory_daily_entry_max_chars=777
memory_significance_threshold=6
memory_prune_keep_days=9
'
	config := parse_config_content(content, base)
	assert config.memory_recent_days == 4
	assert config.memory_recent_chars == 2500
	assert config.memory_summary_max_lines == 11
	assert config.memory_summary_max_chars == 3333
	assert config.memory_daily_entry_max_chars == 777
	assert config.memory_significance_threshold == 6
	assert config.memory_prune_keep_days == 9
}

fn test_parse_config_content_applies_anthropic_base_url_aliases() {
	base := default_config()
	assert base.base_url == 'https://api.minimaxi.com/anthropic'

	config_from_base := parse_config_content('base_url=https://example.com/anthropic',
		base)
	assert config_from_base.base_url == 'https://example.com/anthropic'

	config_from_legacy := parse_config_content('api_url=https://legacy.example.com/anthropic',
		base)
	assert config_from_legacy.base_url == 'https://legacy.example.com/anthropic'
}

fn test_parse_config_content_applies_weixin_settings() {
	base := default_config()
	content := '
weixin_host=0.0.0.0
weixin_port=19081
weixin_base_path=weixin
weixin_processing_text=处理中
'
	config := parse_config_content(content, base)
	assert config.weixin_host == '0.0.0.0'
	assert config.weixin_port == 19081
	assert config.weixin_base_path == '/weixin'
	assert config.weixin_processing_text == '处理中'
}
