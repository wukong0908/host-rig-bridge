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
#   install-rig-bundle.ps1 -Verify    # 5 步验证
#   install-rig-bundle.ps1 -Status    # 显示当前状态
#   install-rig-bundle.ps1 -Force     # 跳过 Ready 检查强制重跑
#   install-rig-bundle.ps1 -Verbose   # 展开 stage 内子步骤

[CmdletBinding()]
param([switch]$Verify, [switch]$Status, [switch]$Force)

$ErrorActionPreference = "Stop"

$UserName  = "mcp-rig"
$ServerDir = "C:\Users\$UserName\mcp-server"
$SshDir    = "C:\Users\$UserName\.ssh"
$AkPath    = "$SshDir\authorized_keys"
$FrpDir    = "C:\frp"
$FrpcExe   = "$FrpDir\frpc.exe"
$FrpcToml  = "$FrpDir\frpc.toml"
$Nssm      = "C:\nssm-2.24\win64\nssm.exe"

# ===== helpers =====

function V { param($m) if ($Verbose) { Write-Host "    → $m" -ForegroundColor DarkGray } }

function Write-Utf8 { param($Path, $Text) [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }

function If-Skip {
    param([scriptblock]$Test, [string]$Name)
    if (& $Test) { V "$Name 已存在,跳过"; return $true }
    return $false
}

$ReadyChecks = @(
    @{ N = "sshd 服务";       T = { (Get-Service sshd -EA SilentlyContinue) -ne $null } }
    @{ N = "sshd listen 22";  T = { (netstat -ano | findstr :22) -match "LISTENING" } }
    @{ N = "mcp-rig 账号";    T = { Get-LocalUser -Name $UserName -EA SilentlyContinue } }
    @{ N = "server dir";      T = { Test-Path $ServerDir } }
    @{ N = "venv";            T = { Test-Path "$ServerDir\.venv\Scripts\python.exe" } }
    @{ N = "src clone";       T = { Test-Path "$ServerDir\src\.git" } }
    @{ N = "authorized_keys"; T = { Test-Path $AkPath } }
    @{ N = "frpc 服务";       T = { (Get-Service frpc -EA SilentlyContinue) -ne $null } }
    @{ N = "frpc.toml";       T = { Test-Path $FrpcToml } }
)

function Test-Ready {
    $script:ReadyDetail = @()
    foreach ($c in $ReadyChecks) {
        $script:ReadyDetail += [pscustomobject]@{ Name = $c.N; Pass = [bool](& $c.T) }
    }
    return ($script:ReadyDetail | Where-Object { -not $_.Pass }).Count -eq 0
}

function Show-ReadyTable {
    Write-Host ""
    $title = if ($Status) { "=== 当前状态 ===" } else { "✓ 外机已就绪 ($($script:ReadyDetail.Count)/$($script:ReadyDetail.Count)):" }
    Write-Host $title -ForegroundColor Cyan
    foreach ($r in $script:ReadyDetail) {
        $mark = if ($r.Pass) { "✓" } else { "✗" }
        Write-Host "  $mark $($r.Name)" -ForegroundColor $(if ($r.Pass) { "DarkGray" } else { "Red" })
    }
    if ($Status) {
        Write-Host ""
        $sshd = Get-Service sshd -EA SilentlyContinue; Write-Host "sshd: $(if ($sshd) { $sshd.Status } else { '未装' })"
        $frpc = Get-Service frpc -EA SilentlyContinue; Write-Host "frpc: $(if ($frpc) { $frpc.Status } else { '未装' })"
        Write-Host "authorized_keys: $(if (Test-Path $AkPath) { (Get-Content $AkPath).Count + ' 行' } else { '不在' })"
    } else {
        Write-Host ""
        Write-Host "无需 deploy。如需重做某项,跑 install-rig-bundle.ps1 -Status" -ForegroundColor Cyan
    }
}

function Invoke-Verify {
    Test-Ready | Out-Null
    Show-ReadyTable
    if ($Status) { exit 0 }

    Write-Host ""
    Write-Host "=== Verify (5 步) ===" -ForegroundColor Cyan
    $pass = 0
    function Step([int]$n, [string]$name, [scriptblock]$test) {
        Write-Host "[$n/5] $name ..." -NoNewline
        if (& $test) { Write-Host " ✓" -ForegroundColor Green; $script:pass++ }
        else { Write-Host " ✗" -ForegroundColor Red }
    }
    $script:pass = 0
    Step 1 "sshd 听 22"           { (netstat -ano | findstr :22) -match "LISTENING" }
    Step 2 "frpc 服务 Running"    { (Get-Service frpc -EA SilentlyContinue).Status -eq "Running" }
    Step 3 "VPS $Vps`:$RemotePort TCP" { (Test-NetConnection $Vps -Port $RemotePort -InformationLevel Quiet -WarningAction SilentlyContinue) }
    Step 4 "mcp SDK"              { (& "$ServerDir\.venv\Scripts\python.exe" -c "from mcp.server.fastmcp import FastMCP" 2>&1) -match $null }
    Step 5 "ssh $UserName@$Vps"   {
        $probe = ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -p $RemotePort "$UserName@$Vps" "echo SSH_OK" 2>&1
        if ($LASTEXITCODE -eq 0 -and $probe -match "SSH_OK") { return $false }  # forced command 没截 = 失败
        if ($probe -match "Permission denied") { return $false }
        return $true
    }
    Write-Host ""
    Write-Host "Verify 结果: $pass / 5 通过" -ForegroundColor $(if ($pass -eq 5) { "Green" } else { "Yellow" })
}

function Show-NextSteps {
    Write-Host ""
    Write-Host "✅ 后续手动步骤:" -ForegroundColor Green
    Write-Host "  [VPS 阿里云控制台]" -ForegroundColor Cyan
    Write-Host "    放行 TCP $RemotePort 入站 (源 0.0.0.0/0,描述 frp-rig-ssh)" -ForegroundColor Cyan
    Write-Host "  [主机]" -ForegroundColor Cyan
    Write-Host "    cd D:\WuKong\Desktop\host-rig-bridge && git pull origin main" -ForegroundColor Cyan
    Write-Host "    pwsh scripts/register-rig.ps1 -RigAlias rig -RigHost $Vps -RigPort $RemotePort -RigUser $UserName" -ForegroundColor Cyan
    Write-Host "  [外机]" -ForegroundColor Cyan
    Write-Host "    install-rig-bundle.ps1 -Verify" -ForegroundColor Cyan
}

# ===== stage 函数 =====

function Install-OpenSsh {
    try {
        $openssh = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -EA Stop
        if ($openssh.State -ne "Installed") { Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null }
    } catch {
        $out = dism /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 2>&1
        if ($LASTEXITCODE -ne 0) { throw "DISM 装 OpenSSH 失败 (exit=$LASTEXITCODE). 手动装: Settings → Apps → Optional Features → OpenSSH Server" }
    }
    Set-Service sshd -StartupType Automatic -EA SilentlyContinue
    Start-Service sshd -EA SilentlyContinue
    if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -EA SilentlyContinue) {
        Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" | Out-Null
    }
}

