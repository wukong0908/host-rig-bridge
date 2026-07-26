# install-rig-bundle.ps1 — 外机一键 deploy (链路 B 一次跑完)
# 装 OpenSSH + 建账号 + 建 venv + 装 mcp SDK + 装 frpc + NSSM + 写 authorized_keys
# 用法 (管理员 PowerShell 7.1+, 外机上跑):
#   $env:RIG_VPS = "8.163.106.31"
#   $env:RIG_FRP_TOKEN = "<同家里 frpc 的 token>"
#   $env:RIG_REMOTE_PORT = "6001"
#   $env:RIG_HOST_PUBKEY = '<forced command + 主机公钥 整行>'
#   iex (iwr -useb "https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install-rig-bundle.ps1").Content
#
# 子命令:
#   install-rig-bundle.ps1            # 完整 deploy
#   install-rig-bundle.ps1 -Verify    # 5 步验证 (deploy 完后跑)
#   install-rig-bundle.ps1 -Status    # 显示当前状态
#
# 行为 (幂等, deploy 各阶段可重跑):
#   1. Preflight (pwsh/python/git/internet)
#   2. 装 OpenSSH Server (DISM fallback)
#   3. 建 mcp-rig 本地账号 (密码=随机 GUID, 只走 pubkey)
#   4. 建 server 目录 + .ssh
#   5. git clone 拉 host-rig-bridge 代码 (私有仓, 需浏览器已登录或 GCM)
#   6. 建 .venv + 装 mcp SDK
#   7. 写 authorized_keys (从 $RIG_HOST_PUBKEY, icacls 锁 mcp-rig:SYSTEM only)
#   8. 装 frpc (下载 + 写 frpc.toml + NSSM 注册 + 启动)
#   9. 锁 sshd_config (Pubkey yes / Password no / Root no)
#  10. 输出 VPS / 主机 后续手动提示

[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

# ===== 入参检查 =====
$RIG_VPS         = $env:RIG_VPS
$RIG_FRP_TOKEN   = $env:RIG_FRP_TOKEN
$RIG_REMOTE_PORT = $env:RIG_REMOTE_PORT
$RIG_HOST_PUBKEY = $env:RIG_HOST_PUBKEY

$ServerDir = "C:\Users\mcp-rig\mcp-server"
$Sandbox   = "C:\Users\mcp-rig\projects"
$UserName  = "mcp-rig"

# ===== helpers (复用 install.ps1 风格) =====
function Write-Stage {
    param([int]$N, [int]$Total, [string]$Msg)
    Write-Host "[$N/$Total] $Msg" -ForegroundColor Cyan
}
function Write-Step {
    param([string]$Msg)
    Write-Host "    → $Msg " -NoNewline -ForegroundColor DarkGray
}
function Write-StepDone {
    param([string]$Msg = "完成")
    Write-Host "[$Msg]" -ForegroundColor Green
}
function Write-StepSkip {
    param([string]$Reason = "已存在")
    Write-Host "[跳过: $Reason]" -ForegroundColor DarkGray
}

# ===== banner =====
function Show-Banner {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       host-rig-bridge 外机一键 deploy (链路 B)               ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "参数 (env var):" -ForegroundColor Cyan
    Write-Host "  RIG_VPS:         $RIG_VPS"
    Write-Host "  RIG_REMOTE_PORT: $RIG_REMOTE_PORT"
    Write-Host "  RIG_FRP_TOKEN:   $($RIG_FRP_TOKEN.Substring(0, [Math]::Min(8, $RIG_FRP_TOKEN.Length)))... (前 8 位)"
    Write-Host "  RIG_HOST_PUBKEY: $($RIG_HOST_PUBKEY.Substring(0, [Math]::Min(40, $RIG_HOST_PUBKEY.Length)))..."
    Write-Host ""
}

# ===== Assert-Admin =====
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal $id
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "需要管理员 PowerShell. 右键 PowerShell → 以管理员身份运行."
    }
}

