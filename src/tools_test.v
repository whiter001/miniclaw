module main

import os

fn test_resolve_workspace_path_prevents_escape() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-workspace')
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	if _ := resolve_workspace_path(workspace, '../outside') {
		assert false
	} else {
		assert true
	}
}

fn test_write_and_read_tool_roundtrip() {
	workspace := os.join_path(os.temp_dir(), 'miniclaw-test-tools')
	os.mkdir_all(workspace) or { panic(err) }
	defer {
		os.rmdir_all(workspace) or {}
	}
	config := Config{
		workspace: workspace
	}
	write_tool := ToolUse{
		name:  'write_file'
		input: {
			'path':    'sample.txt'
			'content': 'alpha\nbeta'
		}
	}
	_ := execute_tool(write_tool, config) or { panic(err) }
	read_tool := ToolUse{
		name:  'read_file'
		input: {
			'path': 'sample.txt'
		}
	}
	content := execute_tool(read_tool, config) or { panic(err) }
	assert content == 'alpha\nbeta'
}

fn test_exec_blocks_dangerous_command() {
	config := Config{
		workspace: os.temp_dir()
	}
	tool := ToolUse{
		name:  'exec'
		input: {
			'command': 'rm -rf tmp-danger'
		}
	}
	if _ := execute_tool(tool, config) {
		assert false
	} else {
		assert err.msg().contains('blocked')
	}
}