function New-McpRigUser {
    if (If-Skip { Get-LocalUser -Name $UserName -EA SilentlyContinue } "mcp-rig 账号") { return }
    $pwd = ConvertTo-SecureString ([Guid]::NewGuid().ToString()) -AsPlainText -Force
    New-LocalUser -Name $UserName -Password $pwd -PasswordNeverExpires -UserMayNotChangePassword `
        -Description "host-rig-bridge MCP server (pubkey only)" | Out-Null
}

function New-ServerDirs {
    if (-not (Test-Path $ServerDir)) { New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null }
    if (-not (Test-Path $SshDir))    { New-Item -ItemType Directory -Path $SshDir    -Force | Out-Null }
}

function Git-CloneRig {
    if (If-Skip { Test-Path "$ServerDir\src\.git" } "src clone") { return }
    $token = $env:RIG_GIT_TOKEN
    $url = if ($token) { "https://${token}@github.com/wukong0908/host-rig-bridge.git" } else { "https://github.com/wukong0908/host-rig-bridge.git" }
    git clone --depth 1 --branch main --progress $url "$ServerDir\src"
    if ($token) { git -C "$ServerDir\src" remote set-url origin "https://github.com/wukong0908/host-rig-bridge.git" }
}

function Install-McpVenv {
    if (-not (Test-Path "$ServerDir\.venv")) {
        & py.exe -3 -m venv "$ServerDir\.venv"
    }
    $py = "$ServerDir\.venv\Scripts\python.exe"
    & $py -m pip install --upgrade pip 2>&1 | Select-Object -Last 1 | ForEach-Object { V $_ }
    & $py -m pip install "mcp>=1.10,<2.0" 2>&1 | Select-Object -Last 1 | ForEach-Object { V $_ }
}

function Write-AuthorizedKey {
    if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }
    if (Test-Path $AkPath) { Remove-Item $AkPath -Force -EA SilentlyContinue }
    Write-Utf8 $AkPath ($HostPubkey + "`r`n")
}

function Install-FrpcService {
    if (-not (Test-Path $FrpDir)) { New-Item -ItemType Directory -Path $FrpDir -Force | Out-Null }
    if (-not (Test-Path $FrpcExe)) {
        $zip = Join-Path $FrpDir "frpc.zip"
        (New-Object System.Net.WebClient).DownloadFile("https://github.com/fatedier/frp/releases/download/v0.61.1/frp_0.61.1_windows_amd64.zip", $zip)
        Expand-Archive $zip $FrpDir -Force
        Remove-Item $zip
        $sub = Get-ChildItem $FrpDir -Directory | Where-Object { $_.Name -like "frp_*" } | Select-Object -First 1
        if ($sub) { Get-ChildItem $sub.FullName | Move-Item -Destination $FrpDir -Force; Remove-Item $sub.FullName -Recurse }
    }
    Write-Utf8 $FrpcToml @"
serverAddr = "$Vps"
serverPort = 7000
auth.method = "token"
auth.token = "$FrpToken"
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30
[[proxies]]
name = "rig-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $RemotePort
"@
    if (-not (Test-Path $Nssm)) {
        $nssmZip = "C:\nssm.zip"
        (New-Object System.Net.WebClient).DownloadFile("https://nssm.cc/release/nssm-2.24.zip", $nssmZip)
        Expand-Archive $nssmZip "C:\" -Force
        Remove-Item $nssmZip
    }
    if (Get-Service frpc -EA SilentlyContinue) { & $Nssm stop frpc 2>&1 | Out-Null; & $Nssm remove frpc confirm 2>&1 | Out-Null }
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

function Lock-SshdConfig {
    $sshdConf = "$env:ProgramData\ssh\sshd_config"
    if (-not (Test-Path "$sshdConf.bak")) { Copy-Item $sshdConf "$sshdConf.bak" -Force }
    $content = Get-Content $sshdConf -Raw
    $content = $content -replace '^\s*#?\s*PubkeyAuthentication\s+.*',   'PubkeyAuthentication yes'
    $content = $content -replace '^\s*#?\s*PasswordAuthentication\s+.*', 'PasswordAuthentication no'
    $content = $content -replace '^\s*#?\s*PermitRootLogin\s+.*',        'PermitRootLogin no'
    if ($content -notmatch '^PubkeyAuthentication\s+yes$')   { $content += "`r`nPubkeyAuthentication yes" }
    if ($content -notmatch '^PasswordAuthentication\s+no$')  { $content += "`r`nPasswordAuthentication no" }
    if ($content -notmatch '^PermitRootLogin\s+no$')         { $content += "`r`nPermitRootLogin no" }
    Write-Utf8 $sshdConf $content
    Restart-Service sshd
}

# ===== 主流程 =====

$Vps        = $env:RIG_VPS
$FrpToken   = $env:RIG_FRP_TOKEN
$RemotePort = $env:RIG_REMOTE_PORT
$HostPubkey = $env:RIG_HOST_PUBKEY

if ($Status) { Invoke-Verify -Status $true; exit 0 }
if ($Verify) { Invoke-Verify; exit 0 }

if (-not $Vps -or -not $FrpToken -or -not $RemotePort -or -not $HostPubkey) {
    Write-Host "❌ deploy 模式需 4 个环境变量:" -ForegroundColor Red
    Write-Host '   $env:RIG_VPS         = "8.163.106.31"' -ForegroundColor Red
    Write-Host '   $env:RIG_FRP_TOKEN   = "<同家里 frpc 的 token>"' -ForegroundColor Red
    Write-Host '   $env:RIG_REMOTE_PORT = "6001"' -ForegroundColor Red
    Write-Host '   $env:RIG_HOST_PUBKEY = "<forced command + 主机公钥 整行>"' -ForegroundColor Red
    Write-Host ""
    Write-Host "子命令不需: install-rig-bundle.ps1 -Verify / -Status" -ForegroundColor Yellow
    exit 1
}

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "需要管理员 PowerShell. 右键 → 以管理员身份运行."
}

$ready = Test-Ready
if ($ready -and -not $Force) {
    Show-ReadyTable
    Show-NextSteps
    exit 0
}

Write-Host ""
Write-Host "🚀 开始 deploy (9 stage):" -ForegroundColor Cyan

function Do([int]$n, [string]$name, [scriptblock]$action) {
    Write-Host "[$n/9] $name ... " -NoNewline -ForegroundColor Cyan
    try { & $action; Write-Host "[完成]" -ForegroundColor Green }
    catch { Write-Host "[失败]" -ForegroundColor Red; throw }
}

Do 1 "OpenSSH Server"     { Install-OpenSsh }
Do 2 "mcp-rig 账号"        { New-McpRigUser }
Do 3 "server 目录 + .ssh"  { New-ServerDirs }
Do 4 "git clone 代码"      { Git-CloneRig }
Do 5 "venv + mcp SDK"      { Install-McpVenv }
Do 6 "authorized_keys"     { Write-AuthorizedKey }
Do 7 "frpc + NSSM"         { Install-FrpcService }
Do 8 "sshd_config 锁"      { Lock-SshdConfig }

Write-Host "[9/9] Verify Ready ... " -NoNewline -ForegroundColor Cyan
if (Test-Ready) { Write-Host "[完成]" -ForegroundColor Green } else { Write-Host "[失败: 见 -Status]" -ForegroundColor Yellow }

Show-NextSteps