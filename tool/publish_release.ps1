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

# ---- 2) 传附件：用 curl ----
# 为什么不用 .NET 的 HttpClient：同样的 multipart，.NET 会被 Gitee 判
# 「登录失效 401」（令牌放在 StringContent 体里它不认），而 curl 的 -F 是好的。
# 另外本机上行很慢（实测 ~31KB/s），所以 max-time 给足、并关掉 Expect: 100-continue
# （大文件带 Expect 容易被服务端晾住）。
$url = "$api/releases/$releaseId/attach_files?access_token=$token"
$respFile = Join-Path $env:TEMP "gitee_attach_resp.json"
Write-Host "正在上传 $attachName（$sizeMb MB）…"
& curl.exe -sS --max-time 3600 -H "Expect:" `
  -X POST $url `
  -F "file=@$ApkPath;type=application/vnd.android.package-archive;filename=$attachName" `
  -o $respFile -w "HTTP=%{http_code} 上传=%{size_upload}字节 耗时=%{time_total}s`n"
$code = $LASTEXITCODE
$body = if (Test-Path $respFile) { Get-Content $respFile -Raw } else { '' }
if ($code -ne 0) { throw "curl 失败（exit=$code）：$body" }
if ($body -notmatch '"name"') { throw "上传未成功，服务端返回：$body" }
Write-Host "上传成功：$($body.Trim())"

Write-Host "下载页：https://gitee.com/$Repo/releases/tag/$tag"
