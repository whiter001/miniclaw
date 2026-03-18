module main

import os
import time

const memory_prompt_recent_days = 2
const memory_prompt_recent_chars = 1600
const memory_summary_max_lines = 20
const memory_summary_max_chars = 2000
const memory_daily_entry_max_chars = 500
const memory_compact_max_line_len = 240
const memory_excerpt_truncate_len = 200

struct MemorySettings {
mut:
	recent_days            int
	recent_chars           int
	summary_max_lines      int
	summary_max_chars      int
	daily_entry_max_chars  int
	significance_threshold int
	prune_keep_days        int
}

struct MemoryStore {
	workspace    string
	memory_dir   string
	memory_file  string
	summary_file string
}

fn new_memory_store(workspace string) MemoryStore {
	memory_dir := os.join_path(workspace, 'memory')
	memory_file := os.join_path(memory_dir, 'MEMORY.md')
	summary_file := os.join_path(memory_dir, 'SUMMARY.md')
	os.mkdir_all(memory_dir) or {}
	return MemoryStore{
		workspace:    workspace
		memory_dir:   memory_dir
		memory_file:  memory_file
		summary_file: summary_file
	}
}

fn default_memory_settings() MemorySettings {
	return MemorySettings{
		recent_days:            memory_prompt_recent_days
		recent_chars:           memory_prompt_recent_chars
		summary_max_lines:      memory_summary_max_lines
		summary_max_chars:      memory_summary_max_chars
		daily_entry_max_chars:  memory_daily_entry_max_chars
		significance_threshold: memory_significance_threshold_default()
		prune_keep_days:        14
	}
}

fn memory_settings_from_config(config Config) MemorySettings {
	mut settings := default_memory_settings()
	if config.memory_recent_days > 0 {
		settings.recent_days = config.memory_recent_days
	}
	if config.memory_recent_chars > 0 {
		settings.recent_chars = config.memory_recent_chars
	}
	if config.memory_summary_max_lines > 0 {
		settings.summary_max_lines = config.memory_summary_max_lines
	}
	if config.memory_summary_max_chars > 0 {
		settings.summary_max_chars = config.memory_summary_max_chars
	}
	if config.memory_daily_entry_max_chars > 0 {
		settings.daily_entry_max_chars = config.memory_daily_entry_max_chars
	}
	if config.memory_significance_threshold > 0 {
		settings.significance_threshold = config.memory_significance_threshold
	}
	if config.memory_prune_keep_days >= 0 {
		settings.prune_keep_days = config.memory_prune_keep_days
	}
	return settings
}

fn (ms MemoryStore) ensure_defaults() ! {
	os.mkdir_all(ms.memory_dir)!
	if !os.exists(ms.memory_file) {
		write_file_atomic(ms.memory_file, '# Memory\n\n')!
	}
	if !os.exists(ms.summary_file) {
		write_file_atomic(ms.summary_file, '# Summary\n\n')!
	}
}

fn (ms MemoryStore) read_long_term() string {
	return read_optional_file(ms.memory_file)
}

fn (ms MemoryStore) write_long_term(content string) ! {
	ms.ensure_defaults()!
	write_file_atomic(ms.memory_file, normalize_markdown_document(content, 'Memory'))!
}

fn (ms MemoryStore) append_long_term(content string) ! {
	ms.ensure_defaults()!
	existing := ms.read_long_term()
	mut next := existing.trim_space()
	addition := content.trim_space()
	if addition.len == 0 {
		return
	}
	if next.len == 0 {
		next = '# Memory\n\n' + addition
	} else {
		if !next.ends_with('\n') {
			next += '\n'
		}
		next += '\n' + addition
	}
	ms.write_long_term(next)!
}

fn (ms MemoryStore) read_summary() string {
	return read_optional_file(ms.summary_file)
}

fn (ms MemoryStore) write_summary(content string) ! {
	ms.ensure_defaults()!
	write_file_atomic(ms.summary_file, normalize_markdown_document(content, 'Summary'))!
}

fn (ms MemoryStore) update_summary(content string) ! {
	ms.write_summary(content)!
}

fn (ms MemoryStore) append_summary_excerpt(content string) ! {
	ms.append_summary_excerpt_with_settings(content, default_memory_settings())!
}

