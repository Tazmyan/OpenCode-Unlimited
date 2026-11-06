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
$script:InfoFile = Join-Path $script:ConfigDir "unlimited-info.json"
$script:PluginDir = Join-Path $script:ConfigDir "plugins"
$script:PluginFolder = Join-Path $script:PluginDir "unlimited-shield"
$script:PluginFile = Join-Path $script:PluginFolder "index.js"
$script:PluginEntry = "./plugins/unlimited-shield"
$script:PluginMarker = Join-Path $script:ConfigDir "unlimited-shield.state.json"
$script:PidFile = Join-Path $script:ConfigDir "unlimited-bridge.pid"
$script:WatchPidFile = Join-Path $script:ConfigDir "unlimited-watch.pid"
$script:WatchLogFile = Join-Path $script:ConfigDir "unlimited-watch.log"
$script:AutoTaskName = "OpenCodeUnlimitedWatch"
$script:LogFile = Join-Path $script:ConfigDir "unlimited-bridge.log"
$script:IpCacheFile = Join-Path $script:ConfigDir "unlimited-ip.json"
$script:PoolCacheFile = Join-Path $script:ConfigDir "unlimited-pool.json"
$script:RotateGateFile = Join-Path $script:ConfigDir "unlimited-rotate.json"
$script:AuthDir = Join-Path $script:DataDir "auth.json"
if ($env:LOCALAPPDATA) { $script:LocalRoot = Join-Path $env:LOCALAPPDATA "opencode-unlimited" }
else { $script:LocalRoot = Join-Path $script:UserHome "AppData\Local\opencode-unlimited" }
$script:AuthSnapshotDir = Join-Path $script:LocalRoot "auth-snapshot"
$script:AuthSnapshot = Join-Path $script:AuthSnapshotDir "auth.json"
$script:Gateway = "https://opencode.ai/inference/openai/v1/chat/completions"
$script:TraceUrl = "https://cloudflare.com/cdn-cgi/trace"
$script:DefaultModel = "deepseek-v4.1-flash-free"
$script:DefaultBridgePort = 8899
$script:SlowProxyMs = 3500
$script:DefaultProxySources = @(
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt",
    "https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt"
)
$script:ToolVersion = "1.0.2"
$script:InfoCache = $null

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
        pluginPath   = $script:PluginFile
        model        = $script:DefaultModel
        orgId        = ""
        proxy        = ""
        proxyPool    = @()
        proxyIndex   = 0
        proxyListUrl = ""
        bridgePort   = $script:DefaultBridgePort
        ipMode       = "manual"
        rotateDb     = $false
        autoMode     = $false
        autoStart    = $false
        autoTries    = 12
        autoMinutes  = 8
        reidOnAuto   = $true
        lastIp       = ""
        lastCountry  = ""
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
        $request.UserAgent = (Get-UserAgent)
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

function Get-EgressTrace([string]$ProxyUrl, [switch]$Force, [int]$TimeoutSec = 8, [switch]$NoFallback) {
    $cache = Get-Json $script:IpCacheFile
    if (-not $Force -and $cache -and $cache.ip) {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$cache.at
        if ($age -ge 0 -and $age -lt 60 -and [string]$cache.via -eq [string]$ProxyUrl) {
            return [pscustomobject]@{
                Ip      = [string]$cache.ip
                Country = [string]$cache.country
                Warp    = [string]$cache.warp
                Colo    = [string]$cache.colo
                At      = [long]$cache.at
                Cached  = $true
                Ms      = 0
            }
        }
    }
    $text = ""
    $elapsed = 0
    $curl = Get-Curl
    if ($curl) {
        $connect = [Math]::Max(2, [Math]::Min(5, $TimeoutSec - 1))
        $curlArgs = @("-s", "--connect-timeout", [string]$connect, "--max-time", [string]$TimeoutSec)
        if ($ProxyUrl) { $curlArgs += @("--proxy", $ProxyUrl) }
        $curlArgs += $script:TraceUrl
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $text = Invoke-Curl $curlArgs
        $watch.Stop()
        $elapsed = [int]$watch.ElapsedMilliseconds
    }
    if ((-not $text -or $text -notmatch "ip=") -and -not $NoFallback) {
        $result = Invoke-WebRequestRaw "GET" $script:TraceUrl $null $ProxyUrl
        if ($result.Status -eq 200) { $text = $result.Body }
    }
    $ip = ""
    $country = ""
    $warp = ""
    $colo = ""
    if ($text) {
        foreach ($line in ($text -split "`n")) {
            $clean = $line.Trim()
            if ($clean -match "^ip=(.+)$") { $ip = $Matches[1].Trim() }
            elseif ($clean -match "^loc=(.+)$") { $country = $Matches[1].Trim() }
            elseif ($clean -match "^warp=(.+)$") { $warp = $Matches[1].Trim() }
            elseif ($clean -match "^colo=(.+)$") { $colo = $Matches[1].Trim() }
        }
    }
    $at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($ip) {
        $entry = [ordered]@{
            ip      = $ip
            country = $country
            warp    = $warp
            colo    = $colo
            at      = $at
            via     = [string]$ProxyUrl
        }
        Write-TextFile $script:IpCacheFile ($entry | ConvertTo-Json -Depth 3)
    }
    return [pscustomobject]@{
        Ip      = $ip
        Country = $country
        Warp    = $warp
        Colo    = $colo
        At      = $at
        Cached  = $false
        Ms      = $elapsed
    }
}

function Invoke-ProxyHealth([string]$Action, [string[]]$Extra) {
    $helper = Join-Path $script:Root "lib\proxy-health.js"
    if (-not (Test-Path $helper)) { return $null }
    $nodeArgs = @($Action)
    if ($Extra) { $nodeArgs += $Extra }
    $raw = Invoke-NodeHelper $helper $nodeArgs
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Set-ProxyHealth([string]$Url, [bool]$Ok, [int]$Ms, [string]$Reason) {
    if (-not $Url) { return }
    $extra = @($Url, $(if ($Ok) { "ok" } else { "fail" }), [string]$Ms)
    if ($Reason) { $extra += $Reason }
    Invoke-ProxyHealth "record" $extra | Out-Null
}

function Get-RankedProxyPool($cfg) {
    $pool = @(Get-ProxyPool $cfg)
    if (-not $pool.Count) { return @() }
    $ranked = Invoke-ProxyHealth "rank" $pool
    if ($ranked -and $ranked.proxies) { return @($ranked.proxies) }
    return $pool
}

function Get-ProxyHealthReport($cfg) {
    $pool = @(Get-ProxyPool $cfg)
    if (-not $pool.Count) { return $null }
    return Invoke-ProxyHealth "rank" $pool
}

function Get-EgressIp([string]$ProxyUrl, [switch]$Force) {
    $trace = Get-EgressTrace $ProxyUrl -Force:$Force
    if ($trace.Ip) { return $trace.Ip }
    return ""
}

function Test-RouteOk($trace, [string]$Mode) {
    if (-not $trace -or -not $trace.Ip) { return $false }
    if ($Mode -eq "warp") { return ($trace.Warp -eq "on" -or $trace.Warp -eq "plus") }
    return $true
}

function Test-RouteFilter($trace, [string]$Country, [string]$Prefix) {
    if (-not $trace -or -not $trace.Ip) { return $false }
    if ($Country -and ([string]$trace.Country).ToUpperInvariant() -ne $Country.ToUpperInvariant()) { return $false }
    if ($Prefix -and -not ([string]$trace.Ip).StartsWith($Prefix)) { return $false }
    return $true
}

function Test-SameBlock([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    $helper = Join-Path $script:Root "lib\egress.js"
    if (Test-Path $helper) {
        $raw = Invoke-NodeHelper $helper @("same", $Left, $Right)
        try {
            $data = $raw | ConvertFrom-Json
            if ($null -ne $data -and $null -ne $data.same) { return [bool]$data.same }
        } catch { }
    }
    return ($Left -eq $Right)
}

function Get-OpenCodeInfo([switch]$Refresh) {
    if (-not $Refresh -and $script:InfoCache) { return $script:InfoCache }

    $info = [pscustomobject]@{
        exe          = (Resolve-OpenCode)
        version      = ""
        major        = 0
        api          = 0
        baseURL      = "https://opencode.ai/inference/openai/v1"
        gateway      = $script:Gateway
        orgId        = ""
        dbPath       = ""
        dataDir      = $script:DataDir
        configDir    = $script:ConfigDir
        freeModels   = @()
        freeModel    = $script:DefaultModel
        sessionTable = ""
        running      = $false
        source       = "fallback"
        detectedAt   = 0
    }

    $helper = Join-Path $script:Root "lib\oc-info.js"
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node -or -not (Test-Path $helper)) {
        $script:InfoCache = $info
        return $info
    }

    $previous = $env:NODE_NO_WARNINGS
    $env:NODE_NO_WARNINGS = "1"
    $raw = ""
    try {
        $nodeArgs = @($helper, "info")
        if ($Refresh) { $nodeArgs += "--refresh" }
        $raw = (& $node.Source @nodeArgs 2>$null | Out-String)
    } catch {
        $raw = ""
    } finally {
        if ($null -eq $previous) { Remove-Item Env:\NODE_NO_WARNINGS -ErrorAction SilentlyContinue }
        else { $env:NODE_NO_WARNINGS = $previous }
    }

    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    if ($parsed) {
        if ($parsed.exe) { $info.exe = [string]$parsed.exe }
        if ($parsed.version) { $info.version = [string]$parsed.version }
        if ($parsed.major) { $info.major = [int]$parsed.major }
        if ($parsed.api) { $info.api = [int]$parsed.api }
        if ($parsed.baseURL) { $info.baseURL = [string]$parsed.baseURL }
        if ($parsed.gateway) { $info.gateway = [string]$parsed.gateway }
        if ($parsed.orgId) { $info.orgId = [string]$parsed.orgId }
        if ($parsed.dbPath) { $info.dbPath = [string]$parsed.dbPath }
        if ($parsed.dataDir) { $info.dataDir = [string]$parsed.dataDir }
        if ($parsed.configDir) { $info.configDir = [string]$parsed.configDir }
        if ($parsed.freeModels) { $info.freeModels = @($parsed.freeModels) }
        if ($parsed.freeModel) { $info.freeModel = [string]$parsed.freeModel }
        if ($parsed.service) { $info.running = [bool]$parsed.service.running }
        if ($parsed.schema -and $parsed.schema.sessionTable) { $info.sessionTable = [string]$parsed.schema.sessionTable }
        if ($parsed.detectedAt) { $info.detectedAt = [int64]$parsed.detectedAt }
        $info.source = "detected"
    }

    $script:InfoCache = $info
    return $info
}

function Resolve-ProbeModel($cfg, $info) {
    $model = [string]$cfg.model
    if ($model -like "*/*") { $model = $model.Split("/")[-1] }
    $free = @($info.freeModels)
    if ($free.Count -gt 0 -and ($free -notcontains $model) -and $info.freeModel) {
        $model = [string]$info.freeModel
    }
    if (-not $model) { $model = $script:DefaultModel }
    return $model
}

function Get-OrgId($cfg) {
    if ($cfg.orgId) { return $cfg.orgId }
    $info = Get-OpenCodeInfo
    if ($info.orgId) {
        $cfg.orgId = $info.orgId
        Save-Config $cfg
        return $info.orgId
    }
    return ""
}

function Test-NodeSqlite {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $false }
    $version = & $node.Source --version 2>$null
    if (-not $version) { return $false }
    $clean = $version.Trim().TrimStart("v")
    $parts = $clean.Split(".")
    if ($parts.Count -lt 2) { return $false }
    $major = 0
    $minor = 0
    if (-not [int]::TryParse($parts[0], [ref]$major)) { return $false }
    if (-not [int]::TryParse($parts[1], [ref]$minor)) { return $false }
    if ($major -gt 22) { return $true }
    if ($major -eq 22 -and $minor -ge 5) { return $true }
    return $false
}

