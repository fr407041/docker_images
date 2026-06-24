$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ImageName = "claude-ccr:ubuntu22"
$ContainerWorkspace = "/workspace"

Write-Host "Using image: $ImageName"
Write-Host "Mounting workspace: $WorkspaceRoot -> $ContainerWorkspace"
Write-Host "Mode: Guarded Codex exec"
Write-Host "OPENAI_BASE_URL defaults to host Ollama on port 11434"
Write-Host ""
Write-Host "Paste one task line after the prompt. The wrapper will force inventory-first batching."
Write-Host ""

$Task = Read-Host "Codex task"

if ([string]::IsNullOrWhiteSpace($Task)) {
  Write-Host "No task entered. Exiting."
  exit 1
}

docker run --rm -it `
  --add-host=host.docker.internal:host-gateway `
  -e OPENAI_API_KEY=dummy-key `
  -e OPENAI_BASE_URL=http://host.docker.internal:11434/v1 `
  -e CODEX_TASK="$Task" `
  -v "${WorkspaceRoot}:${ContainerWorkspace}" `
  $ImageName `
  bash -lc "cd /workspace/linux_remote/ubuntu22-claude-ccr && bash ./scripts/run_codex_guarded.sh"
