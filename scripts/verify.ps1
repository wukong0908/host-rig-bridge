# verify.ps1 - 验证 host-rig-bridge 全链路 (单 rig)
# 跑法: "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoProfile -File verify.ps1 -Rig rig

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

# 1. SSH 链路
Test-Step "SSH 直连 $Rig (BatchMode)" {
    ssh -T -o BatchMode=yes -o RequestTTY=no $Rig "echo SSH_OK"
}

# 2. server.py 文件存在
Test-Step "server.py 存在" {
    ssh -T $Rig "if (Test-Path C:\Users\mcp-rig\mcp-server\src\server\server.py) { Write-Host EXISTS } else { Write-Host MISSING }"
}

# 3. mcp SDK 可导入
Test-Step "mcp SDK 导入" {
    ssh -T $Rig "& C:\Users\mcp-rig\mcp-server\.venv\Scripts\python.exe -c 'from mcp.server.fastmcp import FastMCP; print(chr(79)+chr(75))'"
}

# 4. 沙箱目录存在
Test-Step "沙箱目录存在" {
    ssh -T $Rig "if (Test-Path C:\Users\mcp-rig\projects) { Write-Host EXISTS } else { Write-Host MISSING }"
}

# 5. known_hosts.<rig> 有 fingerprint
Test-Step "known_hosts.$Rig" {
    $kh = "$HOME\.ssh\known_hosts.$Rig"
    if (Test-Path $kh) {
        Write-Host "EXISTS"
    } else {
        Write-Host "MISSING — 跑: ssh -o StrictHostKeyChecking=accept-new $Rig"
    }
}

# 6. ~/.claude.json 含 $Rig
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

# 7. 重启 Claude 提示
Test-Step "重启 Claude" {
    Write-Host "请手动重启主机 Claude Code, 跑 /mcp, 看 $Rig 状态 connected"
}

Write-Host ""
Write-Host "==== 验证完成 ====" -ForegroundColor Yellow
Write-Host "Claude 跑通后, 在 Claude 里试:" -ForegroundColor Yellow
Write-Host "  list_dir()" -ForegroundColor Yellow
Write-Host "  read_file('C:/Users/mcp-rig/projects/<你的文件>')" -ForegroundColor Yellow
Write-Host "  run_command('iverilog -V')" -ForegroundColor Yellow
Write-Host "  start_task('iverilog -o ... ...', timeout=7200)" -ForegroundColor Yellow
Write-Host "  task_status('<task_id>')" -ForegroundColor Yellow