function Get-DatabasePath {
    $info = Get-OpenCodeInfo
    if ($info.dbPath -and (Test-Path $info.dbPath)) { return $info.dbPath }
    $candidates = @(
        (Join-Path $script:DataDir "opencode.db"),
        (Join-Path $script:DataDir "opencode.sqlite"),
        (Join-Path $env:LOCALAPPDATA "opencode\opencode.db"),
        (Join-Path $env:LOCALAPPDATA "opencode\data\opencode.db")
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return ""
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = (& $File @Arguments 2>&1 | Out-String)
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    } catch {
        return [pscustomobject]@{ Code = -1; Text = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-NodeHelper([string]$Helper, [string[]]$HelperArgs) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return "" }
    $previous = $env:NODE_NO_WARNINGS
    $env:NODE_NO_WARNINGS = "1"
    try {
        return (& $node.Source $Helper @HelperArgs 2>$null | Out-String)
    } catch {
        return ""
    } finally {
        if ($null -eq $previous) { Remove-Item Env:\NODE_NO_WARNINGS -ErrorAction SilentlyContinue }
        else { $env:NODE_NO_WARNINGS = $previous }
    }
}

function Invoke-NodeScript([string]$Source, [string[]]$ScriptArgs) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unlimited-" + (New-Hex 5) + ".js")
    Write-TextFile $tmp $Source
    $warn = $env:NODE_NO_WARNINGS
    $env:NODE_NO_WARNINGS = "1"
    try {
        return (& $node.Source $tmp @ScriptArgs 2>&1)
    } catch {
        return @($_.Exception.Message)
    } finally {
        if ($null -eq $warn) { Remove-Item Env:\NODE_NO_WARNINGS -ErrorAction SilentlyContinue }
        else { $env:NODE_NO_WARNINGS = $warn }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-DbPath([string]$Path) {
    $full = $Path
    try { $full = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName } catch {}
    return ($full -replace "\\", "/").TrimEnd("/")
}

function Invoke-DbTool([string]$Action, [string]$Argument) {
    $db = Get-DatabasePath
    if (-not $db) { return @("opencode.db not found") }
    if (-not (Test-NodeSqlite)) { return @("node 22.5+ required") }
    $helper = Join-Path $script:Root "lib\db-tools.js"
    if (-not (Test-Path $helper)) { return @("missing helper: " + $helper) }
    $nodeArgs = @($Action, $db)
    if ($Argument) { $nodeArgs += $Argument }
    $raw = Invoke-NodeHelper $helper $nodeArgs
    if (-not $raw) { return @("no output from " + $helper) }
    return @($raw -split "`r?`n" | Where-Object { $_.Trim() })
}

function Remove-StuckErrors([string]$Directory) {
    $scope = if ($Directory) { ConvertTo-DbPath $Directory } else { "" }
    $out = Invoke-DbTool "clear" $scope
    if ($out) { Write-Info ($out -join " ") }
}

function Install-SlashCommand {
    $cmdRoot = Join-Path $script:ConfigDir "commands"
    Remove-Item (Join-Path $cmdRoot "opencode-unlimited.md") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $cmdRoot "opencode-unlimited") -Recurse -Force -ErrorAction SilentlyContinue

    $cli = Join-Path $script:ScriptDir "opencode-unlimited.ps1"
    $tail = "`n`nAnswer with one short line about what the output above reported. No more."
    $defs = [ordered]@{
        "opencode-unlimited"          = @{ Args = "status"; Desc = "OpenCode free-tier helper - identity, egress block, reset clock" }
        "opencode-unlimited:reset"    = @{ Args = "reset"; Desc = "new device identity, new session ids, clear stuck errors; pass a folder" }
        "opencode-unlimited:identity" = @{ Args = "identity"; Desc = "show, rotate or restore the virtual device identity" }
        "opencode-unlimited:block"    = @{ Args = "block"; Desc = "egress blocks seen today and which are spent" }
        "opencode-unlimited:usage"    = @{ Args = "usage"; Desc = "daily free bucket state and the reset clock" }
        "opencode-unlimited:watch"    = @{ Args = "watch"; Desc = "read the opencode log for a limit line, zero messages spent" }
        "opencode-unlimited:hunt"     = @{ Args = "hunt"; Desc = "rotate until the probe says the route is open" }
        "opencode-unlimited:clear"    = @{ Args = "clear"; Desc = "strip stored free-limit errors from sessions" }
        "opencode-unlimited:token"    = @{ Args = "token"; Desc = "show or save the local auth.json snapshot" }
        "opencode-unlimited:on"       = @{ Args = "on"; Desc = "full auto: identity, pool, route, watcher, autostart" }
        "opencode-unlimited:off"      = @{ Args = "off"; Desc = "stop the watcher, drop the proxy, keep the files" }
        "opencode-unlimited:reid"     = @{ Args = "reid"; Desc = "mint fresh session ids, keep every message" }
        "opencode-unlimited:model"    = @{ Args = "model"; Desc = "list providers and switch this folder to a free model" }
    }
    $argNames = @("opencode-unlimited:reset", "opencode-unlimited:clear", "opencode-unlimited:reid", "opencode-unlimited:model", "opencode-unlimited:watch", "opencode-unlimited:hunt")

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
        $argText = $def.Args
        if ($argNames -contains $name) { $argText = $argText + ' "$ARGUMENTS"' }
        $template = '!`powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cli + '" ' + $argText + '`' + $tail
        $entry = [pscustomobject]@{ description = $def.Desc; template = $template }
        $cfg.commands | Add-Member -NotePropertyName $name -NotePropertyValue $entry -Force
    }

    $json = $cfg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ("slash commands: " + (($defs.Keys) -join ", "))
}

function Get-GlobalConfigPath {
    $jsonc = Join-Path $script:ConfigDir "opencode.jsonc"
    if (Test-Path $jsonc) { return $jsonc }
    return (Join-Path $script:ConfigDir "opencode.json")
}

function Read-GlobalConfig {
    $path = Get-GlobalConfigPath
    if (-not (Test-Path $path)) { return [pscustomobject]@{} }
    try {
        $raw = [System.IO.File]::ReadAllText($path) -replace "^\uFEFF", ""
        $cfg = $raw | ConvertFrom-Json
        if ($cfg) { return $cfg }
    } catch {
        return $null
    }
    return [pscustomobject]@{}
}

function Save-GlobalConfig($cfg) {
    $path = Get-GlobalConfigPath
    $json = $cfg | ConvertTo-Json -Depth 30
    $prop = $cfg.PSObject.Properties["plugins"]
    if ($null -ne $prop -and $prop.Value -is [string] -and $prop.Value) {
        $escaped = $prop.Value -replace '\\', '\\\\' -replace '"', '\"'
        $json = $json -replace '("plugins"\s*:\s*)"' + [regex]::Escape($prop.Value) + '"', ('$1["' + $escaped + '"]')
    }
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-RegisteredPlugins($cfg) {
    if (-not $cfg) { return @() }
    $prop = $cfg.PSObject.Properties["plugins"]
    if ($null -eq $prop -or $null -eq $prop.Value) { return @() }
    return @($prop.Value | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($_ -and $_.package) { [string]$_.package } else { "" }
    } | Where-Object { $_ })
}

function Test-PluginRegistered {
    $cfg = Read-GlobalConfig
    $list = Get-RegisteredPlugins $cfg
    foreach ($item in $list) {
        if ($item -eq $script:PluginEntry) { return $true }
    }
    return $false
}

function Register-PluginEntry([bool]$Enabled) {
    $cfg = Read-GlobalConfig
    if (-not $cfg) { return $false }
    $list = @(Get-RegisteredPlugins $cfg | Where-Object { $_ -ne $script:PluginEntry })
    if ($Enabled) { $list += $script:PluginEntry }
    $value = @()
    if ($list.Count -gt 0) { $value = [string[]]$list }
    $cfg | Add-Member -NotePropertyName plugins -NotePropertyValue $value -Force
    try {
        Save-GlobalConfig $cfg
    } catch {
        Write-Warn2 ("global config not written: " + $_.Exception.Message)
        return $false
    }
    return $true
}

function Install-Plugin {
    if (-not (Test-Path $script:BundledPlugin)) { Write-Bad "bundled plugin missing: $script:BundledPlugin"; return $false }
    if (-not (Test-Path $script:PluginFolder)) { New-Item -ItemType Directory -Path $script:PluginFolder -Force | Out-Null }
    Copy-Item $script:BundledPlugin $script:PluginFile -Force
    if (-not (Register-PluginEntry $true)) { return $false }
    Write-Ok ("plugin installed and listed in opencode config: " + $script:PluginEntry)
    return $true
}

function Get-PluginState {
    $present = Test-Path $script:PluginFile
    $listed = Test-PluginRegistered
    if ($present -and $listed) {
        $marker = Get-Json $script:PluginMarker
        if ($marker -and $marker.loaded -eq $true) { return "loaded" }
        return "enabled (waiting for a server load)"
    }
    if ($present -or $listed) { return "partial" }
    return "missing"
}

function Set-PluginEnabled([bool]$Enabled) {
    $disabled = $script:PluginFile + ".off"
    if ($Enabled) {
        if (-not (Test-Path $script:PluginFile)) {
            if (Test-Path $disabled) {
                if (-not (Test-Path $script:PluginFolder)) { New-Item -ItemType Directory -Path $script:PluginFolder -Force | Out-Null }
                Move-Item $disabled $script:PluginFile -Force
            } elseif (Test-Path $script:BundledPlugin) {
                if (-not (Test-Path $script:PluginFolder)) { New-Item -ItemType Directory -Path $script:PluginFolder -Force | Out-Null }
                Copy-Item $script:BundledPlugin $script:PluginFile -Force
            }
        }
        Register-PluginEntry $true | Out-Null
        return
    }
    Register-PluginEntry $false | Out-Null
    if (Test-Path $script:PluginFile) { Move-Item $script:PluginFile $disabled -Force }
}

function Test-PluginLive {
    $marker = Get-Json $script:PluginMarker
    if ($marker -and $marker.loaded -eq $true) { return $marker }
    $info = Get-OpenCodeInfo
    if (-not $info.exe -or -not $info.running) { return $null }
    $result = Invoke-Native $info.exe @("api", "get", "/api/plugin")
    if ($result.Code -ne 0 -or -not $result.Text) { return $null }
    if ($result.Text -notmatch '"id"\s*:\s*"unlimited-shield"') { return $null }
    return [pscustomobject]@{
        plugin  = "unlimited-shield"
        loaded  = $true
        version = [string]$info.version
        hooks   = @("model.request", "http.request")
        at      = "live"
    }
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

function Test-Upstream([string]$ProxyUrl, [int]$TimeoutSec = 10) {
    $curl = Get-Curl
    if (-not $curl) { return $true }
    $connect = [Math]::Max(2, [Math]::Min(5, $TimeoutSec - 1))
    $out = Invoke-Curl @("-s", "--connect-timeout", [string]$connect, "--max-time", [string]$TimeoutSec, "--proxy", $ProxyUrl, $script:TraceUrl)
    if ($out -and $out -match "ip=") { return $true }
    return $false
}

function ConvertFrom-ProxyText([string]$Raw) {
    $found = @()
    if (-not $Raw) { return $found }
    foreach ($match in [regex]::Matches($Raw, "(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})")) {
        $octets = @()
        if ($match.Groups[1].Value -match "^(\d+)\.(\d+)\.(\d+)\.(\d+)$") {
            $octets = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        }
        if ($octets.Count -ne 4) { continue }
        if (($octets | Where-Object { $_ -gt 255 }).Count -gt 0) { continue }
        $port = [int]$match.Groups[2].Value
        if ($port -lt 1 -or $port -gt 65535) { continue }
        $entry = "http://" + $match.Groups[1].Value + ":" + $port
        if ($found -notcontains $entry) { $found += $entry }
    }
    return $found
}

function Get-ProxySources($cfg) {
    $list = @()
    $custom = [string]$cfg.proxyListUrl
    if ($custom -match "^https?://") { $list += $custom }
    foreach ($url in $script:DefaultProxySources) {
        if ($list -notcontains $url) { $list += $url }
    }
    return $list
}

function Update-ProxyList($cfg, [switch]$Force, [switch]$Quiet) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cache = Get-Json $script:PoolCacheFile
    if (-not $Force -and $cache -and $cache.at -and ($now - [long]$cache.at) -lt 21600) {
        $cached = @($cache.proxies)
        if ($cached.Count -gt 0) { return $cached.Count }
    }
    foreach ($url in @(Get-ProxySources $cfg)) {
        if (-not $Quiet) { Write-Info ("proxy list: asking " + $url) }
        $raw = Invoke-Curl @("-s", "-L", "--max-time", "20", $url)
        if (-not $raw -or $raw.Length -lt 32) { continue }
        $found = @(ConvertFrom-ProxyText $raw)
        if (-not $found.Count) { continue }
        $shuffled = @($found | Sort-Object { Get-Random })
        $take = [Math]::Min($shuffled.Count, 200)
        $picked = @($shuffled[0..($take - 1)])
        $payload = [ordered]@{ at = $now; source = $url; proxies = $picked }
        Write-TextFile $script:PoolCacheFile ($payload | ConvertTo-Json -Depth 4)
        if ([string]$cfg.proxyListUrl -ne $url) {
            $cfg.proxyListUrl = $url
            Save-Config $cfg
        }
        if (-not $Quiet) { Write-Info ("proxy list: " + $picked.Count + " candidates") }
        return $picked.Count
    }
    if (-not $Quiet) { Write-Warn2 "every proxy source came back empty" }
    return 0
}

function Get-ProxyPool($cfg) {
    $pool = @()
    if ($cfg.proxyPool) {
        foreach ($entry in @($cfg.proxyPool)) {
            $url = [string]$entry
            if ($url -and $url -match "^(socks5h?|http|https)://") { $pool += $url }
        }
    }
    $cache = Get-Json $script:PoolCacheFile
    if ($cache -and $cache.proxies) {
        foreach ($entry in @($cache.proxies)) {
            $url = [string]$entry
            if ($url -and $url -match "^https?://" -and $pool -notcontains $url) { $pool += $url }
        }
    }
    return $pool
}

function Step-Egress($cfg, [string]$Url, [string]$AvoidIp, [string]$Country, [string]$Prefix) {
    if (-not $Url) { return $null }
    Write-Info ("testing: " + $Url)
    $trace = Get-EgressTrace $Url -Force -TimeoutSec 6 -NoFallback
    $ms = [int]$trace.Ms
    if (-not $trace.Ip) {
        Set-ProxyHealth $Url $false $ms "timeout"
        Write-Info "  no answer in 6s"
        return $null
    }
    if ($ms -gt $script:SlowProxyMs) {
        Set-ProxyHealth $Url $true $ms "slow"
        Write-Info ("  too slow, " + $ms + " ms")
        return $null
    }
    Set-ProxyHealth $Url $true $ms ""
    if ($AvoidIp -and (Test-SameBlock $trace.Ip $AvoidIp)) {
        Write-Info ("  same egress block, " + $trace.Ip)
        return $null
    }
    if (-not (Test-RouteFilter $trace $Country $Prefix)) {
        Write-Info ("  filtered out, " + $trace.Ip + " " + $trace.Country)
        return $null
    }
    $cfg.proxy = $Url
    $cfg.ipMode = "proxy"
    Save-Config $cfg
    if (-not (Apply-Proxy $cfg -SkipTest)) {
        Set-ProxyHealth $Url $false 0 "upstream"
        return $null
    }
    Write-Info ("  live, " + $ms + " ms")
    return $trace
}

