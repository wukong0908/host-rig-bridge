# 主人外机 admin PowerShell 跑这段
# 目的: 同时救回链路 A (6000) + 加链路 B (6001) + 修 ACL

$ErrorActionPreference = "Stop"
$toml = "C:\frp\frpc.toml"
$nssm = "C:\nssm-2.24\win64\nssm.exe"

# 1) 看当前 toml
Write-Host "=== toml 当前 ===" -ForegroundColor Cyan
Get-Content $toml

# 2) 备份
$bak = "$toml.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item $toml $bak
Write-Host "`n备份: $bak" -ForegroundColor Yellow

# 3) 写新 toml (两个代理共存)
@'
serverAddr = "8.163.106.31"
serverPort = 7000
auth.token = "18ec0556d6ffe6fcc15a92c888fe589a68638ac38408e749ba92dcf10b86dc1a"

transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30

# 链路 A: 反向 SSH (主人家里)
[[proxies]]
name = "home-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
transport.useCompression = true

# 链路 B: 外机 sshd (host-rig-bridge)
[[proxies]]
name = "rig-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6001
transport.useCompression = true
'@ | Set-Content $toml -Encoding UTF8

Write-Host "`n=== toml 新 ===" -ForegroundColor Cyan
Get-Content $toml

# 4) NSSM 重启 frpc
Write-Host "`n=== NSSM restart frpc ===" -ForegroundColor Cyan
& $nssm stop frpc
Start-Sleep 2
& $nssm start frpc
Start-Sleep 2
& $nssm status frpc

# 5) 修 ACL (mcp-rig owner)
Write-Host "`n=== ACL 修复 ===" -ForegroundColor Cyan
cmd /c 'takeown /f "C:\Users\mcp-rig\.ssh" /r /d y' | Out-Null
cmd /c 'icacls "C:\Users\mcp-rig\.ssh" /setowner "mcp-rig" /T /C /L /Q' | Out-Null
cmd /c 'icacls "C:\Users\mcp-rig\.ssh\authorized_keys" /setowner "mcp-rig" /C /L /Q' | Out-Null
Write-Host "ACL 已修"
icacls "C:\Users\mcp-rig\.ssh"
icacls "C:\Users\mcp-rig\.ssh\authorized_keys"

Write-Host "`n=== 完成 ===" -ForegroundColor Green
Write-Host "下一步: 主机跑"
Write-Host "  ssh -p 6000 root@8.163.106.31  (链路 A VPS sshd)"
Write-Host "  ssh -p 6001 -i C:\Users\wukong\.ssh\id_claude_mcp mcp-rig@8.163.106.31  (链路 B 直接走 frp, 不需本地转发)"