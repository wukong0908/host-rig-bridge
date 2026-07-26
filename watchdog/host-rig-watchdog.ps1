# host-rig-watchdog.ps1 — 主机侧分机诊断守护
# 4 类探针: SSH 连通 / MCP server 进程 / 沙箱磁盘 / 主机 claude.json 注册
# 异常 → feishu-notify.ps1 + 1h 内同告警去重 (state/<rig>.<level>.<hash>.last_sent)
# 计划任务: 5min 一次, SYSTEM + Highest + RestartCount 3

[CmdletBinding()]
param(
    [string]$RigAlias = "",
    [string]$RigsFile = "",
    [int]$DedupMinutes = 60,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StateDir = Join-Path $script:Dir "state"

if (-not $RigsFile) {
    $RigsFile = Join-Path $HOME ".claude\host-rig-bridge\rigs.local.yaml"
}

# ===== YAML 极简解析 (单文件 < 100 行, 不引 yq/PowerShell-Yaml) =====
# 只解 rigs[].alias / user / host / sandbox. 注释/嵌套/锚点不支持 — 主人手工维护.
function Read-RigsFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warning "rigs.local.yaml not found at $Path"
        return @()
    }
    $rigs = @()
    $cur = $null
    foreach ($line in (Get-Content $Path)) {
        $t = $line.TrimEnd()
        if ($t -match '^\s*#|^\s*$') { continue }
        if ($t -match '^\s*-\s+alias:\s*(.+)$') {
            if ($cur) { $rigs += $cur }
            $cur = [pscustomobject]@{
                alias = $Matches[1].Trim()
                host  = ""
                user  = ""
                sandbox = ""
            }
            continue
        }
        if ($cur -and $t -match '^\s+host:\s*(.+)$') { $cur.host = $Matches[1].Trim(); continue }
        if ($cur -and $t -match '^\s+user:\s*(.+)$') { $cur.user = $Matches[1].Trim(); continue }
        if ($cur -and $t -match '^\s+sandbox:\s*(.+)$') { $cur.sandbox = $Matches[1].Trim(); continue }
    }
    if ($cur) { $rigs += $cur }
    return $rigs
}

