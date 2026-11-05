#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$NoPath,
    [switch]$WithPlugin
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$bin = Join-Path $root "bin"
$entry = Join-Path $bin "opencode-unlimited.cmd"
$ps1 = Join-Path $bin "opencode-unlimited.ps1"
$pluginSrc = Join-Path $root "plugins\unlimited-shield.js"

$userHome = [Environment]::GetFolderPath("UserProfile")
if (-not $userHome) { $userHome = $env:USERPROFILE }
$configDir = Join-Path $userHome ".config\opencode"
$pluginDir = Join-Path $configDir "plugins"
$pluginDst = Join-Path $pluginDir "unlimited-shield.js"

function Ok($t) { Write-Host "  [+] $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  [x] $t" -ForegroundColor Red; exit 1 }
function Warn($t) { Write-Host "  [!] $t" -ForegroundColor Yellow }
function Info($t) { Write-Host "      $t" -ForegroundColor DarkGray }

Write-Host "==> opencode-unlimited install"

$required = @(
    $entry,
    $ps1,
    (Join-Path $root "lib\proxy-bridge.js"),
    (Join-Path $root "lib\oc-info.js"),
    (Join-Path $root "lib\db-tools.js"),
    (Join-Path $root "lib\session-reid.js"),
    (Join-Path $root "lib\identity.js"),
    (Join-Path $root "lib\egress.js"),
    (Join-Path $root "lib\model-switch.js")
)
foreach ($file in $required) {
    if (-not (Test-Path $file)) { Bad "missing build artifact: $file" }
}
Ok "build artifacts present"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) { Ok "node $((& $node.Source --version).Trim())" } else { Info "node not found: session tools and identity helpers stay unavailable" }

if ($WithPlugin) {
    if (-not (Test-Path $pluginSrc)) { Bad "missing plugin: $pluginSrc" }
    if (-not (Test-Path $pluginDir)) { New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null }
    Copy-Item $pluginSrc $pluginDst -Force
    Ok "plugin deployed: $pluginDst"
} elseif (Test-Path $pluginDst) {
    Warn "an old plugin copy is present: $pluginDst"
    Info "it rewrites request headers and does not change the quota"
    Info "remove it with: opencode-unlimited off"
} else {
    Ok "plugin not installed (it does not change the quota)"
}

if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($null -eq $userPath) { $userPath = "" }
    if ($userPath -notlike "*$bin*") {
        $newPath = if ($userPath.Trim()) { $userPath.TrimEnd(";") + ";" + $bin } else { $bin }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Ok "added to user PATH: $bin"
        Info "open a new terminal to pick it up"
    } else {
        Info "already on user PATH: $bin"
    }
    $currentPath = $env:PATH
    if ($null -eq $currentPath) { $currentPath = "" }
    $env:PATH = $currentPath.TrimEnd(";") + ";" + $bin
}

$shell = Get-Command powershell -ErrorAction SilentlyContinue
if ($shell) {
    & $shell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ps1 install
}

Write-Host ""
Write-Host "  next:" -ForegroundColor Cyan
Info "opencode-unlimited version    tool plus the detected opencode version"
Info "opencode-unlimited usage      what the meter is doing today"
Info "opencode-unlimited reset .    new device id, new session ids, nothing lost"
Info "opencode-unlimited model      providers you can switch to"
Info "opencode-unlimited status     runtime, identity, network, ledger"
Info "opencode-unlimited proxy set socks5://127.0.0.1:1080   optional IP path"
Write-Host ""
Ok "installed"