fn (ms MemoryStore) append_summary_excerpt_with_settings(content string, settings MemorySettings) ! {
	entry := extract_memorable_memory_excerpt_with_threshold(content, settings.summary_max_lines,
		settings.summary_max_chars, settings.significance_threshold)
	if entry.len == 0 {
		return
	}
	existing := ms.read_summary().trim_space()
	mut merged := []string{}
	if existing.len > 0 {
		merged << existing
	}
	merged << entry
	combined := summarize_memory_text_with_threshold(merged.join('\n'), settings.summary_max_lines,
		settings.summary_max_chars, settings.significance_threshold)
	if combined.len == 0 {
		return
	}
	ms.write_summary('# Summary\n\n' + combined + '\n')!
}

fn (ms MemoryStore) today_file() string {
	today := memory_date_key(time.now())
	month_dir := today[..6]
	return os.join_path(ms.memory_dir, month_dir, today + '.md')
}

fn (ms MemoryStore) daily_file_for_date(t time.Time) string {
	date_key := memory_date_key(t)
	month_dir := date_key[..6]
	return os.join_path(ms.memory_dir, month_dir, date_key + '.md')
}

fn (ms MemoryStore) read_today() string {
	return read_optional_file(ms.today_file())
}

fn (ms MemoryStore) append_today(content string) ! {
	entry := content.trim_space()
	if entry.len == 0 {
		return
	}
	now := time.now()
	today_file := ms.daily_file_for_date(now)
	os.mkdir_all(os.dir(today_file))!
	mut existing := read_optional_file(today_file).trim_right('\n')
	mut next := existing
	if next.len == 0 {
		next = '# ' + memory_date_label(now) + '\n\n' + entry
	} else {
		next += '\n\n' + entry
	}
	write_file_atomic(today_file, next.trim_right('\n') + '\n')!
}

fn (ms MemoryStore) recent_daily_notes(days int, max_chars int) string {
	if days <= 0 || max_chars <= 0 {
		return ''
	}
	now := time.now()
	mut parts := []string{}
	mut remaining := max_chars
	for offset in 0 .. days {
		date := now.add_days(-offset)
		file_path := ms.daily_file_for_date(date)
		if data := os.read_file(file_path) {
			trimmed := data.trim_space()
			if trimmed.len == 0 {
				continue
			}
			text := limit_text(trimmed, remaining)
			if text.len == 0 {
				break
			}
			parts << text
			remaining -= text.len
			if remaining <= 0 {
				break
			}
		}
	}
	return parts.join('\n\n---\n\n')
}

fn (ms MemoryStore) context() string {
	return ms.context_with_settings(default_memory_settings())
}

fn (ms MemoryStore) context_with_settings(settings MemorySettings) string {
	return ms.context_with_budget(settings.recent_days, settings.recent_chars)
}

fn (ms MemoryStore) context_with_budget(recent_days int, recent_chars int) string {
	long_term := ms.read_long_term().trim_space()
	summary := ms.read_summary().trim_space()
	recent := ms.recent_daily_notes(recent_days, recent_chars)
	mut parts := []string{}
	if long_term.len > 0 {
		parts << '## Long-term Memory\n\n' + long_term
	}
	if summary.len > 0 {
		parts << '## Summary\n\n' + summary
	}
	if recent.len > 0 {
		parts << '## Recent Daily Notes\n\n' + recent
	}
	return parts.join('\n\n---\n\n')
}

fn (ms MemoryStore) summarize_recent_notes(days int) !string {
	return ms.summarize_recent_notes_with_settings(days, default_memory_settings())
}

fn (ms MemoryStore) summarize_recent_notes_with_settings(days int, settings MemorySettings) !string {
	notes := ms.recent_daily_notes(days, settings.summary_max_chars * 2)
	return extract_memorable_memory_excerpt_with_threshold(notes, settings.summary_max_lines,
		settings.summary_max_chars, settings.significance_threshold)
}

fn (ms MemoryStore) compact_long_term() ! {
	content := ms.read_long_term().trim_space()
	if content.len == 0 {
		ms.write_long_term('# Memory\n\n')!
		return
	}
	ms.write_long_term(compact_memory_text(content))!
}