# ===== 告警 (含 1h 去重) =====
function Send-Alert {
    param(
        [string]$Rig, [string]$Level, [string]$Msg, [string]$Probe = ""
    )
    $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new(
        [Text.Encoding]::UTF8.GetBytes("$Probe|$Msg"))) -Algorithm SHA256).Hash.Substring(0, 12)
    $stateFile = Join-Path $script:StateDir "$Rig.$Level.$hash.last_sent"
    if (Test-Path $stateFile) {
        $age = (Get-Date) - (Get-Item $stateFile).LastWriteTime
        if ($age.TotalMinutes -lt $DedupMinutes) {
            Write-Verbose "dedup: $Rig $Level ($([int]$age.TotalMinutes)m ago)"
            return
        }
    }
    if (-not (Test-Path $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    Set-Content -Path $stateFile -Value (Get-Date -Format "o")
    if ($DryRun) {
        Write-Output "DRY-RUN alert: $Rig $Level $Msg"
        return
    }
    & (Join-Path $script:Dir "feishu-notify.ps1") -Rig $Rig -Level $Level -Msg $Msg -Probe $Probe
}

# ===== 探针 =====
function Test-SshConnect {
    param([string]$Rig)
    $out = & ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o RequestTTY=no $Rig "echo OK" 2>&1
    if ($LASTEXITCODE -ne 0 -or ($out -notmatch "OK")) {
        Send-Alert -Rig $Rig -Level WARN -Msg "SSH 连通失败 (exit=$LASTEXITCODE)" -Probe "ssh -T <rig> echo OK"
        return $false
    }
    return $true
}

function Test-McpServer {
    param([string]$Rig, [string]$User, [string]$SrvPath)
    # Windows 探针: Get-Process 查 server.py 进程
    # 走 mcp-rig 账号 SSH 时 forced command 截胡, 改用 powershell 单引号串
    $out = & ssh -T -o BatchMode=yes -o ConnectTimeout=5 $Rig `
        "powershell -NoProfile -Command `"Get-Process python -ErrorAction SilentlyContinue | Where-Object { `$_.CommandLine -like '*server.py*' } | Select-Object -First 1 | ForEach-Object { 'PID=' + `$_.Id }`"" 2>&1
    if (-not $out -or ($out -notmatch "PID=")) {
        Send-Alert -Rig $Rig -Level CRIT -Msg "MCP server 进程消失" -Probe "ssh $Rig powershell Get-Process *server.py*"
        return $false
    }
    return $true
}

function Test-SandboxDisk {
    param([string]$Rig, [string]$Sandbox)
    if (-not $Sandbox) { return $true }
    # Windows 探针: Get-PSDrive 查沙箱所在盘符使用率
    # Sandbox 形如 C:/Users/mcp-rig/projects → 取盘符
    $drive = ($Sandbox -replace ':.*$', '') + ':'
    $out = & ssh -T -o BatchMode=yes -o ConnectTimeout=5 $Rig `
        "powershell -NoProfile -Command `"Get-PSDrive -Name '$($drive -replace ':','')' | Select-Object -ExpandProperty Used + ' / ' + (`$_.Used + `$_.Free) + ' ' + [int](`$_.Used/(`$_.Used+`$_.Free)*100) + '%%'`"" 2>&1
    # 简化为检查 (Get-PSDrive 字段)
    $out = & ssh -T -o BatchMode=yes -o ConnectTimeout=5 $Rig `
        "powershell -NoProfile -Command `"`$d=Get-PSDrive -Name '$($drive -replace ':','')'; '{0:N1} GB used / {1}%%' -f (`$d.Used/1GB), [int](`$d.Used/(`$d.Used+`$d.Free)*100)`"" 2>&1
    if ($out -match '(\d+)%%') {
        $pct = [int]$Matches[1]
        if ($pct -ge 95) {
            Send-Alert -Rig $Rig -Level CRIT -Msg "沙箱磁盘 ${pct}%" -Probe "Get-PSDrive $drive"
            return $false
        } elseif ($pct -ge 85) {
            Send-Alert -Rig $Rig -Level WARN -Msg "沙箱磁盘 ${pct}%" -Probe "Get-PSDrive $drive"
            return $false
        }
    }
    return $true
}

function Test-ClaudeJsonRig {
    param([string]$Rig, [string]$HomeDir = $HOME)
    $cfg = Join-Path $HomeDir ".claude.json"
    if (-not (Test-Path $cfg)) {
        Send-Alert -Rig $Rig -Level WARN -Msg "~/.claude.json 缺失" -Probe "Test-Path $cfg"
        return $false
    }
    try {
        $json = Get-Content $cfg -Raw | ConvertFrom-Json -AsHashtable
        if (-not $json.mcpServers.$Rig) {
            Send-Alert -Rig $Rig -Level WARN -Msg "~/.claude.json 未注册 mcpServers.$Rig" -Probe "ConvertFrom-Json $cfg"
            return $false
        }
    } catch {
        Send-Alert -Rig $Rig -Level WARN -Msg "~/.claude.json 解析失败: $_" -Probe "ConvertFrom-Json $cfg"
        return $false
    }
    return $true
}

# ===== 主流程 =====
$rigs = Read-RigsFile -Path $RigsFile
if (-not $rigs) {
    Write-Warning "no rigs parsed from $RigsFile"
    exit 0
}

if ($RigAlias) {
    $rigs = @($rigs | Where-Object { $_.alias -eq $RigAlias })
    if (-not $rigs) {
        Write-Error "rig '$RigAlias' not in $RigsFile"
        exit 1
    }
}

foreach ($r in $rigs) {
    Write-Output "[$(Get-Date -Format 'o')] rig=$($r.alias) host=$($r.host) user=$($r.user)"
    if (Test-SshConnect -Rig $r.alias) {
        # Server path 优先从 rigs.yaml 读, 缺则默认 Windows 路径
        $srvPath = if ($r.server) { $r.server } else { "C:/Users/$($r.user)/mcp-server/src/server/server.py" }
        Test-McpServer -Rig $r.alias -User $r.user -SrvPath $srvPath
        Test-SandboxDisk -Rig $r.alias -Sandbox $r.sandbox
    }
    Test-ClaudeJsonRig -Rig $r.alias
}

exit 0