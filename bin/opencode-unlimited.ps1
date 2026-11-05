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
$script:PluginFile = Join-Path $script:PluginDir "unlimited-shield.js"
$script:PidFile = Join-Path $script:ConfigDir "unlimited-bridge.pid"
$script:LogFile = Join-Path $script:ConfigDir "unlimited-bridge.log"
$script:IpCacheFile = Join-Path $script:ConfigDir "unlimited-ip.json"
$script:Gateway = "https://opencode.ai/inference/openai/v1/chat/completions"
$script:TraceUrl = "https://cloudflare.com/cdn-cgi/trace"
$script:DefaultModel = "deepseek-v4.1-flash-free"
$script:DefaultBridgePort = 8899
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

function Get-EgressIp([string]$ProxyUrl, [switch]$Force) {
    $cache = Get-Json $script:IpCacheFile
    if (-not $Force -and $cache -and $cache.ip -and $cache.ip -ne "unavailable") {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$cache.at
        if ($age -ge 0 -and $age -lt 60 -and [string]$cache.via -eq $ProxyUrl) { return $cache.ip }
    }
    $ip = "unavailable"
    $curl = Get-Curl
    if ($curl) {
        $curlArgs = @("-s", "--max-time", "8")
        if ($ProxyUrl) { $curlArgs += @("--proxy", $ProxyUrl) }
        $curlArgs += $script:TraceUrl
        $out = Invoke-Curl $curlArgs
        if ($out) {
            foreach ($line in ($out -split "`n")) {
                if ($line -match "^ip=(.+)$") { $ip = $Matches[1].Trim() }
            }
        }
    }
    if ($ip -eq "unavailable") {
        $result = Invoke-WebRequestRaw "GET" $script:TraceUrl $null $ProxyUrl
        if ($result.Status -eq 200) {
            foreach ($line in ($result.Body -split "`n")) {
                if ($line -match "^ip=(.+)$") { $ip = $Matches[1].Trim() }
            }
        }
    }
    if ($ip -ne "unavailable") {
        $entry = [ordered]@{
            ip  = $ip
            at  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            via = $ProxyUrl
        }
        Write-TextFile $script:IpCacheFile ($entry | ConvertTo-Json -Depth 3)
    }
    return $ip
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
        "opencode-unlimited:clear"    = @{ Args = "clear"; Desc = "strip stored free-limit errors from sessions" }
        "opencode-unlimited:reid"     = @{ Args = "reid"; Desc = "mint fresh session ids, keep every message" }
        "opencode-unlimited:model"    = @{ Args = "model"; Desc = "list providers and switch this folder to a free model" }
    }
    $argNames = @("opencode-unlimited:reset", "opencode-unlimited:clear", "opencode-unlimited:reid", "opencode-unlimited:model")

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

function Test-Upstream([string]$ProxyUrl) {
    $curl = Get-Curl
    if (-not $curl) { return $true }
    $out = Invoke-Curl @("-s", "--max-time", "10", "--proxy", $ProxyUrl, $script:TraceUrl)
    if ($out -and $out -match "ip=") { return $true }
    return $false
}

function Get-ProxyPool($cfg) {
    $pool = @()
    if ($cfg.proxyPool) {
        foreach ($entry in @($cfg.proxyPool)) {
            $url = [string]$entry
            if ($url -and $url -match "^(socks5h?|http|https)://") { $pool += $url }
        }
    }
    return $pool
}

