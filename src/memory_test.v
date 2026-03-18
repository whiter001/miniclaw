module main

import os

fn test_memory_store_write_read_and_context() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-memory')
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	store := memory_store_for_workspace(workspace)
	store.write_long_term('User prefers concise answers.') or { panic(err) }
	store.write_summary('Keep answers short.') or { panic(err) }
	store.append_today('### User\nRemember this.') or { panic(err) }
	assert store.read_long_term().contains('User prefers concise answers.')
	assert store.read_summary().contains('Keep answers short.')
	assert store.read_today().contains('Remember this.')
	context := store.context()
	assert context.contains('Long-term Memory')
	assert context.contains('Summary')
	assert context.contains('Recent Daily Notes')
	assert context.contains('User prefers concise answers.')
}

fn test_load_system_prompt_includes_agents_and_memory() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-system-prompt')
	os.mkdir_all(os.join_path(workspace, 'memory')) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	os.write_file(os.join_path(workspace, 'AGENTS.md'), '# Agent Notes\nUse memory well.') or {
		panic(err)
	}
	store := memory_store_for_workspace(workspace)
	store.write_long_term('Remember the user likes markdown.') or { panic(err) }
	config := Config{
		workspace: workspace
	}
	prompt := load_system_prompt(config)
	assert prompt.contains('Agent Notes')
	assert prompt.contains('Remember the user likes markdown.')
	assert prompt.contains('Long-term Memory')
}

fn test_memory_compact_deduplicates_long_term_entries() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-memory-compact')
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	store := memory_store_for_workspace(workspace)
	store.write_long_term('# Memory\n\nUser prefers concise answers.\nUser prefers concise answers.\n') or {
		panic(err)
	}
	store.compact_long_term() or { panic(err) }
	content := store.read_long_term()
	assert content.contains('User prefers concise answers.')
	assert content.count('User prefers concise answers.') == 1
}

fn test_memory_summary_filters_chatter_and_keeps_signals() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-memory-summary-filter')
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	store := memory_store_for_workspace(workspace)
	day_entry := '## 2026-03-19 10:00:00\n\n### User\nhello\n\n### Assistant\nI can help with that.\n\n### User\nMiniClaw: always keep answers short.\n\n### Assistant\nI will keep answers short and avoid filler.'
	store.append_summary_excerpt(day_entry) or { panic(err) }
	summary := store.read_summary()
	assert summary.contains('[important] User: MiniClaw: always keep answers short.')
	assert summary.contains('Assistant: I will keep answers short and avoid filler.')
	assert !summary.contains('I can help with that.')
	assert !summary.contains('hello')
}

fn test_days_between_date_keys_handles_cross_year_boundaries() {
	assert days_between_date_keys('20260101', '20251231') == 1
	assert days_between_date_keys('20251231', '20260101') == 1
	assert days_between_date_keys('20260319', '20260318') == 1
}
