# rigs-yaml.ps1 — rigs.local.yaml 极简解析 (无 yq/PowerShell-Yaml 依赖)
# 供 register-rig.ps1 / watchdog/host-rig-watchdog.ps1 复用
# 支持字段: alias / host / user / key / sandbox / server / venv / capabilities / tools / notes
# 注释/嵌套/锚点不支持 — 主人手工维护

function Expand-HomePath {
    param([string]$P)
    if ($P -match '^~(/|$)') {
        return ($P -replace '^~', $HOME)
    }
    return $P
}

function Read-RigsLocal {
    param([string]$Path = (Join-Path $HOME ".claude\host-rig-bridge\rigs.local.yaml"))
    if (-not (Test-Path $Path)) {
        $example = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "rigs.local.yaml.example"
        throw "rigs.local.yaml not found at $Path`n  fix: cp $example $Path"
    }
    $rigs = @()
    $cur = $null
    $inTools = $false
    foreach ($line in (Get-Content $Path)) {
        $t = $line.TrimEnd()
        if ($t -match '^\s*#|^\s*$') { continue }
        if ($t -match '^\s*-\s+alias:\s*(.+)$') {
            if ($cur) { $rigs += [pscustomobject]$cur }
            $cur = [ordered]@{
                alias = $Matches[1].Trim()
                host = ""
                user = ""
                key = ""
                sandbox = ""
                server = ""
                venv = ""
                capabilities = @()
                tools = @()
                notes = ""
            }
            $inTools = $false
            continue
        }
        if (-not $cur) { continue }
        if ($t -match '^\s+tools:\s*$') { $inTools = $true; continue }
        if ($inTools -and $t -match '^\s+-\s+(.+)$') {
            $cur.tools += $Matches[1].Trim()
            continue
        }
        $inTools = $false
        if ($t -match '^\s+host:\s*(.+)$') { $cur.host = $Matches[1].Trim(); continue }
        if ($t -match '^\s+user:\s*(.+)$') { $cur.user = $Matches[1].Trim(); continue }
        if ($t -match '^\s+key:\s*(.+)$') { $cur.key = Expand-HomePath $Matches[1].Trim(); continue }
        if ($t -match '^\s+sandbox:\s*(.+)$') { $cur.sandbox = $Matches[1].Trim(); continue }
        if ($t -match '^\s+server:\s*(.+)$') { $cur.server = $Matches[1].Trim(); continue }
        if ($t -match '^\s+venv:\s*(.+)$') { $cur.venv = $Matches[1].Trim(); continue }
        if ($t -match '^\s+capabilities:\s*\[(.+)\]') {
            $cur.capabilities = $Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            continue
        }
        if ($t -match '^\s+notes:\s*"(.*)"\s*$') { $cur.notes = $Matches[1]; continue }
        if ($t -match '^\s+notes:\s*(.+)$') { $cur.notes = $Matches[1].Trim(); continue }
    }
    if ($cur) { $rigs += [pscustomobject]$cur }
    return $rigs
}

function Find-Rig {
    param(
        [object[]]$Rigs,
        [string]$Alias
    )
    $hit = $Rigs | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
    if (-not $hit) {
        $names = ($Rigs | ForEach-Object { $_.alias }) -join ", "
        throw "rig '$Alias' not in rigs.local.yaml. known: $names"
    }
    return $hit
}

# 注意: 顶层 Export-ModuleMember 只在 Import-Module 时有效; dot-source (. ./xxx.ps1) 不要带
# 调用方按需 dot-source 或 Import-Module