function Invoke-EgressRotation($cfg, [string]$AvoidIp, [string]$Country, [string]$Prefix, [switch]$Dry, [switch]$NoRestart, [int]$Tries = 8) {
    if (@(Get-ProxyPool $cfg).Count -eq 0) { Update-ProxyList $cfg | Out-Null }
    $pool = @(Get-RankedProxyPool $cfg)
    if (-not $pool.Count) {
        if ($cfg.ipMode -eq "warp") {
            if ($Dry) { Write-Info "would reconnect warp"; return $null }
            $trace = Invoke-WarpRotate $cfg
            if (-not (Test-RouteOk $trace "warp")) { Write-Warn2 "warp is not carrying the route"; return $null }
            if ($AvoidIp -and (Test-SameBlock $trace.Ip $AvoidIp)) { Write-Warn2 ("same egress block: " + $trace.Ip); return $null }
            if (-not (Test-RouteFilter $trace $Country $Prefix)) { Write-Warn2 ("filtered out: " + $trace.Ip + " " + $trace.Country); return $null }
            Write-Ok ("warp reconnected -> " + $trace.Ip + " " + $trace.Country)
            return $trace
        }
        if ($cfg.proxy) {
            if ($Dry) { Write-Info ("would apply: " + $cfg.proxy); return $null }
            if (-not (Apply-Proxy $cfg)) { return $null }
            Restart-Service
            Start-Sleep -Milliseconds 600
            $trace = Get-EgressTrace $cfg.proxy -Force
            if (-not (Test-RouteOk $trace $cfg.ipMode)) { Write-Warn2 "route check failed"; return $null }
            if ($AvoidIp -and (Test-SameBlock $trace.Ip $AvoidIp)) { Write-Warn2 ("same egress block: " + $trace.Ip); return $null }
            if (-not (Test-RouteFilter $trace $Country $Prefix)) { Write-Warn2 ("filtered out: " + $trace.Ip + " " + $trace.Country); return $null }
            return $trace
        }
        Write-Info "manual mode, no proxy configured"
        Write-Info "change the network yourself, or run: opencode-unlimited on"
        return $null
    }
    if ($Dry) {
        $next = $pool[(([int]$cfg.proxyIndex) % $pool.Count)]
        Write-Info ("would rotate to: " + $next + " (" + $pool.Count + " in the pool)")
        return $null
    }
    $limit = [Math]::Min($pool.Count, [Math]::Max(1, $Tries))
    $start = [int]$cfg.proxyIndex
    for ($i = 0; $i -lt $limit; $i++) {
        $index = ($start + $i) % $pool.Count
        $trace = Step-Egress $cfg $pool[$index] $AvoidIp $Country $Prefix
        if ($trace) {
            $cfg.proxyIndex = ($index + 1) % $pool.Count
            Save-Config $cfg
            if (-not $NoRestart) {
                Restart-Service
                Start-Sleep -Milliseconds 600
            }
            Write-Ok ("egress via " + $cfg.proxy + " -> " + $trace.Ip + " " + $trace.Country + "  [" + $trace.Ms + " ms]")
            return $trace
        }
    }
    Write-Warn2 "no proxy in the pool produced a usable egress block"
    return $null
}

function Set-ProxyEnv([string]$Url) {
    $noProxy = "localhost,127.0.0.1,::1"
    foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy")) {
        Set-ServiceEnv $name $Url
    }
    foreach ($name in @("NO_PROXY", "no_proxy")) {
        Set-ServiceEnv $name $noProxy
    }
}

function Apply-Proxy($cfg, [switch]$SkipTest) {
    if (-not $cfg.proxy) {
        Set-ProxyEnv ""
        Write-Ok "service proxy cleared, direct egress"
        return $true
    }
    $url = $cfg.proxy
    $viaBridge = $false
    if ($url -match "^socks5h?://") {
        if (-not (Start-Bridge $cfg)) { return $false }
        $url = "http://127.0.0.1:" + $cfg.bridgePort
        $viaBridge = $true
    }
    if (-not $SkipTest -and -not (Test-Upstream $url 8)) {
        Write-Bad ("upstream not answering: " + $cfg.proxy)
        Write-Info "opencode was not switched, fix the proxy and retry"
        if ($viaBridge) { Stop-Bridge }
        return $false
    }
    Set-ProxyEnv $url
    Write-Ok ("service proxy set: " + $url)
    return $true
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
    Install-SlashCommand
    $cfg = Get-Config
    $org = Get-OrgId $cfg
    if ($org) { Write-Ok "org id discovered: $org" } else { Write-Warn2 "org id not discovered yet, run opencode once and retry" }
    Save-Config $cfg

    Remove-StaleInstalls

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

    if (Test-Path $script:PluginFile) {
        Write-Warn2 "the shield plugin is installed"
        Write-Info "check it with: opencode-unlimited plugin"
    } else {
        Write-Ok "shield plugin not installed (run 'opencode-unlimited on' when you want it)"
    }
    Write-Step ""
    Write-Ok "done. try: opencode-unlimited usage"
}

function Get-PathArg {
    foreach ($item in $Rest) {
        if (-not $item) { continue }
        if ($item -eq "-Db" -or $item -eq "--db") { continue }
        if ($item -match "^-") { continue }
        return $item
    }
    return ""
}

