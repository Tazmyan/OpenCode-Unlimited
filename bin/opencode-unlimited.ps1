#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:UserHome = [Environment]::GetFolderPath("UserProfile")
if (-not $script:UserHome) { $script:UserHome = $env:USERPROFILE }
$script:ConfigDir = Join-Path $script:UserHome ".config\opencode"
$script:DataDir = Join-Path $script:UserHome ".local\share\opencode"
$script:StateFile = Join-Path $script:ConfigDir "unlimited.json"
$script:IdentityFile = Join-Path $script:ConfigDir "identity.json"
$script:LegacyIdentity = Join-Path $script:UserHome ".opencode\identity.json"
$script:PluginDir = Join-Path $script:ConfigDir "plugins"
$script:PluginFile = Join-Path $script:PluginDir "unlimited-shield.js"
$script:PidFile = Join-Path $script:ConfigDir "unlimited-bridge.pid"
$script:LogFile = Join-Path $script:ConfigDir "unlimited-bridge.log"
$script:Gateway = "https://opencode.ai/inference/openai/v1/chat/completions"
$script:TraceUrl = "https://cloudflare.com/cdn-cgi/trace"
$script:DefaultModel = "deepseek-v4.1-flash-free"
$script:DefaultBridgePort = 8899

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:Root = Split-Path -Parent $script:ScriptDir
if (-not (Test-Path (Join-Path $script:Root "lib\proxy-bridge.js"))) { $script:Root = $script:ScriptDir }
$script:BridgeJs = Join-Path $script:Root "lib\proxy-bridge.js"
$script:BundledPlugin = Join-Path $script:Root "plugins\unlimited-shield.js"

function Write-Step([string]$Text) { Write-Host $Text }
function Write-Ok([string]$Text) { Write-Host "  [+] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [x] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "      $Text" -ForegroundColor DarkGray }

function New-Hex([int]$Bytes) {
    $buf = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buf)
    $rng.Dispose()
    -join ($buf | ForEach-Object { $_.ToString("x2") })
}

function Write-TextFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-TextFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-Json([string]$Path) {
    $raw = Read-TextFile $Path
    if (-not $raw) { return $null }
    try { return ($raw -replace "^\uFEFF", "" | ConvertFrom-Json) } catch { return $null }
}

function Get-Config {
    $cfg = [ordered]@{
        identityPath = $script:IdentityFile
        pluginPath   = $script:PluginFile
        model        = $script:DefaultModel
        orgId        = ""
        proxy        = ""
        bridgePort   = $script:DefaultBridgePort
        ipMode       = "manual"
        rotateDb     = $false
        lastIp       = ""
        lastBucket   = ""
        updatedAt    = ""
    }
    $saved = Get-Json $script:StateFile
    if ($saved) {
        foreach ($name in @($cfg.Keys)) {
            $prop = $saved.PSObject.Properties[$name]
            if ($null -ne $prop -and $null -ne $prop.Value) { $cfg[$name] = $prop.Value }
        }
    }
    return $cfg
}

function Save-Config($cfg) {
    $cfg.updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-TextFile $script:StateFile ($cfg | ConvertTo-Json -Depth 5)
}

function Resolve-OpenCode {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:APPDATA "npm\opencode.cmd"),
        (Join-Path $env:APPDATA "npm\opencode.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\opencode\opencode.exe"),
        (Join-Path $script:UserHome ".opencode\bin\opencode.exe"),
        (Join-Path $script:UserHome ".bun\bin\opencode.exe"),
        (Join-Path $script:UserHome "scoop\shims\opencode.exe"),
        "C:\ProgramData\chocolatey\bin\opencode.exe",
        "C:\Program Files\opencode\opencode.exe"
    )
    foreach ($path in $candidates) { if (Test-Path $path) { return $path } }
    return "opencode"
}

