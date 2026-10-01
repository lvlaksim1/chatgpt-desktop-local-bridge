param(
    [int]$KeepInstallable = 2
)

$ErrorActionPreference = "Stop"

if ($KeepInstallable -lt 1) {
    throw "KeepInstallable must be at least 1."
}

$raw = gh release list --limit 100 --json tagName,isPrerelease,publishedAt | Out-String
$releases = @($raw | ConvertFrom-Json) |
    Where-Object { $_.isPrerelease -and $_.tagName -like "dev-*" } |
    Sort-Object { [DateTimeOffset]$_.publishedAt } -Descending

$installable = New-Object System.Collections.Generic.List[object]

foreach ($release in $releases) {
    $tag = $release.tagName
    $viewRaw = gh release view $tag --json assets | Out-String
    $view = $viewRaw | ConvertFrom-Json
    $assets = @($view.assets)

    foreach ($asset in $assets | Where-Object { $_.name -eq "ChatGptDesktopLocalBridge-win-x64.zip" }) {
        Write-Host "Deleting redundant portable asset $($asset.name) from $tag"
        gh release delete-asset $tag $asset.name --yes
    }

    $hasInstaller = @($assets | Where-Object { $_.name -eq "ChatGptDesktopLocalBridge-Setup.exe" }).Count -gt 0

    if ($hasInstaller) {
        $installable.Add($release)
        continue
    }

    Write-Host "Deleting obsolete non-installable development release $tag"
    gh release delete $tag --cleanup-tag --yes
}

$keep = @($installable | Select-Object -First $KeepInstallable)
$delete = @($installable | Select-Object -Skip $KeepInstallable)

foreach ($release in $delete) {
    Write-Host "Deleting old installable development release $($release.tagName)"
    gh release delete $release.tagName --cleanup-tag --yes
}

Write-Host "Retained development releases:"
foreach ($release in $keep) {
    Write-Host "  $($release.tagName)"
}
