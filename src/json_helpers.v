module main

fn escape_json_string(s string) string {
	// 对字符串做最小 JSON 转义。
	mut result := []u8{cap: s.len}
	for ch in s.bytes() {
		match ch {
			`\\` {
				result << `\\`
				result << `\\`
			}
			`"` {
				result << `\\`
				result << `"`
			}
			`\n` {
				result << `\\`
				result << `n`
			}
			`\t` {
				result << `\\`
				result << `t`
			}
			`\r` {
				result << `\\`
				result << `r`
			}
			else {
				if ch < 0x20 {
					hex_chars := '0123456789abcdef'
					result << `\\`
					result << `u`
					result << `0`
					result << `0`
					result << hex_chars[ch >> 4]
					result << hex_chars[ch & 0x0F]
				} else {
					result << ch
				}
			}
		}
	}
	return result.bytestr()
}

fn decode_json_string(s string) string {
	// 解析常见的 JSON 转义序列。
	if !s.contains('\\') {
		return s
	}
	mut result := []u8{}
	mut index := 0
	for index < s.len {
		if s[index] == `\\` && index + 1 < s.len {
			match s[index + 1] {
				`n` {
					result << `\n`
					index += 2
				}
				`t` {
					result << `\t`
					index += 2
				}
				`r` {
					result << `\r`
					index += 2
				}
				`"` {
					result << `"`
					index += 2
				}
				`\\` {
					result << `\\`
					index += 2
				}
				`u` {
					if index + 5 < s.len {
						hex := s[index + 2..index + 6]
						codepoint := hex.parse_uint(16, 16) or { 0 }
						if codepoint < 0x80 {
							result << u8(codepoint)
						} else if codepoint < 0x800 {
							result << u8(0xC0 | (codepoint >> 6))
							result << u8(0x80 | (codepoint & 0x3F))
						} else {
							result << u8(0xE0 | (codepoint >> 12))
							result << u8(0x80 | ((codepoint >> 6) & 0x3F))
							result << u8(0x80 | (codepoint & 0x3F))
						}
						index += 6
					} else {
						result << s[index]
						index++
					}
				}
				else {
					result << s[index + 1]
					index += 2
				}
			}
		} else {
			result << s[index]
			index++
		}
	}
	return result.bytestr()
}

fn extract_json_string_value(json_str string, key string) string {
	// 从 JSON 字符串中提取指定键的字符串值。
	pattern := '"${key}"'
	if index := json_str.index(pattern) {
		mut pos := index + pattern.len
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len || json_str[pos] != `:` {
			return ''
		}
		pos++
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len || json_str[pos] != `"` {
			return ''
		}
		pos++
		start := pos
		end := find_json_string_terminator(json_str, start)
		if end > start {
			return json_str[start..end]
		}
	}
	return ''
}

fn extract_json_int_value(json_str string, key string) int {
	// 从 JSON 字符串中提取指定键的整数值。
	pattern := '"${key}"'
	if index := json_str.index(pattern) {
		mut pos := index + pattern.len
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len || json_str[pos] != `:` {
			return 0
		}
		pos++
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`, `"`] {
			pos++
		}
		mut end := pos
		for end < json_str.len && json_str[end] >= `0` && json_str[end] <= `9` {
			end++
		}
		if end > pos {
			return json_str[pos..end].int()
		}
	}
	return 0
}

