# Claude Router Orchestrator 懶人包安裝說明

這份 bundle 只聚焦在：
- `Claude Code + router -> child Claude Code + router` orchestration
- 子 Claude/router 數量上限
- 安全清理異常 child 流程
- 多輪小批次執行，降低 token overflow 風險

刻意不包含：
- Claude Code 安裝流程
- Claude Code Router 安裝流程
- 開源模型選型流程
- router model 設定修改

## 使用前提

目標 Linux 環境需要已經具備：
- `bash`
- `python3`
- `jq`
- `claude`
- 可正常啟動的既有 router

如果只是想跑 mock 驗證，不需要真的連到你的 router model。

## 一鍵安裝

```bash
bash ./scripts/install_claude_router_orchestrator_bundle.sh /opt/claude_orchestrator
```

安裝後主要內容會放在：
- `/opt/claude_orchestrator/scripts`
- `/opt/claude_orchestrator/examples`
- `/opt/claude_orchestrator/docker/claude-router-bundle-test`

## 最小啟動範例

```bash
cd /opt/claude_orchestrator
bash ./scripts/orchestrate_claude_to_claude.sh \
  "Edit tests/test_placeholder.py so it contains a deterministic assertion assert 1 + 1 == 2 and keep the file minimal." \
  ./examples/hello-python
```

## Fresh Image Smoke Test

用全新 Ubuntu Docker image 驗證 bundle：

```bash
bash ./scripts/smoke_bundle_in_fresh_image.sh
```

注意：
- 這支 script 應從 Linux shell 啟動
- 若直接從 Windows PowerShell 呼叫本機 `bash`，有可能在進 Docker 前就先失敗
- 正確定位是 Linux 主機、Linux container、或 Linux VM 內使用

這個 smoke test 會驗證：
- single-file managed edit
- multi-round overflow recovery
- child limit protection
- fail-replan recovery
- timeout recovery
- bad planner fallback
- needs-replan recovery
- false-success blocking
- repeated replan loop guard

## 真實 Claude/router 整合測試

如果你的 Linux 環境已經有可用的 `claude` 與既有 router，可執行：

```bash
bash ./scripts/smoke_real_claude_router_integration.sh
```

可選參數：
- 第一個參數：自訂 project root
- 第二個參數：自訂 task
- `CCR_HEALTH_URL`：自訂 router health endpoint
- `ALLOW_AUTOSTART=1` 搭配 `START_CCR_BIN=/your/existing/router-start-command`
  只在你明確要讓 script 啟動既有 router 指令時使用

## 安全發佈邊界

這份 bundle 建議只發佈：
- orchestration scripts
- mock 驗證腳本
- examples
- Docker 測試骨架

不要一起發佈：
- host-specific Ollama/router 設定
- 真實 token / API key
- benchmarks 與 run artifacts
- model-specific 測試腳本
