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
$script:IdentityFile = Join-Path $script:ConfigDir "identity.json"
$script:LegacyIdentity = Join-Path $script:UserHome ".opencode\identity.json"
$script:PluginDir = Join-Path $script:ConfigDir "plugins"
$script:PluginFile = Join-Path $script:PluginDir "unlimited-shield.js"
$script:PidFile = Join-Path $script:ConfigDir "unlimited-bridge.pid"
$script:LogFile = Join-Path $script:ConfigDir "unlimited-bridge.log"
$script:IpCacheFile = Join-Path $script:ConfigDir "unlimited-ip.json"
$script:Gateway = "https://opencode.ai/inference/openai/v1/chat/completions"
$script:TraceUrl = "https://cloudflare.com/cdn-cgi/trace"
$script:DefaultModel = "deepseek-v4.1-flash-free"
$script:DefaultBridgePort = 8899
$script:ToolVersion = "1.0.1"
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

function Get-GatewayUrl($info) {
    if ($info -and $info.gateway) { return [string]$info.gateway }
    return $script:Gateway
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

function Get-GatewayToken {
    $info = Get-OpenCodeInfo
    $dirs = @()
    if ($info -and $info.dataDir) { $dirs += $info.dataDir }
    $dirs += $script:DataDir
    foreach ($dir in $dirs) {
        $parsed = Get-Json (Join-Path $dir "auth.json")
        if (-not $parsed) { continue }
        $entry = $parsed.opencode
        if (-not $entry) { continue }
        if ($entry -is [string]) { if ($entry.Trim()) { return $entry.Trim() } continue }
        foreach ($field in @("key", "token", "access", "apiKey")) {
            $value = $entry.$field
            if ($value -is [string] -and $value.Trim()) { return $value.Trim() }
        }
    }
    return ""
}

function Invoke-QuotaProbe($cfg) {
    $token = Get-GatewayToken
    if (-not $token) {
        return New-ProbeResult 0 "no gateway token in auth.json; run opencode once and sign in" 0
    }

    $info = Get-OpenCodeInfo
    $org = Get-OrgId $cfg
    $model = Resolve-ProbeModel $cfg $info
    $gateway = Get-GatewayUrl $info
    $version = if ($info.version) { $info.version } else { "latest" }
    $payload = @{
        model      = $model
        messages   = @(@{ role = "user"; content = "1" })
        max_tokens = 1
        stream     = $false
    } | ConvertTo-Json -Depth 5 -Compress

    if (-not (Get-Curl)) {
        return New-ProbeResult 0 "curl not found on PATH" 0
    }

    $stamp = New-Hex 6
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unlimited-probe-" + $stamp + ".json")
    $hdr = Join-Path ([System.IO.Path]::GetTempPath()) ("unlimited-probe-" + $stamp + ".hdr")
    Write-TextFile $tmp $payload
    try {
        $curlArgs = @(
            "-s", "-o", "-", "-D", $hdr, "-w", "`n%{http_code}",
            "--max-time", "20",
            "-X", "POST", $gateway,
            "-H", "Content-Type: application/json",
            "-H", ("Authorization: Bearer " + $token),
            "-H", ("User-Agent: opencode/latest/" + $version + "/cli"),
            "-H", "x-opencode-client: cli"
        )
        if ($org) { $curlArgs += @("-H", ("x-opencode-org-id: " + $org)) }
        $curlArgs += @("--data-binary", ("@" + $tmp))

        $raw = Invoke-Curl $curlArgs
        $retry = 0
        if (Test-Path $hdr) {
            foreach ($line in (Get-Content $hdr -ErrorAction SilentlyContinue)) {
                if ($line -match "^\s*retry-after\s*:\s*(\d+)") { $retry = [int]$Matches[1] }
            }
        }
        if ($null -ne $raw) {
            $idx = $raw.LastIndexOf("`n")
            if ($idx -gt 0) {
                $body = $raw.Substring(0, $idx).Trim()
                $code = 0
                [void][int]::TryParse($raw.Substring($idx + 1).Trim(), [ref]$code)
                return New-ProbeResult $code $body $retry
            }
        }
        return New-ProbeResult 0 "probe produced no output" 0
    } finally {
        Remove-Item $tmp, $hdr -Force -ErrorAction SilentlyContinue
    }
}

function New-ProbeResult([int]$Code, [string]$Body, [int]$RetryAfter) {
    $state = "error"
    if ($Code -eq 429 -and $Body -match "FreeUsageLimitError") {
        $state = "spent"
    } elseif ($Code -ge 200 -and $Code -lt 300) {
        $state = "open"
    } elseif ($Code -gt 0) {
        $state = "other"
    }
    $resetAt = $null
    if ($RetryAfter -gt 0) {
        $resetAt = (Get-Date).ToUniversalTime().AddSeconds($RetryAfter)
    }
    return [pscustomobject]@{
        State      = $state
        Status     = $Code
        Body       = $Body
        RetryAfter = $RetryAfter
        ResetAt    = $resetAt
    }
}

function Get-BucketLabel($Probe) {
    if ($Probe.State -eq "open") {
        return "OPEN - this connection still has free messages left"
    }
    if ($Probe.State -eq "spent") {
        $text = "SPENT - this connection has no free messages left"
        if ($Probe.ResetAt) {
            $local = $Probe.ResetAt.ToLocalTime()
            $text += (" until " + $local.ToString("h:mm tt") + " " + $local.ToString("M/d/yyyy"))
        }
        return $text
    }
    if ($Probe.State -eq "other") {
        return ("HTTP " + $Probe.Status + " - " + $Probe.Body)
    }
    return "UNKNOWN - could not reach the gateway"
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

function Update-ProjectIds([string]$Directory) {
    $db = Get-DatabasePath
    if (-not $db) { Write-Warn2 "opencode.db not found at $script:DataDir"; return $false }
    if (-not (Test-NodeSqlite)) { Write-Warn2 "node 22.5+ required for database rotation, skipped"; return $false }
    $source = @'
const { DatabaseSync } = require("node:sqlite");
const { randomBytes } = require("node:crypto");
const fs = require("node:fs");

const norm = (value) => String(value || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
const db = new DatabaseSync(process.argv[2]);
const wantRaw = (process.argv[3] || "").trim();
const want = norm(wantRaw);

const known = db.prepare("select project_id, directory from project_directory").all();
const idsFor = (needle) => [...new Set(known.filter((row) => norm(row.directory) === needle).map((row) => row.project_id))];

let target = null;
let registered = false;

if (want) {
  let ids = idsFor(want);

  if (!ids.length) {
    ids = [...new Set(known.filter((row) => norm(row.directory).startsWith(want + "/")).map((row) => row.project_id))];
  }

  if (!ids.length && fs.existsSync(wantRaw)) {
    let cursor = want;
    while (cursor && cursor !== "/" && !ids.length) {
      ids = idsFor(cursor);
      if (ids.length) break;
      cursor = cursor.slice(0, cursor.lastIndexOf("/"));
    }
  }

  if (ids.length > 1) {
    console.log("ambiguous, " + ids.length + " projects match: " + wantRaw);
    for (const id of ids) {
      const row = known.find((r) => r.project_id === id);
      console.log("  " + (row ? row.directory : id));
    }
    process.exit(4);
  }

  if (ids.length === 1) {
    target = ids[0];
  } else if (!fs.existsSync(wantRaw)) {
    console.log("no project matches and the folder does not exist: " + wantRaw);
    const seen = new Set();
    for (const row of known) {
      const key = norm(row.directory);
      if (seen.has(key)) continue;
      seen.add(key);
      console.log("  " + row.directory);
    }
    process.exit(3);
  } else {
    const orphanRow = db.prepare("select project_id from session_v2 where lower(replace(directory, char(92), '/')) = ? limit 1").get(wantRaw.replace(/\\/g, "/").toLowerCase());
    if (orphanRow) {
      const now = Date.now();
      const worktree = wantRaw.replace(/\\/g, "/").replace(/\/+$/, "");
      db.exec("begin");
      db.prepare("insert or ignore into project (id, worktree, time_created, time_updated, sandboxes, time_active) values (?, ?, ?, ?, '[]', ?)").run(orphanRow.project_id, worktree, now, now, now);
      db.prepare("insert into project_directory (project_id, directory, time_created) values (?, ?, ?)").run(orphanRow.project_id, worktree, now);
      db.exec("commit");
      target = orphanRow.project_id;
    } else {
      const now = Date.now();
      const worktree = wantRaw.replace(/\\/g, "/").replace(/\/+$/, "");
      const fresh = randomBytes(20).toString("hex");
      db.exec("begin");
      db.prepare("insert into project (id, worktree, time_created, time_updated, sandboxes, time_active) values (?, ?, ?, ?, '[]', ?)").run(fresh, worktree, now, now, now);
      db.prepare("insert into project_directory (project_id, directory, time_created) values (?, ?, ?)").run(fresh, worktree, now);
      db.exec("commit");
      target = fresh;
      registered = true;
    }
  }
}

if (registered) {
  console.log("registered new project: " + target.slice(0, 12) + " -> " + wantRaw);
  process.exit(0);
}

const tables = db.prepare("select name from sqlite_master where type='table'").all();
const carriers = [];
for (const table of tables) {
  const columns = db.prepare("pragma table_info(" + table.name + ")").all().map((column) => column.name);
  if (columns.includes("project_id")) carriers.push(table.name);
}

const projects = target
  ? db.prepare("select id from project where id = ?").all(target)
  : db.prepare("select id from project where id != 'global'").all();

if (!projects.length) {
  console.log("project row missing: " + (target || "all"));
  process.exit(5);
}

db.exec("begin");
db.exec("pragma defer_foreign_keys = ON");
let renamed = 0;
let touched = 0;
for (const project of projects) {
  const next = randomBytes(20).toString("hex");
  db.prepare("update project set id = ? where id = ?").run(next, project.id);
  for (const table of carriers) {
    const key = table === "project" ? "id" : "project_id";
    const info = db.prepare("update " + table + " set " + key + " = ? where " + key + " = ?").run(next, project.id);
    touched += Number(info.changes || 0);
  }
  renamed += 1;
}
db.exec("commit");
console.log("projects rotated: " + renamed + ", rows updated: " + touched);
'@
    $out = Invoke-NodeScript $source @($db, $(if ($Directory) { ConvertTo-DbPath $Directory } else { "" }))
    $ok = $true
    if ($out) {
        $line = ($out -join " ").Trim()
        if ($line -match "no project matches|ambiguous|project row missing") { Write-Bad $line; $ok = $false }
        elseif ($line -match "registered new project") { Write-Ok $line }
        else { Write-Ok $line }
    }
    return $ok
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
        "opencode-unlimited"       = @{ Args = "status"; Desc = "OpenCode free-tier helper - project id, egress ip, bucket" }
        "opencode-unlimited:test"  = @{ Args = "test"; Desc = "check the free bucket on this IP (free)" }
        "opencode-unlimited:reset" = @{ Args = "reset"; Desc = "rotate a project (path optional), clear stuck limit errors" }
        "opencode-unlimited:clear" = @{ Args = "clear"; Desc = "strip stored free-limit errors from sessions" }
        "opencode-unlimited:id"    = @{ Args = "id"; Desc = "rotate a project id, pass a folder to pick which" }
    }
    $argNames = @("opencode-unlimited:reset", "opencode-unlimited:clear", "opencode-unlimited:id")

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

function Get-DbFlag {
    return ($Rest -contains "-Db" -or $Rest -contains "--db")
}

function Cmd-Id {
    Write-Step "==> rotating project identity"
    $cfg = Get-Config
    $target = Get-PathArg
    $before = Get-Identity
    $identity = New-Identity
    if ($target) {
        Write-Info ("target: " + $target)
        Update-ProjectIds $target | Out-Null
    } elseif ($cfg.rotateDb -or (Get-DbFlag)) {
        Update-ProjectIds | Out-Null
    } else {
        Write-Info "database rows untouched, use -Db or a path to rotate them"
    }
    if ($before) { Write-Info ("was " + $before.projectId) }
    Save-Config $cfg
    Write-Ok "identity rotated"
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

function Cmd-Repair {
    Write-Step "==> repairing project mappings"
    $db = Get-DatabasePath
    if (-not $db) { Write-Bad "opencode.db not found"; return }
    if (-not (Test-NodeSqlite)) { Write-Bad "node 22.5+ required"; return }
    $source = @'
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(process.argv[2]);
const one = (sql, ...a) => db.prepare(sql).get(...a);
const norm = (v) => String(v || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

const projectDirs = db.prepare("select project_id, directory from project_directory").all();
const sessionDirs = db.prepare("select project_id, directory, count(*) c from session_v2 group by project_id, directory").all();

const byDir = new Map();
for (const row of sessionDirs) {
  const key = norm(row.directory);
  if (!key) continue;
  const entry = byDir.get(key) || { owners: new Map(), directory: norm(row.directory) };
  entry.owners.set(row.project_id, (entry.owners.get(row.project_id) || 0) + row.c);
  byDir.set(key, entry);
}

let merged = 0;
let relinked = 0;
db.exec("begin");
db.exec("pragma defer_foreign_keys = ON");

for (const [key, entry] of byDir) {
  const owners = [...entry.owners.entries()].filter(([id]) => id !== "global").sort((a, b) => b[1] - a[1]);
  if (!owners.length) continue;
  const keep = owners[0][0];
  const linked = projectDirs.filter((row) => norm(row.directory) === key);
  const linkedIds = new Set(linked.map((row) => row.project_id));

  if (!linkedIds.has(keep)) {
    db.prepare("delete from project_directory where lower(replace(directory, char(92), '/')) = ?").run(key);
    db.prepare("insert into project_directory (project_id, directory, time_created) values (?, ?, ?)").run(keep, entry.directory, Date.now());
    relinked += 1;
  }

  for (const [other] of owners.slice(1)) {
    if (other === keep) continue;
    const count = one("select count(*) c from session_v2 where project_id = ?", other).c;
    if (count) continue;
    if (one("select count(*) c from project where id = ?", other).c === 0) continue;
    db.prepare("update project_directory set project_id = ? where project_id = ?").run(keep, other);
    db.prepare("update worktree set project_id = ? where project_id = ?").run(keep, other);
    db.prepare("delete from project where id = ?").run(other);
    merged += 1;
  }
}

const loose = db.prepare("select id from project where id != 'global' and id not in (select project_id from project_directory) and id not in (select project_id from session_v2)").all();
for (const row of loose) {
  db.prepare("delete from project where id = ?").run(row.id);
  merged += 1;
}

db.exec("commit");
const orphans = one("select count(*) c from session_v2 where project_id not in (select id from project)").c;
const dupes = db.prepare("select lower(directory) d, count(*) c from project_directory group by d having c > 1").all().length;
console.log("mappings fixed: " + (merged + relinked) + ", orphan sessions: " + orphans + ", duplicate directories: " + dupes);
'@
    $out = Invoke-NodeScript $source @($db)
    if ($out) { Write-Ok ($out -join " ") }
}

function Cmd-Reset {
    Write-Step "==> full reset"
    $cfg = Get-Config
    $target = Get-PathArg
    $ipBefore = Get-EgressIp $cfg.proxy -Force
    Write-Info ("egress ip before: " + $ipBefore)

    Write-Step "[1/4] rotating project identity"
    $identity = New-Identity
    if ($target) {
        Write-Info ("target: " + $target)
        Update-ProjectIds $target | Out-Null
    } elseif ($cfg.rotateDb -or (Get-DbFlag)) {
        Update-ProjectIds | Out-Null
    } else {
        Write-Info "database rows untouched, sessions stay on the old id"
    }
    Remove-StuckErrors $target
    Cmd-Verify -Fix

    Write-Step "[2/4] proxy path"
    if ($cfg.proxy) {
        Apply-Proxy $cfg
        Restart-Service
    } else {
        Write-Info "manual mode, no proxy configured"
    }

    Write-Step "[3/4] egress ip after"
    Start-Sleep -Seconds 1
    $ipAfter = Get-EgressIp $cfg.proxy -Force
    $cfg.lastIp = $ipAfter
    Save-Config $cfg
    if ($ipAfter -eq $ipBefore) {
        Write-Warn2 ("ip unchanged: " + $ipAfter)
    } else {
        Write-Ok ("new egress ip: " + $ipAfter)
    }

    Write-Step "[4/4] direct api probe"
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    Save-Config $cfg
    if ($probe.State -eq "open") {
        Write-Ok (Get-BucketLabel $probe)
    } else {
        Write-Warn2 (Get-BucketLabel $probe)
    }
    Write-Info "a prompt that works is the real signal, or: opencode-unlimited test -live"
    Write-Step ""
    Write-Ok "reset complete"
    Write-Info ("project id: " + $identity.projectId)
    Write-Info "if a new prompt still refuses: your egress ip is on the spent bucket"
    Write-Info "change the connection, then: opencode-unlimited clear"
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

function Cmd-Test {
    $cfg = Get-Config
    if ($Rest -contains "-live" -or $Rest -contains "--live") {
        $oc = Get-OpenCodeExe
        $info = Get-OpenCodeInfo
        $model = "opencode/" + (Resolve-ProbeModel $cfg $info)
        Write-Step "==> live check through the app (uses one message)"
        Write-Info ("model: " + $model)
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $out = (& $oc run -m $model "reply with: ok" 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
        if (Test-LimitOutput $out) {
            Write-Bad "EMPTY - the app itself is blocked on this connection"
            return
        }
        if ($code -eq 0 -and $out -match "\bok\b") {
            Write-Ok "WORKING - the app answered, keep prompting"
            return
        }
        Write-Warn2 "could not confirm, output:"
        Write-Info (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join " ")
        return
    }
    Write-Step "==> direct api probe (free, but not the app quota)"
    $ip = Get-EgressIp $cfg.proxy
    Write-Info ("egress ip: " + $ip)
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    $cfg.lastIp = $ip
    Save-Config $cfg
    if ($probe.State -eq "open") {
        Write-Ok (Get-BucketLabel $probe)
    } else {
        Write-Warn2 (Get-BucketLabel $probe)
    }
    Write-Info "the app leaves from the same address, a prompt that works means you are fine"
    Write-Info "real answer: opencode-unlimited test -live"
}

function Cmd-Usage {
    $cfg = Get-Config
    Write-Step "==> free tier check"
    $ip = Get-EgressIp $cfg.proxy -Force
    Write-Info ("egress ip : " + $(if ($ip) { $ip } else { "unknown" }))
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    $cfg.lastIp = $ip
    Save-Config $cfg
    if ($probe.State -eq "open") {
        Write-Ok (Get-BucketLabel $probe)
        Write-Info "a heavy session replays more tokens than a fresh one"
        Write-Info "if a big session refuses while a fresh one works, it is cost, not identity"
    } else {
        Write-Warn2 (Get-BucketLabel $probe)
        Write-Info "free tier is metered per source address, not per project"
        Write-Info "rotating the project id or session id does not refill it"
        Write-Info "change your egress ip, or wait for the reset above"
    }
}

function Cmd-Reid {
    Write-Step "==> minting a fresh session id"
    $db = Get-DatabasePath
    if (-not $db) { Write-Bad "opencode.db not found"; return }
    if (-not (Test-NodeSqlite)) { Write-Bad "node 22.5+ required"; return }
    $helper = Join-Path $script:Root "lib\session-reid.js"
    if (-not (Test-Path $helper)) { Write-Bad ("missing helper: " + $helper); return }

    $target = Get-PathArg
    if (-not $target) {
        Write-Bad "name a session id"
        Write-Info "opencode-unlimited reid ses_abc123..."
        Write-Info "opencode-unlimited sessions \"C:\path\to\project\" lists the ids"
        return
    }

    if ($target -notlike "ses_*") {
        Write-Bad "reid needs a session id, not a folder"
        Write-Info ("try: opencode-unlimited sessions `"" + $target + "`"")
        return
    }

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
    Write-Info ("rows   : " + $result.moved)
    foreach ($item in @($result.touched)) { if ($item) { Write-Info ("moved  : " + $item) } }
    Write-Info "open the new id in the app, the messages are all there"
    Write-Info "reid does not refill the quota, it only breaks a fork chain"
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
    foreach ($row in $rows) {
        $title = [string]$row.title
        if (-not $title) { $title = "(untitled)" }
        if ($title.Length -gt 42) { $title = $title.Substring(0, 42) }
        $when = ""
        if ($row.updated -gt 0) {
            $when = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$row.updated)).ToLocalTime().ToString("M/d HH:mm")
        }
        Write-Info ($row.id + "  " + $when.PadRight(12) + "  " + $title)
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
    Write-Step "direct api"
    $probe = Invoke-QuotaProbe $cfg
    $cfg.lastBucket = $probe.State
    $ip = Get-EgressIp $cfg.proxy
    $cfg.lastIp = $ip
    Save-Config $cfg
    if ($probe.State -eq "open") {
        Write-Ok (Get-BucketLabel $probe)
    } else {
        Write-Warn2 (Get-BucketLabel $probe)
    }
    Write-Info "app quota   : not measured here, see: opencode-unlimited test -live"
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
            Cmd-Id | Out-Null
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
    Write-Info "new id does not refill the quota, change the connection and run: opencode-unlimited test -live"
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
    $id = Get-Identity
    if ($id -and $id.projectId -match "^[0-9a-f]{40}$") { Write-Ok ("identity   : " + $id.projectId) } else { Write-Warn2 "identity   : missing or invalid, run: opencode-unlimited id" }
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
    Write-Info "usage                is the free tier open on this connection"
    Write-Info "sessions [path]      list sessions and their ids for a folder"
    Write-Info "reid <session-id>    mint a fresh session id, keep every message"
    Write-Info "version              tool version plus the detected opencode version"
    Write-Step ""
    Write-Info "install              register PATH, install the slash command"
    Write-Info "reset [path] [-Db]   rotate a project, clear stuck errors, verify"
    Write-Info "id [path] [-Db]      rotate the header id, or one project by folder"
    Write-Info "clear [path]         strip stored free-limit errors, no rotation"
    Write-Info "repair               re-link projects to the sessions they own"
    Write-Info "verify [-fix]        check sessions decode, no dangling state"
    Write-Info "test [-live]         direct probe (free) or a real app check (costs 1 message)"
    Write-Info "status               runtime, identity, network, bucket"
    Write-Info "on | off             enable or disable the identity plugin"
    Write-Info "proxy set <url>      route opencode through socks5:// or http://"
    Write-Info "proxy off            drop the upstream, direct egress"
    Write-Info "proxy status         show the current upstream"
    Write-Info "warp on|off|rotate   Cloudflare WARP path (optional)"
    Write-Info "run <args...>        run opencode, rotate on free-limit"
    Write-Info "doctor               check node, service, schema, identity"
    Write-Info "uninstall            remove plugin, slash commands, state"
}

switch ($Command.ToLowerInvariant()) {
    "install" { Cmd-Install }
    "reset" { Cmd-Reset }
    "clear" { Cmd-Clear }
    "repair" { Cmd-Repair }
    "verify" { Cmd-Verify }
    "id" { Cmd-Id }
    "test" { Cmd-Test }
    "usage" { Cmd-Usage }
    "status" { Cmd-Status }
    "sessions" { Cmd-Sessions }
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