function Get-StaleInstalls {
    $root = (Resolve-Path $script:Root).ProviderPath.TrimEnd("\")
    $entries = @()
    $reg = (Get-ItemProperty "HKCU:\Environment" -Name Path -ErrorAction SilentlyContinue).Path
    foreach ($value in @($reg, $env:PATH)) {
        if (-not $value) { continue }
        foreach ($entry in ($value -split ";")) {
            $clean = $entry.Trim().TrimEnd("\")
            if (-not $clean) { continue }
            if ($clean -ieq $root -or $clean -ieq (Join-Path $root "bin")) { continue }
            $script = Join-Path $clean "opencode-unlimited.ps1"
            $isOurDir = (Split-Path -Leaf $clean) -ieq "bin" -and (Split-Path -Leaf (Split-Path -Parent $clean)) -match "unlimited"
            if (-not (Test-Path $script) -and -not $isOurDir) { continue }
            if ($entries -notcontains $clean) { $entries += $clean }
        }
    }
    return $entries
}

function Remove-StaleInstalls {
    $stale = Get-StaleInstalls
    if (-not $stale) { return }
    $reg = (Get-ItemProperty "HKCU:\Environment" -Name Path -ErrorAction SilentlyContinue).Path
    if (-not $reg) { return }
    $keep = @()
    foreach ($entry in ($reg -split ";")) {
        $clean = $entry.Trim().TrimEnd("\")
        if ($clean -and ($stale -contains $clean)) { continue }
        if ($entry.Trim()) { $keep += $entry.Trim() }
    }
    [System.Environment]::SetEnvironmentVariable("Path", ($keep -join ";"), "User")
    Write-Ok ("removed stale path entries: " + ($stale -join ", "))
}

function Cmd-Verify([switch]$Fix) {
    Write-Step "==> checking session integrity"
    $fix = $Fix.IsPresent -or ($Rest -contains "-fix") -or ($Rest -contains "--fix")
    $out = Invoke-DbTool "verify" $(if ($fix) { "fix" } else { "" })
    $found = $false
    foreach ($line in @($out)) {
        $text = ([string]$line).Trim()
        if (-not $text) { continue }
        if ($text -match "^no problems") { Write-Ok $text }
        elseif ($text -match "fixed [1-9]") { Write-Ok $text }
        elseif ($text -match "^(opencode\.db|node 22|node not|missing helper|schema)") { Write-Bad $text; $found = $true }
        else { Write-Warn2 $text; $found = $true }
    }
    if (-not $fix -and $found) { Write-Info "run with -fix to repair the listed items" }
}

function Cmd-Clear {
    Write-Step "==> clearing stored limit errors"
    $target = Get-PathArg
    if ($target) {
        Write-Info ("scope: " + $target)
        Remove-StuckErrors $target
    } else {
        Write-Info "scope: every session"
        Remove-StuckErrors
    }
    Write-Info "the banner comes from stored error rows, not from the server"
    Write-Info "opencode re-reads session state as it goes, no restart needed"
    Write-Info "if a new prompt still fails, your egress ip is still on the spent bucket"
}

function Cmd-Reset {
    $dry = $Rest -contains "-Dry" -or $Rest -contains "--dry"
    $keepIds = $Rest -contains "-KeepIds" -or $Rest -contains "--keep-ids"
    Write-Step $(if ($dry) { "==> reset (dry run, nothing is written)" } else { "==> reset" })
    $cfg = Get-Config
    $target = Get-PathArg
    $hunt = $Rest -contains "-Hunt" -or $Rest -contains "--hunt"
    $traceBefore = Get-EgressTrace $cfg.proxy -Force
    $ipBefore = $traceBefore.Ip
    $beforeText = if ($ipBefore) { $ipBefore } else { "unknown" }
    if ($traceBefore.Country) { $beforeText = $beforeText + "  " + $traceBefore.Country }
    Write-Info ("egress ip before: " + $beforeText)

    Write-Step ""
    Write-Step "[1/6] device identity"
    $idHelper = Join-Path $script:Root "lib\identity.js"
    $identity = $null
    if (Test-Path $idHelper) {
        $raw = Invoke-NodeHelper $idHelper @($(if ($dry) { "show" } else { "rotate" }))
        try { $identity = $raw | ConvertFrom-Json } catch { $identity = $null }
    }
    if ($identity -and $identity.deviceId) {
        if ($dry) { Write-Info ("current id: " + $identity.deviceId) }
        else { Write-Ok ("device id : " + $identity.deviceId) }
        Write-Info ("generation: " + $identity.generation + "   fingerprint: " + $identity.fingerprint)
        Write-Info "local only, the registry and the real machine guid are untouched"
    } else {
        Write-Warn2 "device identity skipped"
    }

    Write-Step ""
    Write-Step "[2/6] stored limit errors"
    if ($dry) {
        Write-Info "skipped in a dry run"
    } else {
        Remove-StuckErrors $target
    }

    Write-Step ""
    Write-Step "[3/6] session ids"
    if ($keepIds) {
        Write-Info "skipped, -KeepIds was passed"
    } elseif (-not $target) {
        Write-Info "skipped, name a folder to re-id its sessions"
        Write-Info 'opencode-unlimited reset "C:\path\to\project"'
    } elseif (-not (Test-NodeSqlite)) {
        Write-Warn2 "node 22.5+ required, session ids left alone"
    } else {
        Show-ReidBatch (Invoke-ReidPath $target -Dry:$dry)
    }

    Write-Step ""
    Write-Step "[4/6] egress route"
    if ($hunt) {
        if ($dry) { Write-Info "would hunt for a route that is not already spent" }
        else { Invoke-Hunt $cfg 4 8 "" "" | Out-Null }
    } else {
        Invoke-EgressRotation $cfg $ipBefore "" "" -Dry:$dry | Out-Null
    }

    Write-Step ""
    Write-Step "[5/6] egress block"
    Start-Sleep -Seconds 1
    $traceAfter = Get-EgressTrace $cfg.proxy -Force
    $ipAfter = $traceAfter.Ip
    if ($dry) {
        Write-Info ("ip now: " + $(if ($ipAfter) { $ipAfter } else { "unknown" }) + ", nothing recorded")
    } else {
        $cfg.lastIp = $ipAfter
        $cfg.lastCountry = $traceAfter.Country
        Save-Config $cfg
        $egressHelper = Join-Path $script:Root "lib\egress.js"
        if ((Test-Path $egressHelper) -and $ipAfter) {
            $env:UNLIMITED_EGRESS_IP = $ipAfter
            if ($traceAfter.Country) { $env:UNLIMITED_EGRESS_COUNTRY = $traceAfter.Country }
            Invoke-NodeHelper $egressHelper @("record", "0", "0") | Out-Null
            Remove-Item Env:\UNLIMITED_EGRESS_IP -ErrorAction SilentlyContinue
            Remove-Item Env:\UNLIMITED_EGRESS_COUNTRY -ErrorAction SilentlyContinue
        }
        if (-not $ipAfter) {
            Write-Warn2 "egress ip unknown"
        } elseif ($ipBefore -and (Test-SameBlock $ipAfter $ipBefore)) {
            Write-Warn2 ("same egress block: " + $ipAfter + " " + $traceAfter.Country)
            Write-Info "the meter follows the egress block, not the project, the session or the device"
            Write-Info "if a refusal was logged today, this block stays spent until 00:00 UTC"
            Write-Info "change the connection, or switch model to leave the meter behind"
        } else {
            Write-Ok ("new egress block: " + $ipAfter + " " + $traceAfter.Country)
        }
    }

    Write-Step ""
    Write-Step "[6/6] database"
    if ($dry) {
        Write-Info "skipped in a dry run"
    } else {
        Cmd-Verify -Fix | Out-Null
        Write-Info "sessions and messages untouched"
    }

    Write-Step ""
    $midnight = [DateTime]::UtcNow.Date.AddDays(1)
    if ($dry) { Write-Ok "dry run complete, nothing was written" }
    else { Write-Ok "reset complete" }
    Write-Info ("quota resets at " + $midnight.ToLocalTime().ToString("h:mm tt") + " local, " + $midnight.ToString("HH:mm") + " UTC")
    Write-Info "switch model to skip the meter: opencode-unlimited model provider/model"
}

function Get-RestFlag([string[]]$Names, [string]$Default) {
    for ($i = 0; $i -lt $Rest.Count - 1; $i++) {
        if ($Names -contains $Rest[$i]) { return [string]$Rest[$i + 1] }
    }
    return $Default
}

function Get-RestInt([string[]]$Names, [int]$Default) {
    $value = 0
    if ([int]::TryParse((Get-RestFlag $Names ""), [ref]$value)) { return $value }
    return $Default
}

function Invoke-Hunt($cfg, [int]$Tries, [int]$Minutes, [string]$Country, [string]$Prefix, [switch]$NoProbe, [switch]$NoRestart) {
    if ($Tries -le 0) { $Tries = 6 }
    if ($Minutes -le 0) { $Minutes = 10 }
    $started = Get-Date
    $avoid = Get-EgressIp $cfg.proxy -Force
    $same = 0
    $burned = 0
    for ($attempt = 1; $attempt -le $Tries; $attempt++) {
        if (((Get-Date) - $started).TotalMinutes -gt $Minutes) {
            Write-Warn2 "hunt: time is up"
            return $null
        }
        Write-Info ("[" + $attempt + "/" + $Tries + "] rotating")
        $trace = Invoke-EgressRotation $cfg $avoid $Country $Prefix -NoRestart:$NoRestart -Tries $Tries
        if (-not $trace) {
            Write-Warn2 "  no route matched"
            Start-Sleep -Seconds 2
            continue
        }
        if ($avoid -and (Test-SameBlock $trace.Ip $avoid)) {
            $same += 1
            Write-Warn2 ("  same block as before (" + $same + "/3)")
            if ($same -ge 3) {
                Write-Bad "  the rotation keeps returning the same block"
                return $null
            }
            Start-Sleep -Seconds 2
            continue
        }
        $same = 0
        $avoid = $trace.Ip
        if ($NoProbe) { return $trace }
        $app = Invoke-AppProbe ""
        if ($app.Ok) {
            Add-EgressRecord 200 0 $trace.Country | Out-Null
            Write-Ok ("  route accepted: " + $trace.Ip + " " + $trace.Country)
            return $trace
        }
        if ($app.Blocked) {
            $burned += 1
            Add-EgressRecord 429 0 $trace.Country | Out-Null
            Write-Warn2 ("  block already spent (" + $burned + " burned)")
            if ($burned -ge 4) {
                Write-Bad "  too many burned blocks, stopping"
                return $null
            }
            continue
        }
        Write-Warn2 ("  probe unconfirmed: " + $app.Reason)
        return $trace
    }
    Write-Bad "hunt: no usable route found"
    return $null
}

function Test-RotateGate {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $state = Get-Json $script:RotateGateFile
    $keep = @()
    if ($state -and $state.stamps) {
        foreach ($stamp in @($state.stamps)) {
            if (($now - [long]$stamp) -lt 1800) { $keep += [long]$stamp }
        }
    }
    if ($keep.Count -ge 5) { return $false }
    $keep += $now
    Write-TextFile $script:RotateGateFile (([ordered]@{ stamps = @($keep) }) | ConvertTo-Json -Depth 3)
    return $true
}

function Cmd-Hunt {
    $cfg = Get-Config
    $tries = Get-RestInt @("-Tries", "--tries", "-n") 6
    $minutes = Get-RestInt @("-Minutes", "--minutes", "-m") 10
    $country = (Get-RestFlag @("-Country", "--country") "").ToUpperInvariant()
    $prefix = Get-RestFlag @("-Prefix", "--prefix") ""
    $noProbe = $Rest -contains "-NoProbe" -or $Rest -contains "--no-probe"
    $noRestart = $Rest -contains "-NoRestart" -or $Rest -contains "--no-restart"
    Write-Step "==> route hunt"
    Write-Info ("tries   : " + $tries)
    Write-Info ("minutes : " + $minutes)
    if ($country) { Write-Info ("country : " + $country) }
    if ($prefix) { Write-Info ("prefix  : " + $prefix) }
    if ($noProbe) { Write-Info "probe   : off, the route is taken on trust" }
    if ($noRestart) { Write-Info "restart : off, the service keeps its current process" }
    Write-Step ""
    $trace = Invoke-Hunt $cfg $tries $minutes $country $prefix -NoProbe:$noProbe -NoRestart:$noRestart
    Write-Step ""
    if ($trace) {
        Write-Ok ("live route: " + $trace.Ip + " " + $trace.Country)
        Write-Info "send the prompt again, the meter is on the new block"
    } else {
        Write-Bad "no usable route found"
        Write-Info "add proxies: opencode-unlimited proxy pool add socks5://host:port"
        Write-Info "or point at a list: opencode-unlimited proxy pool fetch <url>"
    }
}

function Cmd-Watch {
    $follow = $Rest -contains "-Follow" -or $Rest -contains "--follow" -or $Rest -contains "-f"
    $auto = $Rest -contains "-Auto" -or $Rest -contains "--auto"
    $all = $Rest -contains "-All" -or $Rest -contains "--all"
    $helper = Join-Path $script:Root "lib\log-watch.js"
    if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }
    Write-Step "==> free limit watcher"
    $scanArgs = @("scan")
    if ($all) { $scanArgs += "--reset" }
    $first = $true
    while ($true) {
        $scan = $null
        try { $scan = (Invoke-NodeHelper $helper $scanArgs) | ConvertFrom-Json } catch { $scan = $null }
        if (-not $scan -or -not $scan.file) {
            Write-Bad "no opencode log found, start opencode once"
            return
        }
        if ($first) {
            Write-Info ("log    : " + $scan.file)
            Write-Info ("offset : " + $scan.from + " -> " + $scan.offset)
            $first = $false
            $scanArgs = @("scan")
        }
        $events = @($scan.events)
        if (-not $events.Count -and -not $follow) {
            Write-Ok "no free-limit line in the new part of the log"
            Write-Info "pass -all to rescan the whole file, -follow to keep tailing"
        }
        if ($events.Count -gt 6) {
            Write-Info ("older events hidden: " + ($events.Count - 6))
            $events = @($events[($events.Count - 6)..($events.Count - 1)])
        }
        $rotateSeen = 0
        $handled = $false
        foreach ($event in $events) {
            $local = if ($event.at) { ([DateTime]$event.at).ToLocalTime() } else { Get-Date }
            $when = if ($local.Date -eq (Get-Date).Date) { $local.ToString("HH:mm:ss") } else { $local.ToString("MM-dd HH:mm") }
            $label = if ($event.message) { $event.message } else { "error" }
            $reasonText = if ($event.reason) { "  [" + $event.reason + "]" } else { "" }
            if ($event.kind -eq "rotate") {
                $rotateSeen += 1
                Write-Bad ("limit at " + $when + "   " + $label + $reasonText + "  run=" + $event.run)
                if (-not $auto) { continue }
                if (-not (Test-RotateGate)) {
                    Write-Warn2 "rotation gate: 5 moves per 30 minutes, holding"
                    continue
                }
                $cfg = Get-Config
                $trace = Invoke-Hunt $cfg 4 8 "" ""
                if ($trace) {
                    Write-Ok ("route live: " + $trace.Ip + " " + $trace.Country)
                    Write-Info "send the prompt again, the new block is in place"
                    $handled = $true
                    if ($follow) { return }
                } else {
                    Write-Warn2 "no usable route yet, still watching"
                }
            } else {
                Write-Warn2 ("rate limit at " + $when + "   " + $label + $reasonText + "  run=" + $event.run)
                Write-Info "that is a throttle, not the daily bucket: wait and retry"
            }
        }
        if ($rotateSeen -gt 0 -and -not $auto -and -not $handled) {
            Write-Info "next: opencode-unlimited hunt"
            Write-Info "or let the watcher drive: opencode-unlimited watch -follow -auto"
        }
        if (-not $follow) { return }
        Start-Sleep -Seconds 2
    }
}

function Cmd-Token {
    $sub = if ($Rest.Count -ge 1) { $Rest[0].ToLowerInvariant() } else { "status" }
    switch ($sub) {
        "save" {
            if (-not (Test-Path $script:AuthDir)) { Write-Bad ("no auth.json at " + $script:AuthDir); return }
            New-Item -ItemType Directory -Path $script:AuthSnapshotDir -Force | Out-Null
            Copy-Item $script:AuthDir $script:AuthSnapshot -Force
            $size = (Get-Item $script:AuthSnapshot).Length
            Write-Ok ("token snapshot saved, " + $size + " bytes")
            Write-Info ("path: " + $script:AuthSnapshot)
            Write-Info "local app data only, nothing synced, the registry is untouched"
        }
        "restore" {
            if (-not (Test-Path $script:AuthSnapshot)) { Write-Bad "no snapshot yet, run: opencode-unlimited token save"; return }
            $force = $Rest -contains "-Force" -or $Rest -contains "--force"
            if ((Test-Path $script:AuthDir) -and -not $force) {
                Write-Warn2 "auth.json is already there, pass -Force to overwrite it"
                return
            }
            Copy-Item $script:AuthSnapshot $script:AuthDir -Force
            Write-Ok "auth.json restored, no login needed"
            Write-Info "restart opencode so it reads the file"
        }
        "drop" {
            Remove-Item $script:AuthSnapshot -Force -ErrorAction SilentlyContinue
            Write-Ok "token snapshot removed"
        }
        default {
            $live = "missing"
            if (Test-Path $script:AuthDir) {
                $item = Get-Item $script:AuthDir
                $live = $item.Length.ToString() + " bytes, " + $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            }
            $snap = "missing"
            if (Test-Path $script:AuthSnapshot) {
                $item = Get-Item $script:AuthSnapshot
                $snap = $item.Length.ToString() + " bytes, " + $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            }
            Write-Info ("auth.json : " + $live)
            Write-Info ("snapshot  : " + $snap)
            Write-Info ("path      : " + $script:AuthSnapshot)
            Write-Info "save keeps a local copy, restore puts it back after the app drops it"
        }
    }
}

function Get-OpenCodeExe {
    $info = Get-OpenCodeInfo
    if ($info.exe -and (Test-Path $info.exe) -and $info.exe -like "*.exe") { return $info.exe }
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    $candidates = @()
    if ($cmd) {
        $candidates += $cmd.Source
        $candidates += ($cmd.Source -replace "\.(ps1|cmd|bat)$", ".exe")
    }
    $candidates += (Join-Path $env:APPDATA "npm\node_modules\@opencode\cli\bin\opencode.exe")
    foreach ($path in $candidates) {
        if ($path -and $path -like "*.exe" -and (Test-Path $path)) { return $path }
    }
    if ($cmd) { return $cmd.Source }
    return "opencode"
}

function Get-UserAgent {
    $info = Get-OpenCodeInfo
    $version = if ($info.version) { $info.version } else { "latest" }
    return "opencode/latest/" + $version + "/cli"
}

function Test-LimitOutput([string]$Text) {
    if (-not $Text) { return $false }
    return ($Text -match "FreeUsageLimit|Free usage limit|free messages|free tier")
}

function Remove-ProbeSession([string]$OpenCode, [string]$SessionId) {
    if (-not $SessionId) { return }
    try { & $OpenCode session delete $SessionId 2>&1 | Out-Null } catch { }
}

function Invoke-AppProbe([string]$Directory) {
    $oc = Get-OpenCodeExe
    if (-not $oc -or -not (Test-Path $oc)) {
        return [pscustomobject]@{ Ok = $false; Blocked = $false; Broken = $true; Kind = "broken"; Reason = "opencode binary not found"; Raw = ""; Model = ""; Session = "" }
    }
    $cfg = Get-Config
    $info = Get-OpenCodeInfo
    $model = "opencode/" + (Resolve-ProbeModel $cfg $info)
    $work = $Directory
    $throwaway = $false
    if (-not $work) {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("unlimited-probe-" + (New-Hex 6))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $throwaway = $true
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    Push-Location $work
    try {
        $out = (& $oc run --format json -m $model "reply with exactly: ok" 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $previous
        if ($throwaway) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $session = ""
    if ($out -match "(ses_[A-Za-z0-9]+)") { $session = $Matches[1] }
    if ($session) { Remove-ProbeSession $oc $session }
    if (Test-LimitOutput $out) {
        return [pscustomobject]@{ Ok = $false; Blocked = $true; Broken = $false; Kind = "limit"; Reason = "app refused on free limit"; Raw = $out; Model = $model; Session = $session }
    }
    if ($code -eq 0 -and $out -match "\bok\b") {
        return [pscustomobject]@{ Ok = $true; Blocked = $false; Broken = $false; Kind = "ok"; Reason = "app answered"; Raw = $out; Model = $model; Session = $session }
    }
    return [pscustomobject]@{ Ok = $false; Blocked = $false; Broken = $true; Kind = "broken"; Reason = "app did not answer"; Raw = $out; Model = $model; Session = $session }
}

function Get-VirtualIdentity {
    $helper = Join-Path $script:Root "lib\identity.js"
    if (-not (Test-Path $helper)) { return $null }
    $raw = Invoke-NodeHelper $helper @("show")
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

function Cmd-Identity {
    $helper = Join-Path $script:Root "lib\identity.js"
    if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }
    $action = "show"
    if ($Rest -contains "rotate" -or $Rest -contains "--rotate") { $action = "rotate" }
    if ($Rest -contains "restore" -or $Rest -contains "--restore") { $action = "restore" }
    $raw = Invoke-NodeHelper $helper @($action)
    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
    if (-not $data) {
        Write-Bad "identity helper returned nothing"
        return
    }
    if ($action -eq "restore") {
        Write-Ok "virtual device identity removed"
        Write-Info ("state   : " + $data.stateFile)
        Write-Info "the real machine guid was never written, nothing to undo there"
        return
    }
    Write-Step "==> device identity"
    if (-not $data.exists -and $action -eq "show") {
        Write-Warn2 "no virtual identity minted yet"
        Write-Info "opencode-unlimited identity rotate"
        return
    }
    Write-Info ("device id  : " + $data.deviceId)
    Write-Info ("fingerprint: " + $data.fingerprint)
    Write-Info ("generation : " + $data.generation)
    Write-Info ("state      : " + $data.stateFile)
    Write-Info ("value file : " + $data.shimFile)
    Write-Info "registry   : not touched"
    if ($action -eq "rotate") { Write-Ok "new device identity minted" }
}

function Add-EgressRecord([int]$Status, [int]$RetryAfter, [string]$Country) {
    $cfg = Get-Config
    $trace = Get-EgressTrace $cfg.proxy -Force
    if (-not $trace.Ip) { return "" }
    $helper = Join-Path $script:Root "lib\egress.js"
    if (-not (Test-Path $helper)) { return $trace.Ip }
    $env:UNLIMITED_EGRESS_IP = $trace.Ip
    if ($Country) { $env:UNLIMITED_EGRESS_COUNTRY = $Country }
    elseif ($trace.Country) { $env:UNLIMITED_EGRESS_COUNTRY = $trace.Country }
    Invoke-NodeHelper $helper @("record", [string]$Status, [string]$RetryAfter) | Out-Null
    Remove-Item Env:\UNLIMITED_EGRESS_IP -ErrorAction SilentlyContinue
    Remove-Item Env:\UNLIMITED_EGRESS_COUNTRY -ErrorAction SilentlyContinue
    return $trace.Ip
}

function Cmd-Block {
    $helper = Join-Path $script:Root "lib\egress.js"
    if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }
    if ($Rest -contains "clear" -or $Rest -contains "--clear") {
        Invoke-NodeHelper $helper @("clear") | Out-Null
        Write-Ok "egress ledger cleared for today"
        return
    }
    if ($Rest -contains "check" -or $Rest -contains "--check") {
        $cfg = Get-Config
        $ip = Get-EgressIp $cfg.proxy -Force
        if (-not $ip) { Write-Bad "could not read the egress ip"; return }
        $raw = Invoke-NodeHelper $helper @("check", $ip)
        $data = $null
        try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
        Write-Step ("==> " + $ip + "  block " + $(if ($data) { $data.block } else { "?" }))
        if ($data -and $data.spent) {
            Write-Warn2 "SPENT - refused today, dead until 00:00 UTC"
            Write-Info "change the address, or switch model"
        } else {
            Write-Ok "no refusal recorded today on this block"
        }
        return
    }
    $raw = Invoke-NodeHelper $helper @("show")
    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
    if (-not $data) {
        Write-Bad "egress ledger unreadable"
        return
    }
    Write-Step ("==> egress blocks seen today (" + $data.total + ", spent " + $data.spent + ")")
    Write-Info "the meter keys on the block, an ipv4 address or an ipv6 /64"
    foreach ($row in @($data.blocks)) {
        $state = if ($row.spent) { "SPENT" } else { "open " }
        $where = if ($row.country) { "  " + $row.country.PadRight(2) } else { "    " }
        Write-Info ($row.block.PadRight(24) + " " + $state + $where + "  open=" + $row.open + " refused=" + $row.refused + "  last=" + $row.lastStatus)
    }
    $minutes = [math]::Floor($data.secondsToReset / 60)
    Write-Step ""
    Write-Info ("reset at 00:00 UTC, in " + $minutes + " minutes")
}

function Cmd-Usage {
    $cfg = Get-Config
    $deep = $Rest -contains "-check" -or $Rest -contains "--check" -or $Rest -contains "-live" -or $Rest -contains "--live"
    Write-Step "==> free tier check"
    $trace = Get-EgressTrace $cfg.proxy -Force
    $ip = $trace.Ip
    Write-Info ("egress ip : " + $(if ($ip) { $ip } else { "unknown" }))
    if ($trace.Country) { Write-Info ("country   : " + $trace.Country) }
    if ($trace.Warp) { Write-Info ("warp      : " + $trace.Warp) }
    $cfg.lastIp = $ip
    $cfg.lastCountry = $trace.Country
    Save-Config $cfg

    $helper = Join-Path $script:Root "lib\egress.js"
    $row = $null
    $ledger = $null
    if ((Test-Path $helper) -and $ip) {
        $raw = Invoke-NodeHelper $helper @("check", $ip)
        try { $row = $raw | ConvertFrom-Json } catch { $row = $null }
        if ($row -and -not $row.known) { $row = $null }
        $raw = Invoke-NodeHelper $helper @("show")
        try { $ledger = $raw | ConvertFrom-Json } catch { $ledger = $null }
    }

    if ($row) {
        Write-Info ("block     : " + $row.block)
        if ($row.spent) {
            Write-Warn2 ("SPENT - a refusal was recorded today (HTTP " + $row.lastStatus + ")")
            Write-Info "the meter is per egress block, every session on this address shares it"
            Write-Info "change the address, or switch model, or wait for the reset"
        } else {
            Write-Ok "no refusal recorded today on this block"
            if ($row.open -gt 0) { Write-Info ($row.open + " answered requests seen today") }
        }
    } else {
        Write-Info ("block     : " + $(if ($ip) { $ip } else { "unknown" }))
        Write-Warn2 "nothing recorded today on this block"
        Write-Info "a refusal gets logged here the next time the app reports one"
    }

    if ($deep) {
        Write-Step ""
        Write-Step "app check"
        Write-Info "this opens a throwaway session, then deletes it"
        $app = Invoke-AppProbe ""
        if ($app.Ok) {
            Add-EgressRecord 200 0 $trace.Country | Out-Null
            Write-Ok "OPEN - the app answered on this connection"
        } elseif ($app.Blocked) {
            Add-EgressRecord 429 0 $trace.Country | Out-Null
            Write-Bad "BLOCKED - the app itself was refused on this connection"
        } else {
            Write-Warn2 ("unconfirmed - " + $app.Reason)
        }
        if ($app.Session) { Write-Info ("probe session removed: " + $app.Session) }
    }

    if ($ledger) {
        Write-Step ""
        Write-Info ("blocks today: " + $ledger.total + "   spent " + $ledger.spent)
    }

    $midnight = [DateTime]::UtcNow.Date.AddDays(1)
    $wait = [math]::Floor(($midnight - [DateTime]::UtcNow).TotalMinutes)
    Write-Step ""
    Write-Info ("reset : " + $midnight.ToLocalTime().ToString("h:mm tt") + " local   in " + $wait + " minutes")
    Write-Info "zero-cost detection: opencode-unlimited watch"
    Write-Info "skip the meter entirely: opencode-unlimited model"
}

function Invoke-ReidPath([string]$Target, [switch]$Dry) {
    $db = Get-DatabasePath
    if (-not $db) { return $null }
    $helper = Join-Path $script:Root "lib\session-reid.js"
    if (-not (Test-Path $helper)) { return $null }
    $cmdArgs = @($db, "reid-all", $Target)
    if ($Dry) { $cmdArgs += "--dry" }
    $raw = Invoke-NodeHelper $helper $cmdArgs
    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
    if (-not $data) {
        $text = ($raw -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join " "
        return [pscustomobject]@{ error = $text }
    }
    return $data
}

function Show-ReidBatch($Data) {
    if (-not $Data) { Write-Bad "no result"; return }
    if ($Data.error) { Write-Bad ([string]$Data.error); return }
    if ($Data.dryRun) {
        $mb = [math]::Round((($Data.results | Measure-Object -Property bytes -Sum).Sum) / 1048576, 1)
        Write-Step ("==> would re-id " + $Data.selected + " of " + $Data.total + " sessions, " + $mb + " MB")
        foreach ($row in ($Data.results | Select-Object -First 15)) {
            Write-Info ($row.oldId + "  messages=" + $row.messages + " refs=" + $row.refs)
        }
        if ($Data.total -gt 15) { Write-Info ("... and " + ($Data.total - 15) + " more") }
        Write-Info "nothing was written, drop -Dry to run it"
        return
    }
    foreach ($row in @($Data.results)) {
        Write-Ok ($row.oldId + "  ->  " + $row.newId + "  (" + $row.messages + " messages, " + $row.moved + " rows moved)")
    }
    foreach ($row in @($Data.failed)) {
        if ($row) { Write-Bad ($row.oldId + "  " + $row.error) }
    }
    Write-Info ("total   : " + $Data.total + " sessions in that folder")
    Write-Info ("reid    : " + $Data.reid + "   failed: " + @($Data.failed).Count)
    Write-Info ("moved   : " + $Data.rows + " rows, " + $Data.messages + " messages kept")
    Write-Info "no rows were deleted, the old ids are gone from the table"
}

function Cmd-Reid {
    if (-not (Test-NodeSqlite)) { Write-Bad "node 22.5+ required"; return }
    $dry = $Rest -contains "-Dry" -or $Rest -contains "--dry"
    $target = Get-PathArg
    if (-not $target) {
        Write-Step "==> mint a fresh session id"
        Write-Bad "name a session id or a folder"
        Write-Info "opencode-unlimited reid ses_abc123..."
        Write-Info "opencode-unlimited reid \"C:\path\to\project\" -Dry"
        return
    }

    if ($target -like "ses_*") {
        if ($dry) { Write-Info "dry run is for folders, a single id is one transaction"; }
        Write-Step "==> minting a fresh session id"
        $db = Get-DatabasePath
        if (-not $db) { Write-Bad "opencode.db not found"; return }
        $helper = Join-Path $script:Root "lib\session-reid.js"
        if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }
        $raw = Invoke-NodeHelper $helper @($db, "reid", $target)
        $result = $null
        try { $result = $raw | ConvertFrom-Json } catch { $result = $null }
        if (-not $result -or -not $result.newId -or $result.error) {
            Write-Bad "reid failed"
            $reason = if ($result -and $result.error) { [string]$result.error } else { ($raw -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join " " }
            Write-Info $reason
            return
        }
        Write-Ok ("old id : " + $result.oldId)
        Write-Ok ("new id : " + $result.newId)
        Write-Info ("table  : " + $result.sessionTable)
        Write-Info ("messages: " + $result.messages + "   rows moved: " + $result.moved)
        if ($null -ne $result.sequence) { Write-Info ("sequence: " + $result.sequence + " (counter kept ahead of the messages)") }
        foreach ($item in @($result.touched)) { if ($item) { Write-Info ("moved  : " + $item) } }
        Write-Info "open the new id in the app, the messages are all there"
        Write-Info "reid does not refill the quota, it only breaks a fork chain"
        return
    }

    Write-Step ("==> re-id every session in " + $target)
    Show-ReidBatch (Invoke-ReidPath $target -Dry:$dry)
    Write-Info "reid does not refill the quota, it only breaks a fork chain"
}

function Get-RestArgs {
    return @($Rest | Where-Object { $_ -and -not ($_ -match "^-") })
}

function Test-ModelSpec([string]$Value) {
    if (-not $Value) { return $false }
    if ($Value -match "^[A-Za-z]:[\\/]") { return $false }
    if ($Value -match "^ses_") { return $false }
    if ($Value -notmatch "/") { return $false }
    if (Test-Path -LiteralPath $Value) { return $false }
    return $true
}

function Write-ModelLine($Model) {
    if (-not $Model) { return "unset" }
    $provider = [string]$Model.providerID
    $id = [string]$Model.id
    $variant = [string]$Model.variant
    if (-not $provider) { return ($Model | ConvertTo-Json -Compress -Depth 3) }
    $text = $provider + "/" + $id
    if ($variant) { $text = $text + "#" + $variant }
    return $text
}

function Cmd-Model {
    $db = Get-DatabasePath
    if (-not $db) { Write-Bad "opencode.db not found"; return }
    if (-not (Test-NodeSqlite)) { Write-Bad "node 22.5+ required"; return }
    $helper = Join-Path $script:Root "lib\model-switch.js"
    if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }

    $items = @(Get-RestArgs)
    $target = ""
    $spec = ""

    if ($items.Count -eq 0) {
        $raw = Invoke-NodeHelper $helper @($db, "list")
        $data = $null
        try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
        if (-not $data -or -not $data.providers) {
            Write-Bad "could not read the model registry"
            Write-Info "run opencode once so the cache fills, then try again"
            return
        }
        Write-Step ("==> providers with credentials (" + @($data.providers).Count + ")")
        Write-Info ("registry: " + $data.registry)
        Write-Info "free means the provider bills nothing for that model"
        foreach ($provider in $data.providers) {
            $models = @($provider.models)
            $free = @($models | Where-Object { $_.free })
            Write-Step ""
            Write-Step ("  " + $provider.providerID + "  models=" + $models.Count + "  free=" + $free.Count)
            foreach ($model in ($free | Select-Object -First 12)) {
                $ctx = ""
                if ($model.context -gt 0) { $ctx = "  ctx " + [math]::Round($model.context / 1000) + "k" }
                Write-Info ("    " + $provider.providerID + "/" + $model.id + $ctx)
            }
            if ($free.Count -eq 0) {
                foreach ($model in ($models | Select-Object -First 4)) {
                    Write-Info ("    " + $provider.providerID + "/" + $model.id)
                }
            }
        }
        Write-Step ""
        Write-Info "switch a session: opencode-unlimited model <session-id|folder> provider/model"
        return
    }

    if ($items.Count -eq 1) {
        if (Test-ModelSpec $items[0]) {
            $spec = $items[0]
            $target = (Get-Location).Path
        } else {
            $target = $items[0]
        }
    } else {
        $target = $items[0]
        $spec = $items[1]
    }

    if (-not $spec) {
        $raw = Invoke-NodeHelper $helper @($db, "get", $target)
        $data = $null
        try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
        if (-not $data -or -not $data.sessions) {
            Write-Bad "could not read the model for that target"
            if ($data -and $data.error) { Write-Info ([string]$data.error) }
            return
        }
        Write-Step ("==> current model (" + @($data.sessions).Count + " sessions)")
        foreach ($row in $data.sessions) {
            Write-Info ($row.id + "  " + (Write-ModelLine $row.model))
        }
        return
    }

    $raw = Invoke-NodeHelper $helper @($db, "set", $target, $spec)
    $result = $null
    try { $result = $raw | ConvertFrom-Json } catch { $result = $null }
    if (-not $result -or $result.error) {
        Write-Bad "switch failed"
        if ($result -and $result.error) { Write-Info ([string]$result.error) }
        return
    }

    Write-Step "==> model switched"
    Write-Info ("target : " + $result.kind + " " + $(if ($result.directory) { $result.directory } else { "" }))
    Write-Info ("model  : " + $result.spec)
    foreach ($row in @($result.changed)) {
        Write-Ok ($row.id + "  " + (Write-ModelLine $row.before) + " -> " + (Write-ModelLine $row.after))
    }
    Write-Info ("sessions changed: " + @($result.changed).Count)
    Write-Step ""
    if ($result.applied.providerID -eq "opencode") {
        Write-Warn2 "opencode models are metered per egress address, this keeps the daily wall"
    } else {
        Write-Ok "this pipe is not metered by the opencode free wall"
    }
    Write-Info "restart the app so the session picks up the new model"
}

function Cmd-Sessions {
    $db = Get-DatabasePath
    if (-not $db) { Write-Bad "opencode.db not found"; return }
    if (-not (Test-NodeSqlite)) { Write-Bad "node 22.5+ required"; return }
    $helper = Join-Path $script:Root "lib\session-reid.js"
    if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }
    $target = Get-PathArg
    $cmdArgs = @($db, "list")
    if ($target) { $cmdArgs += $target }
    $raw = Invoke-NodeHelper $helper $cmdArgs
    $rows = @()
    try { $rows = @($raw | ConvertFrom-Json) } catch { $rows = @() }
    if ($rows.Count -eq 0) {
        Write-Warn2 "no sessions found"
        return
    }
    $schema = ""
    $info = Get-OpenCodeInfo
    if ($info.sessionTable) { $schema = $info.sessionTable }
    Write-Step ("==> sessions (" + $rows.Count + ")" + $(if ($schema) { ", table " + $schema } else { "" }))
    Write-Info "size is the replayed history, the thing a free turn has to pay for"
    foreach ($row in $rows) {
        $title = [string]$row.title
        if (-not $title) { $title = "(untitled)" }
        if ($title.Length -gt 40) { $title = $title.Substring(0, 40) }
        $when = ""
        if ($row.updated -gt 0) {
            $when = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$row.updated)).ToLocalTime().ToString("M/d HH:mm")
        }
        $mb = [math]::Round(([double]$row.bytes) / 1048576, 1)
        $size = ($mb.ToString("0.0").PadLeft(7) + " MB")
        Write-Info ($row.id + "  " + $when.PadRight(12) + "  " + $size + "  " + $title)
    }
}

function Cmd-Status {
    $cfg = Get-Config
    $info = Get-OpenCodeInfo
    Write-Step "==> opencode-unlimited status"
    Write-Step ""
    Write-Step "runtime"
    $versionText = if ($info.version) { "v" + $info.version } else { "not detected" }
    if ($info.api) { $versionText += "  (api v" + $info.api + ")" }
    Write-Info ("opencode   : " + $versionText)
    Write-Info ("binary     : " + $info.exe)
    Write-Info ("service    : " + $(if ($info.running) { "running" } else { "not running (start the app once)" }))
    Write-Info ("gateway    : " + $info.gateway)
    Write-Info ("database   : " + $(if ($info.dbPath) { $info.dbPath } else { "not found" }))
    Write-Info ("session t. : " + $(if ($info.sessionTable) { $info.sessionTable } else { "unknown" }))
    if (@($info.freeModels).Count -gt 0) {
        Write-Info ("free models: " + @($info.freeModels).Count + " listed, default " + $info.freeModel)
    }
    Write-Step ""
    Write-Step "identity"
    $vid = Get-VirtualIdentity
    if ($vid -and $vid.exists) {
        Write-Info ("device id  : " + $vid.deviceId)
        Write-Info ("fingerprint: " + $vid.fingerprint + "   generation " + $vid.generation)
        Write-Info "registry   : not touched, this id lives in a local file"
    } else {
        Write-Warn2 "no virtual identity yet, run: opencode-unlimited identity rotate"
    }
    Write-Step ""
    Write-Step "plugin"
    Write-Info ("state      : " + (Get-PluginState))
    Write-Info ("path       : " + $script:PluginFile)
    Write-Info ("config     : " + $(if (Test-PluginRegistered) { $script:PluginEntry + " listed" } else { "not listed, so opencode never loads it" }))
    $live = Test-PluginLive
    if ($live) {
        Write-Info ("loaded     : opencode " + $live.version + ", hooks " + (@($live.hooks) -join ", ") + ", at " + $live.at)
    }
    Write-Step ""
    Write-Step "automation"
    $watchPid = Get-WatcherPid
    $watchLive = $watchPid -gt 0 -and (Get-Process -Id $watchPid -ErrorAction SilentlyContinue)
    Write-Info ("mode       : " + $(if ($cfg.autoMode) { "on" } else { "off" }))
    Write-Info ("watcher    : " + $(if ($watchLive) { "running (pid " + $watchPid + ")" } else { "stopped" }))
    Write-Info ("autostart  : " + (Get-AutoStartState))
    $health = Get-ProxyHealthReport $cfg
    if ($health) {
        Write-Info ("pool health: " + $health.usable + " usable, " + $health.held + " parked of " + $health.total)
    } else {
        Write-Info "pool health: no pool yet"
    }
    Write-Step ""
    Write-Step "network"
    $trace = Get-EgressTrace $cfg.proxy
    $ipText = if ($trace.Ip) { $trace.Ip } else { "unknown" }
    if ($trace.Country) { $ipText = $ipText + "  " + $trace.Country }
    if ($trace.Warp) { $ipText = $ipText + "  warp=" + $trace.Warp }
    Write-Info ("egress ip  : " + $ipText)
    Write-Info ("ipMode     : " + $cfg.ipMode)
    Write-Info ("upstream   : " + $(if ($cfg.proxy) { $cfg.proxy } else { "none (manual)" }))
    if ($cfg.proxyListUrl) { Write-Info ("list url   : " + $cfg.proxyListUrl) }
    $bridgePid = Get-BridgePid
    if ($bridgePid -gt 0 -and (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue)) {
        Write-Info ("bridge     : running (pid " + $bridgePid + ", port " + $cfg.bridgePort + ")")
    } else {
        Write-Info "bridge     : stopped"
    }
    $warp = Get-WarpCli
    Write-Info ("warp-cli   : " + $(if ($warp) { $warp } else { "not installed (optional)" }))
    Write-Step ""
    Write-Step "egress ledger"
    $helper = Join-Path $script:Root "lib\egress.js"
    if (Test-Path $helper) {
        $raw = Invoke-NodeHelper $helper @("show")
        $ledger = $null
        try { $ledger = $raw | ConvertFrom-Json } catch { $ledger = $null }
        if ($ledger) {
            Write-Info ("today       : " + $ledger.day + "   blocks seen " + $ledger.total + "   spent " + $ledger.spent)
            $minutes = [math]::Floor($ledger.secondsToReset / 60)
            Write-Info ("next reset  : 00:00 UTC, in " + $minutes + " minutes")
        } else {
            Write-Warn2 "ledger unreadable"
        }
    } else {
        Write-Warn2 "egress helper missing"
    }
    Write-Info "details     : opencode-unlimited usage"
}

function Get-WatcherPid {
    $raw = Read-TextFile $script:WatchPidFile
    if (-not $raw) { return 0 }
    $first = ($raw.Trim() -split "\s+")[0]
    if ($first -match "^\d+$") { return [int]$first }
    return 0
}

function Start-WatcherDaemon {
    $watchPid = Get-WatcherPid
    if ($watchPid -gt 0 -and (Get-Process -Id $watchPid -ErrorAction SilentlyContinue)) {
        Write-Info ("watcher already running (pid " + $watchPid + ")")
        return $true
    }
    $entry = Join-Path $script:ScriptDir "opencode-unlimited.ps1"
    if (-not (Test-Path $entry)) {
        Write-Warn2 ("watcher entry not found: " + $entry)
        return $false
    }
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $entry, "watch", "-follow", "-auto")
    $errFile = $script:WatchLogFile + ".err"
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:WatchLogFile -RedirectStandardError $errFile
    } catch {
        Write-Warn2 ("watcher could not start: " + $_.Exception.Message)
        return $false
    }
    Start-Sleep -Milliseconds 900
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
        Write-TextFile $script:WatchPidFile ([string]$proc.Id)
        Write-Ok ("watcher running (pid " + $proc.Id + "), log " + $script:WatchLogFile)
        return $true
    }
    Write-Warn2 ("watcher exited at once, read " + $errFile)
    return $false
}

