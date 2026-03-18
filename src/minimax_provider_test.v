module main

fn test_build_minimax_request_json_uses_anthropic_fields() {
	config := Config{
		model:       'MiniMax-M2.7'
		max_tokens:  512
		temperature: 0.7
		base_url:    'https://api.minimaxi.com/anthropic'
		workspace:   '/tmp/miniclaw-workspace'
	}
	body := build_minimax_request_json(config, 'Hello, world')
	assert body.contains('"model":"MiniMax-M2.7"')
	assert body.contains('"max_tokens":512')
	assert body.contains('"temperature":0.7')
	assert body.contains('"top_p":1')
	assert body.contains('"messages":[{"role":"user","content":[{"type":"text","text":"Hello, world"}]}]')
}

fn test_resolve_anthropic_messages_url_normalizes_base_endpoint() {
	assert resolve_anthropic_messages_url('https://api.minimaxi.com/anthropic') == 'https://api.minimaxi.com/anthropic/messages'
	assert resolve_anthropic_messages_url('https://api.minimaxi.com/anthropic/') == 'https://api.minimaxi.com/anthropic/messages'
	assert resolve_anthropic_messages_url('https://api.minimaxi.com/anthropic/messages') == 'https://api.minimaxi.com/anthropic/messages'
	assert resolve_anthropic_messages_url('https://api.minimaxi.com/anthropic/v1/messages') == 'https://api.minimaxi.com/anthropic/v1/messages'
}
