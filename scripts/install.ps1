# install.ps1 — Windows 外机一次性 setup (等价 Linux install.sh)
# 用法 (管理员 PowerShell 7.1+, 在外机上跑):
#   iwr -useb https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install.ps1 | iex `
#       -UserName mcp-rig -ServerDir C:\Users\mcp-rig\mcp-server -Sandbox C:\Users\mcp-rig\projects
# 或:
#   Invoke-WebRequest .../install.ps1 -OutFile install.ps1
#   .\install.ps1 -UserName mcp-rig -ServerDir C:\Users\mcp-rig\mcp-server -Sandbox C:\Users\mcp-rig\projects
#
# 硬要求: PowerShell 7.1+ (PS 5.1 不兼容, preflight 拦)
# 必传: -UserName / -ServerDir / -Sandbox (路径不固定, 防误装)
# 选传: -GitToken (私有仓 clone 需 PAT)
#
# 行为:
#   0. Preflight 体检 (pwsh / python / git / OpenSSH / 网络)
#   1. 建 mcp-rig 本地账号 (密码 = 随机 GUID, 只走 pubkey)
#   2. 建 server 目录 C:\Users\mcp-rig\mcp-server
#   3. git clone 拉代码
#   4. 建 venv + 装 mcp[server]
#   5. 建沙箱 C:\Users\mcp-rig\projects
#   6. 装 OpenSSH Server (若未装) + 启 sshd
#   7. 不写 authorized_keys (需主机公钥, 留给 register-rig.ps1 提示)

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$UserName,
    [string]$Repo = "wukong0908/host-rig-bridge",
    [string]$Branch = "main",
    # ServerDir 必传 — 不固定位置, 防误装
    [Parameter(Mandatory)]
    [string]$ServerDir,
    [Parameter(Mandatory)]
    [string]$Sandbox,
    # PAT 走 clone (private repo iwr | bash 拿不到 raw URL; 主人在自己机手输)
    [string]$GitToken = ""
)

$ErrorActionPreference = "Stop"

function Write-Stage {
    param([int]$N, [int]$Total, [string]$Msg)
    Write-Host "[$N/$Total] $Msg" -ForegroundColor Cyan
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal $id
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "需要管理员 PowerShell. 右键 PowerShell → 以管理员身份运行."
    }
}

function Test-Preflight {
    # 体检: pwsh 版本 / Python / git / OpenSSH capability / 网络
    $report = [ordered]@{
        pwsh      = $false
        python    = $false
        git       = $false
        openssh   = $false
        internet  = $false
    }
    $report.pwsh = $PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 1
    if (-not $report.pwsh) {
        # pwsh 7.1+ 是硬要求, 下面 throw 兜底
        Write-Verbose "PowerShell 7.1+ 未装 (当前 $($PSVersionTable.PSVersion))"
    }

    $pyCmd = Get-Command py.exe -ErrorAction SilentlyContinue
    $pyAbs = "C:\Users\$UserName\AppData\Local\Python\bin\python.exe"
    if ($pyCmd -or (Test-Path $pyAbs)) { $report.python = $true }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { $report.git = $true }

    $sshCap = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction SilentlyContinue
    if ($sshCap -and $sshCap.State -in @("Installed", "InstallPending")) {
        $report.openssh = $true
    }

    try {
        $null = Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 -Method Head
        $report.internet = $true
    } catch {
        $report.internet = $false
    }

    Write-Host ""
    Write-Host "=== Preflight 体检 ===" -ForegroundColor Cyan
    foreach ($k in $report.Keys) {
        $mark = if ($report[$k]) { "✓" } else { "✗" }
        $color = if ($report[$k]) { "Green" } else { "Red" }
        Write-Host ("  {0} {1}" -f $mark, $k) -ForegroundColor $color
    }
    Write-Host ""

    $missing = $report.GetEnumerator() | Where-Object { -not $_.Value -and $_.Key -ne "openssh" } | ForEach-Object { $_.Key }
    # openssh 缺可自动装 (stage 6), 不算 fatal
    if ($missing -contains "python") {
        Write-Error "缺 Python — 装: winget install --id Python.Python.3.13 -e   (3.13 当前 stable latest, 后续 winget upgrade 跟新)"
    }
    if ($missing -contains "git") {
        Write-Error "缺 git — 装: winget install --id Git.Git -e"
    }
    if ($missing -contains "internet") {
        Write-Error "无网络 (github.com 不可达), 检查代理/DNS"
    }
    if ($missing -contains "pwsh") {
        Write-Error "缺 PowerShell 7.1+ — 装: winget install --id Microsoft.PowerShell -e"
    }

    if ($missing -match "python|git|internet|pwsh") {
        throw "Preflight 失败, 请先补齐上面缺失项再跑"
    }
}

