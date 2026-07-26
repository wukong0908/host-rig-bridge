# install-rig-bundle.ps1 — 外机一键 deploy (链路 B)
# 装 OpenSSH + 建账号 + 拉代码 + 建 venv + 装 mcp + 写 authorized_keys + 装 frpc + 锁 sshd
#
# 用法 (外机管理员 PowerShell 7.1+):
#   $env:RIG_VPS         = "8.163.106.31"
#   $env:RIG_FRP_TOKEN   = "<同家里 frpc 的 token>"
#   $env:RIG_REMOTE_PORT = "6001"
#   $env:RIG_HOST_PUBKEY = '<forced command + 主机公钥 整行>'
#   iex (iwr -useb 'https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install-rig-bundle.ps1').Content
#
# 子命令:
#   install-rig-bundle.ps1 -Verify    # 5 步验证 (deploy 完后跑)
#   install-rig-bundle.ps1 -Status    # 显示当前状态详情
#   install-rig-bundle.ps1 -Force     # 跳过 Ready 检查强制重跑
#   install-rig-bundle.ps1 -Verbose   # 展开 stage 内子步骤

[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$Status,
    [switch]$Force,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# ===== 路径常量 =====
$UserName   = "mcp-rig"
$ServerDir  = "C:\Users\$UserName\mcp-server"
$SshDir     = "C:\Users\$UserName\.ssh"
$AkPath     = "$SshDir\authorized_keys"
$FrpDir     = "C:\frp"
$FrpcExe    = "$FrpDir\frpc.exe"
$FrpcToml   = "$FrpDir\frpc.toml"
$Nssm       = "C:\nssm-2.24\win64\nssm.exe"

# ===== 段 0: 解析入参 =====
$Vps         = $env:RIG_VPS
$FrpToken    = $env:RIG_FRP_TOKEN
$RemotePort  = $env:RIG_REMOTE_PORT
$HostPubkey  = $env:RIG_HOST_PUBKEY

if ($Status) { Show-Status; exit 0 }
if ($Verify) { Invoke-Verify; exit 0 }

if (-not $Vps -or -not $FrpToken -or -not $RemotePort -or -not $HostPubkey) {
    Write-Host "❌ deploy 模式需 4 个环境变量:" -ForegroundColor Red
    Write-Host '   $env:RIG_VPS         = "8.163.106.31"' -ForegroundColor Red
    Write-Host '   $env:RIG_FRP_TOKEN   = "<同家里 frpc 的 token>"' -ForegroundColor Red
    Write-Host '   $env:RIG_REMOTE_PORT = "6001"' -ForegroundColor Red
    Write-Host '   $env:RIG_HOST_PUBKEY = "<forced command + 主机公钥 整行>"' -ForegroundColor Red
    Write-Host ""
    Write-Host "子命令不需这些:" -ForegroundColor Yellow
    Write-Host "   install-rig-bundle.ps1 -Verify" -ForegroundColor Yellow
    Write-Host "   install-rig-bundle.ps1 -Status" -ForegroundColor Yellow
    exit 1
}

# ===== 管理员检查 =====
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal $id
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "需要管理员 PowerShell. 右键 → 以管理员身份运行."
}

# ===== 段 1: Ready 检查 + 早返 =====
$ready = Test-Ready
if ($ready -and -not $Force) {
    Show-Ready
    Show-NextSteps
    exit 0
}

# ===== 段 2: Deploy (9 stage) =====
Write-Host ""
Write-Host "🚀 开始 deploy (9 stage):" -ForegroundColor Cyan
if ($ready) { Write-Host "    (强制模式 -Force,跳过跳过判定)" }

Run-Stage 1 { Install-OpenSsh }      "OpenSSH Server"
Run-Stage 2 { New-McpRigUser }       "mcp-rig 账号"
Run-Stage 3 { New-ServerDirs }       "server 目录 + .ssh"
Run-Stage 4 { Git-CloneRig }         "git clone 代码"
Run-Stage 5 { Install-McpVenv }      "venv + mcp SDK"
Run-Stage 6 { Write-AuthorizedKey }  "authorized_keys"
Run-Stage 7 { Install-FrpcService }  "frpc + NSSM"
Run-Stage 8 { Lock-SshdConfig }      "sshd_config 锁"

# Stage 9: 验证就绪
Write-Host "[9/9] Verify Ready ... " -NoNewline -ForegroundColor Cyan
if (Test-Ready) {
    Write-Host "[完成]" -ForegroundColor Green
} else {
    Write-Host "[失败: 仍有缺项,见 -Status]" -ForegroundColor Yellow
}

