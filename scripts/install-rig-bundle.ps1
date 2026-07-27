# install-rig-bundle.ps1 — 外机一键 deploy (链路 B)
# 装 OpenSSH + 建账号 + 拉代码 + 建 venv + 装 mcp + 写 authorized_keys + 装 frpc + 锁 sshd
#
# 版本: 改此文件前先跑 scripts/bump-version.ps1 (自动 +0.0.1 + commit [bump] 信息)
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
#   install-rig-bundle.ps1 -Status    # 显示当前状态 (含版本 + commit)
#   install-rig-bundle.ps1 -Force     # 跳过 Ready 检查强制重跑
#   install-rig-bundle.ps1 -Verbose   # 展开 stage 内子步骤
#   install-rig-bundle.ps1 -Auto      # 跳过 deploy 前确认 (无人值守)

[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$Status,
    [switch]$Force,
    [switch]$Auto   # 跳过 deploy 前确认 (无人值守/主机调用)
)

$ScriptVersion = "0.9.11"
# commit 由 git 自动注入:本地跑 = 本地 HEAD;iex 拉 = GitHub raw CDN 抓到的 commit (需 GitHub 提供)
# iwr Content 模式拿不到 commit,所以版本自报只显示 \$ScriptVersion,commit 由主人查 git log 补

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

# stage → ReadyCheck 名字映射 (deploy 时只看对应 ReadyCheck 决定跑不跑)
$StageMap = [ordered]@{
    1 = @("sshd 服务", "sshd listen 22")
    2 = @("mcp-rig 账号")
    3 = @("server dir")
    4 = @("src clone")
    5 = @("venv")
    6 = @("authorized_keys")
    7 = @("frpc 服务", "frpc.toml")
    8 = @()  # sshd_config 锁不在 ReadyCheck,总是跑(幂等覆盖)
    9 = @()  # Verify Ready 总是跑
}

function Should-Stage {
    param([int]$N)
    if ($Force) { return $true }
    $names = $StageMap[[string]$N]
    if (-not $names -or $names.Count -eq 0) { return $true }
    $missing = $script:ReadyDetail | Where-Object { -not $_.Pass } | ForEach-Object { $_.Name }
    foreach ($n in $names) { if ($missing -contains $n) { return $true } }
    return $false
}

function Step-In {
    param([int]$N, [string]$Sub, [string]$Status = "")
    $tag = if ($Status) { " [$Status]" } else { "" }
    Write-Host "  [$N.$Sub]$tag" -ForegroundColor DarkGray
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
    Write-Host "[版本 v$ScriptVersion]" -ForegroundColor DarkGray
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
    # 三层快路径:
    #   1) Get-Service sshd <100ms — 已装
    #   2) CBS 注册表包 <200ms — 装过但服务没起
    #   3) dism /add-capability — 真没装(慢但 Win11 兼容)
    $sshdSvc = Get-Service sshd -EA SilentlyContinue
    if ($sshdSvc) {
        Step-In 1 "1 sshd 服务已注册 (Get-Service, ~20ms) — 跳过装"
    } else {
        $cbs = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackageIndex\OpenSSH-Server~~~~0.0.1.0" -EA SilentlyContinue
        if ($cbs) {
            Step-In 1 "1 CBS 包已注册 (~200ms) — 装过,跳"
        } else {
            Step-In 1 "1 真没装, dism /add-capability (60-180s)"
            $installOut = dism /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "DISM 装 OpenSSH 失败 (exit=$LASTEXITCODE):$installOut`n手动装: Settings → Apps → Optional Features → OpenSSH Server"
            }
            Step-In 1 "2 OpenSSH 装完"
        }
    }
    Step-In 1 "3 设 sshd 自动启动 + 启动"
    Set-Service sshd -StartupType Automatic -EA SilentlyContinue
    Start-Service sshd -EA SilentlyContinue
    Step-In 1 "4 放行防火墙 OpenSSH-Server-In-TCP"
    if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -EA SilentlyContinue) {
        Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" | Out-Null
    }
}