fn (ms MemoryStore) prune_daily_notes(keep_days int) !int {
	if keep_days < 0 {
		return error('keep_days must be non-negative')
	}
	if !os.exists(ms.memory_dir) {
		return 0
	}
	now_key := memory_date_key(time.now())
	mut removed := 0
	entries := os.ls(ms.memory_dir) or { return error('failed to list memory dir: ${err.msg()}') }
	for month_dir in entries {
		month_path := os.join_path(ms.memory_dir, month_dir)
		if !os.is_dir(month_path) {
			continue
		}
		mut month_removed := false
		files := os.ls(month_path) or { continue }
		for file_name in files {
			if !file_name.ends_with('.md') {
				continue
			}
			if file_name.len <= 3 {
				continue
			}
			date_key := file_name[..file_name.len - 3]
			if date_key.len != 8 {
				continue
			}
			if days_between_date_keys(now_key, date_key) > keep_days {
				file_path := os.join_path(month_path, file_name)
				if os.exists(file_path) {
					os.rm(file_path) or {
						return error('failed to remove ${file_path}: ${err.msg()}')
					}
					removed++
					month_removed = true
				}
			}
		}
		if month_removed {
			remaining_files := os.ls(month_path) or { continue }
			if remaining_files.len == 0 {
				os.rmdir(month_path) or {
					return error('failed to remove empty month dir ${month_path}: ${err.msg()}')
				}
			}
		}
	}
	return removed
}

fn memory_store_for_workspace(workspace string) MemoryStore {
	return new_memory_store(workspace)
}

fn memory_date_key(t time.Time) string {
	return t.str().split(' ')[0].replace('-', '')
}

fn memory_date_label(t time.Time) string {
	return t.str().split(' ')[0]
}

fn read_optional_file(path string) string {
	if data := os.read_file(path) {
		return data.trim_space()
	}
	return ''
}

fn write_file_atomic(path string, content string) ! {
	tmp_path := path + '.tmp.' + os.getpid().str()
	os.write_file(tmp_path, content)!
	os.rename(tmp_path, path)!
}

fn normalize_markdown_document(content string, default_title string) string {
	mut normalized := content.trim_space()
	if normalized.len == 0 {
		return '# ${default_title}\n\n'
	}
	if !normalized.starts_with('#') {
		normalized = '# ${default_title}\n\n' + normalized
	}
	return normalized.trim_right('\n') + '\n'
}

fn compact_memory_text(content string) string {
	mut lines := []string{}
	mut seen := map[string]bool{}
	for raw_line in content.split_into_lines() {
		line := raw_line.trim_space()
		if line.len == 0 {
			continue
		}
		if seen[line] {
			continue
		}
		seen[line] = true
		if line.len > memory_compact_max_line_len {
			lines << line[..memory_compact_max_line_len]
		} else {
			lines << line
		}
	}
	if lines.len == 0 {
		return '# Memory\n\n'
	}
	return '# Memory\n\n' + lines.join('\n') + '\n'
}

fn extract_memorable_memory_excerpt(content string, max_lines int, max_chars int) string {
	return extract_memorable_memory_excerpt_with_threshold(content, max_lines, max_chars,
		memory_significance_threshold_default())
}

fn extract_memorable_memory_excerpt_with_threshold(content string, max_lines int, max_chars int, threshold int) string {
	if content.len == 0 || max_lines <= 0 || max_chars <= 0 {
		return ''
	}
	mut lines := []string{}
	mut chars := 0
	mut seen := map[string]bool{}
	mut section := ''
	for raw_line in content.split_into_lines() {
		line := raw_line.trim_space()
		if line.len == 0 {
			continue
		}
		if line.starts_with('### ') {
			section = line[4..].trim_space()
			continue
		}
		if line.starts_with('## ') {
			section = ''
			continue
		}
		score := memory_line_importance_score(section, line)
		if score < threshold {
			continue
		}
		mut candidate := compact_memory_excerpt_line(section, line)
		if candidate.len == 0 {
			continue
		}
		candidate = scored_memory_excerpt_line(score, candidate)
		mut selected := candidate
		if selected.len > memory_excerpt_truncate_len {
			selected = selected[..memory_excerpt_truncate_len]
		}
		if seen[selected] {
			continue
		}
		if chars + selected.len > max_chars {
			break
		}
		seen[selected] = true
		lines << selected
		chars += selected.len
		if lines.len >= max_lines {
			break
		}
	}
	return lines.join('\n')
}