function Get-Curl {
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Invoke-Curl([string[]]$CurlArgs) {
    $curl = Get-Curl
    if (-not $curl) { return $null }
    $raw = & $curl @CurlArgs 2>$null
    if ($null -eq $raw) { return "" }
    return ($raw -join "`n")
}

function Invoke-WebRequestRaw([string]$Method, [string]$Url, [string]$Body, [string]$ProxyUrl) {
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = $Method
        $request.Timeout = 20000
        $request.UserAgent = "opencode/2.1.4"
        if ($ProxyUrl -and $ProxyUrl -match "^(https?|socks5h?)://") {
            $request.Proxy = New-Object System.Net.WebProxy($ProxyUrl)
        }
        if ($Body) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentType = "application/json"
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
        }
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        $status = [int]$response.StatusCode
        $response.Dispose()
        return [pscustomobject]@{ Status = $status; Body = $text }
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -eq $response) {
            return [pscustomobject]@{ Status = 0; Body = $_.Exception.Message }
        }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        $status = [int]$response.StatusCode
        $response.Dispose()
        return [pscustomobject]@{ Status = $status; Body = $text }
    } catch {
        return [pscustomobject]@{ Status = 0; Body = $_.Exception.Message }
    }
}

function Get-EgressIp([string]$ProxyUrl) {
    $curl = Get-Curl
    if ($curl) {
        $curlArgs = @("-s", "--max-time", "8")
        if ($ProxyUrl) { $curlArgs += @("--proxy", $ProxyUrl) }
        $curlArgs += $script:TraceUrl
        $out = Invoke-Curl $curlArgs
        if ($out) {
            foreach ($line in ($out -split "`n")) {
                if ($line -match "^ip=(.+)$") { return $Matches[1].Trim() }
            }
        }
    }
    $result = Invoke-WebRequestRaw "GET" $script:TraceUrl $null $ProxyUrl
    if ($result.Status -eq 200) {
        foreach ($line in ($result.Body -split "`n")) {
            if ($line -match "^ip=(.+)$") { return $Matches[1].Trim() }
        }
    }
    return "unavailable"
}

function Get-OrgId($cfg) {
    if ($cfg.orgId) { return $cfg.orgId }
    try {
        $oc = Resolve-OpenCode
        $raw = & $oc api get /api/provider 2>$null | Out-String
        $json = $raw | ConvertFrom-Json
        foreach ($provider in $json.data) {
            if ($provider.id -eq "opencode" -and $provider.headers.PSObject.Properties["x-opencode-org-id"]) {
                $org = $provider.headers."x-opencode-org-id"
                if ($org) {
                    $cfg.orgId = $org
                    Save-Config $cfg
                    return $org
                }
            }
        }
    } catch { }
    return ""
}

function Invoke-QuotaProbe($cfg) {
    $org = Get-OrgId $cfg
    if (-not $org) {
        return [pscustomobject]@{ State = "unknown"; Status = 0; Body = "org id not discovered yet" }
    }
    $model = $cfg.model
    if ($model -like "*/*") { $model = $model.Split("/")[-1] }
    $payload = @{
        model      = $model
        messages   = @(@{ role = "user"; content = "1" })
        max_tokens = 1
        stream     = $false
    } | ConvertTo-Json -Depth 5 -Compress

    $curl = Get-Curl
    if ($curl) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unlimited-probe-" + (New-Hex 6) + ".json")
        Write-TextFile $tmp $payload
        try {
            $raw = Invoke-Curl @(
                "-s", "-o", "-", "-w", "`n%{http_code}",
                "--max-time", "20",
                "-X", "POST", $script:Gateway,
                "-H", "Content-Type: application/json",
                "-H", "User-Agent: opencode/2.1.4",
                "-H", "x-opencode-client: cli",
                "-H", ("x-opencode-project: " + (New-Hex 20)),
                "-H", ("x-opencode-org-id: " + $org),
                "--data-binary", ("@" + $tmp)
            )
            if ($null -ne $raw) {
                $idx = $raw.LastIndexOf("`n")
                if ($idx -gt 0) {
                    $body = $raw.Substring(0, $idx).Trim()
                    $code = [int]($raw.Substring($idx + 1).Trim())
                    return New-ProbeResult $code $body
                }
            }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    $headers = "x-opencode-org-id: " + $org
    $fallback = Invoke-WebRequestRaw "POST" $script:Gateway $payload $null
    return New-ProbeResult $fallback.Status $fallback.Body
}

function New-ProbeResult([int]$Code, [string]$Body) {
    $state = "unknown"
    if ($Code -eq 429 -and $Body -match "FreeUsageLimitError") {
        $state = "exhausted"
    } elseif ($Code -eq 400 -and $Body -match "x-opencode-org-id") {
        $state = "unknown"
    } elseif ($Code -gt 0) {
        $state = "fresh"
    } else {
        $state = "error"
    }
    return [pscustomobject]@{ State = $state; Status = $Code; Body = $Body }
}

function Get-BucketLabel([string]$State) {
    switch ($State) {
        "fresh" { return "FRESH - free messages available on this IP" }
        "exhausted" { return "EMPTY - daily free messages used up on this IP" }
        "unknown" { return "UNKNOWN - could not read the bucket" }
        default { return "ERROR - probe failed" }
    }
}

function New-Identity([switch]$Quiet) {
    $id = New-Hex 20
    $drive = $env:SystemDrive
    if (-not $drive) { $drive = "C:" }
    $dir = Join-Path $drive ("dev\workspace-" + (New-Hex 4))
    $identity = [ordered]@{
        projectId = $id
        clientId  = "cli"
        directory = $dir
        createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $json = $identity | ConvertTo-Json -Depth 4
    Write-TextFile $script:IdentityFile $json
    if (Test-Path (Split-Path -Parent $script:LegacyIdentity)) {
        Write-TextFile $script:LegacyIdentity $json
    }
    if (-not $Quiet) {
        Write-Ok ("project id  " + $id)
        Write-Ok ("directory   " + $dir)
        Write-Info "written to $script:IdentityFile"
    }
    return $identity
}

function Get-Identity {
    foreach ($path in @($script:IdentityFile, $script:LegacyIdentity)) {
        $parsed = Get-Json $path
        if ($parsed -and $parsed.projectId) { return $parsed }
    }
    return $null
}

function Test-NodeSqlite {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $false }
    $version = & $node.Source -e "process.versions.node" 2>$null
    if (-not $version) { return $false }
    $parts = $version.Trim().Split(".")
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -gt 22) { return $true }
    if ($major -eq 22 -and $minor -ge 5) { return $true }
    return $false
}

