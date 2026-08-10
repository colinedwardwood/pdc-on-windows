#Requires -Version 5.1
<#
.SYNOPSIS
    Reports the health of the Grafana PDC agent service and its dependencies.

.DESCRIPTION
    A single command to answer "is PDC working, and if not, where is it stuck?".
    Checks the service state, outbound reachability of the PDC API and SSH gateway,
    the SSH transport in use, the signed certificate's expiry, the Prometheus metrics
    endpoint, and the tail of the agent log.

    Read-only: it changes nothing.

.PARAMETER Tail
    Number of log lines to show. Defaults to 20. Pass 0 to suppress the log section.

.EXAMPLE
    .\Get-PdcAgentStatus.ps1

.EXAMPLE
    .\Get-PdcAgentStatus.ps1 -Tail 100
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\GrafanaLabs\PDC",
    [string]$DataDir = "$env:ProgramData\GrafanaLabs\PDC",
    [string]$ServiceName = 'grafana-pdc-agent',
    [int]$Tail = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:Problems = @()

function Write-Section { param([string]$Title) Write-Host "`n$Title" -ForegroundColor Cyan }
function Write-Pass { param([string]$Message) Write-Host "  [ OK ] $Message" -ForegroundColor Green }
function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    $script:Problems += $Message
}
function Write-Warn2 { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-Detail { param([string]$Message) Write-Host "         $Message" -ForegroundColor DarkGray }

Write-Host "Grafana PDC agent status" -ForegroundColor White
Write-Host "Host: $env:COMPUTERNAME    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor DarkGray

# --------------------------------------------------------------------------------------
# Service
# --------------------------------------------------------------------------------------

Write-Section "Service"

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Fail "Service '$ServiceName' is not registered. Run install.ps1."
}
else {
    if ($service.Status -eq 'Running') {
        Write-Pass "'$ServiceName' is Running"
    }
    else {
        Write-Fail "'$ServiceName' is $($service.Status)"
    }

    $wmiService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if ($wmiService) {
        Write-Detail "Start mode : $($wmiService.StartMode)"
        Write-Detail "Runs as    : $($wmiService.StartName)"
        if ($wmiService.ProcessId -and $wmiService.ProcessId -ne 0) {
            $wrapper = Get-Process -Id $wmiService.ProcessId -ErrorAction SilentlyContinue
            if ($wrapper) {
                $uptime = (Get-Date) - $wrapper.StartTime
                Write-Detail ("Uptime     : {0:d}d {0:hh}h {0:mm}m {0:ss}s" -f $uptime)
            }
        }
    }

    # The wrapper stays up even when the agent underneath has died, so check for the
    # actual agent process too.
    $agentProcess = Get-Process -Name 'pdc' -ErrorAction SilentlyContinue
    if ($agentProcess) {
        Write-Pass "pdc.exe is running (PID $($agentProcess.Id -join ', '))"
    }
    elseif ($service.Status -eq 'Running') {
        Write-Fail "The service is Running but no pdc.exe process exists -- the agent is crash-looping."
    }
}

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------

Write-Section "Configuration"

$serviceXml = Join-Path $InstallDir "$ServiceName.xml"
$cluster = $null
$stackId = $null
$domain = 'grafana.net'
$regionFormat = $false
$metricsAddr = '127.0.0.1:8090'
$usesGoSsh = $false
$logDir = Join-Path $DataDir 'logs'

