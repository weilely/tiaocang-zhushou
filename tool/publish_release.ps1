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

# ---- 2) 传附件：流式 multipart ----
#    用 StreamContent 而不是 ByteArrayContent：
#    ① 97MB 不必全读进内存；② PowerShell 传数组给构造器会踩
#    "Cannot find an overload ... argument count: 102458758" 的坑。
Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMinutes(30)

$content = [System.Net.Http.MultipartFormDataContent]::new()
$content.Add([System.Net.Http.StringContent]::new($token), 'access_token')

$fs = [System.IO.File]::OpenRead($ApkPath)
$fileContent = [System.Net.Http.StreamContent]::new($fs)
$fileContent.Headers.ContentType =
  [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/vnd.android.package-archive')
$content.Add($fileContent, 'file', $attachName)

$url = "$api/releases/$releaseId/attach_files"
Write-Host "正在上传 $attachName（$sizeMb MB，可能要几分钟）…"
try {
  $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
  $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  if (-not $resp.IsSuccessStatusCode) {
    throw "上传失败 HTTP $([int]$resp.StatusCode)：$text"
  }
  Write-Host "上传成功"
} finally {
  $fs.Dispose()
  $client.Dispose()
}

Write-Host "下载页：https://gitee.com/$Repo/releases/tag/$tag"