function Get-DatabasePath {
    $db = Join-Path $script:DataDir "opencode.db"
    if (Test-Path $db) { return $db }
    return ""
}

function Invoke-NodeScript([string]$Source, [string[]]$ScriptArgs) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unlimited-" + (New-Hex 5) + ".js")
    Write-TextFile $tmp $Source
    try {
        return (& $node.Source $tmp @ScriptArgs 2>&1)
    } catch {
        return @($_.Exception.Message)
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Update-ProjectIds([string]$NewId) {
    $db = Get-DatabasePath
    if (-not $db) { Write-Warn2 "opencode.db not found at $script:DataDir"; return }
    if (-not (Test-NodeSqlite)) { Write-Warn2 "node 22.5+ required for -Db rotation, skipped"; return }
    $source = @'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2]);
const rows = db.prepare("select id from project where id != 'global'").all();
const stmt = db.prepare("update project set id = ? where id = ?");
let count = 0;
for (const row of rows) { stmt.run(process.argv[3], row.id); count += 1; }
console.log("projects renamed: " + count);
'@
    $out = Invoke-NodeScript $source @($db, $NewId)
    if ($out) { Write-Ok ($out -join " ") }
}

function Remove-StuckErrors {
    $db = Get-DatabasePath
    if (-not $db) { return }
    if (-not (Test-NodeSqlite)) { return }
    $source = @'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2]);
let removed = 0;
const tables = db.prepare("select name from sqlite_master where type='table'").all();
for (const table of tables) {
  const columns = db.prepare("pragma table_info(" + table.name + ")").all().map((c) => c.name);
  const text = columns.filter((c) => c !== "id" && c !== "session_id");
  if (!text.length) continue;
  const where = text.map((c) => c + " like '%FreeUsageLimitError%'").join(" or ");
  try {
    const info = db.prepare("delete from " + table.name + " where " + where).run();
    removed += Number(info.changes || 0);
  } catch (error) {}
}
console.log("stuck limit rows removed: " + removed);
'@
    $out = Invoke-NodeScript $source @($db)
    if ($out) { Write-Info ($out -join " ") }
}

function Install-SlashCommand {
    $cmdRoot = Join-Path $script:ConfigDir "commands"
    Remove-Item (Join-Path $cmdRoot "opencode-unlimited.md") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $cmdRoot "opencode-unlimited") -Recurse -Force -ErrorAction SilentlyContinue

    $cli = Join-Path $script:ScriptDir "opencode-unlimited.ps1"
    $tail = "`n`nAnswer with one short line about what the output above reported. No more."
    $defs = [ordered]@{
        "opencode-unlimited"      = @{ Args = "status"; Desc = "OpenCode free-tier helper - project id, egress ip, bucket" }
        "opencode-unlimited:test"  = @{ Args = "test"; Desc = "check the free bucket on this IP (free)" }
        "opencode-unlimited:reset" = @{ Args = "reset"; Desc = "new id, clear stuck limit errors, re-check bucket" }
        "opencode-unlimited:id"    = @{ Args = "id"; Desc = "rotate the project id only" }
    }

    $cfgPath = Join-Path $script:ConfigDir "opencode.jsonc"
    if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $script:ConfigDir "opencode.json" }
    $cfg = $null
    if (Test-Path $cfgPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($cfgPath) -replace "^\uFEFF", ""
            $cfg = $raw | ConvertFrom-Json
        } catch {
            Write-Warn2 "could not parse $cfgPath, slash commands skipped"
            return
        }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }

    $prop = $cfg.PSObject.Properties["commands"]
    if ($null -eq $prop -or $null -eq $prop.Value) {
        $cfg | Add-Member -NotePropertyName commands -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    foreach ($name in $defs.Keys) {
        $def = $defs[$name]
        $template = '!`powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cli + '" ' + $def.Args + '`' + $tail
        $entry = [pscustomobject]@{ description = $def.Desc; template = $template }
        $cfg.commands | Add-Member -NotePropertyName $name -NotePropertyValue $entry -Force
    }

    $json = $cfg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ("slash commands: " + (($defs.Keys) -join ", "))
}