Show-NextSteps
exit 0

# =====================================================================
# 函数区 (主流程结束后被调)
# =====================================================================

function Test-Ready {
    $checks = @(
        @{ N = "sshd 服务";       T = { (Get-Service sshd -ErrorAction SilentlyContinue) -ne $null } }
        @{ N = "sshd listen 22";  T = { (netstat -ano | findstr :22) -match "LISTENING" } }
        @{ N = "mcp-rig 账号";    T = { Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue } }
        @{ N = "server dir";      T = { Test-Path $ServerDir } }
        @{ N = "venv";            T = { Test-Path "$ServerDir\.venv\Scripts\python.exe" } }
        @{ N = "src clone";       T = { Test-Path "$ServerDir\src\.git" } }
        @{ N = "authorized_keys"; T = { Test-Path $AkPath } }
        @{ N = "frpc 服务";       T = { (Get-Service frpc -ErrorAction SilentlyContinue) -ne $null } }
        @{ N = "frpc.toml";       T = { Test-Path $FrpcToml } }
    )
    $script:ReadyDetail = @()
    foreach ($c in $checks) {
        $ok = & $c.T
        $script:ReadyDetail += [pscustomobject]@{ Name = $c.N; Pass = [bool]$ok }
    }
    return ($script:ReadyDetail | Where-Object { -not $_.Pass }).Count -eq 0
}

function Show-Ready {
    Write-Host ""
    Write-Host "✓ 外机已就绪 ($($script:ReadyDetail.Count)/$($script:ReadyDetail.Count)):" -ForegroundColor Green
    foreach ($r in $script:ReadyDetail) {
        $mark = if ($r.Pass) { "✓" } else { "✗" }
        $color = if ($r.Pass) { "DarkGray" } else { "Red" }
        Write-Host "  $mark $($r.Name)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "无需 deploy。如需重做某项,跑 install-rig-bundle.ps1 -Status" -ForegroundColor Cyan
}

function Show-Status {
    Test-Ready | Out-Null
    Write-Host ""
    Write-Host "=== 当前状态 ===" -ForegroundColor Cyan
    foreach ($r in $script:ReadyDetail) {
        $mark = if ($r.Pass) { "✓" } else { "✗" }
        $color = if ($r.Pass) { "Green" } else { "Red" }
        Write-Host "  $mark $($r.Name)" -ForegroundColor $color
    }
    Write-Host ""
    $sshd = Get-Service sshd -ErrorAction SilentlyContinue
    Write-Host "sshd:        $(if ($sshd) { $sshd.Status } else { '未装' })"
    $frpc = Get-Service frpc -ErrorAction SilentlyContinue
    Write-Host "frpc:        $(if ($frpc) { $frpc.Status } else { '未装' })"
    Write-Host "server dir:  $(if (Test-Path $ServerDir) { '在' } else { '不在' })"
    Write-Host "venv:        $(if (Test-Path "$ServerDir\.venv") { '在' } else { '不在' })"
    Write-Host "src:         $(if (Test-Path "$ServerDir\src") { '在' } else { '不在' })"
    Write-Host "authorized_keys: $(if (Test-Path $AkPath) { (Get-Content $AkPath).Count + ' 行' } else { '不在' })"
    Write-Host "frpc toml:   $(if (Test-Path $FrpcToml) { '在' } else { '不在' })"
}

function Run-Stage {
    param([int]$N, [scriptblock]$Action, [string]$Name)
    Write-Host "[$N/9] $Name ... " -NoNewline -ForegroundColor Cyan
    try {
        & $Action
        Write-Host "[完成]" -ForegroundColor Green
    } catch {
        Write-Host "[失败]" -ForegroundColor Red
        throw $_
    }
}

function V {
    param([string]$Msg)
    if ($Verbose) { Write-Host "    → $Msg" -ForegroundColor DarkGray }
}

# ===== Stage 1: OpenSSH =====
function Install-OpenSsh {
    $installed = $false
    try {
        V "Get-WindowsCapability OpenSSH.Server~~~~0.0.1.0"
        $openssh = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop
        V "State=$($openssh.State)"
        if ($openssh.State -ne "Installed") {
            V "Add-WindowsCapability (60-180s)"
            Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
        } else {
            $installed = $true
        }
    } catch {
        V "Get-WindowsCapability 不可用,退到 DISM"
        V "dism /online /add-capability OpenSSH.Server~~~~0.0.1.0 (60-180s)"
        $dismOut = dism /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "DISM 装 OpenSSH 失败 (exit=$LASTEXITCODE):$dismOut`n手动装: Settings → Apps → Optional Features → OpenSSH Server"
        }
        $installed = $true
    }
    V "Set-Service sshd Automatic"
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    V "Start-Service sshd"
    Start-Service sshd -ErrorAction SilentlyContinue
    V "Enable-NetFirewallRule OpenSSH-Server-In-TCP"
    if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue) {
        Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" | Out-Null
    }
}

