[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$GatewayRequestPath,
    [Parameter(Mandatory = $true)] [string]$GatewayResultPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

function Finish([string]$Status,[int]$Code,[string]$ErrorText='',[hashtable]$Extra=@{}){
    $p=[ordered]@{status=$Status;error=$ErrorText;exit_code=$Code}
    foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]}
    $d=Split-Path -Parent $GatewayResultPath
    if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null}
    $p|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
    exit $Code
}

try{
    $request=Get-Content -LiteralPath $GatewayRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $target=[string]$request.args.target_request_id
    if([string]::IsNullOrWhiteSpace($target)){throw 'target_request_id is required.'}

    $ledgerRoot=Join-Path $env:LOCALAPPDATA 'GitHubRunner\pc-runner-gateway\request-ledger\evidence'
    $projectResult=Join-Path (Join-Path $ledgerRoot $target) 'project-result.json'
    if(-not(Test-Path -LiteralPath $projectResult -PathType Leaf)){throw "project-result.json not found for $target"}

    $payload=Get-Content -LiteralPath $projectResult -Raw -Encoding UTF8|ConvertFrom-Json
    $b64=[string]$payload.dom_json_base64
    if([string]::IsNullOrWhiteSpace($b64)){throw 'dom_json_base64 is missing in target result.'}

    $json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    $dom=$json|ConvertFrom-Json
    $rows=@()

    foreach($c in @($dom.candidates)){
        $rows += [ordered]@{
            tag=[string]$c.tag
            id=[string]$c.id
            role=[string]$c.role
            ce=[string]$c.contenteditable
            testid=[string]$c.testid
            placeholder=[string]$c.placeholder
            aria=[string]$c.ariaLabel
            cls=([string]$c.classes).Substring(0,[Math]::Min(120,([string]$c.classes).Length))
        }
    }

    $compact=($rows|ConvertTo-Json -Depth 5 -Compress)
    if($compact.Length -gt 600){$compact=$compact.Substring(0,600)}

    Finish 'pass' 0 $compact @{
        target_request_id=$target
        href=[string]$dom.href
        title=[string]$dom.title
        candidate_count=@($dom.candidates).Count
        body_prefix=([string]$dom.bodyText).Substring(0,[Math]::Min(300,([string]$dom.bodyText).Length))
    }
}catch{
    Finish 'fail' 31 $_.Exception.Message
}
