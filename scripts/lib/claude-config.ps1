# claude-config.ps1 — ~/.claude.json 读写工具
# 供 setup-host.ps1 / register-rig.ps1 复用

function Add-McprigServer {
    param(
        [string]$ClaudeCfg = "$HOME\.claude.json",
        [string]$Alias,
        [string[]]$Args,
        [string]$Command = "ssh"
    )
    if (Test-Path $ClaudeCfg) {
        $existing = Get-Content $ClaudeCfg -Raw | ConvertFrom-Json -AsHashtable
    } else {
        $existing = @{ mcpServers = @{} }
    }
    if (-not $existing.mcpServers) {
        $existing.mcpServers = @{}
    }
    $existing.mcpServers[$Alias] = @{
        command = $Command
        args    = $Args
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content $ClaudeCfg -Encoding UTF8
}

function Get-McpServers {
    param([string]$ClaudeCfg = "$HOME\.claude.json")
    if (-not (Test-Path $ClaudeCfg)) { return @{} }
    $cfg = Get-Content $ClaudeCfg -Raw | ConvertFrom-Json -AsHashtable
    return $cfg.mcpServers
}