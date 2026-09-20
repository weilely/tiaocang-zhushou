<#
升版本号 + 同步到 GitHub 一条龙。

用法（在仓库根目录；本机执行策略禁止直接跑 .ps1，所以要带 Bypass）：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\bump_version.ps1 -Version 1.0.2
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\bump_version.ps1 -Version 1.1.0 -Message "新增 xxx"

注意：本文件必须存成 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 GBK 读中文，
把字符串引号吃掉、整个脚本语法报错。

做的事：
  1. 改 pubspec.yaml 的 `version: X+Y`（build 号自动 +1）
  2. 改 lib/core/app_info.dart 的 appVersion
  3. flutter analyze + flutter test
  4. git add / commit / tag vX / push（含 tag）

版本号约定（和用户商定）：每次改动 +1 patch（1.0.1、1.0.2…），
攒到一定量或加了成体系的功能再跳 minor（1.1.0）。

**发布附件的约定**：默认**不传 APK 附件**（本机上行只有 ~31KB/s，传一次要 7 分钟）。
只在"值得的版本"加 -Publish 才出包并上传，界面上的应用内更新就以
最近一次带附件的版本为目标。平时 `git push` 推代码即可。
事后再补传某一版：publish_release.ps1 -Version X -ApkPath <该版 APK>。
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Message = '',
  [switch]$SkipPush,
  [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "版本号格式应为 X.Y.Z，收到：$Version"
}

$pubspec = Join-Path $root 'pubspec.yaml'
$info = Join-Path $root 'lib\core\app_info.dart'

# ---- 1) pubspec.yaml：version: X.Y.Z+BUILD，build 号自增 ----
$lines = [System.IO.File]::ReadAllLines($pubspec)
$found = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^version:\s*(\S+)\s*$') {
    $old = $Matches[1]
    $build = 1
    if ($old -match '\+(\d+)$') { $build = [int]$Matches[1] + 1 }
    $lines[$i] = "version: $Version+$build"
    $found = $true
    Write-Host "pubspec: $old -> $Version+$build"
    break
  }
}
if (-not $found) { throw "pubspec.yaml 里没找到 version: 行" }
[System.IO.File]::WriteAllLines($pubspec, $lines, [System.Text.UTF8Encoding]::new($false))

# ---- 2) app_info.dart ----
$c = [System.IO.File]::ReadAllText($info)
$new = [regex]::Replace($c, "appVersion = '[^']*'", "appVersion = '$Version'")
if ($new -eq $c -and $c -notmatch "appVersion = '$Version'") {
  throw "app_info.dart 里没能替换 appVersion"
}
[System.IO.File]::WriteAllText($info, $new, [System.Text.UTF8Encoding]::new($false))
Write-Host "app_info: appVersion = $Version"

# ---- 3) 校验 ----
# 两个坑：
# ① flutter analyze 只要有任何 issue（含 info）就返回非 0 → 要看输出而不是退出码；
#    项目门线是「零错误零告警」，info 级 lint 属建议性、不拦发布。
# ② flutter.bat 会把「N issues found」写到 stderr，在 $ErrorActionPreference='Stop'
#    下会被当成终止错误 → 调用期间临时改成 Continue。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $analyzeOut = @(& 'E:\flutter\bin\flutter.bat' analyze 2>&1 | ForEach-Object { "$_" })
  $analyzeOut | ForEach-Object { Write-Host $_ }
  $hard = $analyzeOut | Select-String -Pattern '^\s*(error|warning)\s+-'
  if ($hard) {
    $hard | ForEach-Object { Write-Host $_.Line }
    throw "flutter analyze 有错误或告警，已中止"
  }
  # info 级 lint 也拦一道：`unrelated_type_equality_checks` 这类错误只是 info，
  # 我因为"只 grep error|warning"漏过两次真 bug（最典型：拿 AssetKind 枚举去比
  # 字符串，判等恒为假）。基线 7 条属既有，**变多就说明新代码引入了新问题**。
  $infos = @($analyzeOut | Select-String -Pattern '^\s*info\s+-')
  Write-Host "info 级 lint：$($infos.Count) 条（基线 7）"
  if ($infos.Count -gt 7) {
    $infos | ForEach-Object { Write-Host $_.Line }
    throw "info 级 lint 比基线多了，先看看是不是新引入的"
  }
  & 'E:\flutter\bin\flutter.bat' test 2>&1 | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0) { throw "flutter test 未通过，已中止" }
} finally {
  $ErrorActionPreference = $prevEap
}

# ---- 4) 提交 + 打标 + 推送 ----
if (-not $Message) { $Message = "发布 v$Version" }
git add -A
git -c user.email=me@local -c user.name=dev commit -q -m "$Message"
git tag -a "v$Version" -m "v$Version"
Write-Host "已提交并打标 v$Version"

if (-not $SkipPush) {
  # BatchMode + ConnectTimeout：ssh 不会停下来等交互输入（不带的话
  # 首次连新主机会卡住直到超时）
  $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new'
  git push
  git push origin "v$Version"
  Write-Host "已推送到 GitHub（含 tag v$Version）"

  # Gitee 镜像：有 gitee 远端就一起推（国内访问更稳，
  # 「检查更新」在 GitHub 不通时会落到它）
  $hasGitee = (git remote) -contains 'gitee'
  if ($hasGitee) {
    git push gitee main
    git push gitee "v$Version"
    Write-Host "已推送到 Gitee（含 tag v$Version）"
  }
}

# ---- 5) 出包并上传发行版附件（应用内更新靠它；-Publish 才做）----
# 只传**拆分包**：通用包 97.7MB，本机上行实测只有 ~31KB/s，传不动；
# 拆成 ABI 后 arm64 才 36.7MB。App 端按设备 ABI 挑对应附件
# （见 lib/data/update_source.dart 的 pickApkAssetForAbi）。
if ($Publish) {
  if (-not $env:GITEE_TOKEN) {
    Write-Host "跳过上传：没有 GITEE_TOKEN"
  } else {
    & 'E:\flutter\bin\flutter.bat' build apk --release --split-per-abi | Out-Host
    foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
      $src = Join-Path $root "build\app\outputs\flutter-apk\app-$abi-release.apk"
      if (-not (Test-Path $src)) { Write-Host "没有 $abi 的产物，跳过"; continue }
      $dst = Join-Path (Split-Path -Parent $root) "tiaocang-zhushou-v$Version-$abi.apk"
      Copy-Item $src $dst -Force
      & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot 'publish_release.ps1') `
        -Version $Version -ApkPath $dst `
        -AssetName "tiaocang-zhushou-v$Version-$abi.apk"
    }
  }
}
