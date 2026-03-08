# MiniClaw Agent Guide

## Working Rules

- All V code changes must be formatted with `v fmt -w` before finishing the task.
- All Markdown changes must be formatted with `oxfmt` before finishing the task.
- Do not commit or expose secrets, tokens, API keys, app secrets, cookies, access tokens, or local credential files.
- Do not commit or expose runtime data that may contain sensitive identifiers, including `openid`, `union_openid`, session logs, webhook event dumps, access token caches, or local validation artifacts.
- Keep sensitive values in local config or environment variables only. Source code, Markdown, examples, and test fixtures must use placeholders instead of real values.
- Before suggesting a commit, re-check that temporary files, runtime state files, downloaded verification files, and local debug outputs are ignored and not staged.
