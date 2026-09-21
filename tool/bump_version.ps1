<#
升版本号 + 推双仓库（GitHub + Gitee）一条龙。

用法（在仓库根目录；本机执行策略禁止直接跑 .ps1，所以要带 Bypass）：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\bump_version.ps1 -Version 1.1.1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\bump_version.ps1 -Version 1.1.1 -Message "修 xxx"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\bump_version.ps1 -Version 1.2.0 -Publish

注意：本文件必须存成 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 GBK 读中文，
把字符串引号吃掉、整个脚本语法报错。

做的事：
  1. 改 pubspec.yaml 的 `version: X+Y`（build 号自动 +1）
  2. 改 lib/core/app_info.dart 的 appVersion
  3. flutter analyze（零错误零告警 + info 不许超基线）+ flutter test
  4. git add / commit / tag vX / **推 GitHub 与 Gitee 两边**（含 tag）
  5. 带 -Publish 时：出拆分包并传到 Gitee 发行版附件

**发布节奏（用户 2026-09-20 明确要求）**：
「以后不要修一次就发布，累计个5次以上，或者等我通知」
→ **默认不要跑这个脚本**。改动留在工作区攒着（`git status` 看得见），
   攒够约 5 项、或用户明确说"发吧"再跑一次。一个版本号对应**一批**改动。

**-Publish 的语义 = 必须把 APK 附件传成功**（在线更新能不能用全看发行版上有没有包）：
缺 GITEE_TOKEN 直接中止、构建失败中止、子脚本失败中止、传完还要回查附件在不在 ——
四道都不许"静默放过"，否则会出现"脚本说发布了、用户点检查更新却说没有适配机型的包"。
只传拆分包（arm64-v8a + armeabi-v7a）；通用包 97.7MB 在本机上行下传不动。
事后单独补传某一版：`publish_release.ps1 -Version X -ApkPath <该版 APK>`（带重试，可重复跑）。
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

# ---- 5) 出包并上传发行版附件（-Publish 才做）----
#
# **-Publish 的语义 = 必须把附件传成功**，因为"在线更新能不能用"全看发行版上有没有包。
# 早先这里只是"顺手试一下"：缺令牌静默跳过、构建失败不拦、子脚本失败不拦、传完不校验 ——
# 结果就是"脚本说发布了，用户点检查更新却提示没有适配机型的包"。
# 现在四道都拦：缺令牌中止 / 构建失败中止 / 子脚本非 0 中止 / 最后确认附件真的在。
#
# 只传**拆分包**：通用包 97.7MB 在这种上行下传不动；拆成 ABI 后 arm64 才 36.9MB。
# App 端按设备 ABI 挑对应附件（见 lib/data/update_source.dart 的 pickApkAssetForAbi）。
if ($Publish) {
  if (-not $env:GITEE_TOKEN) {
    throw "带了 -Publish 但没有 GITEE_TOKEN：附件传不上去，在线更新会断。请先设置令牌，或去掉 -Publish。"
  }

  # 构建：**必须看退出码** —— 否则构建失败会拿上一次的旧包去传（静默传错产物）
  $prevEap2 = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & 'E:\flutter\bin\flutter.bat' build apk --release --split-per-abi 2>&1 |
      ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "flutter build 失败，没有产出可发布的包" }
  } finally {
    $ErrorActionPreference = $prevEap2
  }

  $failed = @()
  foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
    $src = Join-Path $root "build\app\outputs\flutter-apk\app-$abi-release.apk"
    if (-not (Test-Path $src)) {
      Write-Host "没有 $abi 的产物"
      $failed += $abi
      continue
    }
    $dst = Join-Path (Split-Path -Parent $root) "tiaocang-zhushou-v$Version-$abi.apk"
    Copy-Item $src $dst -Force
    # 子脚本的 stderr 也要接进来、并**检查退出码**：不带 2>&1 时它的失败
    # 只写到控制台、父脚本完全感知不到，于是两个附件都没传上去也照样"成功"
    $prevEap3 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot 'publish_release.ps1') `
        -Version $Version -ApkPath $dst `
        -AssetName "tiaocang-zhushou-v$Version-$abi.apk" 2>&1 |
        ForEach-Object { Write-Host $_ }
      if ($LASTEXITCODE -ne 0) { $failed += $abi }
    } finally {
      $ErrorActionPreference = $prevEap3
    }
  }

  if ($failed.Count -gt 0) {
    throw "这些架构的附件没传成功：$($failed -join '、') —— 对应机型在线更新会不可用。" +
      "补救（可重复跑，只重传）：publish_release.ps1 -Version $Version -ApkPath E:\DSH\tiaocang-zhushou-v$Version-<abi>.apk"
  }
  Write-Host "在线更新已就绪：v$Version 的 APK 附件已在 Gitee 发行版上"
}
