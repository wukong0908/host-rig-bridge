# bump-version.ps1 — install-rig-bundle.ps1 版本自增
#
# 用法 (仓根目录):
#   pwsh scripts/bump-version.ps1              # 默认 patch +0.0.1
#   pwsh scripts/bump-version.ps1 -Bump minor  # +0.1.0
#   pwsh scripts/bump-version.ps1 -Bump major  # +1.0.0
#
# 行为:
#   1. 读 scripts/install-rig-bundle.ps1 里的 $ScriptVersion = "X.Y.Z"
#   2. 算 next = X.Y.Z+1 (按 -Bump 维度)
#   3. Edit 替换为 next
#   4. git add + commit "[bump X.Y.Z → X.Y.Z+1] <reason>"
#   5. 不自动 push (主人 review 后手动 push)
#
# 纪律:
#   - 改 install-rig-bundle.ps1 之前先跑这个 (生成一个独立 commit)
#   - 之后改代码, commit 信息里 [v0.9.6] 标记

[CmdletBinding()]
param([ValidateSet("patch","minor","major")][string]$Bump = "patch")

$ErrorActionPreference = "Stop"
$ScriptPath = Join-Path $PSScriptRoot "install-rig-bundle.ps1"

if (-not (Test-Path $ScriptPath)) { throw "找不到 $ScriptPath" }

# 读当前版本
$content = Get-Content $ScriptPath -Raw
if ($content -notmatch '\$ScriptVersion\s*=\s*"(\d+)\.(\d+)\.(\d+)"') {
    throw "install-rig-bundle.ps1 里找不到 \$ScriptVersion = X.Y.Z"
}
$major = [int]$Matches[1]
$minor = [int]$Matches[2]
$patch = [int]$Matches[3]
$current = "$major.$minor.$patch"

# 算下一版
switch ($Bump) {
    "patch" { $patch++; $next = "$major.$minor.$patch" }
    "minor" { $minor++; $patch = 0; $next = "$major.$minor.$patch" }
    "major" { $major++; $minor = 0; $patch = 0; $next = "$major.$minor.$patch" }
}

Write-Host "当前版本: $current"
Write-Host "下一版本: $next"

# 替换 (字面值,不经过 regex)
$old = '$ScriptVersion = "' + $current + '"'
$new = '$ScriptVersion = "' + $next + '"'
if (-not $content.Contains($old)) { throw "源文件里找不到字面值: $old" }
$newContent = $content.Replace($old, $new)
Set-Content -Path $ScriptPath -Value $newContent -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host "已写入 \$ScriptVersion = `"$next`"" -ForegroundColor Green
Write-Host ""
Write-Host "下一步:" -ForegroundColor Yellow
Write-Host "  git add scripts/install-rig-bundle.ps1"
Write-Host "  git commit -m '[bump $current → $next] <reason>'"
Write-Host "  git push origin main  (主人手动)"