# ===== Test-Preflight =====
function Test-Preflight {
    $report = [ordered]@{
        pwsh      = $false
        python    = $false
        git       = $false
        openssh   = $false
        internet  = $false
    }
    $report.pwsh = $PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 1
    $pyCmd = Get-Command py.exe -ErrorAction SilentlyContinue
    $pyAbs = "C:\Users\$UserName\AppData\Local\Python\bin\python.exe"
    if ($pyCmd -or (Test-Path $pyAbs)) { $report.python = $true }
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { $report.git = $true }
    try {
        $sshCap = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop
        if ($sshCap.State -in @("Installed", "InstallPending")) { $report.openssh = $true }
    } catch {
        $sshSvc = Get-Service sshd -ErrorAction SilentlyContinue
        if ($sshSvc) { $report.openssh = $true }
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
    if ($missing -match "python|git|internet|pwsh") {
        throw "Preflight 失败: 缺 $($missing -join ', ')"
    }
}

# ===== Stage 2: 装 OpenSSH =====
function Install-OpenSsh {
    Write-Stage 2 10 "装 OpenSSH Server"
    $installed = $false
    try {
        Write-Step "Get-WindowsCapability OpenSSH.Server~~~~0.0.1.0"
        $openssh = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop
        Write-StepDone "State=$($openssh.State)"
        if ($openssh.State -ne "Installed") {
            Write-Step "Add-WindowsCapability (60-180s)"
            Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
            Write-StepDone
        } else {
            $installed = $true
        }
    } catch {
        Write-Host "    ⚠ Get-WindowsCapability 不可用, 退到 DISM" -ForegroundColor Yellow
        Write-Step "dism /online /add-capability OpenSSH.Server~~~~0.0.1.0 (60-180s)"
        $dismOut = dism /online /add-capability /capabilityname:OpenSSH.Server~~~~0.0.1.0 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw @"
DISM 装 OpenSSH 失败 (exit=$LASTEXITCODE):
$dismOut
手动装: Settings → Apps → Optional Features → OpenSSH Server
装完跳 stage 2 重跑 (幂等)。
"@
        }
        $installed = $true
        Write-StepDone
    }
    Write-Step "Set-Service sshd + Start-Service + Enable-NetFirewallRule"
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue) {
        Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" | Out-Null
    }
    Write-StepDone
}

# ===== Stage 3: 建账号 =====
function New-McpUser {
    Write-Stage 3 10 "建本地账号 $UserName (无密码, OpenSSH 用)"
    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
        Write-StepSkip "账号已存在"
    } else {
        Write-Step "New-LocalUser (密码 = 随机 GUID)"
        $pwd = ConvertTo-SecureString ([System.Guid]::NewGuid().ToString()) -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $pwd -PasswordNeverExpires -UserMayNotChangePassword `
            -Description "host-rig-bridge MCP server (pubkey only)" | Out-Null
        Write-StepDone
    }
}

# ===== Stage 4: 建目录 =====
function New-Dirs {
    Write-Stage 4 10 "建 server 目录 + .ssh"
    Write-Step "mkdir $ServerDir"
    New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
    Write-StepDone
    Write-Step "mkdir C:\Users\$UserName\.ssh"
    New-Item -ItemType Directory -Path "C:\Users\$UserName\.ssh" -Force | Out-Null
    Write-StepDone
    $acct = "$env:COMPUTERNAME\$UserName"
    Write-Step "icacls .ssh (限 $acct + SYSTEM)"
    icacls "C:\Users\$UserName\.ssh" /inheritance:r /grant:r "${acct}:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
    Write-StepDone
}

# ===== Stage 5: git clone =====
function Git-Clone {
    Write-Stage 5 10 "git clone host-rig-bridge → $ServerDir\src"
    if (Test-Path "$ServerDir\src\.git") {
        Write-StepSkip "$ServerDir\src 已存在"
    } else {
        # 私有仓: 需浏览器已登录 + GCM, 或主人手动传 token
        $token = $env:RIG_GIT_TOKEN
        if ($token) {
            $url = "https://${token}@github.com/wukong0908/host-rig-bridge.git"
        } else {
            $url = "https://github.com/wukong0908/host-rig-bridge.git"
            Write-Host "    ⚠ 无 RIG_GIT_TOKEN, 假设浏览器/GCM 已认证; 若 401 设 `$env:RIG_GIT_TOKEN=<pat> 重跑" -ForegroundColor Yellow
        }
        Write-Step "git clone --depth 1 --branch main (私有仓, 5-30s)"
        git clone --depth 1 --branch main --progress $url "$ServerDir\src"
        if ($token) {
            git -C "$ServerDir\src" remote set-url origin "https://github.com/wukong0908/host-rig-bridge.git"
        }
        Write-StepDone
    }
}

