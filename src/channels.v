module main

import os
import time

const channels_login_default_channel = 'weixin'
const channels_login_state_file = 'channels_login_state.json'
const channels_login_events_file = 'channels_login_events.jsonl'
const channels_login_qr_size = 21
const channels_login_qr_quiet_zone = 4
const channels_login_qr_data_codewords = 19
const channels_login_qr_ecc_codewords = 7
const channels_login_qr_generator = [u8(0x87), 0x7D, 0x9E, 0x9E, 0x02, 0x67, 0x15]

struct ChannelsLoginSession {
	channel     string
	session_id  string
	pairing_url string
	created_at  string
}

fn run_channels(config Config, args []string) int {
	// 处理 MiniClaw 的 channels 兼容入口。
	ensure_workspace(config) or {
		eprintln('failed to prepare workspace: ${err.msg()}')
		return 1
	}
	if args.len == 0 {
		eprintln('usage: miniclaw channels [status|login --channel weixin]')
		return 1
	}
	match args[0] {
		'status' {
			return run_channels_status(config)
		}
		'login' {
			return run_channels_login(config, args[1..])
		}
		else {
			eprintln('unknown channels command: ${args[0]}')
			eprintln('supported: status, login')
			return 1
		}
	}
}

fn run_channels_status(config Config) int {
	// 输出当前 channels 登录状态摘要。
	state_path := os.join_path(config.workspace, 'state', channels_login_state_file)
	if !os.exists(state_path) {
		println('channels status: not started')
		println('channel: ${channels_login_default_channel}')
		println('state file: ${state_path}')
		return 0
	}
	state_json := os.read_file(state_path) or {
		eprintln('failed to read channels login state: ${err.msg()}')
		return 1
	}
	channel := decode_json_string(extract_json_string_value(state_json, 'channel'))
	status := decode_json_string(extract_json_string_value(state_json, 'status'))
	detail := decode_json_string(extract_json_string_value(state_json, 'detail'))
	ts := decode_json_string(extract_json_string_value(state_json, 'ts'))
	println('channels status: ${if status.len > 0 { status } else { 'unknown' }}')
	println('channel: ${if channel.len > 0 { channel } else { channels_login_default_channel }}')
	println('detail: ${detail}')
	println('updated at: ${ts}')
	println('state file: ${state_path}')
	return 0
}

fn run_channels_login(config Config, args []string) int {
	// 启动本地 Weixin 配对码流程并生成可在浏览器中打开的 SVG 图片。
	channel := parse_named_arg(args, '--channel')
	resolved_channel := if channel.len > 0 { channel } else { parse_channels_login_target(args) }
	if resolved_channel.len == 0 {
		eprintln('usage: miniclaw channels login --channel weixin')
		return 1
	}
	if resolved_channel != channels_login_default_channel {
		eprintln('unsupported channel: ${resolved_channel}')
		eprintln('supported channel: ${channels_login_default_channel}')
		return 1
	}
	append_channels_login_event(config, resolved_channel, 'requested', 'local login flow requested') or {}
	write_channels_login_state(config, resolved_channel, 'requested', 'local login flow requested') or {}
	append_channels_login_event(config, resolved_channel, 'starting', 'generating local pairing code') or {}
	write_channels_login_state(config, resolved_channel, 'starting', 'generating local pairing code') or {}
	session := build_channels_login_session(resolved_channel)
	svg_path := write_channels_login_qr_svg(config, session) or {
		append_channels_login_event(config, resolved_channel, 'failed', 'failed to write svg qr image') or {}
		write_channels_login_state(config, resolved_channel, 'failed', 'failed to write svg qr image') or {}
		eprintln('failed to write QR image: ${err.msg()}')
		return 1
	}
	println('MiniClaw Weixin login started.')
	println('QR image written to: ${svg_path}')
	println('Open the SVG in your browser for a clearer scan target.')
	println('channel: ${session.channel}')
	println('session: ${session.session_id}')
	println('pairing url: ${session.pairing_url}')
	append_channels_login_event(config, resolved_channel, 'awaiting_scan', 'local svg pairing image displayed') or {}
	write_channels_login_state(config, resolved_channel, 'awaiting_scan', 'local svg pairing image displayed') or {}
	if has_flag(args, '--once') {
		append_channels_login_event(config, resolved_channel, 'finished', 'bootstrap-only login flow finished') or {}
		write_channels_login_state(config, resolved_channel, 'finished', 'bootstrap-only login flow finished') or {}
		return 0
	}
	_ := os.input('Press Enter after you finish pairing: ')
	append_channels_login_event(config, resolved_channel, 'finished', 'local login flow ended') or {}
	write_channels_login_state(config, resolved_channel, 'finished', 'local login flow ended') or {}
	return 0
}