function New-McpRigUser {
    if (If-Skip { Get-LocalUser -Name $UserName -EA SilentlyContinue } "mcp-rig 账号") { return }
    Step-In 2 "1 生成随机密码 (GUID)"
    $pwd = ConvertTo-SecureString ([Guid]::NewGuid().ToString()) -AsPlainText -Force
    Step-In 2 "2 New-LocalUser (密码永不过期,只能 pubkey)"
    New-LocalUser -Name $UserName -Password $pwd -PasswordNeverExpires -UserMayNotChangePassword `
        -Description "host-rig-bridge MCP server (pubkey only)" | Out-Null
}

function New-ServerDirs {
    if (-not (Test-Path $ServerDir)) {
        Step-In 3 "1 mkdir $ServerDir"
        New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
    } else { Step-In 3 "1 $ServerDir 已存在" }
    if (-not (Test-Path $SshDir)) {
        Step-In 3 "2 mkdir $SshDir (Windows 默认 ACL)"
        New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    } else { Step-In 3 "2 $SshDir 已存在" }
}

function Git-CloneRig {
    if (If-Skip { Test-Path "$ServerDir\src\.git" } "src clone") { return }
    $token = $env:RIG_GIT_TOKEN
    $url = if ($token) { "https://${token}@github.com/wukong0908/host-rig-bridge.git" } else { "https://github.com/wukong0908/host-rig-bridge.git" }
    if ($token) { Step-In 4 "1 用 RIG_GIT_TOKEN 克隆 (5-30s)" } else { Step-In 4 "1 无 TOKEN,假设已认证,克隆 (5-30s)" }
    git clone --depth 1 --branch main --progress $url "$ServerDir\src"
    if ($token) {
        Step-In 4 "2 清掉 remote URL 里的 token"
        git -C "$ServerDir\src" remote set-url origin "https://github.com/wukong0908/host-rig-bridge.git"
    }
}

function Install-McpVenv {
    if (-not (Test-Path "$ServerDir\.venv")) {
        Step-In 5 "1 py -3 -m venv"
        & py.exe -3 -m venv "$ServerDir\.venv"
    } else { Step-In 5 "1 venv 已存在" }
    $py = "$ServerDir\.venv\Scripts\python.exe"
    Step-In 5 "2 pip install --upgrade pip (30-60s)"
    & $py -m pip install --upgrade pip 2>&1 | Select-Object -Last 1 | ForEach-Object { V $_ }
    Step-In 5 "3 pip install mcp>=1.10,<2.0 (30-90s)"
    & $py -m pip install "mcp>=1.10,<2.0" 2>&1 | Select-Object -Last 1 | ForEach-Object { V $_ }
}

function Write-AuthorizedKey {
    if (-not (Test-Path $SshDir)) {
        Step-In 6 "1 mkdir $SshDir"
        New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    }
    if (Test-Path $AkPath) {
        Step-In 6 "2 删旧 authorized_keys"
        Remove-Item $AkPath -Force -EA SilentlyContinue
    }
    Step-In 6 "3 写新 authorized_keys (UTF8 无 BOM)"
    try {
        Write-Utf8 $AkPath ($HostPubkey + "`r`n")
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        # 前几版 icacls /grant:r 把 .ssh 目录 Administrators:F 剥离 → 管理员写文件 Access Denied
        # 自动恢复: 用 cmd /c rd /s /q 砍 .ssh 整目录 (cmd 走 Win32 不被 PS ACL 拦截) + 重 mkdir
        Step-In 6 "3.1 写失败 (旧 ACL 中毒),cmd /c rd /s /q 砍 .ssh"
        cmd /c "rd /s /q `"$SshDir`"" 2>&1 | Out-Null
        New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
        Step-In 6 "3.2 重写 authorized_keys"
        Write-Utf8 $AkPath ($HostPubkey + "`r`n")
    }
}

function Install-FrpcService {
    if (-not (Test-Path $FrpDir)) {
        Step-In 7 "1 mkdir $FrpDir"
        New-Item -ItemType Directory -Path $FrpDir -Force | Out-Null
    }
    if (-not (Test-Path $FrpcExe)) {
        Step-In 7 "2 下载 frpc v0.61.1 (WebClient 绕 Defender)"
        $zip = Join-Path $FrpDir "frpc.zip"
        (New-Object System.Net.WebClient).DownloadFile("https://github.com/fatedier/frp/releases/download/v0.61.1/frp_0.61.1_windows_amd64.zip", $zip)
        Step-In 7 "3 解压 + 整理子目录"
        Expand-Archive $zip $FrpDir -Force
        Remove-Item $zip
        $sub = Get-ChildItem $FrpDir -Directory | Where-Object { $_.Name -like "frp_*" } | Select-Object -First 1
        if ($sub) { Get-ChildItem $sub.FullName | Move-Item -Destination $FrpDir -Force; Remove-Item $sub.FullName -Recurse }
    } else { Step-In 7 "2-3 frpc.exe 已存在" }
    Step-In 7 "4 写 $FrpcToml (心跳放 transport.*)"
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
        Step-In 7 "5 下载 NSSM (WebClient 绕 Defender)"
        $nssmZip = "C:\nssm.zip"
        (New-Object System.Net.WebClient).DownloadFile("https://nssm.cc/release/nssm-2.24.zip", $nssmZip)
        Expand-Archive $nssmZip "C:\" -Force
        Remove-Item $nssmZip
    } else { Step-In 7 "5 NSSM 已存在" }
    if (Get-Service frpc -EA SilentlyContinue) {
        Step-In 7 "6 停 + 删旧 frpc 服务 (重注册)"
        & $Nssm stop frpc 2>&1 | Out-Null; & $Nssm remove frpc confirm 2>&1 | Out-Null
    }
    Step-In 7 "7 NSSM install frpc + 7 个 set + start"
    & $Nssm install frpc $FrpcExe "-c $FrpcToml" | Out-Null
    & $Nssm set frpc AppDirectory $FrpDir | Out-Null
    & $Nssm set frpc Start SERVICE_AUTO_START | Out-Null
    & $Nssm set frpc AppStdout "$FrpDir\frpc.out.log" | Out-Null
    & $Nssm set frpc AppStderr "$FrpDir\frpc.err.log" | Out-Null
    & $Nssm set frpc AppRotateFiles 1 | Out-Null
    & $Nssm set frpc AppRotateBytes 10485760 | Out-Null
    & $Nssm set frpc AppRestartDelay 5000 | Out-Null
    & $Nssm start frpc | Out-Null
}