Assert-Admin

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          host-rig-bridge Windows 外机安装                     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "参数:" -ForegroundColor Cyan
Write-Host "  user:    $UserName"
Write-Host "  server:  $ServerDir"
Write-Host "  sandbox: $Sandbox"
Write-Host "  repo:    $Repo @ $Branch"
Write-Host ""
Write-Host "硬要求:" -ForegroundColor Yellow
Write-Host "  - PowerShell 7.1+ (当前 $($PSVersionTable.PSVersion))"
Write-Host "  - Python 3.10+"
Write-Host "  - Git"
Write-Host "  - 网络可达 github.com (克隆私有仓)"
Write-Host ""
Write-Host "接下来 8 stage (预计 3-10 min):" -ForegroundColor Cyan
Write-Host "  0. Preflight 体检"
Write-Host "  1. 建本地账号 $UserName"
Write-Host "  2. 建 server 目录 + .ssh"
Write-Host "  3. git clone 代码"
Write-Host "  4. 建 venv + 装 mcp SDK"
Write-Host "  5. 建沙箱 $Sandbox"
Write-Host "  6. 装 OpenSSH Server"
Write-Host "  7. 锁 sshd_config (禁密码登录)"
Write-Host ""
Write-Host "回滚: 各 stage 幂等, 重跑 install.ps1 即可" -ForegroundColor DarkGray
Write-Host ""

Test-Preflight