fn parse_channels_login_target(args []string) string {
	// 兼容 `miniclaw channels login weixin` 这类简写。
	for arg in args {
		if arg.len == 0 || arg.starts_with('-') {
			continue
		}
		return arg
	}
	return ''
}

fn build_channels_login_session(channel string) ChannelsLoginSession {
	// 生成本地一次性配对会话。
	now := time.now()
	seed_input := '${channel}|${os.getpid()}|${now.unix()}|${now.str()}'
	session_id := build_channels_login_session_id(seed_input)
	return ChannelsLoginSession{
		channel:     channel
		session_id:  session_id
		pairing_url: 'miniclaw://weixin/login?channel=${channel}&session=${session_id}'
		created_at:  now.str()
	}
}

fn build_channels_login_session_id(seed_input string) string {
	// 生成适合终端展示的短会话码。
	mut value := u64(1469598103934665603)
	for byte_value in seed_input.bytes() {
		value ^= u64(byte_value)
		value *= u64(1099511628211)
	}
	alphabet := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
	mut result := []u8{cap: 10}
	for index in 0 .. 10 {
		value ^= value << 13
		value ^= value >> 7
		value ^= value << 17
		value += u64(index + 1)
		result << alphabet[int(value % u64(alphabet.len))]
	}
	return 'WX-' + result.bytestr()
}

fn build_channels_login_qr_payload(session ChannelsLoginSession) string {
	// 让二维码承载一个短而稳定的本地配对 token。
	return 'WX:${session.session_id}'
}

fn write_channels_login_qr_svg(config Config, session ChannelsLoginSession) !string {
	// 写出浏览器可直接打开的 SVG 二维码文件。
	payload := build_channels_login_qr_payload(session)
	modules := build_channels_login_qr_modules(payload)
	if modules.len == 0 {
		return error('failed to build QR modules')
	}
	state_dir := os.join_path(config.workspace, 'state')
	os.mkdir_all(state_dir)!
	svg_path := os.join_path(state_dir, 'weixin_login_qr.svg')
	visual_size := channels_login_qr_size + channels_login_qr_quiet_zone * 2
	module_pixel := 14
	canvas_px := visual_size * module_pixel
	mut svg := []string{cap: 8 + modules.len + 8}
	svg << '<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
	svg << '<svg xmlns="http://www.w3.org/2000/svg" width="${canvas_px}" height="${canvas_px + 72}" viewBox="0 0 ${canvas_px} ${
		canvas_px + 72}" shape-rendering="crispEdges" role="img" aria-label="MiniClaw Weixin login QR code">'
	svg << '<rect x="0" y="0" width="${canvas_px}" height="${canvas_px + 72}" fill="#ffffff"/>'
	svg << '<rect x="0" y="0" width="${canvas_px}" height="${canvas_px}" fill="#ffffff"/>'
	for y in 0 .. visual_size {
		for x in 0 .. visual_size {
			if x < channels_login_qr_quiet_zone || y < channels_login_qr_quiet_zone
				|| x >= channels_login_qr_quiet_zone + channels_login_qr_size
				|| y >= channels_login_qr_quiet_zone + channels_login_qr_size {
				continue
			}
			if modules[(y - channels_login_qr_quiet_zone) * channels_login_qr_size +
				(x - channels_login_qr_quiet_zone)] {
				x_pos := x * module_pixel
				y_pos := y * module_pixel
				svg << '<rect x="${x_pos}" y="${y_pos}" width="${module_pixel}" height="${module_pixel}" fill="#111111"/>'
			}
		}
	}
	text_y := canvas_px + 22
	svg << '<rect x="0" y="${canvas_px}" width="${canvas_px}" height="72" fill="#ffffff"/>'
	svg << '<text x="0" y="${text_y}" fill="#111111" font-family="Menlo, Consolas, monospace" font-size="14">MiniClaw Weixin login pairing code</text>'
	svg << '<text x="0" y="${text_y + 20}" fill="#444444" font-family="Menlo, Consolas, monospace" font-size="12">session: ${escape_xml_text(session.session_id)}</text>'
	svg << '<text x="0" y="${text_y + 38}" fill="#444444" font-family="Menlo, Consolas, monospace" font-size="12">url: ${escape_xml_text(session.pairing_url)}</text>'
	svg << '</svg>'
	os.write_file(svg_path, svg.join('\n'))!
	return svg_path
}