function Stop-WatcherDaemon {
    $watchPid = Get-WatcherPid
    if ($watchPid -gt 0) {
        $proc = Get-Process -Id $watchPid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $watchPid -Force -ErrorAction SilentlyContinue
            Write-Ok "watcher stopped"
        }
    }
    Remove-Item $script:WatchPidFile -Force -ErrorAction SilentlyContinue
}

function Get-AutoStartState {
    $result = Invoke-Native "schtasks.exe" @("/Query", "/TN", $script:AutoTaskName)
    if ($result.Code -eq 0 -and $result.Text -notmatch "ERROR:") { return "installed" }
    return "absent"
}

function Install-AutoStart {
    $entry = Join-Path $script:ScriptDir "opencode-unlimited.ps1"
    if (-not (Test-Path $entry)) { return $false }
    $task = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$entry`" watch -follow -auto"
    $result = Invoke-Native "schtasks.exe" @("/Create", "/F", "/SC", "ONLOGON", "/TN", $script:AutoTaskName, "/TR", $task)
    if ($result.Code -eq 0) {
        Write-Ok ("autostart task: " + $script:AutoTaskName + " at logon")
        return $true
    }
    Write-Warn2 "autostart task was not created"
    if ($result.Text) { Write-Info $result.Text.Trim() }
    return $false
}

function Remove-AutoStart {
    $result = Invoke-Native "schtasks.exe" @("/Delete", "/F", "/TN", $script:AutoTaskName)
    if ($result.Code -eq 0) { Write-Ok "autostart task removed" }
}

function Select-FreeModel($cfg) {
    $info = Get-OpenCodeInfo
    $free = @($info.freeModels)
    $current = [string]$cfg.model
    if ($current -and ($free.Count -eq 0 -or $free -contains $current)) { return $current }
    $pick = [string]$info.freeModel
    if (-not $pick -and $free.Count -gt 0) { $pick = [string]$free[0] }
    if (-not $pick) { $pick = $script:DefaultModel }
    if ($pick -ne $current) {
        $cfg.model = $pick
        Save-Config $cfg
    }
    return $pick
}

function Invoke-AutoSetup($cfg, [switch]$KeepId, [switch]$NoReid, [switch]$NoProbe, [switch]$NoStart, [switch]$KeepRoute) {
    $total = 7
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Bad "node is not on PATH, install Node.js 22.5 or newer first"
        return $false
    }

    Write-Step ("[1/" + $total + "] prerequisites")
    Write-Ok ("node " + ((& $node.Source --version) -join "").Trim())
    $oc = Resolve-OpenCode
    Write-Info ("opencode : " + $oc)
    $dbPath = Get-DatabasePath
    Write-Info ("database : " + $(if ($dbPath) { $dbPath } else { "not found, the app has not run yet" }))

    Write-Step ""
    Write-Step ("[2/" + $total + "] device identity")
    $idHelper = Join-Path $script:Root "lib\identity.js"
    if (-not (Test-Path $idHelper)) {
        Write-Warn2 "identity helper missing"
    } else {
        $action = if ($KeepId) { "show" } else { "rotate" }
        $raw = Invoke-NodeHelper $idHelper @($action)
        $ident = $null
        try { $ident = $raw | ConvertFrom-Json } catch { $ident = $null }
        if ($ident -and $ident.deviceId) {
            $tag = if ($KeepId) { "kept" } else { "fresh" }
            Write-Ok ("device id : " + $ident.deviceId + "  (" + $tag + ")")
            Write-Info ("generation: " + $ident.generation + "   fingerprint: " + $ident.fingerprint)
            Write-Info "local file only, the registry and the real machine id are untouched"
        } else {
            Write-Warn2 "identity left as it was"
        }
    }

    Write-Step ""
    Write-Step ("[3/" + $total + "] model")
    $model = Select-FreeModel $cfg
    Write-Ok ("free model: " + $model)

    Write-Step ""
    Write-Step ("[4/" + $total + "] proxy pool")
    $pool = @(Get-ProxyPool $cfg)
    if ($pool.Count -eq 0) {
        Write-Info "pool is empty, pulling a public list"
        Update-ProxyList $cfg | Out-Null
        $pool = @(Get-ProxyPool $cfg)
    }
    if ($pool.Count -gt 0) {
        $report = Get-ProxyHealthReport $cfg
        $tail = ""
        if ($report) { $tail = ", " + $report.usable + " usable, " + $report.held + " parked" }
        Write-Ok ([string]$pool.Count + " candidates" + $tail)
    } else {
        Write-Warn2 "no proxy list came back, the machine keeps its own route"
    }

    Write-Step ""
    Write-Step ("[5/" + $total + "] egress route")
    if ($KeepRoute) {
        $trace = Get-EgressTrace $cfg.proxy -Force
        if ($trace.Ip) { Write-Info ("left alone, egress " + $trace.Ip + " " + $trace.Country) }
        else { Write-Warn2 "route unknown" }
    } elseif ($pool.Count -eq 0) {
        Write-Info "no pool to rotate through, nothing to change"
    } else {
        $tries = [int]$cfg.autoTries
        $minutes = [int]$cfg.autoMinutes
        if ($tries -le 0) { $tries = 12 }
        if ($minutes -le 0) { $minutes = 8 }
        Write-Info ("hunting: " + $tries + " tries, " + $minutes + " minute cap" + $(if ($NoProbe) { ", probe off" } else { ", each route probed" }))
        $trace = Invoke-Hunt $cfg $tries $minutes "" "" -NoProbe:$NoProbe
        if ($trace) {
            Write-Ok ("route live: " + $trace.Ip + " " + $trace.Country + "  [" + $trace.Ms + " ms]")
        } else {
            Write-Warn2 "nothing in the pool worked, rolling back to direct"
            $cfg.proxy = ""
            $cfg.ipMode = "manual"
            Save-Config $cfg
            Apply-Proxy $cfg | Out-Null
            Restart-Service
        }
    }

    Write-Step ""
    Write-Step ("[6/" + $total + "] sessions")
    $here = (Get-Location).Path
    Write-Info "clearing stored free-limit errors in every session, not just this folder"
    Remove-StuckErrors
    if ($NoReid -or -not $cfg.reidOnAuto) {
        Write-Info "reid skipped"
    } elseif (-not (Test-NodeSqlite)) {
        Write-Warn2 "node 22.5+ required for reid, sessions left alone"
    } else {
        Show-ReidBatch (Invoke-ReidPath $here)
    }

    Write-Step ""
    Write-Step ("[7/" + $total + "] watcher and plugin")
    if (-not (Install-Plugin)) { Write-Warn2 "plugin not installed, everything else still runs" }
    Set-PluginEnabled $true
    Start-Sleep -Milliseconds 1200
    $live = Test-PluginLive
    if ($live) {
        Write-Ok ("plugin loaded in opencode " + $live.version + ", hooks " + (@($live.hooks) -join ", "))
    } else {
        Write-Info "plugin is installed and listed, opencode picks it up on the next file save or app start"
    }
    if ($NoStart) {
        Write-Info "watcher skipped, -NoStart was passed"
    } else {
        $cfg.autoMode = $true
        Save-Config $cfg
        Start-WatcherDaemon | Out-Null
        if (Install-AutoStart) { $cfg.autoStart = $true }
        Save-Config $cfg
    }
    return $true
}

function Cmd-On {
    $cfg = Get-Config
    Write-Step "==> opencode-unlimited on"
    Write-Info "one pass: identity, model, pool, verified route, sessions, watcher"
    Write-Info "after that the watcher keeps it moving by itself"
    Write-Step ""
    $ok = Invoke-AutoSetup $cfg `
        -KeepId:($Rest -contains "-KeepId" -or $Rest -contains "--keep-id") `
        -NoReid:($Rest -contains "-NoReid" -or $Rest -contains "--no-reid") `
        -NoProbe:($Rest -contains "-NoProbe" -or $Rest -contains "--no-probe") `
        -NoStart:($Rest -contains "-NoStart" -or $Rest -contains "--no-start") `
        -KeepRoute:($Rest -contains "-KeepRoute" -or $Rest -contains "--keep-route")
    Write-Step ""
    if (-not $ok) {
        Write-Bad "setup stopped early, see the notes above"
        return
    }
    $trace = Get-EgressTrace $cfg.proxy
    $ipText = if ($trace.Ip) { $trace.Ip } else { "unknown" }
    if ($trace.Country) { $ipText = $ipText + "  " + $trace.Country }
    $watcherText = if ($Rest -contains "-NoStart" -or $Rest -contains "--no-start") { "watcher off" } else { "watcher on" }
    Write-Ok ("ready. egress " + $ipText + ", " + $watcherText + ", autostart " + $(if ($cfg.autoStart) { "installed" } else { "off" }))
    Write-Info "state: opencode-unlimited status"
    Write-Info "stop : opencode-unlimited off"
}