function Invoke-EgressRotation($cfg, [string]$AvoidIp, [switch]$Dry) {
    $pool = @(Get-ProxyPool $cfg)
    if (-not $pool.Count) {
        if ($cfg.proxy) {
            if ($Dry) { Write-Info ("would apply: " + $cfg.proxy); return }
            if (Apply-Proxy $cfg) { Restart-Service }
            return
        }
        Write-Info "manual mode, no proxy configured"
        Write-Info "change the network yourself, or load a pool: opencode-unlimited proxy pool add socks5://host:port"
        return
    }
    if ($Dry) {
        $next = $pool[(([int]$cfg.proxyIndex + 1) % $pool.Count)]
        Write-Info ("would rotate to: " + $next + " (" + $pool.Count + " in the pool)")
        return
    }
    $tries = [Math]::Min($pool.Count, 8)
    for ($attempt = 0; $attempt -lt $tries; $attempt++) {
        $cfg.proxyIndex = (([int]$cfg.proxyIndex + 1) % $pool.Count)
        $url = $pool[$cfg.proxyIndex]
        Write-Info ("trying proxy " + ($cfg.proxyIndex + 1) + "/" + $pool.Count + ": " + $url)
        $cfg.proxy = $url
        $cfg.ipMode = "proxy"
        Save-Config $cfg
        if (-not (Apply-Proxy $cfg)) { continue }
        Restart-Service
        Start-Sleep -Seconds 1
        $ip = Get-EgressIp $url -Force
        if (-not $ip) { Write-Warn2 "egress ip unknown through this proxy, next"; continue }
        if ($AvoidIp -and $ip -eq $AvoidIp) { Write-Warn2 ("same egress ip: " + $ip + ", next"); continue }
        Write-Ok ("egress via " + $url + " -> " + $ip)
        return
    }
    Write-Warn2 "no proxy in the pool produced a new egress ip"
}