if (-not (Test-Path -LiteralPath $serviceXml)) {
    Write-Fail "Service configuration not found at $serviceXml"
}
else {
    try {
        [xml]$config = Get-Content -LiteralPath $serviceXml -Raw

        # Use XPath rather than property access: under Set-StrictMode, reading a missing
        # element as a property throws, which would break this diagnostic on a
        # hand-edited config -- precisely when it is most needed. SelectSingleNode
        # returns $null instead.
        foreach ($envNode in $config.SelectNodes('/service/env')) {
            switch ($envNode.GetAttribute('name')) {
                'GCLOUD_PDC_CLUSTER' { $cluster = $envNode.GetAttribute('value') }
                'GCLOUD_HOSTED_GRAFANA_ID' { $stackId = $envNode.GetAttribute('value') }
            }
        }

        $arguments = ''
        $argumentsNode = $config.SelectSingleNode('/service/arguments')
        if ($argumentsNode) { $arguments = $argumentsNode.InnerText }

        if ($arguments -match '-domain\s+(\S+)') { $domain = $Matches[1] }
        if ($arguments -match '-metrics-addr\s+(\S+)') { $metricsAddr = $Matches[1] }
        if ($arguments -match '-region-format') { $regionFormat = $true }
        if ($arguments -match '-use-gossh') { $usesGoSsh = $true }

        $logPathNode = $config.SelectSingleNode('/service/logpath')
        if ($logPathNode -and $logPathNode.InnerText) { $logDir = $logPathNode.InnerText }

        Write-Pass "Loaded $serviceXml"
        Write-Detail "Stack ID   : $stackId"
        Write-Detail "Cluster    : $cluster"
        Write-Detail "Domain     : $domain"
        if ($usesGoSsh) {
            Write-Detail "SSH mode   : built-in Go client (-use-gossh)"
        }
        else {
            Write-Detail "SSH mode   : OpenSSH (ssh.exe)"
        }

        # The token must not be visible in the process command line.
        if ($arguments -match '-token') {
            Write-Warn2 "The signing token appears in <arguments>; it is visible to any user via the process list. Reinstall to move it into <env>."
        }

        # Confirm the ACL on the file holding the token.
        $acl = Get-Acl -LiteralPath $serviceXml
        $broadAccess = $acl.Access | Where-Object {
            $_.IdentityReference -match 'Everyone|BUILTIN\\Users|Authenticated Users'
        }
        if ($broadAccess) {
            Write-Warn2 "$serviceXml is readable by $(($broadAccess.IdentityReference | Select-Object -Unique) -join ', ') and contains the signing token."
        }
    }
    catch {
        Write-Fail "Could not parse $serviceXml : $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------------------
# SSH transport
# --------------------------------------------------------------------------------------

Write-Section "SSH transport"

if ($usesGoSsh) {
    Write-Pass "Using the agent's built-in Go SSH client -- no OpenSSH dependency."
}
else {
    $ssh = Get-Command -Name 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $ssh) {
        Write-Fail "ssh.exe not found on PATH, but the agent is configured to use OpenSSH."
    }
    else {
        $raw = (& $ssh.Source -V 2>&1 | Out-String).Trim()
        if ($raw -match 'OpenSSH_(?:for_Windows_)?(\d+)\.(\d+)') {
            $version = [version]"$($Matches[1]).$($Matches[2])"
            if ($version -ge [version]'9.2') {
                Write-Pass "OpenSSH $version at $($ssh.Source)"
            }
            else {
                Write-Fail "OpenSSH $version is below the required 9.2. Upgrade it, or reinstall with -SshMode gossh."
            }
        }
        else {
            Write-Warn2 "Could not parse the OpenSSH version from: $raw"
        }
    }
}

# --------------------------------------------------------------------------------------
# Connectivity
# --------------------------------------------------------------------------------------

Write-Section "Outbound connectivity"

function Test-Endpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Purpose
    )

    try {
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $completed = $async.AsyncWaitHandle.WaitOne(5000, $false)
        if ($completed -and $client.Connected) {
            $client.EndConnect($async)
            $client.Close()
            Write-Pass "$HostName`:$Port reachable ($Purpose)"
            return
        }
        $client.Close()
        Write-Fail "$HostName`:$Port unreachable ($Purpose) -- check the firewall and any egress proxy."
    }
    catch {
        Write-Fail "$HostName`:$Port failed ($Purpose): $($_.Exception.Message)"
    }
}

if ($cluster) {
    if ($regionFormat) {
        $apiHost = "private-datasource-connect-api.$cluster.$domain"
        $gatewayHost = "private-datasource-connect.$cluster.$domain"
    }
    else {
        $apiHost = "private-datasource-connect-api-$cluster.$domain"
        $gatewayHost = "private-datasource-connect-$cluster.$domain"
    }

    Test-Endpoint -HostName $apiHost -Port 443 -Purpose 'certificate signing API'
    Test-Endpoint -HostName $gatewayHost -Port 22 -Purpose 'SSH tunnel'
}
else {
    Write-Warn2 "Cluster unknown; skipping endpoint checks."
}

# --------------------------------------------------------------------------------------
# Keys and certificate
# --------------------------------------------------------------------------------------

Write-Section "Keys and certificate"

$keyFile = Join-Path (Join-Path $DataDir 'keys') 'grafana_pdc'
$certFile = "$keyFile-cert.pub"

if (Test-Path -LiteralPath $keyFile) {
    Write-Pass "Private key present: $keyFile"
}
else {
    Write-Warn2 "No private key at $keyFile yet. The agent generates one on first successful start."
}

if (Test-Path -LiteralPath $certFile) {
    $certAge = (Get-Date) - (Get-Item -LiteralPath $certFile).LastWriteTime
    Write-Pass ("Certificate present, last renewed {0:N0} minutes ago" -f $certAge.TotalMinutes)

    # ssh-keygen -L decodes the validity window. Not required, so treat it as a bonus.
    $keygen = Get-Command -Name 'ssh-keygen.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($keygen) {
        $certText = (& $keygen.Source -L -f $certFile 2>&1 | Out-String)
        if ($certText -match 'Valid:\s*(.+)') {
            Write-Detail "Valid: $($Matches[1].Trim())"
        }
    }
}
else {
    Write-Warn2 "No signed certificate at $certFile. The agent has not completed a signing request."
}

# --------------------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------------------

Write-Section "Metrics"

$metricsUrl = "http://$metricsAddr/metrics"
if ($metricsAddr -match '^:(\d+)$') { $metricsUrl = "http://127.0.0.1:$($Matches[1])/metrics" }