function Cmd-Off {
    $cfg = Get-Config
    Write-Step "==> opencode-unlimited off"
    Stop-WatcherDaemon
    Remove-AutoStart
    Stop-Bridge
    $cfg.autoMode = $false
    $cfg.autoStart = $false
    $cfg.proxy = ""
    $cfg.ipMode = "manual"
    Save-Config $cfg
    Set-PluginEnabled $false
    Apply-Proxy $cfg | Out-Null
    Restart-Service
    Write-Step ""
    Write-Ok "watcher stopped, autostart gone, egress direct again"
    Write-Info "sessions, messages and the identity file were not touched"
}

function Show-ProxyPool($cfg) {
    $pool = @(Get-ProxyPool $cfg)
    $cache = Get-Json $script:PoolCacheFile
    if (-not $pool.Count) {
        Write-Info "pool: empty"
        Write-Info "opencode-unlimited proxy pool add socks5://host:port"
        Write-Info "opencode-unlimited proxy pool fetch https://example.com/list.txt"
        return
    }
    $active = [int]$cfg.proxyIndex
    Write-Info ("pool: " + $pool.Count + " entries, active #" + ($active + 1))
    $shown = [Math]::Min($pool.Count, 20)
    for ($i = 0; $i -lt $shown; $i++) {
        $mark = if ($i -eq $active) { "->" } else { "  " }
        Write-Info ("  " + $mark + " " + ($i + 1) + ". " + $pool[$i])
    }
    if ($pool.Count -gt $shown) { Write-Info ("  .. " + ($pool.Count - $shown) + " more, use: proxy stats") }
    if ($cache -and $cache.proxies) { Write-Info ("list cache: " + @($cache.proxies).Count + " from " + $cache.source) }
    if ($cfg.proxyListUrl) { Write-Info ("list url  : " + $cfg.proxyListUrl) }
}

