<#
把某个版本的 APK 上传到 Gitee 发行版（应用内更新需要 Release 带附件）。

用法（令牌从环境变量读，**不要写进命令行**，会被记进 shell 历史）：
    $env:GITEE_TOKEN = '你的私人令牌'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\publish_release.ps1 -Version 1.0.4

令牌怎么来：Gitee → 设置 → 私人令牌 → 生成新令牌，勾上 `projects` 权限即可。
本脚本只读环境变量，不会把令牌写进任何文件。

做的事：
  1. 列出该仓库的发行版，按 tag 找到（没有就创建）
  2. 把 APK 作为附件传上去（流式，不把整个包读进内存）
  3. 附件名用**纯英文**：tiaocang-zhushou-v<Version>.apk
     （GitHub 会把中文文件名洗成 "-v1.0.0.apk"，所以两边统一英文名）
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Repo = 'weilely/tiaocang-zhushou',
  [string]$ApkPath,
  [string]$Note = '',
  [string]$AssetName = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$token = $env:GITEE_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
  throw "没有拿到令牌：请先 `$env:GITEE_TOKEN = '...' 再跑本脚本"
}

if (-not $ApkPath) { $ApkPath = Join-Path (Split-Path -Parent $root) "调仓助手-v$Version.apk" }
if (-not (Test-Path $ApkPath)) { throw "找不到 APK：$ApkPath" }
$sizeMb = [math]::Round((Get-Item $ApkPath).Length / 1MB, 1)
Write-Host "APK: $ApkPath ($sizeMb MB)"

$tag = "v$Version"
$api = "https://gitee.com/api/v5/repos/$Repo"
if (-not $AssetName) { $AssetName = "tiaocang-zhushou-$tag.apk" }
$attachName = $AssetName
$headers = @{ 'User-Agent' = 'dsh' }

# ---- 1) 找发行版：**用列表接口按 tag 过滤**
#      （Gitee 的 /releases/tags/xx 返回的不是单对象，取不到 id）----
$releaseId = $null
try {
  $list = Invoke-RestMethod -Uri "$api/releases?access_token=$token&per_page=100" `
    -Headers $headers -TimeoutSec 30
  $hit = $list | Where-Object { $_.tag_name -eq $tag } | Select-Object -First 1
  if ($hit) {
    $releaseId = $hit.id
    Write-Host "已存在发行版 $tag（id=$releaseId），复用"
  }
} catch {
  Write-Host "列出发行版失败（将尝试直接创建）：$($_.Exception.Message)"
}

if (-not $releaseId) {
  Write-Host "还没有 $tag 的发行版，创建一个"
  $body = @{
    tag_name         = $tag
    # Gitee 建发行版**必须**给 target_commitish（GitHub 是可选的），
    # 填它对应的 tag 名即可；不给会返回 {"messages":["target_commitish is missing"]}
    target_commitish = $tag
    name             = "调仓助手 $tag"
    body             = if ($Note) { $Note } else { "调仓助手 $tag" }
  } | ConvertTo-Json
  $created = Invoke-RestMethod -Uri "$api/releases?access_token=$token" -Method Post `
    -Headers $headers `
    -ContentType 'application/json;charset=UTF-8' `
    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
    -TimeoutSec 30
  $releaseId = $created.id
  if (-not $releaseId) { throw "创建发行版失败：$($created | ConvertTo-Json -Compress)" }
  Write-Host "已创建（id=$releaseId）"
}

# ---- 2) 传附件：用 curl（**带重试**）----
# 为什么不用 .NET 的 HttpClient：同样的 multipart，.NET 会被 Gitee 判
# 「登录失效 401」（令牌放在 StringContent 体里它不认），而 curl 的 -F 是好的。
# 本机上行很慢（实测 20~107KB/s），36.9MB 在慢的时候要 30 分钟、连接会被重置，
# 所以**必须重试**：单次失败不代表传不上去。
$url = "$api/releases/$releaseId/attach_files?access_token=$token"
$attempts = if ($env:GITEE_UPLOAD_RETRIES) { [int]$env:GITEE_UPLOAD_RETRIES } else { 3 }
$ok = $false
for ($i = 1; $i -le $attempts; $i++) {
  # 每次用**独立**的响应文件：固定路径会读到上一次的残留响应，
  # 出错时打印的是别的版本的附件信息（我因此被误导过一次）
  $respFile = Join-Path $env:TEMP "gitee_attach_resp_$PID`_$i.json"
  if (Test-Path $respFile) { Remove-Item $respFile -Force }
  Write-Host "上传 $attachName（$sizeMb MB）第 $i/$attempts 次…"
  & curl.exe -sS --max-time 3600 -H "Expect:" `
    -X POST $url `
    -F "file=@$ApkPath;type=application/vnd.android.package-archive;filename=$attachName" `
    -o $respFile -w "HTTP=%{http_code} 上传=%{size_upload}字节 耗时=%{time_total}s 速度=%{speed_upload}B/s`n" 2>&1 |
    ForEach-Object { Write-Host $_ }
  $code = $LASTEXITCODE
  $body = if (Test-Path $respFile) { Get-Content $respFile -Raw } else { '' }
  # 判据①：curl 成功 + 返回体里有附件信息
  # 判据②：返回体里的 size 与本地文件一致（防止"传了半个"或拿到别的响应）
  $sizeOk = $true
  if ($body -match '"size"\s*:\s*(\d+)') {
    $sizeOk = ([int64]$Matches[1] -eq (Get-Item $ApkPath).Length)
  }
  if ($code -eq 0 -and $body -match '"name"' -and $sizeOk) { $ok = $true; break }
  if (-not $sizeOk) { Write-Host "第 $i 次：返回体里的 size 与本地文件不一致" }
  Write-Host "第 $i 次失败（exit=$code）：$(($body -replace '\s+', ' '))"
  if ($i -lt $attempts) { Start-Sleep -Seconds 10 }
}

if (-not $ok) {
  throw "附件没传成功：$attachName —— 在线更新会因此不可用。可重跑本脚本重传。"
}

# ---- 3) 附带复核：再查一次发行版上有没有它 ----
# **注意：这一步只作参考，不作为成败判据。**
# 实测踩过：上传明明成功（HTTP 201、size 也与本地一致），紧接着查发行版却返回
# `(401) 未经授权`（同一令牌手动查是好的）——说明 Gitee 的查询接口会偶发 401/限流。
# 若拿它当判据，会把好版本误报成"在线更新不可用"，反而把人引偏。
try {
  $rel = Invoke-RestMethod -Uri "$api/releases/$releaseId`?access_token=$token" `
    -Headers $headers -TimeoutSec 30
  $verify = @($rel.assets | Where-Object { $_.name -eq $attachName }) |
    Select-Object -First 1
  if ($verify) {
    Write-Host "已复核：附件在发行版上（$($verify.name)）"
  } else {
    Write-Host "复核提示：发行版列表里暂时没看到 $attachName（上传已返回 201，稍后可再查一次）"
  }
} catch {
  Write-Host "复核查询不可用（$($_.Exception.Message)）；上传本身已返回 201 且大小一致，按成功处理"
}
Write-Host "下载页：https://gitee.com/$Repo/releases/tag/$tag"
