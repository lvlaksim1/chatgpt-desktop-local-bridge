[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
try {
  $req=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
  $target=[string]$req.args.target_request_id
  if([string]::IsNullOrWhiteSpace($target)){throw 'target_request_id_missing'}
  if($target -notmatch '^[A-Za-z0-9._-]{1,160}$'){throw 'target_request_id_invalid'}
  $root=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence'
  $project=Join-Path (Join-Path $root $target) 'project-result.json'
  if(-not(Test-Path -LiteralPath $project -PathType Leaf)){throw 'project_result_missing'}
  $p=Get-Content -LiteralPath $project -Raw -Encoding UTF8|ConvertFrom-Json
  $obs=$p.observation
  $files=@()
  if($null -ne $obs -and $null -ne $obs.file_inputs){foreach($f in @($obs.file_inputs)){$files += [ordered]@{i=if($null -ne $f.i){[int]$f.i}else{[int]$f.index};accept=[string]$f.accept;multiple=[bool]$f.multiple;aria=[string]$f.aria;testid=[string]$f.testid}}}
  $buttons=@()
  if($null -ne $obs -and $null -ne $obs.buttons){foreach($b in @($obs.buttons)){$joined=([string]$b.text+' '+[string]$b.aria+' '+[string]$b.title+' '+[string]$b.testid);if($joined -match '(?i)attach|upload|file|add|plus|прикреп|добав|файл'){$buttons += [ordered]@{i=[int]$b.i;text=[string]$b.text;aria=[string]$b.aria;title=[string]$b.title;testid=[string]$b.testid}}}}
  $body=''; if($null -ne $obs -and $null -ne $obs.body_text){$body=[string]$obs.body_text}; if($body.Length -gt 2000){$body=$body.Substring(0,2000)}
  $evidence=[ordered]@{target=$target;status=[string]$p.status;url=if($null -ne $obs){[string]$obs.url}else{''};title=if($null -ne $obs){[string]$obs.title}else{''};file_inputs=$files;buttons=$buttons;body=$body}
  $compact=$evidence|ConvertTo-Json -Depth 8 -Compress
  @{status='evidence';exit_code=7;error=$compact}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit 7
}
catch {
  @{status='fail';exit_code=40;error=$_.Exception.Message}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit 40
}