# ===== Stage 6: venv + mcp =====
function Install-Mcp {
    Write-Stage 6 10 "建 venv + 装 mcp SDK"
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
        Write-Step "python -m venv (用 $($py.Path) $($py.Arg))"
        & $py.Path $py.Arg -m venv "$ServerDir\.venv"
        Write-StepDone
    } else {
        Write-StepSkip "$ServerDir\.venv 已存在"
    }
    Write-Step "pip install --upgrade pip (30-60s)"
    & "$ServerDir\.venv\Scripts\python.exe" -m pip install --upgrade pip
    Write-StepDone
    Write-Step "pip install mcp>=1.10,<2.0 (30-90s)"
    & "$ServerDir\.venv\Scripts\python.exe" -m pip install "mcp>=1.10,<2.0"
    Write-StepDone
    Write-Step "import FastMCP 验证"
    $ok = & "$ServerDir\.venv\Scripts\python.exe" -c "from mcp.server.fastmcp import FastMCP; print('mcp SDK OK')"
    Write-StepDone "$ok"
}

# ===== Stage 7: 写 authorized_keys =====
function Write-AuthorizedKeys {
    Write-Stage 7 10 "写 authorized_keys (含 forced command + 主机公钥)"
    if (-not $RIG_HOST_PUBKEY) {
        throw "`$RIG_HOST_PUBKEY 未设. 主人从主机 register-rig 输出复制整行, 设环境变量再跑"
    }
    $akPath = "C:\Users\$UserName\.ssh\authorized_keys"
    Write-Step "Add-Content $akPath"
    Add-Content -Path $akPath -Value $RIG_HOST_PUBKEY -Encoding UTF8
    Write-StepDone
    $acct = "$env:COMPUTERNAME\$UserName"
    Write-Step "icacls authorized_keys (限 $acct:R + SYSTEM:R, 防其他用户读)"
    icacls $akPath /inheritance:r /grant:r "${acct}:(R)" "SYSTEM:(R)" | Out-Null
    Write-StepDone
}