function Install-Plugin {
    if (-not (Test-Path $script:BundledPlugin)) { Write-Bad "bundled plugin missing: $script:BundledPlugin"; return }
    if (-not (Test-Path $script:PluginDir)) { New-Item -ItemType Directory -Path $script:PluginDir -Force | Out-Null }
    Copy-Item $script:BundledPlugin $script:PluginFile -Force
    Write-Ok "plugin deployed: $script:PluginFile"
}

function Get-PluginState {
    if (Test-Path $script:PluginFile) { return "enabled" }
    if (Test-Path ($script:PluginFile + ".disabled")) { return "disabled" }
    return "missing"
}

function Set-PluginEnabled([bool]$Enabled) {
    $disabled = $script:PluginFile + ".disabled"
    if ($Enabled) {
        if (Test-Path $disabled) { Move-Item $disabled $script:PluginFile -Force }
        return
    }
    if (Test-Path $script:PluginFile) { Move-Item $script:PluginFile $disabled -Force }
}

function Set-ServiceEnv([string]$Name, [string]$Value) {
    $oc = Resolve-OpenCode
    try {
        if ([string]::IsNullOrEmpty($Value)) {
            & $oc service unset env $Name 2>$null | Out-Null
        } else {
            & $oc service set env $Name $Value 2>$null | Out-Null
        }
    } catch { }
}

function Restart-Service {
    $oc = Resolve-OpenCode
    Write-Info "restarting background service"
    try { & $oc service restart 2>$null | Out-Null } catch { Write-Warn2 "service restart failed" }
}

function Get-BridgePid {
    $raw = Read-TextFile $script:PidFile
    if ($raw -and $raw.Trim() -match "^\d+$") { return [int]$raw.Trim() }
    return 0
}

function Start-Bridge($cfg) {
    $bridgePid = Get-BridgePid
    if ($bridgePid -gt 0 -and (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)) {
        Write-Info "bridge already running (pid $bridgePid)"
        return $true
    }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { Write-Bad "node not found on PATH, bridge cannot start"; return $false }
    if (-not (Test-Path $script:BridgeJs)) { Write-Bad "bridge script missing: $script:BridgeJs"; return $false }
    $argList = @($script:BridgeJs, "--listen", ("127.0.0.1:" + $cfg.bridgePort), "--upstream", $cfg.proxy, "--log", $script:LogFile)
    $proc = Start-Process -FilePath $node.Source -ArgumentList $argList -WindowStyle Hidden -PassThru
    Write-TextFile $script:PidFile ([string]$proc.Id)
    Start-Sleep -Milliseconds 800
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
        Write-Ok ("bridge up on 127.0.0.1:" + $cfg.bridgePort + " -> " + $cfg.proxy)
        return $true
    }
    Write-Bad "bridge exited, see $script:LogFile"
    return $false
}

