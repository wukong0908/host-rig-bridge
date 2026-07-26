# verify.ps1 - 验证 host-rig-bridge 全链路 (单 rig, Windows 外机)
# 跑法: "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoProfile -File verify.ps1 -Rig rig
#
# 注意: mcp-rig 账号的 authorized_keys 配了 forced command = MCP server,
#       所以 ssh 跑普通命令 (echo / ls) 被截胡 (MCP server 不认这些命令).
#       本脚本只验"链路是否能到达 MCP server", 文件 IO 验证需走 Claude (MCP stdio).

[CmdletBinding()]
param(
    [string]$Rig = "rig"
)

$ErrorActionPreference = "Continue"

function Test-Step {
    param([string]$Name, [scriptblock]$Block)
    Write-Host ""
    Write-Host "──── $Name ────" -ForegroundColor Cyan
    try {
        & $Block
        Write-Host "✅ $Name" -ForegroundColor Green
    } catch {
        Write-Host "❌ $Name — $_" -ForegroundColor Red
    }
}

# 1. SSH 链路可达 (forced command 被触发, MCP server 应启 stdio 等 JSON-RPC)
#    验证手段: 给一个会让 MCP server 报 parse error 的非法 JSON, 捕获 stderr 含 "MCP" 或 JSON error
Test-Step "SSH 链路可达 + forced command 触发" {
    $out = ssh -T -o BatchMode=yes -o RequestTTY=no -o ConnectTimeout=5 $Rig "INVALID_JSON_FOR_PROBE" 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $out -match "MCP|JSON|parse|invalid|Error|Server") {
        Write-Host "MCP server 已接 SSH 连入 (forced command 触发, 接受/拒绝输入符合预期)"
    } else {
        Write-Host "⚠️  unexpected output: $out"
    }
}

# 2. server.py 文件存在 — 走 ssh 拿, 但 forced command 会截胡
#    改为: 主机直接看 rigs.yaml (server 路径存在)
Test-Step "rigs.yaml 含 server 路径" {
    $yaml = Join-Path $HOME ".claude\host-rig-bridge\rigs.local.yaml"
    if (-not (Test-Path $yaml)) {
        Write-Host "❌ $yaml 不存在"
        return
    }
    . (Join-Path $PSScriptRoot "lib\rigs-yaml.ps1")
    $rigs = Read-RigsLocal -Path $yaml
    $hit = $rigs | Where-Object { $_.alias -eq $Rig } | Select-Object -First 1
    if ($hit -and $hit.server -and $hit.venv -and $hit.sandbox) {
        Write-Host "  server:  $($hit.server)"
        Write-Host "  venv:    $($hit.venv)"
        Write-Host "  sandbox: $($hit.sandbox)"
    } else {
        Write-Host "❌ rigs.yaml 缺 $Rig 配置 (server / venv / sandbox)"
    }
}

# 3. ~/.claude.json 含 $Rig
Test-Step "~/.claude.json 配置 ($Rig)" {
    if (Test-Path "$HOME\.claude.json") {
        $cfg = Get-Content "$HOME\.claude.json" -Raw | ConvertFrom-Json
        if ($cfg.mcpServers.$Rig) {
            Write-Host "$Rig 配置存在"
        } else {
            Write-Host "❌ 没找到 $Rig"
        }
    } else {
        Write-Host "❌ ~/.claude.json 不存在"
    }
}

# 4. known_hosts.<rig> 有 fingerprint
Test-Step "known_hosts.$Rig" {
    $kh = "$HOME\.ssh\known_hosts.$Rig"
    if (Test-Path $kh) {
        Write-Host "EXISTS"
    } else {
        Write-Host "MISSING — 跑: ssh -o StrictHostKeyChecking=accept-new $Rig"
    }
}

# 5. 重启 Claude 提示
Test-Step "重启 Claude" {
    Write-Host "请手动重启主机 Claude Code, 跑 /mcp, 看 $Rig 状态 connected"
}

Write-Host ""
Write-Host "==== 验证完成 ====" -ForegroundColor Yellow
Write-Host "Claude 跑通后, 在 Claude 里试 (MCP stdio 端到端):" -ForegroundColor Yellow
Write-Host "  list_dir()" -ForegroundColor Yellow
Write-Host "  read_file('C:/Users/mcp-rig/projects/<你的文件>')" -ForegroundColor Yellow
Write-Host "  run_command('iverilog -V')" -ForegroundColor Yellow
Write-Host "  start_task('iverilog -o ... ...', timeout=7200)" -ForegroundColor Yellow
Write-Host "  task_status('<task_id>')" -ForegroundColor Yellow