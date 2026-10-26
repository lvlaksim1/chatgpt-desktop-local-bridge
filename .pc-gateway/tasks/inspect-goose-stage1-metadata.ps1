[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GatewayRequestPath,[Parameter(Mandatory=$true)][string]$GatewayResultPath)
$ErrorActionPreference='Continue'
$dir='D:\LocalAI\Goose\stage1-isolated\data\logs'
$report=[ordered]@{status='diagnostic';error='';directory_exists=$false;matching_files=@();latest_file='';entries=@()}
$report.directory_exists=(Test-Path -LiteralPath $dir -PathType Container)
if($report.directory_exists){
 $files=@(Get-ChildItem -LiteralPath $dir -File -Filter 'llm_request*.jsonl' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 4)
 $report.matching_files=@($files|ForEach-Object{$_.Name+':'+$_.Length})
 if($files.Count -gt 0){
  $report.latest_file=$files[0].Name
  $lines=@(Get-Content -LiteralPath $files[0].FullName -Tail 8 -ErrorAction SilentlyContinue)
  foreach($line in $lines){
   if([string]::IsNullOrWhiteSpace($line)){continue}
   $item=[ordered]@{length=$line.Length;keys='';request_keys='';model='';stream='';num_ctx='';num_predict='';max_tokens='';message_count='';tool_count='';system_chars='';message_chars=''}
   try{
    $obj=ConvertFrom-Json -InputObject $line -ErrorAction Stop
    $item.keys=@($obj.PSObject.Properties.Name) -join ','
    $payload=$obj
    if($null -ne $obj.input){$payload=$obj.input}
    if($payload -is [string]){try{$payload=ConvertFrom-Json -InputObject $payload}catch{}}
    if($null -ne $obj.payload){$payload=$obj.payload}
    if($null -ne $obj.request){$payload=$obj.request}
    if($null -ne $payload.payload){$payload=$payload.payload}
    if($null -ne $payload.body){$payload=$payload.body}
    $item.request_keys=@($payload.PSObject.Properties.Name) -join ','
    if($null -ne $payload.model){$item.model=[string]$payload.model}
    if(-not $item.model -and $null -ne $obj.model_config){$item.model=[string]$obj.model_config.model_name}
    if($null -ne $payload.stream){$item.stream=[string]$payload.stream}
    if($null -ne $payload.max_tokens){$item.max_tokens=[string]$payload.max_tokens}
    if($null -ne $payload.max_completion_tokens){$item.max_tokens=[string]$payload.max_completion_tokens}
    if($null -ne $payload.options){
     if($null -ne $payload.options.num_ctx){$item.num_ctx=[string]$payload.options.num_ctx}
     if($null -ne $payload.options.num_predict){$item.num_predict=[string]$payload.options.num_predict}
    }
    if($null -ne $payload.messages){
     $item.message_count=[string]@($payload.messages).Count
     $sum=0
     foreach($m in @($payload.messages)){if($null -ne $m.content){$sum+=([string]$m.content).Length}}
     $item.message_chars=[string]$sum
    }
    if($null -ne $payload.tools){$item.tool_count=[string]@($payload.tools).Count}
    if($null -ne $payload.system){$item.system_chars=[string]([string]$payload.system).Length}
   }catch{$item.keys='JSON_PARSE_ERROR'}
   $report.entries+=($item)
  }
 }
}
$report.error='files='+($report.matching_files -join ';')+' entries='+(@($report.entries|ForEach-Object{'line='+$_.length+' keys='+$_.keys+' request_keys='+$_.request_keys+' model='+$_.model+' num_ctx='+$_.num_ctx+' num_predict='+$_.num_predict+' max_tokens='+$_.max_tokens+' msgs='+$_.message_count+' msg_chars='+$_.message_chars+' tools='+$_.tool_count}) -join ' | ')
if($report.error.Length -gt 690){$report.error=$report.error.Substring(0,690)}
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