function Show-ProxyStats($cfg) {
    $report = Get-ProxyHealthReport $cfg
    if (-not $report) {
        Write-Info "pool: empty"
        Write-Info "opencode-unlimited proxy pool fetch"
        return
    }
    Write-Info ("pool    : " + $report.total + " entries, " + $report.usable + " usable, " + $report.held + " parked")
    $index = 0
    foreach ($row in @($report.detail | Select-Object -First 40)) {
        $index++
        $state = if ($row.quarantined) { "park" } elseif ($row.ms -gt $script:SlowProxyMs) { "slow" } elseif ($row.ms -gt 0) { "ok  " } else { "new " }
        $msText = if ($row.ms -gt 0) { ([string]$row.ms).PadLeft(5) + " ms" } else { "    ---" }
        $failText = ([string]$row.fail).PadLeft(2)
        Write-Info ("  " + ([string]$index).PadLeft(2) + ". " + $state + " " + $msText + "  fail=" + $failText + "  " + $row.url)
    }
}

function Test-ProxyBatch($cfg, [int]$Top) {
    $pool = @(Get-RankedProxyPool $cfg)
    if (-not $pool.Count) {
        Write-Bad "pool is empty, run: opencode-unlimited proxy pool fetch"
        return
    }
    if ($Top -le 0) { $Top = 20 }
    $limit = [Math]::Min($pool.Count, $Top)
    Write-Info ("probing " + $limit + " of " + $pool.Count + " proxies, 6s each")
    $usable = 0
    for ($i = 0; $i -lt $limit; $i++) {
        $url = $pool[$i]
        $trace = Get-EgressTrace $url -Force -TimeoutSec 6 -NoFallback
        $ms = [int]$trace.Ms
        if ($trace.Ip) {
            Set-ProxyHealth $url $true $ms ""
            $mark = if ($ms -gt $script:SlowProxyMs) { "slow" } else { "ok  " }
            if ($ms -le $script:SlowProxyMs) { $usable++ }
            Write-Info ("  " + $mark + " " + ([string]$ms).PadLeft(5) + " ms  " + $trace.Ip.PadRight(15) + " " + $trace.Country.PadRight(2) + "  " + $url)
        } else {
            Set-ProxyHealth $url $false 0 "timeout"
            Write-Info ("  dead     ---  " + $url)
        }
    }
    Write-Step ""
    if ($usable -gt 0) { Write-Ok ($usable + " usable of " + $limit + " probed") }
    else { Write-Bad ("0 usable of " + $limit + " probed") }
}

function Cmd-Plugin {
    $sub = if ($Rest.Count -ge 1) { [string]$Rest[0] } else { "status" }
    switch ($sub.ToLowerInvariant()) {
        "install" {
            Write-Step "==> installing the shield plugin"
            if (Install-Plugin) {
                Set-PluginEnabled $true
                Write-Info "opencode reloads config on save, the plugin appears at the next request"
                Write-Info "check it with: opencode-unlimited plugin status"
            }
        }
        "off" {
            Set-PluginEnabled $false
            Remove-Item $script:PluginMarker -Force -ErrorAction SilentlyContinue
            Write-Ok "plugin unlisted from opencode config and parked on disk"
        }
        "verify" {
            Restart-Service
            Start-Sleep -Milliseconds 1500
            $live = Test-PluginLive
            if ($live) { Write-Ok ("loaded, hooks " + (@($live.hooks) -join ", ")) }
            else { Write-Warn2 "not reported by the server yet, open the app once and check again" }
        }
        default {
            Write-Step "==> shield plugin"
            Write-Info ("state  : " + (Get-PluginState))
            Write-Info ("path   : " + $script:PluginFile)
            Write-Info ("config : " + $(if (Test-PluginRegistered) { $script:PluginEntry + " listed" } else { "not listed" }))
            $live = Test-PluginLive
            if ($live) {
                Write-Ok ("live   : opencode " + $live.version + ", hooks " + (@($live.hooks) -join ", "))
                Write-Info "it stamps the virtual project id and session affinity on every model request"
            } else {
                Write-Info "live   : not reported yet"
            }
        }
    }
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
        "next" {
            $trace = Invoke-EgressRotation $cfg ""
            Save-Config $cfg
            if ($trace) { Write-Ok ("egress: " + $trace.Ip + " " + $trace.Country) }
            else { Write-Warn2 "no new route, see the notes above" }
        }
        "pool" {
            $action = if ($Rest.Count -ge 2) { $Rest[1] } else { "show" }
            switch ($action) {
                "add" {
                    $urls = @($Rest | Select-Object -Skip 2)
                    if (-not $urls.Count) { Write-Bad "expected one or more proxy urls"; return }
                    $pool = @(Get-ProxyPool $cfg)
                    $added = 0
                    foreach ($url in $urls) {
                        if ($url -notmatch "^(socks5h?|http|https)://") { Write-Bad ("skipped, not a proxy url: " + $url); continue }
                        if ($pool -contains $url) { Write-Info ("already in the pool: " + $url); continue }
                        $pool += $url
                        $added++
                    }
                    $cfg.proxyPool = $pool
                    Save-Config $cfg
                    Write-Ok ("pool size: " + $pool.Count + " (+" + $added + ")")
                    Show-ProxyPool $cfg
                }
                "set" {
                    $urls = @($Rest | Select-Object -Skip 2 | Where-Object { $_ -match "^(socks5h?|http|https)://" })
                    if (-not $urls.Count) { Write-Bad "expected one or more proxy urls"; return }
                    $cfg.proxyPool = $urls
                    $cfg.proxyIndex = 0
                    Save-Config $cfg
                    Write-Ok ("pool replaced, " + $urls.Count + " entries")
                    Show-ProxyPool $cfg
                }
                "clear" {
                    $cfg.proxyPool = @()
                    $cfg.proxyIndex = 0
                    $cfg.proxyListUrl = ""
                    Remove-Item $script:PoolCacheFile -Force -ErrorAction SilentlyContinue
                    Save-Config $cfg
                    Write-Ok "pool cleared, the current upstream was left alone"
                }
                "fetch" {
                    $url = if ($Rest.Count -ge 3) { $Rest[2] } else { "" }
                    if ($url -and $url -notmatch "^https?://") { Write-Bad "expected an http(s) list url"; return }
                    $cfg.proxyListUrl = $url
                    Save-Config $cfg
                    $count = Update-ProxyList $cfg -Force
                    if ($count -gt 0) { Write-Ok ("list cache: " + $count + " proxies") }
                    Show-ProxyPool $cfg
                }
                "refresh" {
                    if (-not $cfg.proxyListUrl) { Write-Bad "no list url yet, run: proxy pool fetch <url>"; return }
                    $count = Update-ProxyList $cfg -Force
                    if ($count -gt 0) { Write-Ok ("list cache refreshed: " + $count) }
                    Show-ProxyPool $cfg
                }
                default {
                    Show-ProxyPool $cfg
                }
            }
        }
        "status" {
            $trace = Get-EgressTrace $cfg.proxy
            $ipText = if ($trace.Ip) { $trace.Ip } else { "unknown" }
            if ($trace.Country) { $ipText = $ipText + "  " + $trace.Country }
            Write-Info ("upstream : " + $(if ($cfg.proxy) { $cfg.proxy } else { "none (manual)" }))
            Write-Info ("bridge   : 127.0.0.1:" + $cfg.bridgePort)
            Write-Info ("ip       : " + $ipText)
            Show-ProxyPool $cfg
        }
        "stats" { Show-ProxyStats $cfg }
        "test" { Test-ProxyBatch $cfg (Get-RestInt @("-Top", "--top", "-n") 20) }
        "healthreset" {
            Invoke-ProxyHealth "reset" | Out-Null
            Write-Ok "proxy health cleared, every entry is a clean slate again"
        }
        default {
            $url = if ($sub -eq "set" -and $Rest.Count -ge 2) { $Rest[1] } else { $Rest[0] }
            if ($url -notmatch "^(socks5h?|http|https)://") {
                Write-Bad "expected socks5://host:port or http://host:port"
                return
            }
            $cfg.proxy = $url
            $cfg.ipMode = "proxy"
            if (-not (Apply-Proxy $cfg)) {
                $cfg.proxy = ""
                $cfg.ipMode = "manual"
                Save-Config $cfg
                Write-Info "state left on manual, nothing was restarted"
                return
            }
            Save-Config $cfg
            Restart-Service
            Start-Sleep -Seconds 1
            $trace = Get-EgressTrace $cfg.proxy -Force
            $ipText = if ($trace.Ip) { $trace.Ip } else { "unknown" }
            if ($trace.Country) { $ipText = $ipText + "  " + $trace.Country }
            Write-Info ("egress via proxy: " + $ipText)
        }
    }
}