function Apply-Proxy($cfg) {
    if (-not $cfg.proxy) {
        Set-ServiceEnv "HTTPS_PROXY" ""
        Set-ServiceEnv "HTTP_PROXY" ""
        Set-ServiceEnv "ALL_PROXY" ""
        Set-ServiceEnv "NO_PROXY" "localhost,127.0.0.1"
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
    if (-not (Test-Upstream $url)) {
        Write-Bad ("upstream not answering: " + $cfg.proxy)
        Write-Info "opencode was not switched, fix the proxy and retry"
        if ($viaBridge) { Stop-Bridge }
        return $false
    }
    Write-Ok "upstream reachable"
    Set-ServiceEnv "HTTPS_PROXY" $url
    Set-ServiceEnv "HTTP_PROXY" $url
    Set-ServiceEnv "ALL_PROXY" $url
    Set-ServiceEnv "NO_PROXY" "localhost,127.0.0.1"
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
        Write-Warn2 "an old header plugin is still present"
        Write-Info "remove it with: opencode-unlimited off"
    } else {
        Write-Ok "header plugin not installed (it does not change the quota)"
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
    Write-Info "if a new prompt still fails, your egress ip is still on the spent bucket"
}

function Cmd-Reset {
    $dry = $Rest -contains "-Dry" -or $Rest -contains "--dry"
    $keepIds = $Rest -contains "-KeepIds" -or $Rest -contains "--keep-ids"
    Write-Step $(if ($dry) { "==> reset (dry run, nothing is written)" } else { "==> reset" })
    $cfg = Get-Config
    $target = Get-PathArg
    $ipBefore = Get-EgressIp $cfg.proxy -Force
    Write-Info ("egress ip before: " + $(if ($ipBefore) { $ipBefore } else { "unknown" }))

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
    Invoke-EgressRotation $cfg $ipBefore -Dry:$dry

    Write-Step ""
    Write-Step "[5/6] egress block"
    Start-Sleep -Seconds 1
    $ipAfter = Get-EgressIp $cfg.proxy -Force
    if ($dry) {
        Write-Info ("ip now: " + $(if ($ipAfter) { $ipAfter } else { "unknown" }) + ", nothing recorded")
    } else {
        $cfg.lastIp = $ipAfter
        Save-Config $cfg
        $egressHelper = Join-Path $script:Root "lib\egress.js"
        if ((Test-Path $egressHelper) -and $ipAfter) {
            $env:UNLIMITED_EGRESS_IP = $ipAfter
            Invoke-NodeHelper $egressHelper @("record", "0", "0") | Out-Null
            Remove-Item Env:\UNLIMITED_EGRESS_IP -ErrorAction SilentlyContinue
        }
        if (-not $ipAfter) {
            Write-Warn2 "egress ip unknown"
        } elseif ($ipAfter -eq $ipBefore) {
            Write-Warn2 ("ip unchanged: " + $ipAfter)
            Write-Info "the meter follows the egress block, not the project, the session or the device"
            Write-Info "if a refusal was logged today, this block stays spent until 00:00 UTC"
            Write-Info "change the connection, or switch model to leave the meter behind"
        } else {
            Write-Ok ("new egress ip: " + $ipAfter)
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

function Invoke-AppProbe([string]$Directory) {
    $oc = Get-OpenCodeExe
    if (-not $oc -or -not (Test-Path $oc)) {
        return [pscustomobject]@{ Ok = $false; Blocked = $false; Reason = "opencode binary not found"; Raw = ""; Model = "" }
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
        $out = (& $oc run -m $model "reply with exactly: ok" 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $previous
        if ($throwaway) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-LimitOutput $out) {
        return [pscustomobject]@{ Ok = $false; Blocked = $true; Reason = "app refused on free limit"; Raw = $out; Model = $model }
    }
    if ($code -eq 0 -and $out -match "\bok\b") {
        return [pscustomobject]@{ Ok = $true; Blocked = $false; Reason = "app answered"; Raw = $out; Model = $model }
    }
    return [pscustomobject]@{ Ok = $false; Blocked = $false; Reason = "app did not answer"; Raw = $out; Model = $model }
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

function Add-EgressRecord([int]$Status, [int]$RetryAfter) {
    $cfg = Get-Config
    $ip = Get-EgressIp $cfg.proxy -Force
    if (-not $ip) { return "" }
    $helper = Join-Path $script:Root "lib\egress.js"
    if (-not (Test-Path $helper)) { return $ip }
    $env:UNLIMITED_EGRESS_IP = $ip
    Invoke-NodeHelper $helper @("record", [string]$Status, [string]$RetryAfter) | Out-Null
    Remove-Item Env:\UNLIMITED_EGRESS_IP -ErrorAction SilentlyContinue
    return $ip
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
        Write-Info ($row.block.PadRight(24) + " " + $state + "  open=" + $row.open + " refused=" + $row.refused + "  last=" + $row.lastStatus)
    }
    $minutes = [math]::Floor($data.secondsToReset / 60)
    Write-Step ""
    Write-Info ("reset at 00:00 UTC, in " + $minutes + " minutes")
}

function Cmd-Usage {
    $cfg = Get-Config
    $deep = $Rest -contains "-check" -or $Rest -contains "--check" -or $Rest -contains "-live" -or $Rest -contains "--live"
    Write-Step "==> free tier check"
    $ip = Get-EgressIp $cfg.proxy -Force
    Write-Info ("egress ip : " + $(if ($ip) { $ip } else { "unknown" }))
    $cfg.lastIp = $ip
    Save-Config $cfg

    $helper = Join-Path $script:Root "lib\egress.js"
    $ledger = $null
    if (Test-Path $helper) {
        $raw = Invoke-NodeHelper $helper @("show")
        try { $ledger = $raw | ConvertFrom-Json } catch { $ledger = $null }
    }

    $row = $null
    if ($ledger -and $ip) {
        $want = if ($ip -like "*:*") { ($ip -split ":")[0..3] -join ":" } else { $ip }
        foreach ($item in @($ledger.blocks)) {
            if ($item.block -like ($want + "*")) { $row = $item; break }
        }
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
        Write-Info "this opens a throwaway session and spends one real message"
        $app = Invoke-AppProbe ""
        if ($app.Ok) {
            Add-EgressRecord 200 0 | Out-Null
            Write-Ok "OPEN - the app answered on this connection"
        } elseif ($app.Blocked) {
            Add-EgressRecord 429 0 | Out-Null
            Write-Bad "BLOCKED - the app itself was refused on this connection"
        } else {
            Write-Warn2 ("unconfirmed - " + $app.Reason)
        }
    }

    $midnight = [DateTime]::UtcNow.Date.AddDays(1)
    $wait = [math]::Floor(($midnight - [DateTime]::UtcNow).TotalMinutes)
    Write-Step ""
    Write-Info ("reset : " + $midnight.ToLocalTime().ToString("h:mm tt") + " local   in " + $wait + " minutes")
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

function Cmd-On {
    Install-Plugin
    Set-PluginEnabled $true
    Write-Ok "identity plugin enabled"
}

function Cmd-Off {
    Set-PluginEnabled $false
    Write-Ok "identity plugin disabled"
}

function Show-ProxyPool($cfg) {
    $pool = @(Get-ProxyPool $cfg)
    if (-not $pool.Count) {
        Write-Info "pool: empty"
        Write-Info "opencode-unlimited proxy pool add socks5://host:port"
        return
    }
    $active = [int]$cfg.proxyIndex
    Write-Info ("pool: " + $pool.Count + " entries, active #" + ($active + 1))
    for ($i = 0; $i -lt $pool.Count; $i++) {
        $mark = if ($i -eq $active) { "->" } else { "  " }
        Write-Info ("  " + $mark + " " + ($i + 1) + ". " + $pool[$i])
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
            Invoke-EgressRotation $cfg ""
            Save-Config $cfg
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
                    Save-Config $cfg
                    Write-Ok "pool cleared, the current upstream was left alone"
                }
                default {
                    Show-ProxyPool $cfg
                }
            }
        }
        "status" {
            Write-Info ("upstream : " + $(if ($cfg.proxy) { $cfg.proxy } else { "none (manual)" }))
            Write-Info ("bridge   : 127.0.0.1:" + $cfg.bridgePort)
            Write-Info ("ip       : " + (Get-EgressIp $cfg.proxy))
            Show-ProxyPool $cfg
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
            Write-Info "reconnecting warp, this can change the egress ip"
            $before = Get-EgressIp $cfg.proxy
            & $warp disconnect 2>$null | Out-Null
            Start-Sleep -Seconds 2
            & $warp connect 2>$null | Out-Null
            Start-Sleep -Seconds 4
            $after = Get-EgressIp $cfg.proxy
            if ($after -eq $before) {
                Write-Warn2 ("ip unchanged: " + $after)
                Write-Info "warp does not guarantee a new ip, reconnect again or use a proxy"
            } else {
                Write-Ok ("new egress ip: " + $before + " -> " + $after)
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
    Write-Info ("egress ip  : " + (Get-EgressIp $cfg.proxy))
}

function Cmd-Uninstall {
    Write-Step "==> uninstalling opencode-unlimited"
    Stop-Bridge
    Set-PluginEnabled $false
    Remove-Item $script:PluginFile -Force -ErrorAction SilentlyContinue
    Remove-Item ($script:PluginFile + ".disabled") -Force -ErrorAction SilentlyContinue
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
    Write-Info "on | off             enable or disable the identity plugin"
    Write-Info "proxy set <url>      route opencode through socks5:// or http://"
    Write-Info "proxy off            drop the upstream, direct egress"
    Write-Info "proxy status         show the current upstream and the pool"
    Write-Info "proxy pool add <url> queue proxies for reset to cycle through"
    Write-Info "proxy pool clear     empty the pool, upstream left as is"
    Write-Info "proxy next           jump to the next pooled proxy now"
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
    "warp" { Cmd-Warp }
    "run" { Cmd-Run }
    "doctor" { Cmd-Doctor }
    "uninstall" { Cmd-Uninstall }
    default { Cmd-Help }
}