# 1. 本地账号
Write-Stage 1 8 "建本地账号 $UserName (无密码, OpenSSH 用)"
if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
    Write-Host "    账号已存在, 跳过"
} else {
    # Password = [System.Guid]::NewGuid() — 不可登密码 (OpenSSH 走 pubkey)
    $pwd = ConvertTo-SecureString ([System.Guid]::NewGuid().ToString()) -AsPlainText -Force
    New-LocalUser -Name $UserName -Password $pwd -PasswordNeverExpires -UserMayNotChangePassword `
        -Description "host-rig-bridge MCP server (pubkey only)" | Out-Null
    Write-Host "    账号已建 (密码 = 随机 GUID, 不开放密码登)"
}

# 2. server 目录
Write-Stage 2 8 "建 server 目录 + .ssh"
New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Users\$UserName\.ssh" -Force | Out-Null
# icacls 域限定 (本地账号 + 计算机名) 防极少数上下文解析失败
$acct = "$env:COMPUTERNAME\$UserName"
icacls "C:\Users\$UserName\.ssh" /inheritance:r /grant:r "${acct}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

# 3. git clone
Write-Stage 3 8 "git clone $Repo @ $Branch → $ServerDir\src"
if (Test-Path "$ServerDir\src\.git") {
    Write-Host "    已存在, 跳过"
} else {
    if ($GitToken) {
        $cloneUrl = "https://${GitToken}@github.com/$Repo.git"
    } else {
        # 走浏览器登录态 (无 token 假设浏览器已登录 + gh credential manager)
        $cloneUrl = "https://github.com/$Repo.git"
        Write-Host "    无 -GitToken, 假设浏览器/GCM 已认证; 若 401 请加 -GitToken <pat>" -ForegroundColor Yellow
    }
    git clone --depth 1 --branch $Branch $cloneUrl "$ServerDir\src"
    # 清 token 不留痕迹: 重写 remote 为不带 PAT
    if ($GitToken) {
        git -C "$ServerDir\src" remote set-url origin "https://github.com/$Repo.git"
    }
}

# 4. venv + pip
Write-Stage 4 8 "建 venv + 装 mcp[server]"
if (-not (Test-Path "$ServerDir\.venv")) {
    # 三种探测, 任一可用: py 启动器 / python 绝对路径 / PATH python
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
        throw "找不到 Python: 装 py 启动器 (winget install Python.Python.3.13) 或本地 Python"
    }
    Write-Host "    用 $($py.Path) $($py.Arg)"
    & $py.Path $py.Arg -m venv "$ServerDir\.venv"
}
& "$ServerDir\.venv\Scripts\python.exe" -m pip install --upgrade pip --quiet
# mcp 1.x 后期 [server] extra 被合并/移除, 直接 pip install mcp
# (pyproject 还写 mcp[server]~=1.10 是历史, extras 不存在但 ~1.10 仍约束主版本)
& "$ServerDir\.venv\Scripts\python.exe" -m pip install "mcp>=1.10,<2.0" --quiet

# 验证 SDK
$ok = & "$ServerDir\.venv\Scripts\python.exe" -c "from mcp.server.fastmcp import FastMCP; print('mcp SDK OK')"
Write-Host "    $ok"

# 5. 沙箱
Write-Stage 5 8 "建沙箱 $Sandbox"
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null
icacls $Sandbox /inheritance:r /grant:r "${acct}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

# 6. OpenSSH Server
Write-Stage 6 8 "装/启 OpenSSH Server"
$openssh = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction SilentlyContinue
if ($openssh.State -ne "Installed") {
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
} else {
    Write-Host "    OpenSSH Server 已装"
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
# 防火墙放行 (若启用)
if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue) {
    Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" | Out-Null
}

# 7. sshd_config 锁 (匹配 examples/authorized-keys 假设)
Write-Stage 7 8 "配 sshd_config (PasswordAuthentication no, PubkeyAuthentication yes)"
$sshdConf = "$env:ProgramData\ssh\sshd_config"
$backup = "$sshdConf.bak.$(Get-Date -Format yyyyMMdd)"
if (-not (Test-Path $backup)) { Copy-Item $sshdConf $backup -Force }
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
# 追加 (若不存在)
if (-not ($new | Select-String '^PubkeyAuthentication\s+yes$')) { $new += "PubkeyAuthentication yes" }
if (-not ($new | Select-String '^PasswordAuthentication\s+no$')) { $new += "PasswordAuthentication no" }
if (-not ($new | Select-String '^PermitRootLogin\s+no$')) { $new += "PermitRootLogin no" }
# 写文件用 utf8NoBOM — sshd 不接受 BOM (BOM 致 sshd 解析失败, 服务不启)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($sshdConf, ($new -join "`r`n") + "`r`n", $utf8NoBom)
Restart-Service sshd
Write-Host "    sshd_config 已改 (utf8NoBOM), 服务已重启"

Write-Host ""
Write-Host "==========================================="
Write-Host " ✅ Windows 外机安装完成"
Write-Host "==========================================="
Write-Host ""
Write-Host "下一步:" -ForegroundColor Yellow
Write-Host "  0. 浏览器登录 https://github.com/wukong0908/host-rig-bridge 或传 -GitToken <pat>" -ForegroundColor Yellow
Write-Host "  1. 在主机生成 SSH key (若尚未有):" -ForegroundColor Yellow
Write-Host "       ssh-keygen -t ed25519 -f \$HOME\.ssh\id_claude_mcp -N \"\"" -ForegroundColor Yellow
Write-Host "  2. 把主机公钥贴到外机 authorized_keys (一行, 带 forced command):" -ForegroundColor Yellow
Write-Host "       command=`"$ServerDir\.venv\Scripts\python.exe -u $ServerDir\src\server\server.py`",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA..." -ForegroundColor Yellow
Write-Host ""
Write-Host "     外机 PowerShell (管理员):" -ForegroundColor Yellow
Write-Host "       Add-Content -Path \"C:\Users\$UserName\.ssh\authorized_keys\" -Value \"<上面那行>\"" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. 主机首次 SSH 验握手:" -ForegroundColor Yellow
Write-Host "       ssh -o StrictHostKeyChecking=accept-new $UserName@<rig-host>" -ForegroundColor Yellow
Write-Host "  4. 重启主机 Claude Code, /mcp 看 rig connected." -ForegroundColor Yellow
Write-Host ""
Write-Host "出错留日志 (pwsh 7 才支持 *>&1):" -ForegroundColor Yellow
Write-Host "   .\install.ps1 ...args... *>&1 | Tee-Object -FilePath C:\install.log" -ForegroundColor Yellow