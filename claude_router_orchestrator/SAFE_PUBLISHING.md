# Safe Publishing Notes

Publish only the Claude/router orchestration bundle.

Safe to publish:
- orchestration scripts under `scripts/` that implement `main Claude/router -> child Claude/router`
- mock evaluation scripts
- `examples/hello-python`
- `examples/multi-file-python`
- `docker/claude-router-bundle-test`
- `README.md`
- `BUNDLE_INSTALL.zh-TW.md`
- `SAFE_PUBLISHING.md`

Do not publish:
- host-specific Ollama or router configuration files
- real API keys, tokens, cookies, or auth headers
- generated run artifacts under `orchestrator-*` or `benchmarks/`
- caches such as `.pytest_cache` and `__pycache__`
- machine-specific temp folders

Keep placeholder-only values if an example config is ever needed:
- `local-test-key`
- `dummy-key`
- `ollama`

Before publishing, scan for these strings and stop if any real secret appears:
- `sk-`
- `Bearer `
- `Authorization:`
- `ANTHROPIC_AUTH_TOKEN=`
- `OPENAI_API_KEY=`

Current publication scope intentionally excludes:
- Claude Code installation flow
- Claude Code Router installation flow
- router model setting changes
- open-source model selection flow
