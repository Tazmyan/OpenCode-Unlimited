$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$version = if ($env:RELEASE_TAG) { $env:RELEASE_TAG.TrimStart("v") } else { "0.0.0" }
$outDir = Join-Path $root "dist"
$stage = Join-Path $outDir "OpenCode-Unlimited-$version"
$zip = Join-Path $outDir "OpenCode-Unlimited-$version.zip"

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

foreach ($item in @("bin", "lib", "plugins", "install.ps1", "README.md")) {
    Copy-Item (Join-Path $root $item) (Join-Path $stage $item) -Recurse -Force
}

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$size = [math]::Round((Get-Item $zip).Length / 1KB)

Write-Host "artifact : $zip"
Write-Host "size     : $size KB"
Write-Host "sha256   : $hash"

$manifest = [ordered]@{
    version     = $version
    description = "Gets you past OpenCode's free message limit, and tells you when it's back."
    homepage    = "https://github.com/Tazmyan/OpenCode-Unlimited"
    url         = "https://github.com/Tazmyan/OpenCode-Unlimited/releases/download/v$version/OpenCode-Unlimited-$version.zip"
    hash        = $hash
    bin         = ,@("opencode-unlimited.cmd", "opencode-unlimited")
    depends     = "nodejs"
    checkver    = "github"
    autoupdate  = @{
        url = "https://github.com/Tazmyan/OpenCode-Unlimited/releases/download/v`$version/OpenCode-Unlimited-`$version.zip"
    }
}

$scoopDir = Join-Path $root "scoop"
New-Item -ItemType Directory -Path $scoopDir -Force | Out-Null
$manifestPath = Join-Path $scoopDir "opencode-unlimited.json"
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "manifest : $manifestPath"