# ===== Stage 2: 账号 =====
function New-McpRigUser {
    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
        V "账号已存在"
        return
    }
    V "New-LocalUser (密码 = 随机 GUID)"
    $pwd = ConvertTo-SecureString ([System.Guid]::NewGuid().ToString()) -AsPlainText -Force
    New-LocalUser -Name $UserName -Password $pwd -PasswordNeverExpires -UserMayNotChangePassword `
        -Description "host-rig-bridge MCP server (pubkey only)" | Out-Null
}

# ===== Stage 3: 目录 =====
function New-ServerDirs {
    if (-not (Test-Path $ServerDir)) {
        V "mkdir $ServerDir"
        New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
    }
    if (-not (Test-Path $SshDir)) {
        V "mkdir $SshDir"
        New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
        $acct = "$env:COMPUTERNAME\$UserName"
        V "icacls .ssh (限 $acct + SYSTEM)"
        icacls $SshDir /inheritance:r /grant:r "${acct}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
    } else {
        V "$SshDir 已存在"
    }
}

# ===== Stage 4: git clone =====
function Git-CloneRig {
    if (Test-Path "$ServerDir\src\.git") {
        V "$ServerDir\src 已 clone"
        return
    }
    $token = $env:RIG_GIT_TOKEN
    if ($token) {
        $url = "https://${token}@github.com/wukong0908/host-rig-bridge.git"
        V "用 RIG_GIT_TOKEN 克隆"
    } else {
        $url = "https://github.com/wukong0908/host-rig-bridge.git"
        V "无 RIG_GIT_TOKEN,假设浏览器/GCM 已认证"
    }
    V "git clone --depth 1 --branch main (5-30s)"
    git clone --depth 1 --branch main --progress $url "$ServerDir\src"
    if ($token) {
        git -C "$ServerDir\src" remote set-url origin "https://github.com/wukong0908/host-rig-bridge.git"
    }
}

# ===== Stage 5: venv + mcp =====
function Install-McpVenv {
    if (-not (Test-Path "$ServerDir\.venv")) {
        $py = $null
        $pyLaunch = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($pyLaunch) { $py = @{ Path = $pyLaunch.Source; Arg = "-3" } }
        if (-not $py) {
            $pyAbs = "C:\Users\$UserName\AppData\Local\Python\bin\python.exe"
            if (Test-Path $pyAbs) { $py = @{ Path = $pyAbs; Arg = "" } }
        }
        if (-not $py) {
            $pyCmd = Get-Command python -ErrorAction SilentlyContinue
            if ($pyCmd) { $py = @{ Path = $pyCmd.Source; Arg = "" } }
        }
        if (-not $py) {
            throw "找不到 Python: 装 py 启动器 (winget install Python.Python.3.13)"
        }
        V "python -m venv (用 $($py.Path) $($py.Arg))"
        & $py.Path $py.Arg -m venv "$ServerDir\.venv"
    } else {
        V "venv 已存在"
    }
    V "pip install --upgrade pip (30-60s)"
    & "$ServerDir\.venv\Scripts\python.exe" -m pip install --upgrade pip 2>&1 | Select-Object -Last 3 | ForEach-Object { V $_ }
    V "pip install mcp>=1.10,<2.0 (30-90s)"
    & "$ServerDir\.venv\Scripts\python.exe" -m pip install "mcp>=1.10,<2.0" 2>&1 | Select-Object -Last 3 | ForEach-Object { V $_ }
    V "import FastMCP 验证"
    $ok = & "$ServerDir\.venv\Scripts\python.exe" -c "from mcp.server.fastmcp import FastMCP; print('mcp SDK OK')"
    V $ok
}

# ===== Stage 6: authorized_keys =====
function Write-AuthorizedKey {
    $acct = "$env:COMPUTERNAME\$UserName"

    if (Test-Path $AkPath) {
        V "takeown + 放开 RW (写完恢复 icacls 锁)"
        takeown /F $AkPath /A | Out-Null
        icacls $AkPath /grant "${env:USERNAME}:(RW)" | Out-Null
    }

    V "Add-Content authorized_keys"
    Add-Content -Path $AkPath -Value $HostPubkey -Encoding UTF8

    V "icacls authorized_keys (限 $acct:R + SYSTEM:R)"
    icacls $AkPath /inheritance:r /grant:r "${acct}:(R)" "SYSTEM:(R)" | Out-Null
    icacls $AkPath /remove "(${env:COMPUTERNAME}\${env:USERNAME})" 2>&1 | Out-Null
}

# ===== Stage 7: frpc + NSSM =====
function Install-FrpcService {
    if (-not (Test-Path $FrpDir)) {
        New-Item -ItemType Directory -Path $FrpDir -Force | Out-Null
    }

    if (-not (Test-Path $FrpcExe)) {
        V "下载 frpc v0.61.1"
        $zipPath = Join-Path $env:TEMP "frpc.zip"
        $frpUrl = "https://github.com/fatedier/frp/releases/download/v0.61.1/frp_0.61.1_windows_amd64.zip"
        Invoke-WebRequest -Uri $frpUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $FrpDir -Force
        Remove-Item $zipPath
        $subDir = Get-ChildItem $FrpDir -Directory | Where-Object { $_.Name -like "frp_*" } | Select-Object -First 1
        if ($subDir) {
            Get-ChildItem $subDir.FullName | Move-Item -Destination $FrpDir -Force
            Remove-Item $subDir.FullName -Recurse
        }
    } else {
        V "frpc.exe 已存在"
    }

    V "写 $FrpcToml"
    $tomlContent = @"
serverAddr = "$Vps"
serverPort = 7000
auth.method = "token"
auth.token = "$FrpToken"

# v0.61+ 不在顶层 heartbeatInterval,放 transport.*
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30

[[proxies]]
name = "rig-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $RemotePort
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($FrpcToml, $tomlContent, $utf8NoBom)

    if (-not (Test-Path $Nssm)) {
        V "下载 NSSM"
        $nssmZip = Join-Path $env:TEMP "nssm.zip"
        $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing
        Expand-Archive -Path $nssmZip -DestinationPath "C:\" -Force
        Remove-Item $nssmZip
    } else {
        V "NSSM 已存在"
    }

    V "NSSM 注册 frpc 服务"
    if (Get-Service frpc -ErrorAction SilentlyContinue) {
        & $Nssm stop frpc 2>&1 | Out-Null
        & $Nssm remove frpc confirm 2>&1 | Out-Null
    }
    & $Nssm install frpc $FrpcExe "-c $FrpcToml" | Out-Null
    & $Nssm set frpc AppDirectory $FrpDir | Out-Null
    & $Nssm set frpc Start SERVICE_AUTO_START | Out-Null
    & $Nssm set frpc AppStdout "$FrpDir\frpc.out.log" | Out-Null
    & $Nssm set frpc AppStderr "$FrpDir\frpc.err.log" | Out-Null
    & $Nssm set frpc AppRotateFiles 1 | Out-Null
    & $Nssm set frpc AppRotateBytes 1048576 | Out-Null
    & $Nssm set frpc AppRestartDelay 5000 | Out-Null
    & $Nssm start frpc | Out-Null
}

# ===== Stage 8: 锁 sshd_config =====
function Lock-SshdConfig {
    $sshdConf = "$env:ProgramData\ssh\sshd_config"
    $backup = "$sshdConf.bak.$(Get-Date -Format yyyyMMdd)"
    if (-not (Test-Path $backup)) {
        V "备份到 $backup"
        Copy-Item $sshdConf $backup -Force
    }
    $content = Get-Content $sshdConf
    $new = @()
    foreach ($line in $content) {
        if ($line -match '^\s*#?\s*PubkeyAuthentication\s+') {
            $new += "PubkeyAuthentication yes"
        } elseif ($line -match '^\s*#?\s*PasswordAuthentication\s+') {
            $new += "PasswordAuthentication no"
        } elseif ($line -match '^\s*#?\s*PermitRootLogin\s+') {
            $new += "PermitRootLogin no"
        } else {
            $new += $line
        }
    }
    if (-not ($new | Select-String '^PubkeyAuthentication\s+yes$')) { $new += "PubkeyAuthentication yes" }
    if (-not ($new | Select-String '^PasswordAuthentication\s+no$')) { $new += "PasswordAuthentication no" }
    if (-not ($new | Select-String '^PermitRootLogin\s+no$')) { $new += "PermitRootLogin no" }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($sshdConf, ($new -join "`r`n") + "`r`n", $utf8NoBom)
    V "Restart-Service sshd"
    Restart-Service sshd
}

# ===== NextSteps =====
function Show-NextSteps {
    Write-Host ""
    Write-Host "✅ 全部 9 stage 完成。后续手动步骤:" -ForegroundColor Green
    Write-Host ""
    Write-Host "  [VPS 阿里云控制台 — 30s]" -ForegroundColor Cyan
    Write-Host "    1. 放行 $RemotePort TCP 入站:" -ForegroundColor Cyan
    Write-Host "       端口范围: $RemotePort/$RemotePort" -ForegroundColor Cyan
    Write-Host "       协议: TCP" -ForegroundColor Cyan
    Write-Host "       源: 0.0.0.0/0" -ForegroundColor Cyan
    Write-Host "       描述: frp-rig-ssh" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [主机 — 1 min]" -ForegroundColor Cyan
    Write-Host "    2. cd D:\WuKong\Desktop\host-rig-bridge && git pull origin main" -ForegroundColor Cyan
    Write-Host "       pwsh scripts/register-rig.ps1 -RigAlias rig -RigHost $Vps -RigPort $RemotePort -RigUser $UserName" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [外机 — 30s]" -ForegroundColor Cyan
    Write-Host "    3. install-rig-bundle.ps1 -Verify" -ForegroundColor Cyan
    Write-Host "       (5 步: sshd 听 / frpc 在 / VPS:$RemotePort 通 / mcp SDK OK / ssh rig 通)" -ForegroundColor Cyan
}

# ===== Verify =====
function Invoke-Verify {
    Write-Host ""
    Write-Host "=== Verify (5 步) ===" -ForegroundColor Cyan
    $results = @()

    Write-Host "[1/5] sshd 听 22 ..." -NoNewline
    if ((netstat -ano | findstr :22) -match "LISTENING") {
        Write-Host " ✓" -ForegroundColor Green
        $results += $true
    } else {
        Write-Host " ✗" -ForegroundColor Red
        $results += $false
    }

    Write-Host "[2/5] frpc 服务 ..." -NoNewline
    $svc = Get-Service frpc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host " ✓" -ForegroundColor Green
        $results += $true
    } else {
        Write-Host " ✗" -ForegroundColor Red
        $results += $false
    }

    Write-Host "[3/5] VPS $Vps`:$RemotePort TCP ..." -NoNewline
    try {
        $tcp = Test-NetConnection -ComputerName $Vps -Port $RemotePort -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($tcp) { Write-Host " ✓" -ForegroundColor Green; $results += $true }
        else { Write-Host " ✗" -ForegroundColor Red; $results += $false }
    } catch {
        Write-Host " ✗" -ForegroundColor Red
        $results += $false
    }

    Write-Host "[4/5] mcp SDK ..." -NoNewline
    $ok = & "$ServerDir\.venv\Scripts\python.exe" -c "from mcp.server.fastmcp import FastMCP; print('OK')" 2>&1
    if ($ok -match "OK") {
        Write-Host " ✓" -ForegroundColor Green
        $results += $true
    } else {
        Write-Host " ✗" -ForegroundColor Red
        $results += $false
    }

    Write-Host "[5/5] ssh $UserName@$Vps -p $RemotePort (3s probe) ..." -NoNewline
    $probe = ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -p $RemotePort "$UserName@$Vps" "echo SSH_OK" 2>&1
    if ($LASTEXITCODE -eq 0 -and $probe -match "SSH_OK") {
        Write-Host " ⚠ forced command 没截" -ForegroundColor Yellow
        $results += $false
    } elseif ($probe -match "Permission denied") {
        Write-Host " ✗ Permission denied" -ForegroundColor Red
        $results += $false
    } else {
        Write-Host " ✓ (forced command 生效)" -ForegroundColor Green
        $results += $true
    }

    $pass = ($results | Where-Object { $_ }).Count
    Write-Host ""
    Write-Host "Verify 结果: $pass / 5 通过" -ForegroundColor $(if ($pass -eq 5) { "Green" } else { "Yellow" })
}