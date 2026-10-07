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
  $matches=@()
  if($null -ne $obs -and $null -ne $obs.links){
    foreach($a in @($obs.links)){
      $s=([string]$a.text+' '+[string]$a.href+' '+[string]$a.aria)
      if($s -match '(?i)scheduled|task|automation|заплан'){
        $matches += [ordered]@{text=[string]$a.text;href=[string]$a.href;aria=[string]$a.aria}
      }
    }
  }
  $compact=([ordered]@{target=$target;url=[string]$obs.url;links=$matches}|ConvertTo-Json -Depth 6 -Compress)
  @{status='evidence';exit_code=7;error=$compact}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit 7
}
catch {
  @{status='fail';exit_code=40;error=$_.Exception.Message}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit 40
}