fn extract_json_object_value(json_str string, key string) string {
	// 从 JSON 字符串中提取指定键对应的对象或数组片段。
	pattern := '"${key}"'
	if index := json_str.index(pattern) {
		mut pos := index + pattern.len
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len || json_str[pos] != `:` {
			return ''
		}
		pos++
		for pos < json_str.len && json_str[pos] in [u8(` `), `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len || (json_str[pos] != `{` && json_str[pos] != `[`) {
			return ''
		}
		end := find_matching_bracket(json_str, pos)
		if end > pos {
			return json_str[pos..end + 1]
		}
	}
	return ''
}

fn is_json_quote_escaped(s string, quote_index int) bool {
	// 判断当前位置的引号是否被反斜杠转义。
	if quote_index <= 0 || quote_index >= s.len {
		return false
	}
	mut slash_count := 0
	mut index := quote_index - 1
	for index >= 0 && s[index] == `\\` {
		slash_count++
		if index == 0 {
			break
		}
		index--
	}
	return slash_count % 2 == 1
}

fn find_json_string_terminator(s string, start int) int {
	// 查找 JSON 字符串的结束引号位置。
	mut index := start
	for index < s.len {
		if s[index] == `"` && !is_json_quote_escaped(s, index) {
			return index
		}
		index++
	}
	return -1
}

fn find_matching_bracket(s string, start int) int {
	// 查找对象或数组起始括号对应的结束位置。
	if start >= s.len {
		return -1
	}
	open_char := s[start]
	close_char := if open_char == `[` { u8(`]`) } else { u8(`}`) }
	mut depth := 1
	mut index := start + 1
	mut in_string := false
	for index < s.len {
		ch := s[index]
		if in_string {
			if ch == `"` && !is_json_quote_escaped(s, index) {
				in_string = false
			}
		} else {
			if ch == `"` {
				in_string = true
			} else if ch == open_char {
				depth++
			} else if ch == close_char {
				depth--
				if depth == 0 {
					return index
				}
			}
		}
		index++
	}
	return -1
}

fn extract_content_array(body string) string {
	// 从模型响应体中截取 content 数组片段。
	target := '"content":['
	if index := body.index(target) {
		array_start := index + target.len - 1
		array_end := find_matching_bracket(body, array_start)
		if array_end > array_start {
			return body[array_start..array_end + 1]
		}
	}
	return ''
}

fn extract_text_blocks(content_json string) string {
	// 拼接 content 数组中的所有 text 块。
	mut result := ''
	mut index := 0
	for index < content_json.len {
		if content_json[index] != `{` {
			index++
			continue
		}
		block_end := find_matching_bracket(content_json, index)
		if block_end <= index {
			break
		}
		block := content_json[index..block_end + 1]
		if decode_json_string(extract_json_string_value(block, 'type')) == 'text' {
			text := decode_json_string(extract_json_string_value(block, 'text'))
			if text.len > 0 {
				result += text
			}
		}
		index = block_end + 1
	}
	return result
}

fn parse_json_string_object(json_str string) map[string]string {
	// 解析键和值都较简单的 JSON 对象。
	mut result := map[string]string{}
	mut pos := 1
	for pos < json_str.len - 1 {
		for pos < json_str.len && json_str[pos] in [u8(` `), `,`, `\n`, `\t`, `\r`] {
			pos++
		}
		if pos >= json_str.len - 1 {
			break
		}
		if json_str[pos] != `"` {
			break
		}
		pos++
		key_end := find_json_string_terminator(json_str, pos)
		if key_end < pos {
			break
		}
		key := decode_json_string(json_str[pos..key_end])
		pos = key_end + 1
		for pos < json_str.len && json_str[pos] in [u8(`:`), ` `, `\t`, `\n`, `\r`] {
			pos++
		}
		if pos >= json_str.len {
			break
		}
		ch := json_str[pos]
		if ch == `"` {
			pos++
			val_end := find_json_string_terminator(json_str, pos)
			if val_end < pos {
				break
			}
			result[key] = decode_json_string(json_str[pos..val_end])
			pos = val_end + 1
		} else if ch == `{` || ch == `[` {
			end := find_matching_bracket(json_str, pos)
			if end > pos {
				result[key] = json_str[pos..end + 1]
				pos = end + 1
			} else {
				break
			}
		} else {
			mut val_end := pos
			for val_end < json_str.len
				&& json_str[val_end] !in [u8(`,`), `}`, `]`, ` `, `\n`, `\t`, `\r`] {
				val_end++
			}
			result[key] = json_str[pos..val_end]
			pos = val_end
		}
	}
	return result
}

fn extract_tool_use_blocks(content_json string) []ToolUse {
	// 从 content 数组中提取所有 tool_use 块。
	mut tools := []ToolUse{}
	mut index := 0
	for index < content_json.len {
		if content_json[index] != `{` {
			index++
			continue
		}
		block_end := find_matching_bracket(content_json, index)
		if block_end <= index {
			break
		}
		block := content_json[index..block_end + 1]
		if decode_json_string(extract_json_string_value(block, 'type')) == 'tool_use' {
			mut tool := ToolUse{}
			tool.id = decode_json_string(extract_json_string_value(block, 'id'))
			tool.name = decode_json_string(extract_json_string_value(block, 'name'))
			if input_index := block.index('"input":') {
				mut obj_start := input_index + 8
				for obj_start < block.len && block[obj_start] in [u8(` `), `\t`, `\n`, `\r`] {
					obj_start++
				}
				if obj_start < block.len && block[obj_start] == `{` {
					input_end := find_matching_bracket(block, obj_start)
					if input_end > obj_start {
						tool.input = parse_json_string_object(block[obj_start..input_end + 1])
					}
				}
			}
			if tool.id.len > 0 && tool.name.len > 0 {
				tools << tool
			}
		}
		index = block_end + 1
	}
	return tools
}