function Stop-Bridge {
    $bridgePid = Get-BridgePid
    if ($bridgePid -gt 0) {
        $proc = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
            Write-Ok "bridge stopped"
        }
    }
    Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
}

function Apply-Proxy($cfg) {
    if (-not $cfg.proxy) {
        Set-ServiceEnv "HTTPS_PROXY" ""
        Set-ServiceEnv "HTTP_PROXY" ""
        Set-ServiceEnv "ALL_PROXY" ""
        Set-ServiceEnv "NO_PROXY" "localhost,127.0.0.1"
        Write-Ok "service proxy cleared, direct egress"
        return
    }
    $url = $cfg.proxy
    if ($url -match "^socks5h?://") {
        if (-not (Start-Bridge $cfg)) { return }
        $url = "http://127.0.0.1:" + $cfg.bridgePort
    }
    Set-ServiceEnv "HTTPS_PROXY" $url
    Set-ServiceEnv "HTTP_PROXY" $url
    Set-ServiceEnv "ALL_PROXY" $url
    Set-ServiceEnv "NO_PROXY" "localhost,127.0.0.1"
    Write-Ok ("service proxy set: " + $url)
}

function Get-WarpCli {
    $cmd = Get-Command warp-cli -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe",
        "C:\Program Files (x86)\Cloudflare\Cloudflare WARP\warp-cli.exe"
    )
    foreach ($path in $candidates) { if (Test-Path $path) { return $path } }
    return ""
}