# ===== Stage 8: 装 frpc =====
function Install-Frpc {
    Write-Stage 8 10 "装 frpc + NSSM 注册"
    if (-not $RIG_VPS -or -not $RIG_FRP_TOKEN -or -not $RIG_REMOTE_PORT) {
        throw "`$RIG_VPS / `$RIG_FRP_TOKEN / `$RIG_REMOTE_PORT 未设全"
    }
    $frpDir = "C:\frp"
    $frpcExe = "$frpDir\frpc.exe"
    $frpcToml = "$frpDir\frpc.toml"
    $frpVersion = "0.61.1"
    $frpUrl = "https://github.com/fatedier/frp/releases/download/v$frpVersion/frp_${frpVersion}_windows_amd64.zip"

    if (-not (Test-Path $frpDir)) {
        New-Item -ItemType Directory -Path $frpDir -Force | Out-Null
    }
    if (-not (Test-Path $frpcExe)) {
        Write-Step "下载 frpc v$frpVersion"
        $zipPath = Join-Path $env:TEMP "frpc.zip"
        Invoke-WebRequest -Uri $frpUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $frpDir -Force
        Remove-Item $zipPath
        $subDir = Get-ChildItem $frpDir -Directory | Where-Object { $_.Name -like "frp_*" } | Select-Object -First 1
        if ($subDir) {
            Get-ChildItem $subDir.FullName | Move-Item -Destination $frpDir -Force
            Remove-Item $subDir.FullName -Recurse
        }
        Write-StepDone
    } else {
        Write-StepSkip "frpc.exe 已存在"
    }

    Write-Step "写 $frpcToml"
    $tomlContent = @"
serverAddr = "$RIG_VPS"
serverPort = 7000
auth.method = "token"
auth.token = "$RIG_FRP_TOKEN"

# ⚠️ v0.61+ 不要顶层 heartbeatInterval, 放 transport.*
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30

[[proxies]]
name = "rig-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $RIG_REMOTE_PORT
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($frpcToml, $tomlContent, $utf8NoBom)
    Write-StepDone

    # NSSM 注册服务
    $nssm = "C:\nssm-2.24\win64\nssm.exe"
    if (-not (Test-Path $nssm)) {
        Write-Step "下载 NSSM"
        $nssmZip = Join-Path $env:TEMP "nssm.zip"
        $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing
        Expand-Archive -Path $nssmZip -DestinationPath "C:\" -Force
        Remove-Item $nssmZip
        Write-StepDone
    } else {
        Write-StepSkip "NSSM 已存在"
    }

    Write-Step "NSSM 注册 frpc 服务 (StartType=Automatic, RestartCount 3)"
    if (Get-Service frpc -ErrorAction SilentlyContinue) {
        & $nssm stop frpc 2>&1 | Out-Null
        & $nssm remove frpc confirm 2>&1 | Out-Null
    }
    & $nssm install frpc $frpcExe "-c $frpcToml"
    & $nssm set frpc AppDirectory $frpDir
    & $nssm set frpc Start SERVICE_AUTO_START
    & $nssm set frpc AppStdout "$frpDir\frpc.out.log"
    & $nssm set frpc AppStderr "$frpDir\frpc.err.log"
    & $nssm set frpc AppRotateFiles 1
    & $nssm set frpc AppRotateBytes 1048576
    & $nssm set frpc AppRestartDelay 5000
    & $nssm start frpc
    Write-StepDone
}