function Lock-SshdConfig {
    $sshdConf = "$env:ProgramData\ssh\sshd_config"
    if (-not (Test-Path "$sshdConf.bak")) {
        Step-In 8 "1 备份 sshd_config → sshd_config.bak"
        Copy-Item $sshdConf "$sshdConf.bak" -Force
    } else { Step-In 8 "1 已有备份" }
    Step-In 8 "2 regex 替换 3 项 (Pubkey/Password/PermitRoot)"
    $content = Get-Content $sshdConf -Raw
    $content = $content -replace '^\s*#?\s*PubkeyAuthentication\s+.*',   'PubkeyAuthentication yes'
    $content = $content -replace '^\s*#?\s*PasswordAuthentication\s+.*', 'PasswordAuthentication no'
    $content = $content -replace '^\s*#?\s*PermitRootLogin\s+.*',        'PermitRootLogin no'
    if ($content -notmatch '^PubkeyAuthentication\s+yes$')   { $content += "`r`nPubkeyAuthentication yes" }
    if ($content -notmatch '^PasswordAuthentication\s+no$')  { $content += "`r`nPasswordAuthentication no" }
    if ($content -notmatch '^PermitRootLogin\s+no$')         { $content += "`r`nPermitRootLogin no" }
    Write-Utf8 $sshdConf $content
    Step-In 8 "3 Restart-Service sshd"
    Restart-Service sshd
}

# ===== 主流程 =====

$Vps        = $env:RIG_VPS
$FrpToken   = $env:RIG_FRP_TOKEN
$RemotePort = $env:RIG_REMOTE_PORT
$HostPubkey = $env:RIG_HOST_PUBKEY

if ($Status) { Invoke-Verify; exit 0 }
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
Write-Host "[版本 v$ScriptVersion]" -ForegroundColor DarkGray
if ($Force) {
    Write-Host "🚀 开始 deploy (9 stage, 强制模式 -Force, 全跑):" -ForegroundColor Cyan
} else {
    $missing = $script:ReadyDetail | Where-Object { -not $_.Pass }
    Write-Host "🚀 开始 deploy (缺 $($missing.Count) 项):" -ForegroundColor Cyan
    foreach ($m in $missing) { Write-Host "    ✗ $($m.Name)" -ForegroundColor Yellow }
}

# 交互确认 (deploy 模式 + 非 -Auto)
if (-not $Auto) {
    Write-Host ""
    Write-Host "准备 deploy (链路 B frp):" -ForegroundColor Yellow
    Write-Host "  VPS:         $Vps"
    Write-Host "  RemotePort:  $RemotePort"
    Write-Host "  mcp-rig 账号: $UserName"
    $answer = Read-Host "确认 deploy? [Y/n]"
    if ($answer -match '^[Nn]') {
        Write-Host "已取消。" -ForegroundColor Yellow
        exit 0
    }
}

function Run([int]$n, [string]$name, [scriptblock]$action) {
    Write-Host "[$n/9] $name ... " -NoNewline -ForegroundColor Cyan
    try { & $action; Write-Host "[完成]" -ForegroundColor Green }
    catch { Write-Host "[失败]" -ForegroundColor Red; throw }
}

function Skip([int]$n, [string]$name) {
    Write-Host "[$n/9] $name ... [跳过: 已就绪]" -ForegroundColor DarkGray
}

$Stages = @(
    @{ N = 1; Name = "OpenSSH Server";     A = { Install-OpenSsh } }
    @{ N = 2; Name = "mcp-rig 账号";        A = { New-McpRigUser } }
    @{ N = 3; Name = "server 目录 + .ssh";  A = { New-ServerDirs } }
    @{ N = 4; Name = "git clone 代码";      A = { Git-CloneRig } }
    @{ N = 5; Name = "venv + mcp SDK";      A = { Install-McpVenv } }
    @{ N = 6; Name = "authorized_keys";     A = { Write-AuthorizedKey } }
    @{ N = 7; Name = "frpc + NSSM";         A = { Install-FrpcService } }
    @{ N = 8; Name = "sshd_config 锁";      A = { Lock-SshdConfig } }
)

foreach ($s in $Stages) {
    if (Should-Stage $s.N) { Run $s.N $s.Name $s.A } else { Skip $s.N $s.Name }
}

Write-Host "[9/9] Verify Ready ... " -NoNewline -ForegroundColor Cyan
if (Test-Ready) { Write-Host "[完成]" -ForegroundColor Green } else { Write-Host "[失败: 见 -Status]" -ForegroundColor Yellow }

Show-NextSteps