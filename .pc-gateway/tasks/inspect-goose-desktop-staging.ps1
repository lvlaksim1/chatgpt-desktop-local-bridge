param([string]$GatewayRequestPath,[string]$GatewayResultPath)
$ErrorActionPreference='Stop'
$dir='D:\LocalAI\Goose\desktop\.stage-v1.56.0'
$r=@{status='diagnostic';error='';exe_files=@();top_directories=@();zip_present=$false}
try{
 $r.zip_present=Test-Path 'D:\LocalAI\Goose\downloads\Goose-win32-x64-v1.56.0.zip'
 if(Test-Path -LiteralPath $dir -PathType Container){
  $r.exe_files=@(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'Goose.exe'|ForEach-Object { $_.FullName + ';bytes='+[string]$_.Length })
  $r.top_directories=@(Get-ChildItem -LiteralPath $dir | Select-Object -First 10 | ForEach-Object { $_.Name })
 }
 $r.error='exes='+($r.exe_files -join ' | ')+'; tops='+($r.top_directories -join ',')
}catch{$r.error=[string]$_.Exception.Message}
if($r.error.Length -gt 680){$r.error=$r.error.Substring(0,680)}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $GatewayResultPath -Encoding UTF8
exit 0