fn render_channels_login_qr_lines(payload string) []string {
	// 渲染一个真正的版本 1-L 二维码，适合终端扫描。
	modules := build_channels_login_qr_modules(payload)
	if modules.len == 0 {
		return ['[failed to render QR code]']
	}
	visual_size := channels_login_qr_size + channels_login_qr_quiet_zone * 2
	mut lines := []string{cap: visual_size}
	for y in 0 .. visual_size {
		mut line := ''
		for x in 0 .. visual_size {
			if x < channels_login_qr_quiet_zone || y < channels_login_qr_quiet_zone
				|| x >= channels_login_qr_quiet_zone + channels_login_qr_size
				|| y >= channels_login_qr_quiet_zone + channels_login_qr_size {
				line += '  '
			} else if modules[(y - channels_login_qr_quiet_zone) * channels_login_qr_size +
				(x - channels_login_qr_quiet_zone)] {
				line += '██'
			} else {
				line += '  '
			}
		}
		lines << line
	}
	return lines
}

fn build_channels_login_qr_modules(payload string) []bool {
	data_codewords := build_channels_login_qr_data_codewords(payload)
	if data_codewords.len == 0 {
		return []bool{}
	}
	ecc_codewords := build_channels_login_qr_ecc_codewords(data_codewords)
	mut all_codewords := data_codewords.clone()
	all_codewords << ecc_codewords
	base_modules, reserved := build_channels_login_qr_template()
	if base_modules.len == 0 {
		return []bool{}
	}
	mut best_modules := []bool{}
	mut best_penalty := int(1 << 30)
	for mask in 0 .. 8 {
		mut candidate := base_modules.clone()
		channels_login_apply_data_bits(mut candidate, reserved, all_codewords)
		channels_login_apply_mask(mut candidate, reserved, mask)
		channels_login_apply_format_info(mut candidate, mask)
		penalty := channels_login_qr_penalty(candidate)
		if penalty < best_penalty {
			best_penalty = penalty
			best_modules = candidate.clone()
		}
	}
	return best_modules
}

fn build_channels_login_qr_data_codewords(payload string) []u8 {
	// 仅支持版本 1-L 的 byte mode，足够容纳本地配对 token。
	if payload.len > 17 {
		return []u8{}
	}
	mut bits := []u8{}
	channels_login_append_bits(mut bits, u32(0x04), 4)
	channels_login_append_bits(mut bits, u32(payload.len), 8)
	for byte_value in payload.bytes() {
		channels_login_append_bits(mut bits, u32(byte_value), 8)
	}
	capacity_bits := channels_login_qr_data_codewords * 8
	if bits.len > capacity_bits {
		return []u8{}
	}
	terminator := if capacity_bits - bits.len < 4 { capacity_bits - bits.len } else { 4 }
	for _ in 0 .. terminator {
		bits << u8(0)
	}
	for bits.len % 8 != 0 {
		bits << u8(0)
	}
	mut codewords := []u8{}
	for index in 0 .. bits.len / 8 {
		mut value := u8(0)
		for bit_index in 0 .. 8 {
			value = (value << 1) | bits[index * 8 + bit_index]
		}
		codewords << value
	}
	mut pad_byte := true
	for codewords.len < channels_login_qr_data_codewords {
		codewords << if pad_byte { u8(0xec) } else { u8(0x11) }
		pad_byte = !pad_byte
	}
	return codewords
}