function Test-IsAdmin {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Cmd-Install {
    Write-Step "==> installing opencode-unlimited"
    Install-Plugin
    Install-SlashCommand
    $cfg = Get-Config
    $org = Get-OrgId $cfg
    if ($org) { Write-Ok "org id discovered: $org" } else { Write-Warn2 "org id not discovered yet, run opencode once and retry" }
    Save-Config $cfg

    $binDir = $script:ScriptDir
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($null -eq $userPath) { $userPath = "" }
    if ($userPath -notlike "*$binDir*") {
        $newPath = if ($userPath.Trim()) { $userPath.TrimEnd(";") + ";" + $binDir } else { $binDir }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Ok "added to user PATH: $binDir"
        Write-Info "open a new terminal to pick it up"
    } else {
        Write-Info "already on PATH: $binDir"
    }

    if (-not (Get-Identity)) { New-Identity | Out-Null }
    Write-Step ""
    Write-Ok "done. try: opencode-unlimited status"
}

function Cmd-Id {
    Write-Step "==> rotating project identity"
    $cfg = Get-Config
    $before = Get-Identity
    $identity = New-Identity
    if ($cfg.rotateDb -or $Rest -contains "-Db" -or $Rest -contains "--db") {
        Update-ProjectIds $identity.projectId
    }
    if ($before) { Write-Info ("was " + $before.projectId) }
    Save-Config $cfg
    Write-Ok "identity rotated"
}

function Cmd-Reset {
    Write-Step "==> full reset"
    $cfg = Get-Config
    $ipBefore = Get-EgressIp $cfg.proxy
    Write-Info ("egress ip before: " + $ipBefore)

    Write-Step "[1/4] rotating project identity"
    $identity = New-Identity
    if ($cfg.rotateDb -or $Rest -contains "-Db" -or $Rest -contains "--db") {
        Update-ProjectIds $identity.projectId
    }
    Remove-StuckErrors

    Write-Step "[2/4] proxy path"
    if ($cfg.proxy) {
        Apply-Proxy $cfg
        Restart-Service
    } else {
        Write-Info "manual mode, no proxy configured"
    }

    Write-Step "[3/4] egress ip after"
    Start-Sleep -Seconds 1
    $ipAfter = Get-EgressIp $cfg.proxy
    $cfg.lastIp = $ipAfter
    Save-Config $cfg
    if ($ipAfter -eq $ipBefore) {
        Write-Warn2 ("ip unchanged: " + $ipAfter)
    } else {
        Write-Ok ("new egress ip: " + $ipAfter)
    }

    Write-Step "[4/4] verifying free-tier bucket"
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    Save-Config $cfg
    if ($probe.State -eq "fresh") {
        Write-Ok (Get-BucketLabel $probe.State)
    } elseif ($probe.State -eq "exhausted") {
        Write-Bad (Get-BucketLabel $probe.State)
        Write-Info "the cap follows the IP, change IP and run: opencode-unlimited test"
    } else {
        Write-Warn2 (Get-BucketLabel $probe.State)
        Write-Info $probe.Body
    }
    Write-Step ""
    Write-Ok "reset complete"
    Write-Info ("project id: " + $identity.projectId)
}

function Cmd-Test {
    $cfg = Get-Config
    Write-Step "==> probing free-tier bucket (no auth, costs nothing)"
    Write-Info ("egress ip: " + (Get-EgressIp $cfg.proxy))
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    $cfg.lastIp = Get-EgressIp $cfg.proxy
    Save-Config $cfg
    if ($probe.State -eq "fresh") {
        Write-Ok (Get-BucketLabel $probe.State)
    } elseif ($probe.State -eq "exhausted") {
        Write-Bad (Get-BucketLabel $probe.State)
    } else {
        Write-Warn2 (Get-BucketLabel $probe.State)
        Write-Info ($probe.Body.Substring(0, [Math]::Min(240, $probe.Body.Length)))
    }
}

function Cmd-Status {
    $cfg = Get-Config
    Write-Step "==> opencode-unlimited status"
    Write-Step ""
    Write-Step "identity"
    $id = Get-Identity
    if ($id) {
        Write-Info ("project id : " + $id.projectId)
        Write-Info ("directory  : " + $id.directory)
        Write-Info ("updated    : " + $id.createdAt)
    } else {
        Write-Warn2 "no identity yet, run: opencode-unlimited id"
    }
    Write-Step ""
    Write-Step "plugin"
    Write-Info ("state      : " + (Get-PluginState))
    Write-Info ("path       : " + $script:PluginFile)
    Write-Step ""
    Write-Step "network"
    Write-Info ("egress ip  : " + (Get-EgressIp $cfg.proxy))
    Write-Info ("ipMode     : " + $cfg.ipMode)
    Write-Info ("upstream   : " + $(if ($cfg.proxy) { $cfg.proxy } else { "none (manual)" }))
    $bridgePid = Get-BridgePid
    if ($bridgePid -gt 0 -and (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)) {
        Write-Info ("bridge     : running (pid " + $bridgePid + ", port " + $cfg.bridgePort + ")")
    } else {
        Write-Info "bridge     : stopped"
    }
    $warp = Get-WarpCli
    Write-Info ("warp-cli   : " + $(if ($warp) { $warp } else { "not installed (optional)" }))
    Write-Step ""
    Write-Step "bucket"
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    $cfg.lastIp = Get-EgressIp $cfg.proxy
    Save-Config $cfg
    if ($probe.State -eq "fresh") {
        Write-Ok (Get-BucketLabel $probe.State)
    } elseif ($probe.State -eq "exhausted") {
        Write-Bad (Get-BucketLabel $probe.State)
    } else {
        Write-Warn2 (Get-BucketLabel $probe.State)
    }
    Write-Info ("last check : " + $cfg.lastBucket + " @ " + $cfg.lastIp)
}

function Cmd-On {
    Install-Plugin
    Set-PluginEnabled $true
    Write-Ok "identity plugin enabled"
}

function Cmd-Off {
    Set-PluginEnabled $false
    Write-Ok "identity plugin disabled"
}

function Cmd-Proxy {
    $cfg = Get-Config
    $sub = if ($Rest.Count -ge 1) { $Rest[0] } else { "status" }
    switch ($sub) {
        "off" {
            Stop-Bridge
            $cfg.proxy = ""
            $cfg.ipMode = "manual"
            Save-Config $cfg
            Apply-Proxy $cfg
            Restart-Service
            Write-Info "egress is direct again"
        }
        "status" {
            Write-Info ("upstream : " + $(if ($cfg.proxy) { $cfg.proxy } else { "none (manual)" }))
            Write-Info ("bridge   : 127.0.0.1:" + $cfg.bridgePort)
            Write-Info ("ip       : " + (Get-EgressIp $cfg.proxy))
        }
        default {
            $url = if ($sub -eq "set" -and $Rest.Count -ge 2) { $Rest[1] } else { $Rest[0] }
            if ($url -notmatch "^(socks5h?|http|https)://") {
                Write-Bad "expected socks5://host:port or http://host:port"
                return
            }
            $cfg.proxy = $url
            $cfg.ipMode = "proxy"
            Save-Config $cfg
            Apply-Proxy $cfg
            Restart-Service
            Start-Sleep -Seconds 1
            Write-Info ("egress ip via proxy: " + (Get-EgressIp $cfg.proxy))
        }
    }
}

function Cmd-Warp {
    $warp = Get-WarpCli
    if (-not $warp) {
        Write-Bad "warp-cli not found, install Cloudflare WARP or use: proxy set socks5://host:port"
        return
    }
    $cfg = Get-Config
    $sub = if ($Rest.Count -ge 1) { $Rest[0] } else { "status" }
    switch ($sub) {
        "on" {
            & $warp mode proxy 2>$null | Out-Null
            & $warp proxy port 40000 2>$null | Out-Null
            & $warp connect 2>$null | Out-Null
            $cfg.proxy = "socks5://127.0.0.1:40000"
            $cfg.ipMode = "warp"
            Save-Config $cfg
            Apply-Proxy $cfg
            Restart-Service
            Write-Ok "warp proxy mode on, opencode routed through the bridge"
        }
        "off" {
            & $warp disconnect 2>$null | Out-Null
            Stop-Bridge
            $cfg.proxy = ""
            $cfg.ipMode = "manual"
            Save-Config $cfg
            Apply-Proxy $cfg
            Restart-Service
            Write-Ok "warp off, direct egress"
        }
        "rotate" {
            & $warp tunnel rotate-keys 2>$null | Out-Null
            Start-Sleep -Seconds 2
            Write-Ok ("rotated. egress ip: " + (Get-EgressIp $cfg.proxy))
        }
        default {
            & $warp status 2>&1 | ForEach-Object { Write-Info $_ }
        }
    }
}

function Cmd-Run {
    if ($Rest.Count -eq 0) { Write-Bad "usage: opencode-unlimited run <opencode args>"; return }
    $oc = Resolve-OpenCode
    $cfg = Get-Config
    $attempt = 1
    while ($attempt -le 3) {
        $out = & $oc @Rest 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($out -match "Free usage limit reached|used today's free messages") {
            Write-Warn2 ("free limit hit (attempt " + $attempt + "/3)")
            Cmd-Id | Out-Null
            if ($cfg.proxy) { Apply-Proxy $cfg; Restart-Service }
            Start-Sleep -Seconds 2
            $attempt++
            continue
        }
        Write-Host $out
        return $code
    }
    Write-Bad "still limited after 3 attempts, change the egress IP and retry"
    return 1
}

function Cmd-Help {
    Write-Step "opencode-unlimited <command>"
    Write-Step ""
    Write-Info "install              deploy plugin, register PATH, write state"
    Write-Info "reset                rotate identity, clear stuck errors, verify bucket"
    Write-Info "id [-Db]             rotate project identity only"
    Write-Info "test                 probe the free bucket on this IP"
    Write-Info "status               identity, plugin, network, bucket"
    Write-Info "on | off             enable or disable the identity plugin"
    Write-Info "proxy set <url>      route opencode through socks5:// or http://"
    Write-Info "proxy off            drop the upstream, direct egress"
    Write-Info "proxy status         show the current upstream"
    Write-Info "warp on|off|rotate   Cloudflare WARP path (optional)"
    Write-Info "run <args...>        run opencode, rotate on free-limit"
}

switch ($Command.ToLowerInvariant()) {
    "install" { Cmd-Install }
    "reset" { Cmd-Reset }
    "id" { Cmd-Id }
    "test" { Cmd-Test }
    "status" { Cmd-Status }
    "on" { Cmd-On }
    "off" { Cmd-Off }
    "proxy" { Cmd-Proxy }
    "warp" { Cmd-Warp }
    "run" { Cmd-Run }
    default { Cmd-Help }
}