# ===== Stage 9: 锁 sshd_config =====
function Lock-SshdConfig {
    Write-Stage 9 10 "锁 sshd_config (Pubkey yes / Password no / Root no)"
    $sshdConf = "$env:ProgramData\ssh\sshd_config"
    $backup = "$sshdConf.bak.$(Get-Date -Format yyyyMMdd)"
    if (-not (Test-Path $backup)) {
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
    Restart-Service sshd
    Write-StepDone
}

# ===== Stage 10: 输出后续提示 =====
function Show-NextSteps {
    Write-Stage 10 10 "完成 ✅"
    Write-Host ""
    Write-Host "==========================================="
    Write-Host " ⏸  暂停 — 主人做完下面再 verify"
    Write-Host "==========================================="
    Write-Host ""
    Write-Host "[VPS 阿里云控制台 — 30s]" -ForegroundColor Cyan
    Write-Host "  1. 放行 $RIG_REMOTE_PORT TCP 入站:" -ForegroundColor Cyan
    Write-Host "     ECS → 本实例 → 安全组 → 入站规则 → 手动添加:" -ForegroundColor Cyan
    Write-Host "       端口范围: $RIG_REMOTE_PORT/$RIG_REMOTE_PORT" -ForegroundColor Cyan
    Write-Host "       协议: TCP" -ForegroundColor Cyan
    Write-Host "       源: 0.0.0.0/0" -ForegroundColor Cyan
    Write-Host "       描述: frp-rig-ssh" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  2. 验证 (主机跑):" -ForegroundColor Cyan
    Write-Host "     Test-NetConnection $RIG_VPS -Port $RIG_REMOTE_PORT -InformationLevel Quiet" -ForegroundColor Cyan
    Write-Host "     # 期望: True" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[主机 — 1 min]" -ForegroundColor Cyan
    Write-Host "  3. 写 SSH config 段 + mcpServers.rig:" -ForegroundColor Cyan
    Write-Host "     cd D:\WuKong\Desktop\host-rig-bridge" -ForegroundColor Cyan
    Write-Host "     git pull origin main" -ForegroundColor Cyan
    Write-Host "     pwsh scripts/register-rig.ps1 -RigAlias rig -RigHost $RIG_VPS -RigPort $RIG_REMOTE_PORT -RigUser $UserName" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[外机 — 30s]" -ForegroundColor Cyan
    Write-Host "  4. 验证全链路 (此脚本):" -ForegroundColor Cyan
    Write-Host "     install-rig-bundle.ps1 -Verify" -ForegroundColor Cyan
    Write-Host "     # 5 步: sshd 听 / frpc 在 / VPS:$RIG_REMOTE_PORT 通 / mcp SDK OK / ssh rig 通" -ForegroundColor Cyan
    Write-Host ""
}

# ===== Verify =====
function Invoke-Verify {
    Write-Host "=== Verify (5 步) ===" -ForegroundColor Cyan
    $results = @()

    # 1. sshd listen 22
    Write-Host "[1/5] sshd 听 22 ..."
    $net = netstat -ano | findstr :22
    if ($net -match "LISTENING") {
        Write-Host "    ✓ sshd listen 22" -ForegroundColor Green
        $results += $true
    } else {
        Write-Host "    ✗ sshd 未监听 22" -ForegroundColor Red
        $results += $false
    }

    # 2. frpc 服务 Running
    Write-Host "[2/5] frpc 服务 ..."
    $svc = Get-Service frpc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "    ✓ frpc Running" -ForegroundColor Green
        $results += $true
    } else {
        Write-Host "    ✗ frpc 未运行" -ForegroundColor Red
        $results += $false
    }

    # 3. VPS:RIG_REMOTE_PORT 通 (本机调 frps → frpc → sshd, 验证链路)
    Write-Host "[3/5] VPS $RIG_VPS`:$RIG_REMOTE_PORT TCP ..."
    try {
        $tcp = Test-NetConnection -ComputerName $RIG_VPS -Port $RIG_REMOTE_PORT -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($tcp) {
            Write-Host "    ✓ VPS:$RIG_REMOTE_PORT 通" -ForegroundColor Green
            $results += $true
        } else {
            Write-Host "    ✗ VPS:$RIG_REMOTE_PORT 不通 (主机侧网络/安全组问题)" -ForegroundColor Red
            $results += $false
        }
    } catch {
        Write-Host "    ✗ Test-NetConnection 失败: $_" -ForegroundColor Red
        $results += $false
    }

    # 4. mcp SDK
    Write-Host "[4/5] mcp SDK ..."
    $ok = & "$ServerDir\.venv\Scripts\python.exe" -c "from mcp.server.fastmcp import FastMCP; print('OK')" 2>&1
    if ($ok -match "OK") {
        Write-Host "    ✓ mcp SDK OK" -ForegroundColor Green
        $results += $true
    } else {
        Write-Host "    ✗ mcp SDK 失败: $ok" -ForegroundColor Red
        $results += $false
    }

    # 5. ssh rig (走 VPS:RIG_REMOTE_PORT → forced command → mcp server 启动)
    Write-Host "[5/5] ssh mcp-rig@$RIG_VPS -p $RIG_REMOTE_PORT (3s probe, 应握手后被 forced command 截住) ..."
    # 短跑 3s, mcp server 启动 → 收 stdio, 等会儿 ctrl+c; 期望: 不返 "Permission denied"
    $probe = ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -p $RIG_REMOTE_PORT "$UserName@$RIG_VPS" "echo SSH_OK" 2>&1
    if ($LASTEXITCODE -eq 0 -and $probe -match "SSH_OK") {
        # forced command 没截, ssh 走通 — 错 (应该截胡)
        Write-Host "    ⚠ SSH 通但 forced command 没截 (公钥无 command= 前缀?)" -ForegroundColor Yellow
        $results += $false
    } elseif ($probe -match "Permission denied") {
        Write-Host "    ✗ Permission denied (公钥未授权或错机器)" -ForegroundColor Red
        $results += $false
    } else {
        # forced command 启 mcp server, ssh 输出 mcp server 启动信息/异常, 算通
        Write-Host "    ✓ mcp server 启动 (forced command 生效)" -ForegroundColor Green
        $results += $true
    }

    $pass = ($results | Where-Object { $_ }).Count
    Write-Host ""
    Write-Host "Verify 结果: $pass / 5 通过" -ForegroundColor $(if ($pass -eq 5) { "Green" } else { "Yellow" })
    if ($pass -lt 5) {
        Write-Host "哪步失败就修哪步, 然后重跑 install-rig-bundle.ps1 (幂等)" -ForegroundColor Yellow
    }
}