fn build_channels_login_qr_ecc_codewords(data_codewords []u8) []u8 {
	// 使用版本 1-L 对应的 7 个纠错码字。
	mut exp_table := []u8{len: 512, init: 0}
	mut log_table := []u8{len: 256, init: 0}
	mut value := 1
	for index in 0 .. 255 {
		exp_table[index] = u8(value)
		log_table[value] = u8(index)
		value <<= 1
		if value & 0x100 != 0 {
			value ^= 0x11d
		}
	}
	for index in 255 .. 512 {
		exp_table[index] = exp_table[index - 255]
	}
	mut message := data_codewords.clone()
	message << []u8{len: channels_login_qr_ecc_codewords, init: 0}
	for index in 0 .. data_codewords.len {
		factor := message[index]
		if factor == 0 {
			continue
		}
		for poly_index in 0 .. channels_login_qr_generator.len {
			message[index + poly_index] ^= channels_login_qr_gf_mul(channels_login_qr_generator[poly_index],
				factor, exp_table, log_table)
		}
	}
	return message[data_codewords.len..]
}

fn channels_login_qr_gf_mul(a u8, b u8, exp_table []u8, log_table []u8) u8 {
	if a == 0 || b == 0 {
		return 0
	}
	return exp_table[int(log_table[int(a)]) + int(log_table[int(b)])]
}

fn build_channels_login_qr_template() ([]bool, []bool) {
	mut modules := []bool{len: channels_login_qr_size * channels_login_qr_size, init: false}
	mut reserved := []bool{len: channels_login_qr_size * channels_login_qr_size, init: false}
	channels_login_draw_finder_pattern(mut modules, mut reserved, 0, 0)
	channels_login_draw_finder_pattern(mut modules, mut reserved, channels_login_qr_size - 7,
		0)
	channels_login_draw_finder_pattern(mut modules, mut reserved, 0, channels_login_qr_size - 7)
	channels_login_draw_timing_pattern(mut modules, mut reserved)
	channels_login_set_fixed_module(mut modules, mut reserved, 8, 13, true)
	channels_login_reserve_format_info(mut reserved)
	return modules, reserved
}

fn channels_login_draw_finder_pattern(mut modules []bool, mut reserved []bool, origin_x int, origin_y int) {
	for dy in -1 .. 8 {
		for dx in -1 .. 8 {
			x := origin_x + dx
			y := origin_y + dy
			if x < 0 || y < 0 || x >= channels_login_qr_size || y >= channels_login_qr_size {
				continue
			}
			mut dark := false
			if dx >= 0 && dx <= 6 && dy >= 0 && dy <= 6 {
				if dx == 0 || dx == 6 || dy == 0 || dy == 6 {
					dark = true
				} else if dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4 {
					dark = true
				}
			}
			channels_login_set_fixed_module(mut modules, mut reserved, x, y, dark)
		}
	}
}

fn channels_login_draw_timing_pattern(mut modules []bool, mut reserved []bool) {
	for x in 8 .. channels_login_qr_size - 8 {
		channels_login_set_fixed_module(mut modules, mut reserved, x, 6, x % 2 == 0)
	}
	for y in 8 .. channels_login_qr_size - 8 {
		channels_login_set_fixed_module(mut modules, mut reserved, 6, y, y % 2 == 0)
	}
}

fn channels_login_reserve_format_info(mut reserved []bool) {
	for i in 0 .. 15 {
		if i < 6 {
			channels_login_set_reserved(mut reserved, 8, i)
		} else if i < 8 {
			channels_login_set_reserved(mut reserved, 8, i + 1)
		} else {
			channels_login_set_reserved(mut reserved, 14 - i, 8)
		}
		if i < 8 {
			channels_login_set_reserved(mut reserved, channels_login_qr_size - 1 - i,
				8)
		} else {
			channels_login_set_reserved(mut reserved, 8, channels_login_qr_size - 15 + i)
		}
	}
}

