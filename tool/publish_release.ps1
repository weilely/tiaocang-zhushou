<#
把某个版本的 APK 上传到 Gitee 发行版（应用内更新需要 Release 带附件）。

用法（令牌从环境变量读，**不要写进命令行**，会被记进 shell 历史）：
    $env:GITEE_TOKEN = '你的私人令牌'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\publish_release.ps1 -Version 1.0.4

令牌怎么来：Gitee → 设置 → 私人令牌 → 生成新令牌，勾上 `projects` 权限即可。
本脚本只读环境变量，不会把令牌写进任何文件。

做的事：
  1. 找 tag v<Version>（没有就报错）
  2. 建/取该 tag 的发行版（已存在就复用）
  3. 把 APK 作为附件传上去
  4. 附件名用**纯英文**：tiaocang-zhushou-v<Version>.apk
     （GitHub 会把中文文件名洗成 "-v1.0.0.apk"，所以两边统一用英文名）
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Repo = 'weilely/tiaocang-zhushou',
  [string]$ApkPath,
  [string]$Note = ''
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
$attachName = "tiaocang-zhushou-$tag.apk"

# ---- 1) 发行版：存在就复用 ----
$releaseId = $null
try {
  $rel = Invoke-RestMethod -Uri "$api/releases/tags/$tag" -Headers @{ 'User-Agent' = 'dsh' } -TimeoutSec 30
  $releaseId = $rel.id
  Write-Host "已存在发行版 $tag（id=$releaseId），复用"
} catch {
  Write-Host "还没有 $tag 的发行版，创建一个"
  $body = @{
    tag_name = $tag
    name     = "调仓助手 $tag"
    body     = if ($Note) { $Note } else { "调仓助手 $tag" }
  } | ConvertTo-Json
  $created = Invoke-RestMethod -Uri "$api/releases" -Method Post `
    -Headers @{ 'User-Agent' = 'dsh' } `
    -ContentType 'application/json;charset=UTF-8' `
    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
    -TimeoutSec 30
  $releaseId = $created.id
  Write-Host "已创建（id=$releaseId）"
}

# ---- 2) 传附件（multipart/form-data）----
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(30)

$content = New-Object System.Net.Http.MultipartFormDataContent
$content.Add((New-Object System.Net.Http.StringContent($token)), 'access_token')

$bytes = [System.IO.File]::ReadAllBytes($ApkPath)
$fileContent = New-Object System.Net.Http.ByteArrayContent($bytes)
$fileContent.Headers.ContentType =
  [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/vnd.android.package-archive')
$content.Add($fileContent, 'file', $attachName)

$url = "$api/releases/$releaseId/attach_files"
Write-Host "正在上传 $attachName（$sizeMb MB，可能要一会儿）…"
$resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
$text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
if (-not $resp.IsSuccessStatusCode) {
  throw "上传失败 HTTP $([int]$resp.StatusCode)：$text"
}
Write-Host "上传成功"
Write-Host "下载页：https://gitee.com/$Repo/releases/tag/$tag"