fn memory_significance_threshold_default() int {
	return 3
}

fn memory_line_importance_score(section string, line string) int {
	mut score := 0
	lower := line.to_lower()
	if lower.len == 0 {
		return 0
	}
	if lower.starts_with('- ') || lower.starts_with('* ') || lower.starts_with('1. ')
		|| lower.starts_with('2. ') || lower.starts_with('3. ') || lower.starts_with('4. ') {
		score += 1
	}
	if lower.contains(':') && lower.len <= 60 {
		score += 1
	}
	for keyword in memory_strong_signal_keywords() {
		if lower.contains(keyword) {
			score += 3
			break
		}
	}
	for keyword in memory_weak_signal_keywords() {
		if lower.contains(keyword) {
			score += 1
		}
	}
	for phrase in memory_noise_phrases() {
		if lower.contains(phrase) {
			score -= 3
			break
		}
	}
	if section.len > 0 {
		section_lower := section.to_lower()
		if section_lower == 'user' {
			score += 1
		}
		if section_lower == 'assistant' && (lower.contains('remember') || lower.contains('keep')
			|| lower.contains('will')) {
			score += 1
		}
	}
	if lower.len < 12 {
		score -= 1
	}
	return score
}

fn compact_memory_excerpt_line(section string, line string) string {
	mut normalized := line.replace('\t', ' ').replace('  ', ' ').trim_space()
	if normalized.len == 0 {
		return ''
	}
	if section.len > 0 {
		normalized = '${section}: ${normalized}'
	}
	return normalized
}

fn scored_memory_excerpt_line(score int, line string) string {
	if score >= 8 {
		return '[critical] ${line}'
	}
	if score >= 5 {
		return '[important] ${line}'
	}
	return line
}

fn memory_strong_signal_keywords() []string {
	return [
		'prefer',
		'remember',
		'must',
		'should',
		'need to',
		'important',
		'decision',
		'decided',
		'summary',
		'fix',
		'bug',
		'error',
		'issue',
		'fail',
		'todo',
		'completed',
		'done',
		'keep',
		'always',
		'never',
		'偏好',
		'记住',
		'必须',
		'需要',
		'不要',
		'应该',
		'决定',
		'完成',
		'总结',
		'修复',
		'报错',
		'问题',
		'结论',
		'重要',
		'配置',
		'工作区',
		'工具',
	]
}

fn memory_weak_signal_keywords() []string {
	return [
		'keep',
		'done',
		'completed',
		'todo',
		'配置',
		'工作区',
		'记忆',
		'总结',
	]
}

fn memory_noise_phrases() []string {
	return [
		'i can help',
		'let me know',
		'happy to help',
		'sounds good',
		'thanks',
		'sure',
		'当然',
		'没问题',
		'好的',
	]
}

fn summarize_memory_text(content string, max_lines int, max_chars int) string {
	return summarize_memory_text_with_threshold(content, max_lines, max_chars, memory_significance_threshold_default())
}

fn summarize_memory_text_with_threshold(content string, max_lines int, max_chars int, threshold int) string {
	return extract_memorable_memory_excerpt_with_threshold(content, max_lines, max_chars,
		threshold)
}

fn limit_text(content string, max_chars int) string {
	if max_chars <= 0 || content.len <= max_chars {
		return content
	}
	return content[..max_chars] + '\n... (truncated)'
}

fn days_between_date_keys(today_key string, date_key string) int {
	if today_key.len != 8 || date_key.len != 8 {
		return 0
	}
	today_days := civil_days_since_epoch(today_key[..4].int(), today_key[4..6].int(),
		today_key[6..8].int())
	other_days := civil_days_since_epoch(date_key[..4].int(), date_key[4..6].int(), date_key[6..8].int())
	diff := today_days - other_days
	if diff < 0 {
		return -diff
	}
	return diff
}

fn civil_days_since_epoch(year int, month int, day int) int {
	mut y := year
	if month <= 2 {
		y--
	}
	era := if y >= 0 { y } else { y - 399 } / 400
	yoe := y - era * 400
	m := month + if month > 2 { -3 } else { 9 }
	doy := (153 * m + 2) / 5 + day - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}