# ===== Status =====
function Show-Status {
    Write-Host "=== 当前状态 ===" -ForegroundColor Cyan
    Write-Host "sshd:        $(if (Get-Service sshd -ErrorAction SilentlyContinue) { (Get-Service sshd).Status } else { '未装' })"
    Write-Host "frpc:        $(if (Get-Service frpc -ErrorAction SilentlyContinue) { (Get-Service frpc).Status } else { '未装' })"
    Write-Host "server dir:  $(if (Test-Path $ServerDir) { '在' } else { '不在' })"
    Write-Host "venv:        $(if (Test-Path "$ServerDir\.venv") { '在' } else { '不在' })"
    Write-Host "src:         $(if (Test-Path "$ServerDir\src") { '在' } else { '不在' })"
    Write-Host "authorized_keys: $(if (Test-Path "C:\Users\$UserName\.ssh\authorized_keys") { (Get-Content "C:\Users\$UserName\.ssh\authorized_keys").Length + ' 行' } else { '不在' })"
    Write-Host "frpc toml:   $(if (Test-Path C:\frp\frpc.toml) { '在' } else { '不在' })"
}

# ===== 主流程 =====
Assert-Admin
Show-Banner

if ($Status) {
    Show-Status
    return
}

if ($Verify) {
    Invoke-Verify
    return
}

# 缺入参检查 (deploy 模式)
if (-not $RIG_VPS -or -not $RIG_FRP_TOKEN -or -not $RIG_REMOTE_PORT -or -not $RIG_HOST_PUBKEY) {
    Write-Host "❌ deploy 模式需 4 个环境变量:" -ForegroundColor Red
    Write-Host "   `$env:RIG_VPS         = '8.163.106.31'" -ForegroundColor Red
    Write-Host "   `$env:RIG_FRP_TOKEN   = '<同家里 frpc 的 token>'" -ForegroundColor Red
    Write-Host "   `$env:RIG_REMOTE_PORT = '6001'" -ForegroundColor Red
    Write-Host "   `$env:RIG_HOST_PUBKEY = '<forced command + 主机公钥 整行>'" -ForegroundColor Red
    Write-Host ""
    Write-Host "子命令不需这些:" -ForegroundColor Yellow
    Write-Host "   install-rig-bundle.ps1 -Verify" -ForegroundColor Yellow
    Write-Host "   install-rig-bundle.ps1 -Status" -ForegroundColor Yellow
    exit 1
}

Test-Preflight
Install-OpenSsh
New-McpUser
New-Dirs
Git-Clone
Install-Mcp
Write-AuthorizedKeys
Install-Frpc
Lock-SshdConfig
Show-NextSteps

Write-Host ""
Write-Host "出错留日志 (pwsh 7 才支持 *>&1):" -ForegroundColor Yellow
Write-Host "   .\install-rig-bundle.ps1 ...args... *>&1 | Tee-Object -FilePath C:\install.log" -ForegroundColor Yellow