fn channels_login_apply_data_bits(mut modules []bool, reserved []bool, codewords []u8) {
	mut bit_index := 0
	for x := channels_login_qr_size - 1; x > 0; x -= 2 {
		if x == 6 {
			x--
		}
		mut y := channels_login_qr_size - 1
		mut direction := -1
		for {
			for dx in 0 .. 2 {
				col := x - dx
				idx := y * channels_login_qr_size + col
				if reserved[idx] {
					continue
				}
				mut bit := false
				if bit_index < codewords.len * 8 {
					byte_index := bit_index / 8
					shift := bit_index % 8
					bit = ((codewords[byte_index] >> shift) & 1) == 1
					bit_index++
				}
				modules[idx] = bit
			}
			y += direction
			if y < 0 || y >= channels_login_qr_size {
				y -= direction
				direction = -direction
				break
			}
		}
	}
}

fn channels_login_apply_mask(mut modules []bool, reserved []bool, mask int) {
	for y in 0 .. channels_login_qr_size {
		for x in 0 .. channels_login_qr_size {
			idx := y * channels_login_qr_size + x
			if reserved[idx] {
				continue
			}
			if channels_login_mask_bit(mask, x, y) {
				modules[idx] = !modules[idx]
			}
		}
	}
}

fn channels_login_mask_bit(mask int, x int, y int) bool {
	return match mask {
		0 { (x + y) % 2 == 0 }
		1 { y % 2 == 0 }
		2 { x % 3 == 0 }
		3 { (x + y) % 3 == 0 }
		4 { ((y / 2) + (x / 3)) % 2 == 0 }
		5 { ((x * y) % 2 + (x * y) % 3) == 0 }
		6 { (((x * y) % 2 + (x * y) % 3) % 2) == 0 }
		else { (((x + y) % 2 + (x * y) % 3) % 2) == 0 }
	}
}

fn channels_login_apply_format_info(mut modules []bool, mask int) {
	format_info := channels_login_qr_format_bits(mask)
	for i in 0 .. 15 {
		bit := ((format_info >> (14 - i)) & 1) == 1
		if i < 6 {
			channels_login_set_module(mut modules, 8, i, bit)
		} else if i < 8 {
			channels_login_set_module(mut modules, 8, i + 1, bit)
		} else {
			channels_login_set_module(mut modules, 8, channels_login_qr_size - 15 + i,
				bit)
		}
		if i < 8 {
			channels_login_set_module(mut modules, channels_login_qr_size - 1 - i, 8,
				bit)
		} else if i < 9 {
			channels_login_set_module(mut modules, 7, 8, bit)
		} else {
			channels_login_set_module(mut modules, 15 - i - 1, 8, bit)
		}
	}
}

fn channels_login_qr_format_bits(mask int) u32 {
	data := u32((0 << 3) | mask)
	mut bits := data << 10
	for i := 14; i >= 10; i-- {
		if ((bits >> u32(i)) & 1) == 1 {
			bits ^= u32(0x537) << u32(i - 10)
		}
	}
	return ((data << 10) | (bits & 0x3ff)) ^ 0x5412
}

