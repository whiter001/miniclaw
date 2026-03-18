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