function Invoke-WarpRotate($cfg) {
    $warp = Get-WarpCli
    if (-not $warp) { return $null }
    & $warp disconnect 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $warp connect 2>$null | Out-Null
    Start-Sleep -Seconds 4
    return Get-EgressTrace $cfg.proxy -Force
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
            Write-Info "reconnecting warp, this can change the egress ip"
            $before = Get-EgressTrace $cfg.proxy -Force
            $after = Invoke-WarpRotate $cfg
            if (-not (Test-RouteOk $after "warp")) {
                Write-Bad ("warp is not carrying the route (warp=" + $after.Warp + ")")
                Write-Info "check: warp-cli status"
                return
            }
            if ($before.Ip -and (Test-SameBlock $after.Ip $before.Ip)) {
                Write-Warn2 ("same egress block: " + $after.Ip + " " + $after.Country)
                Write-Info "warp does not guarantee a new ip, reconnect again or use a proxy pool"
            } else {
                Write-Ok ("new egress block: " + $before.Ip + " -> " + $after.Ip + " " + $after.Country)
            }
        }
        default {
            & $warp status 2>&1 | ForEach-Object { Write-Info $_ }
        }
    }
}

function Cmd-Run {
    if ($Rest.Count -eq 0) { Write-Bad "usage: opencode-unlimited run <opencode args>"; return }
    $oc = Resolve-OpenCode
    $attempt = 1
    while ($attempt -le 3) {
        $out = & $oc @Rest 2>&1 | Out-String
        $code = $LASTEXITCODE
        if (Test-LimitOutput $out) {
            Write-Warn2 ("free limit hit (attempt " + $attempt + "/3)")
            Add-EgressRecord 429 0 | Out-Null
            $idHelper = Join-Path $script:Root "lib\identity.js"
            if (Test-Path $idHelper) { Invoke-NodeHelper $idHelper @("rotate") | Out-Null }
            $cfg = Get-Config
            if ($cfg.proxy) { Apply-Proxy $cfg; Restart-Service }
            Start-Sleep -Seconds 2
            $attempt++
            continue
        }
        Write-Host $out
        return $code
    }
    Write-Bad "still limited after 3 attempts"
    Write-Info "the meter follows the egress block, change the connection and run: opencode-unlimited usage"
    return 1
}

function Cmd-Doctor {
    Write-Step "==> opencode-unlimited doctor"
    Write-Step ""
    $os = [System.Environment]::OSVersion.Version
    Write-Info ("windows    : " + $os.Major + "." + $os.Minor + " build " + $os.Build)
    Write-Info ("powershell : " + $PSVersionTable.PSVersion.ToString())
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $nv = (& $node.Source --version 2>$null)
        Write-Ok ("node       : " + $nv)
        if (Test-NodeSqlite) { Write-Ok "sqlite     : node:sqlite available" } else { Write-Warn2 "sqlite     : needs node 22.5+ for -Db features" }
    } else {
        Write-Warn2 "node       : not found (proxy bridge and -Db need it)"
    }
    if (Get-Curl) { Write-Ok "curl       : found" } else { Write-Warn2 "curl       : missing, using .NET fallback" }
    Write-Info ("tool       : " + $PSCommandPath)
    $stale = Get-StaleInstalls
    if ($stale) {
        Write-Warn2 ("stale copy : " + ($stale -join ", "))
        Write-Info "this is why an old version can answer instead of this one"
        Write-Info "fix: opencode-unlimited install"
    } else {
        Write-Ok "stale copy : none"
    }
    $ocInfo = Get-OpenCodeInfo
    Write-Info ("opencode   : " + $ocInfo.exe)
    if ($ocInfo.version) {
        Write-Ok ("version    : v" + $ocInfo.version + $(if ($ocInfo.api) { " (api v" + $ocInfo.api + ")" } else { "" }))
    } else {
        Write-Warn2 "version    : not detected, is opencode on PATH?"
    }
    if ($ocInfo.running) {
        Write-Ok "service    : running"
    } else {
        Write-Warn2 "service    : not reachable, start opencode once"
    }
    Write-Info ("gateway    : " + $ocInfo.gateway)
    Write-Info ("database   : " + $(if ($ocInfo.dbPath) { $ocInfo.dbPath } else { "not found" }))
    Write-Info ("session t. : " + $(if ($ocInfo.sessionTable) { $ocInfo.sessionTable } else { "unknown" }))
    $pluginApi = & $ocInfo.exe api get /api/plugin 2>$null | Out-String
    if ($pluginApi -match '"id":"unlimited-shield"') {
        if ($pluginApi -match '"id":"unlimited-shield".{0,200}?"status":"active"') { Write-Ok "plugin     : loaded and active" } else { Write-Warn2 "plugin     : loaded but not active" }
    } else {
        Write-Warn2 "plugin     : not loaded (optional, it does not change the quota)"
    }
    $vid = Get-VirtualIdentity
    if ($vid -and $vid.exists) { Write-Ok ("identity   : " + $vid.deviceId) } else { Write-Warn2 "identity   : missing, run: opencode-unlimited identity rotate" }
    $cfg = Get-Config
    Write-Info ("upstream   : " + $(if ($cfg.proxy) { $cfg.proxy } else { "none (manual)" }))
    $trace = Get-EgressTrace $cfg.proxy
    Write-Info ("egress ip  : " + $(if ($trace.Ip) { $trace.Ip + $(if ($trace.Country) { "  " + $trace.Country } else { "" }) } else { "unknown" }))
    $logHelper = Join-Path $script:Root "lib\log-watch.js"
    if (Test-Path $logHelper) {
        $raw = Invoke-NodeHelper $logHelper @("path")
        try { $logInfo = $raw | ConvertFrom-Json } catch { $logInfo = $null }
        if ($logInfo -and $logInfo.file) { Write-Info ("log        : " + $logInfo.file) } else { Write-Warn2 "log        : not found yet" }
    } else {
        Write-Warn2 "log helper : missing"
    }
    if (Test-Path $script:AuthDir) {
        if (Test-Path $script:AuthSnapshot) { Write-Ok "token      : live, snapshot present" }
        else { Write-Info "token      : live, no snapshot (opencode-unlimited token save)" }
    } else {
        Write-Warn2 "token      : auth.json missing"
    }
}

function Cmd-Uninstall {
    Write-Step "==> uninstalling opencode-unlimited"
    Stop-Bridge
    Set-PluginEnabled $false
    Remove-Item $script:PluginFile -Force -ErrorAction SilentlyContinue
    Remove-Item ($script:PluginFile + ".off") -Force -ErrorAction SilentlyContinue
    Remove-Item $script:PluginFolder -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:PluginMarker -Force -ErrorAction SilentlyContinue
    Write-Ok "plugin removed"

    $cfgPath = Join-Path $script:ConfigDir "opencode.jsonc"
    if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $script:ConfigDir "opencode.json" }
    if (Test-Path $cfgPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($cfgPath) -replace "^\uFEFF", ""
            $cfg = $raw | ConvertFrom-Json
            $prop = $cfg.PSObject.Properties["commands"]
            if ($prop -and $prop.Value) {
                foreach ($name in @($prop.Value.PSObject.Properties.Name)) {
                    if ($name -like "opencode-unlimited*") { $prop.Value.PSObject.Properties.Remove($name) }
                }
                [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
                Write-Ok "slash commands removed"
            }
        } catch {
            Write-Warn2 "config not touched, edit it by hand: $cfgPath"
        }
    }

    Set-ServiceEnv "HTTPS_PROXY" ""
    Set-ServiceEnv "HTTP_PROXY" ""
    Set-ServiceEnv "ALL_PROXY" ""
    Write-Ok "service proxy cleared"
    Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
    Remove-Item $script:InfoFile -Force -ErrorAction SilentlyContinue
    Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item $script:LogFile -Force -ErrorAction SilentlyContinue
    Write-Ok "state files removed"
    Write-Info ("repo and PATH entry kept, delete manually if you want: " + $script:Root)
}

function Cmd-Version {
    $info = Get-OpenCodeInfo
    Write-Step ("opencode-unlimited " + $script:ToolVersion)
    Write-Info ("opencode   : " + $(if ($info.version) { "v" + $info.version } else { "not detected" }))
    Write-Info ("api        : " + $(if ($info.api) { "v" + $info.api } else { "unknown" }))
    Write-Info ("session t. : " + $(if ($info.sessionTable) { $info.sessionTable } else { "unknown" }))
    Write-Info ("gateway    : " + $info.gateway)
}

function Cmd-Help {
    Write-Step "opencode-unlimited <command>"
    Write-Step ""
    Write-Info "reset [path]         new device id, new session ids, clear errors"
    Write-Info "reset [path] -Dry    show what the session re-id would touch"
    Write-Info "identity [rotate]    show or rotate the virtual device identity"
    Write-Info "identity restore     drop the virtual identity, registry never touched"
    Write-Info "block                egress blocks seen today, and which are spent"
    Write-Info "block check          is the address you are on now still usable"
    Write-Info "usage                free check of the meter and the reset clock"
    Write-Info "watch [-follow]      read the opencode log, zero messages spent"
    Write-Info "watch -follow -auto  rotate the moment a limit line lands"
    Write-Info "hunt                 rotate until the probe says the route is open"
    Write-Info "hunt -Country XX -Prefix a.b.c.   steer the search"
    Write-Info "hunt -NoProbe        rotate without spending a probe message"
    Write-Info "token [save|restore] keep a local copy of auth.json"
    Write-Info "sessions [path]      list sessions and their ids for a folder"
    Write-Info "model                list providers and free models you can switch to"
    Write-Info "model <spec>         switch this folder to provider/model[#variant]"
    Write-Info "model <path> <spec>  switch a session id or a whole folder"
    Write-Info "reid <id|path>       mint fresh session ids, keep every message"
    Write-Info "clear [path]         strip stored free-limit errors"
    Write-Info "verify [-fix]        check sessions decode, no dangling state"
    Write-Info ""
    Write-Info "install              register PATH, install the slash command"
    Write-Info "status               runtime, identity, network, bucket"
    Write-Info "doctor               check node, service, schema, identity"
    Write-Info "version              tool version plus the detected opencode version"
    Write-Info "on | off             full auto: identity, pool, route, watcher, autostart"
    Write-Info "on -KeepId -NoProbe  keep the identity, skip the probe message"
    Write-Info "proxy set <url>      route opencode through socks5:// or http://"
    Write-Info "proxy off            drop the upstream, direct egress"
    Write-Info "proxy status         show the current upstream and the pool"
    Write-Info "proxy stats          per-proxy health, speed and quarantine"
    Write-Info "proxy test [-Top 20] probe the pool and park the dead ones"
    Write-Info "proxy pool add <url> queue proxies for reset to cycle through"
    Write-Info "proxy pool fetch [u] pull a free proxy list into the pool"
    Write-Info "proxy pool refresh   refetch the list now"
    Write-Info "proxy pool clear     empty the pool, upstream left as is"
    Write-Info "proxy next           jump to the next pooled proxy now"
    Write-Info "plugin               is the shield loaded, and where it lives"
    Write-Info "plugin install|off   list or unlist the shield in the opencode config"
    Write-Info "warp on|off|rotate   Cloudflare WARP path (optional)"
    Write-Info "run <args...>        run opencode, rotate on free-limit"
    Write-Info "uninstall            remove plugin, slash commands, state"
}

switch ($Command.ToLowerInvariant()) {
    "install" { Cmd-Install }
    "reset" { Cmd-Reset }
    "clear" { Cmd-Clear }
    "verify" { Cmd-Verify }
    "identity" { Cmd-Identity }
    "block" { Cmd-Block }
    "usage" { Cmd-Usage }
    "watch" { Cmd-Watch }
    "hunt" { Cmd-Hunt }
    "token" { Cmd-Token }
    "status" { Cmd-Status }
    "sessions" { Cmd-Sessions }
    "model" { Cmd-Model }
    "reid" { Cmd-Reid }
    "version" { Cmd-Version }
    "-v" { Cmd-Version }
    "--version" { Cmd-Version }
    "on" { Cmd-On }
    "off" { Cmd-Off }
    "proxy" { Cmd-Proxy }
    "plugin" { Cmd-Plugin }
    "warp" { Cmd-Warp }
    "run" { Cmd-Run }
    "doctor" { Cmd-Doctor }
    "uninstall" { Cmd-Uninstall }
    default { Cmd-Help }
}
