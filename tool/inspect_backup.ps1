<#
备份文件对账（只读，不改任何东西）

用法：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool\inspect_backup.ps1 -Path <备份.json>

打印：版本/导出时间/各表条数/关注列表代码/定投计划/目标占比/账户，
并**检查关注列表有没有重复条目**（恢复后关注页出现重复行的常见原因）。

为什么要它：用户反馈"覆盖恢复后持仓、金额、关注列表都不一样"。
先把备份本身的真实内容列清楚，才能判断是"恢复丢了数据"还是"数据本来就长这样"。
#>
param(
  [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { throw "找不到文件：$Path" }

$raw = [System.IO.File]::ReadAllText($Path)
$j = $raw | ConvertFrom-Json

$n = { param($x) if ($null -eq $x) { 0 } else { @($x).Count } }

Write-Host "===== 备份概览 ====="
Write-Host ("版本      : v{0}" -f $j.version)
if ($j.exportedAt) {
  $t = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$j.exportedAt).ToLocalTime()
  Write-Host ("导出时间  : {0}" -f $t.ToString('yyyy-MM-dd HH:mm:ss'))
}
Write-Host ("账户      : {0}" -f (& $n $j.accounts))
Write-Host ("标的      : {0}" -f (& $n $j.assets))
Write-Host ("交易流水  : {0}" -f (& $n $j.txns))
Write-Host ("现金流水  : {0}" -f (& $n $j.cashTxns))
Write-Host ("调仓目标  : {0}" -f (& $n $j.targets))
Write-Host ("关注列表  : {0}" -f (& $n $j.watchlist))
Write-Host ("定投计划  : {0}" -f (& $n $j.dcaPlans))
Write-Host ("设置项    : {0}" -f (& $n ($j.settings.PSObject.Properties)))

Write-Host ""
Write-Host "===== 账户 ====="
foreach ($a in @($j.accounts)) { Write-Host ("  id={0}  {1}" -f $a.id, $a.name) }

Write-Host ""
Write-Host "===== 标的（代码 → 名称）====="
foreach ($a in @($j.assets)) {
  Write-Host ("  id={0}  {1}  {2}  kind={3}  link={4}" -f $a.id, $a.code, $a.name, $a.kind, $a.link_code)
}

Write-Host ""
Write-Host "===== 关注列表 ====="
$codes = @()
foreach ($w in @($j.watchlist)) {
  Write-Host ("  {0}  {1}" -f $w.code, $w.name)
  $codes += [string]$w.code
}
$dup = $codes | Group-Object | Where-Object { $_.Count -gt 1 }
if ($dup) {
  Write-Host ""
  Write-Host "!! 关注列表里有重复代码（这会让关注页出现重复行）："
  foreach ($d in $dup) { Write-Host ("   {0} × {1}" -f $d.Name, $d.Count) }
} else {
  Write-Host ("  （无重复，共 {0} 个唯一代码）" -f (@($codes | Select-Object -Unique).Count))
}

Write-Host ""
Write-Host "===== 调仓目标 ====="
foreach ($t in @($j.targets)) { Write-Host ("  {0}  ratio={1}  ({2})" -f $t.key, $t.ratio, $t.label) }

Write-Host ""
Write-Host "===== 定投计划 ====="
foreach ($p in @($j.dcaPlans)) {
  Write-Host ("  assetId={0}  每期 {1}  {2}  day={3}  启用={4}" -f $p.asset_id, $p.amount, $p.frequency, $p.day_of_period, $p.enabled)
}

Write-Host ""
Write-Host "===== 按标的汇总流水（笔数 / 买入-卖出）====="
$byAsset = @{}
foreach ($t in @($j.txns)) {
  $k = [string]$t.asset_id
  if (-not $byAsset.ContainsKey($k)) { $byAsset[$k] = @{ n = 0; buy = 0.0; sell = 0.0 } }
  $byAsset[$k].n++
  $amt = [double]$t.amount
  if ($t.type -eq 'buy') { $byAsset[$k].buy += $amt }
  elseif ($t.type -eq 'sell') { $byAsset[$k].sell += $amt }
}
foreach ($k in ($byAsset.Keys | Sort-Object)) {
  $asset = @($j.assets) | Where-Object { [string]$_.id -eq $k } | Select-Object -First 1
  $nm = if ($asset) { "$($asset.code) $($asset.name)" } else { "(assetId=$k)" }
  Write-Host ("  {0}`n     笔数={1}  买入={2:N2}  卖出={3:N2}" -f $nm, $byAsset[$k].n, $byAsset[$k].buy, $byAsset[$k].sell)
}

Write-Host ""
Write-Host "===== 关键设置 ====="
foreach ($k in @('accountFilter', 'threshold', 'themeMode', 'biometricEnabled', 'lastAutoBackupDay')) {
  $v = $j.settings.$k
  if ($null -ne $v) { Write-Host ("  {0} = {1}" -f $k, $v) }
}
$shortKeys = @($j.settings.PSObject.Properties.Name | Where-Object { $_ -like 'assetShort:*' })
if ($shortKeys.Count -gt 0) { Write-Host ("  简称设置 {0} 条" -f $shortKeys.Count) }
$divKeys = @($j.settings.PSObject.Properties.Name | Where-Object { $_ -like 'dividendMode:*' })
if ($divKeys.Count -gt 0) { Write-Host ("  分红方式设置 {0} 条" -f $divKeys.Count) }

Write-Host ""
Write-Host "===== 交易流水逐笔（按时间）====="
foreach ($t in (@($j.txns) | Sort-Object { [int64]$_.date })) {
  $asset = @($j.assets) | Where-Object { [string]$_.id -eq [string]$t.asset_id } | Select-Object -First 1
  $cd = if ($asset) { [string]$asset.code } else { "assetId=$($t.asset_id)" }
  $d = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$t.date).ToLocalTime().ToString('yyyy-MM-dd')
  Write-Host ("  {0}  {1,-5} 金额={2,12:N2} 份额={3,12:N2} 费={4,7:N2}  {5}" -f $d, $t.type, $t.amount, $t.shares, $t.fee, "$cd $($t.note)")
}