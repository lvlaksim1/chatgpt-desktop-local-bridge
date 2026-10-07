[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GatewayRequestPath,
  [Parameter(Mandatory=$true)][string]$GatewayResultPath
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
function Finish([string]$s,[int]$c,[string]$e,[hashtable]$x){
  $o=[ordered]@{status=$s;exit_code=$c;error=$e}
  foreach($k in $x.Keys){$o[$k]=$x[$k]}
  $d=Split-Path -Parent $GatewayResultPath
  if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  $o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
  exit $c
}
try{
  $req=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
  $target=[string]$req.args.target_request_id
  if([string]::IsNullOrWhiteSpace($target)){throw 'target_request_id_missing'}
  if($target -notmatch '^[A-Za-z0-9._-]{1,160}$'){throw 'target_request_id_invalid'}
  $root=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence'
  $project=Join-Path (Join-Path $root $target) 'project-result.json'
  if(-not(Test-Path -LiteralPath $project -PathType Leaf)){throw 'project_result_missing'}
  $p=Get-Content -LiteralPath $project -Raw -Encoding UTF8|ConvertFrom-Json
  $obs=$p.observation
  $fileInputs=@()
  if($null -ne $obs -and $null -ne $obs.file_inputs){
    foreach($f in @($obs.file_inputs)){
      $fileInputs += [ordered]@{
        index = if($null -ne $f.i){[int]$f.i}elseif($null -ne $f.index){[int]$f.index}else{-1}
        accept = [string]$f.accept
        multiple = [bool]$f.multiple
        aria = [string]$f.aria
        testid = [string]$f.testid
      }
    }
  }
  $interestingButtons=@()
  if($null -ne $obs -and $null -ne $obs.buttons){
    foreach($b in @($obs.buttons)){
      $joined=([string]$b.text+' '+[string]$b.aria+' '+[string]$b.title+' '+[string]$b.testid)
      if($joined -match '(?i)attach|upload|file|add|plus|прикреп|добав|файл'){
        $interestingButtons += [ordered]@{index=[int]$b.i;text=[string]$b.text;aria=[string]$b.aria;title=[string]$b.title;testid=[string]$b.testid}
      }
    }
  }
  $body=''
  if($null -ne $obs -and $null -ne $obs.body_text){$body=[string]$obs.body_text}
  if($body.Length -gt 6000){$body=$body.Substring(0,6000)}
  Finish 'pass' 0 '' @{
    target_request_id=$target
    probe_status=[string]$p.status
    probe_error=[string]$p.error
    cdp_ws=[string]$p.cdp_ws
    page_url=if($null -ne $obs){[string]$obs.url}else{''}
    page_title=if($null -ne $obs){[string]$obs.title}else{''}
    page_ready=if($null -ne $obs){[string]$obs.ready}else{''}
    file_input_count=$fileInputs.Count
    file_inputs=$fileInputs
    interesting_button_count=$interestingButtons.Count
    interesting_buttons=$interestingButtons
    body_text=$body
  }
}catch{Finish 'fail' 40 $_.Exception.Message @{}}