try {
    $response = Invoke-WebRequest -Uri $metricsUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Pass "Metrics endpoint responding at $metricsUrl"

    $metrics = $response.Content

    if ($metrics -match '(?m)^pdc_agent_agent_info\{(.+?)\}') {
        Write-Detail "agent_info: $($Matches[1])"
    }

    # The two transports expose connection health through different metrics. The Go
    # client never touches pdc_agent_ssh_connections, so reading that gauge in gossh
    # mode would always report a dead tunnel.
    if ($usesGoSsh) {
        if ($metrics -match 'pdc_agent_ssh_time_to_connect_seconds_count\{[^}]*connection="gossh"[^}]*\}\s+(\S+)') {
            $connectCount = [double]$Matches[1]
            if ($connectCount -ge 1) {
                Write-Pass "Go SSH client has established $connectCount connection(s) since start"
            }
            else {
                Write-Fail "The Go SSH client has never completed a connection -- the tunnel is down."
            }
        }
        else {
            Write-Fail "No connection observations recorded -- the Go SSH client has not connected."
        }
    }
    else {
        if ($metrics -match '(?m)^pdc_agent_ssh_connections\s+(\S+)') {
            $count = [double]$Matches[1]
            if ($count -ge 1) {
                Write-Pass "Established SSH connections: $count"
            }
            else {
                Write-Fail "Established SSH connections: 0 -- the tunnel is down."
            }
        }
        else {
            Write-Warn2 "pdc_agent_ssh_connections not present in the metrics output."
        }
    }

    # Restart counters are cumulative across the process lifetime; churn is worth noting
    # but is not itself a failure.
    $totalRestarts = 0
    foreach ($restartMatch in [regex]::Matches($metrics, '(?m)^pdc_agent_ssh_restarts_total\{.*?\}\s+(\S+)')) {
        $totalRestarts += [double]$restartMatch.Groups[1].Value
    }
    if ($totalRestarts -gt 0) {
        Write-Warn2 "SSH restarts since the agent started: $totalRestarts (reconnection churn)"
    }

    # Per-target TCP counters show whether Grafana Cloud is actually querying anything.
    $failedTargets = [regex]::Matches($metrics, '(?m)^pdc_agent_tcp_connections_total\{([^}]*status="failure"[^}]*)\}\s+(\S+)')
    foreach ($failure in $failedTargets) {
        if ([double]$failure.Groups[2].Value -gt 0) {
            if ($failure.Groups[1].Value -match 'target="([^"]+)"') {
                Write-Warn2 "Failed connections to $($Matches[1]): $($failure.Groups[2].Value) -- the agent cannot reach that data source."
            }
        }
    }
}
catch {
    Write-Warn2 "Metrics endpoint $metricsUrl not responding: $($_.Exception.Message)"
    Write-Detail "Expected if the agent has not finished starting, or if the tunnel never came up."
}

# --------------------------------------------------------------------------------------
# Logs
# --------------------------------------------------------------------------------------

if ($Tail -gt 0) {
    Write-Section "Recent log output"

    $outLog = Join-Path $logDir "$ServiceName.out.log"
    $errLog = Join-Path $logDir "$ServiceName.err.log"

    if (Test-Path -LiteralPath $outLog) {
        $lines = Get-Content -LiteralPath $outLog -Tail $Tail -ErrorAction SilentlyContinue
        if ($lines) {
            Write-Host "  --- $ServiceName.out.log (last $Tail) ---" -ForegroundColor DarkGray
            foreach ($line in $lines) {
                $colour = 'Gray'
                if ($line -match 'level=error') { $colour = 'Red' }
                elseif ($line -match 'level=warn') { $colour = 'Yellow' }
                elseif ($line -match 'This is Grafana Private Data\s?[Ss]ource Connect!') { $colour = 'Green' }
                Write-Host "  $line" -ForegroundColor $colour
            }
        }
    }
    else {
        Write-Warn2 "No log file at $outLog"
    }

    if (Test-Path -LiteralPath $errLog) {
        $errLines = Get-Content -LiteralPath $errLog -Tail $Tail -ErrorAction SilentlyContinue
        if ($errLines) {
            Write-Host "  --- $ServiceName.err.log (last $Tail) ---" -ForegroundColor DarkGray
            foreach ($line in $errLines) { Write-Host "  $line" -ForegroundColor Red }
        }
    }
}

# --------------------------------------------------------------------------------------
# Verdict
# --------------------------------------------------------------------------------------

Write-Host ""
if ($script:Problems.Count -eq 0) {
    Write-Host "No problems detected." -ForegroundColor Green
    exit 0
}

Write-Host "$($script:Problems.Count) problem(s) detected:" -ForegroundColor Red
foreach ($problem in $script:Problems) {
    Write-Host "  - $problem" -ForegroundColor Red
}
Write-Host "`nSee docs/TROUBLESHOOTING.md" -ForegroundColor Yellow
exit 1