fn channels_login_qr_penalty(modules []bool) int {
	mut penalty := 0
	for y in 0 .. channels_login_qr_size {
		mut run_color := modules[y * channels_login_qr_size]
		mut run_length := 1
		for x in 1 .. channels_login_qr_size {
			color := modules[y * channels_login_qr_size + x]
			if color == run_color {
				run_length++
			} else {
				if run_length >= 5 {
					penalty += 3 + (run_length - 5)
				}
				run_color = color
				run_length = 1
			}
		}
		if run_length >= 5 {
			penalty += 3 + (run_length - 5)
		}
	}
	for x in 0 .. channels_login_qr_size {
		mut run_color := modules[x]
		mut run_length := 1
		for y in 1 .. channels_login_qr_size {
			color := modules[y * channels_login_qr_size + x]
			if color == run_color {
				run_length++
			} else {
				if run_length >= 5 {
					penalty += 3 + (run_length - 5)
				}
				run_color = color
				run_length = 1
			}
		}
		if run_length >= 5 {
			penalty += 3 + (run_length - 5)
		}
	}
	for y in 0 .. channels_login_qr_size - 1 {
		for x in 0 .. channels_login_qr_size - 1 {
			color := modules[y * channels_login_qr_size + x]
			if color == modules[y * channels_login_qr_size + x + 1]
				&& color == modules[(y + 1) * channels_login_qr_size + x]
				&& color == modules[(y + 1) * channels_login_qr_size + x + 1] {
				penalty += 3
			}
		}
	}
	pattern_a := [true, false, true, true, true, false, true, false, false, false, false]
	pattern_b := [false, false, false, false, true, false, true, true, true, false, true]
	for y in 0 .. channels_login_qr_size {
		for x in 0 .. channels_login_qr_size - 10 {
			if channels_login_qr_window_matches(modules, x, y, 1, pattern_a)
				|| channels_login_qr_window_matches(modules, x, y, 1, pattern_b) {
				penalty += 40
			}
		}
	}
	for x in 0 .. channels_login_qr_size {
		for y in 0 .. channels_login_qr_size - 10 {
			if channels_login_qr_window_matches(modules, x, y, channels_login_qr_size, pattern_a)
				|| channels_login_qr_window_matches(modules, x, y, channels_login_qr_size, pattern_b) {
				penalty += 40
			}
		}
	}
	mut dark_count := 0
	for cell in modules {
		if cell {
			dark_count++
		}
	}
	dark_percent := dark_count * 100 / modules.len
	diff := if dark_percent > 50 {
		dark_percent - 50
	} else {
		50 - dark_percent
	}
	penalty += (diff / 5) * 10
	return penalty
}

fn channels_login_qr_window_matches(modules []bool, x int, y int, stride int, pattern []bool) bool {
	for index in 0 .. pattern.len {
		if modules[y * channels_login_qr_size + x + index * stride] != pattern[index] {
			return false
		}
	}
	return true
}

fn channels_login_set_fixed_module(mut modules []bool, mut reserved []bool, x int, y int, dark bool) {
	if x < 0 || y < 0 || x >= channels_login_qr_size || y >= channels_login_qr_size {
		return
	}
	idx := y * channels_login_qr_size + x
	modules[idx] = dark
	reserved[idx] = true
}

fn channels_login_set_reserved(mut reserved []bool, x int, y int) {
	if x < 0 || y < 0 || x >= channels_login_qr_size || y >= channels_login_qr_size {
		return
	}
	reserved[y * channels_login_qr_size + x] = true
}

fn channels_login_set_module(mut modules []bool, x int, y int, dark bool) {
	if x < 0 || y < 0 || x >= channels_login_qr_size || y >= channels_login_qr_size {
		return
	}
	modules[y * channels_login_qr_size + x] = dark
}

fn channels_login_append_bits(mut bits []u8, value u32, count int) {
	mut shift := count - 1
	for shift >= 0 {
		bits << u8((value >> u32(shift)) & 1)
		shift--
	}
}

fn escape_xml_text(text string) string {
	mut escaped := text.replace('&', '&amp;')
	escaped = escaped.replace('<', '&lt;')
	escaped = escaped.replace('>', '&gt;')
	escaped = escaped.replace('"', '&quot;')
	escaped = escaped.replace("'", '&apos;')
	return escaped
}

fn append_channels_login_event(config Config, channel string, status string, detail string) ! {
	// 记录 channels 登录过程中的关键事件。
	log_path := os.join_path(config.workspace, 'state', channels_login_events_file)
	existing := if os.exists(log_path) { os.read_file(log_path) or { '' } } else { '' }
	line := '{"ts":"${escape_json_string(time.now().str())}","channel":"${escape_json_string(channel)}","status":"${escape_json_string(status)}","detail":"${escape_json_string(detail)}"}\n'
	os.write_file(log_path, existing + line)!
}

fn write_channels_login_state(config Config, channel string, status string, detail string) ! {
	// 记录最新的 channels 登录状态，方便后续查看本地登录流程。
	state_path := os.join_path(config.workspace, 'state', channels_login_state_file)
	state_json := '{"ts":"${escape_json_string(time.now().str())}","channel":"${escape_json_string(channel)}","status":"${escape_json_string(status)}","detail":"${escape_json_string(detail)}"}'
	os.write_file(state_path, state_json)!
}
