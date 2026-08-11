#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Grafana Private Data Source Connect (PDC) agent as a Windows service.

.DESCRIPTION
    Downloads the pdc-agent release, installs it under a WinSW service wrapper, and
    registers it as an auto-starting Windows service with restart-on-failure and log
    rotation -- roughly the equivalent of a systemd unit on Linux.

    The PDC agent is a plain console executable and does not implement the Windows
    Service Control Manager protocol, so registering it directly with sc.exe fails with
    "Error 1053: The service did not respond to the start or control request in a timely
    fashion". WinSW is a small supervisor that speaks SCM and manages the child process.

    Credentials (signing token, stack ID, cluster) are passed to the agent through
    environment variables rather than command-line arguments so they do not appear in
    the process list. They live in the service XML, which is ACL'd to SYSTEM and
    Administrators only.

.PARAMETER Token
    Grafana Cloud access policy token with the pdc-signing:write scope.

.PARAMETER HostedGrafanaId
    Numeric ID of the Grafana Cloud stack.

.PARAMETER Cluster
    PDC cluster, e.g. prod-eu-west-2.

.PARAMETER SshMode
    auto     - use OpenSSH if ssh.exe >= 9.2 is on PATH, otherwise the agent's built-in
               Go SSH client (default)
    gossh    - always use the built-in Go SSH client; no OpenSSH dependency
    openssh  - always use ssh.exe; fails if the version is below 9.2

.PARAMETER Connections
    Number of parallel SSH connections. Only honoured in openssh mode; the Go SSH
    client currently ignores it.

.PARAMETER PermitDomains
    Restrict which endpoints the tunnel may reach, as host:port entries, e.g.
    mysql.internal:3306. Omit to allow all.

.PARAMETER ServiceAccount
    Optional credential to run the service as. Defaults to LocalSystem. The account is
    granted the "Log on as a service" right. The password is used only at registration
    time and is stripped from the XML afterwards.

.PARAMETER AgentArchive
    Path to a pre-downloaded pdc-agent_Windows_<arch>.zip, for offline installs.

.PARAMETER WinSwBinary
    Path to a pre-downloaded WinSW.NET461.exe, for offline installs.

.EXAMPLE
    .\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-eu-west-2'

.EXAMPLE
    .\install.ps1 -ConfigFile .\examples\config.example.psd1

.EXAMPLE
    .\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-us-east-0' `
        -PermitDomains 'mysql.corp.local:3306','pg.corp.local:5432' -LogLevel debug
#>
[CmdletBinding()]
param(
    [string]$Token,
    [string]$HostedGrafanaId,
    [string]$Cluster,

    [string]$Domain = 'grafana.net',
    [switch]$RegionFormat,

    [ValidateSet('auto', 'gossh', 'openssh')]
    [string]$SshMode = 'auto',

    [ValidateRange(1, 50)]
    [int]$Connections = 1,

    [string[]]$PermitDomains,

    [string]$MetricsAddr = '127.0.0.1:8090',

    [ValidateSet('debug', 'info', 'warn', 'error')]
    [string]$LogLevel = 'info',

    [string]$InstallDir = "$env:ProgramFiles\GrafanaLabs\PDC",
    [string]$DataDir = "$env:ProgramData\GrafanaLabs\PDC",

    [string]$ServiceName = 'grafana-pdc-agent',
    [string]$ServiceDisplayName = 'Grafana Private Data Source Connect Agent',

    [string]$AgentVersion = 'latest',
    [string]$WinSwVersion = 'v2.12.0',

    [System.Management.Automation.PSCredential]$ServiceAccount,

    [string]$AgentArchive,
    [string]$WinSwBinary,

    [string]$ConfigFile,

    [switch]$SkipChecksum,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without it

# --------------------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    $Message" }
function Write-Note { param([string]$Message) Write-Host "    ! $Message" -ForegroundColor Yellow }

# --------------------------------------------------------------------------------------
# Config file support
# --------------------------------------------------------------------------------------

if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }
    Write-Step "Loading configuration from $ConfigFile"
    $fileConfig = Import-PowerShellDataFile -LiteralPath $ConfigFile

    # Explicit parameters on the command line win over the config file.
    foreach ($key in $fileConfig.Keys) {
        if ($PSBoundParameters.ContainsKey($key)) {
            Write-Info "$key : overridden on command line"
            continue
        }
        $target = Get-Variable -Name $key -Scope 0 -ErrorAction SilentlyContinue
        if (-not $target) {
            Write-Note "Ignoring unknown config key '$key'"
            continue
        }
        Set-Variable -Name $key -Scope 0 -Value $fileConfig[$key]
    }
}

foreach ($required in 'Token', 'HostedGrafanaId', 'Cluster') {
    if (-not (Get-Variable -Name $required -ValueOnly)) {
        throw "Missing required setting: -$required (supply it as a parameter or in -ConfigFile)"
    }
}

# --------------------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------------------

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw "This script must be run from an elevated PowerShell session (Run as Administrator)."
}

function Get-OsArch {
    # PROCESSOR_ARCHITEW6432 is set when a 32-bit process runs on a 64-bit OS.
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'x86_64' }
        'ARM64' { return 'arm64' }
        'X86' { return 'i386' }
        default { throw "Unsupported processor architecture: $arch" }
    }
}

$osArch = Get-OsArch
Write-Step "Preflight"
Write-Info "OS architecture     : $osArch"
Write-Info "Install directory   : $InstallDir"
Write-Info "Data directory      : $DataDir"
Write-Info "Service name        : $ServiceName"

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService -and -not $Force) {
    throw "Service '$ServiceName' already exists. Re-run with -Force to reinstall, or run uninstall.ps1 first."
}

# TLS 1.2 is not the default on older Windows builds and GitHub requires it.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Note "Could not raise TLS version; downloads may fail on older Windows builds."
}

# --------------------------------------------------------------------------------------
# SSH mode resolution
# --------------------------------------------------------------------------------------

function Get-OpenSshClientVersion {
    $ssh = Get-Command -Name 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $ssh) { return $null }

    try {
        # ssh -V writes to stderr, so redirect it into the success stream.
        $raw = (& $ssh.Source -V 2>&1 | Out-String).Trim()
    }
    catch {
        return $null
    }

    # Matches both "OpenSSH_9.5p1" and "OpenSSH_for_Windows_9.5p1".
    if ($raw -match 'OpenSSH_(?:for_Windows_)?(\d+)\.(\d+)') {
        return [pscustomobject]@{
            Version = [version]"$($Matches[1]).$($Matches[2])"
            Path    = $ssh.Source
            Raw     = $raw
        }
    }
    return $null
}

$minimumSsh = [version]'9.2'
$sshInfo = Get-OpenSshClientVersion

Write-Step "Resolving SSH mode (requested: $SshMode)"
if ($sshInfo) {
    Write-Info "Found ssh.exe       : $($sshInfo.Path)"
    Write-Info "Reported version    : $($sshInfo.Raw)"
}
else {
    Write-Info "No usable ssh.exe found on PATH."
}

$resolvedSshMode = $SshMode
if ($SshMode -eq 'auto') {
    if ($sshInfo -and $sshInfo.Version -ge $minimumSsh) {
        $resolvedSshMode = 'openssh'
        Write-Ok "OpenSSH $($sshInfo.Version) meets the $minimumSsh minimum -- using OpenSSH."
    }
    else {
        $resolvedSshMode = 'gossh'
        if ($sshInfo) {
            Write-Note "OpenSSH $($sshInfo.Version) is below the $minimumSsh minimum -- using the built-in Go SSH client."
        }
        else {
            Write-Note "Using the agent's built-in Go SSH client (no OpenSSH required)."
        }
    }
}
elseif ($SshMode -eq 'openssh') {
    if (-not $sshInfo) {
        throw "-SshMode openssh was requested but no ssh.exe was found on PATH. Install the OpenSSH Client feature, or use -SshMode gossh."
    }
    if ($sshInfo.Version -lt $minimumSsh) {
        throw ("-SshMode openssh was requested but ssh.exe is version $($sshInfo.Version), " +
            "below the required $minimumSsh. Upgrade via https://github.com/PowerShell/Win32-OpenSSH/releases, " +
            "or use -SshMode gossh which needs no OpenSSH at all.")
    }
    Write-Ok "Using OpenSSH $($sshInfo.Version)."
}
else {
    Write-Ok "Using the agent's built-in Go SSH client."
}

if ($resolvedSshMode -eq 'gossh' -and $Connections -gt 1) {
    Write-Note "-Connections $Connections ignored: the Go SSH client opens a single connection. Use -SshMode openssh for multiple."
    $Connections = 1
}

# --------------------------------------------------------------------------------------
# Download helpers
# --------------------------------------------------------------------------------------

function Invoke-Fetch {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge 3) {
                throw "Download failed after $attempt attempts: $Uri`n$($_.Exception.Message)"
            }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Resolve-AgentVersion {
    param([string]$Requested)
    if ($Requested -and $Requested -ne 'latest') {
        if ($Requested -notmatch '^v') { return "v$Requested" }
        return $Requested
    }
    Write-Info "Querying GitHub for the latest pdc-agent release..."
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/grafana/pdc-agent/releases/latest' `
        -UseBasicParsing -Headers @{ 'User-Agent' = 'pdc-on-windows-installer' }
    return $release.tag_name
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("pdc-install-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    # ----------------------------------------------------------------------------------
    # Acquire the PDC agent
    # ----------------------------------------------------------------------------------

    Write-Step "Acquiring the PDC agent"

    $archiveName = "pdc-agent_Windows_$osArch.zip"
    $localArchive = Join-Path $workDir $archiveName

    if ($AgentArchive) {
        if (-not (Test-Path -LiteralPath $AgentArchive)) {
            throw "Agent archive not found: $AgentArchive"
        }
        Copy-Item -LiteralPath $AgentArchive -Destination $localArchive -Force
        Write-Ok "Using local archive: $AgentArchive"
        $resolvedVersion = 'local'
    }
    else {
        $resolvedVersion = Resolve-AgentVersion -Requested $AgentVersion
        $baseUrl = "https://github.com/grafana/pdc-agent/releases/download/$resolvedVersion"
        Write-Info "Version             : $resolvedVersion"

        Invoke-Fetch -Uri "$baseUrl/$archiveName" -OutFile $localArchive
        Write-Ok "Downloaded $archiveName"

        if (-not $SkipChecksum) {
            $checksumFile = Join-Path $workDir 'checksums.txt'
            Invoke-Fetch -Uri "$baseUrl/checksums.txt" -OutFile $checksumFile

            $expected = $null
            foreach ($line in Get-Content -LiteralPath $checksumFile) {
                # Format: "<sha256>  <filename>"
                $parts = $line -split '\s+', 2
                if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $archiveName) {
                    $expected = $parts[0].Trim().ToLowerInvariant()
                    break
                }
            }
            if (-not $expected) {
                throw "No SHA256 entry for $archiveName in checksums.txt. Re-run with -SkipChecksum to bypass."
            }

            $actual = (Get-FileHash -LiteralPath $localArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $expected) {
                throw "Checksum mismatch for $archiveName.`n  expected: $expected`n  actual:   $actual"
            }
            Write-Ok "SHA256 verified"
        }
        else {
            Write-Note "Checksum verification skipped."
        }
    }

    $extractDir = Join-Path $workDir 'extract'
    Expand-Archive -LiteralPath $localArchive -DestinationPath $extractDir -Force

    # The archive nests everything under pdc-agent_Windows_<arch>/ and the binary is
    # named pdc.exe, not pdc-agent.exe.
    $agentBinary = Get-ChildItem -Path $extractDir -Filter 'pdc.exe' -Recurse -File |
        Select-Object -First 1
    if (-not $agentBinary) {
        throw "pdc.exe not found inside $archiveName"
    }
    Write-Ok "Extracted pdc.exe"

    # ----------------------------------------------------------------------------------
    # Acquire WinSW
    # ----------------------------------------------------------------------------------

    Write-Step "Acquiring the WinSW service wrapper"

    $localWinSw = Join-Path $workDir 'WinSW.exe'
    if ($WinSwBinary) {
        if (-not (Test-Path -LiteralPath $WinSwBinary)) {
            throw "WinSW binary not found: $WinSwBinary"
        }
        Copy-Item -LiteralPath $WinSwBinary -Destination $localWinSw -Force
        Write-Ok "Using local WinSW: $WinSwBinary"
    }
    else {
        # The .NET Framework 4.6.1 build is AnyCPU and ~650 KB. .NET Framework 4.6.2+ is
        # in-box on Windows Server 2016+ and Windows 10 1607+, so there is nothing to
        # install. The self-contained builds are ~18 MB and buy us nothing here.
        $winSwUrl = "https://github.com/winsw/winsw/releases/download/$WinSwVersion/WinSW.NET461.exe"
        Invoke-Fetch -Uri $winSwUrl -OutFile $localWinSw
        Write-Ok "Downloaded WinSW $WinSwVersion"
    }

    # ----------------------------------------------------------------------------------
    # Remove any previous installation
    # ----------------------------------------------------------------------------------

    $serviceExe = Join-Path $InstallDir "$ServiceName.exe"
    $serviceXml = Join-Path $InstallDir "$ServiceName.xml"

    if ($existingService) {
        Write-Step "Removing the existing '$ServiceName' service"
        if ($existingService.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            $existingService.WaitForStatus('Stopped', [timespan]::FromSeconds(30))
        }
        if (Test-Path -LiteralPath $serviceExe) {
            & $serviceExe uninstall | Out-Null
        }
        else {
            & sc.exe delete $ServiceName | Out-Null
        }

        # SCM removal is asynchronous; wait for it to actually disappear.
        for ($i = 0; $i -lt 30; $i++) {
            if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }
        Write-Ok "Previous service removed"
    }

    # ----------------------------------------------------------------------------------
    # Lay out directories and files
    # ----------------------------------------------------------------------------------

    Write-Step "Installing files"

    $keyDir = Join-Path $DataDir 'keys'
    $logDir = Join-Path $DataDir 'logs'
    foreach ($dir in $InstallDir, $DataDir, $keyDir, $logDir) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Copy-Item -LiteralPath $agentBinary.FullName -Destination (Join-Path $InstallDir 'pdc.exe') -Force
    Copy-Item -LiteralPath $localWinSw -Destination $serviceExe -Force

    $licenseFile = Get-ChildItem -Path $extractDir -Filter 'LICENSE' -Recurse -File |
        Select-Object -First 1
    if ($licenseFile) {
        Copy-Item -LiteralPath $licenseFile.FullName `
            -Destination (Join-Path $InstallDir 'LICENSE.pdc-agent') -Force
    }

    Write-Ok "pdc.exe and $ServiceName.exe installed to $InstallDir"

    # ----------------------------------------------------------------------------------
    # Build the service configuration
    # ----------------------------------------------------------------------------------

    Write-Step "Writing the service configuration"

    # IMPORTANT: the agent derives the key directory and the known_hosts path by splitting
    # -ssh-key-file on "/" (pkg/ssh/ssh.go and pkg/ssh/keymanager.go import "path", not
    # "path/filepath"). A backslash path collapses the directory to an empty string, so
    # known_hosts lands in the working directory and key creation misbehaves. Windows
    # file APIs accept forward slashes, so we normalise here.
    $keyFileForward = ((Join-Path $keyDir 'grafana_pdc') -replace '\\', '/')

    $agentArgs = @(
        '-log.level', $LogLevel
        '-ssh-key-file', $keyFileForward
        '-metrics-addr', $MetricsAddr
        '-domain', $Domain
    )
    if ($RegionFormat) { $agentArgs += '-region-format' }

    if ($resolvedSshMode -eq 'gossh') {
        $agentArgs += '-use-gossh'
        foreach ($permitted in $PermitDomains) {
            $agentArgs += @('-permit-domains', $permitted)
        }
    }
    else {
        if ($Connections -gt 1) { $agentArgs += @('-connections', "$Connections") }
        if ($PermitDomains) {
            # OpenSSH mode takes one space-separated PermitRemoteOpen option. The "="
            # form keeps the leading "-o" from being parsed as a separate flag.
            $agentArgs += ('-ssh-flag=-o PermitRemoteOpen=' + ($PermitDomains -join ' '))
        }
    }

    function Format-CommandArg {
        param([string]$Value)
        if ($Value -match '[\s"]') {
            return '"' + ($Value -replace '"', '\"') + '"'
        }
        return $Value
    }

    $argumentString = (($agentArgs | ForEach-Object { Format-CommandArg $_ }) -join ' ')

    function ConvertTo-XmlText {
        param([string]$Value)
        return [System.Security.SecurityElement]::Escape($Value)
    }

    $serviceAccountBlock = ''
    if ($ServiceAccount) {
        $accountName = $ServiceAccount.UserName
        $accountDomain = ''
        if ($accountName -match '^(?<domain>[^\\]+)\\(?<user>.+)$') {
            $accountDomain = $Matches['domain']
            $accountName = $Matches['user']
        }
        $plainPassword = $ServiceAccount.GetNetworkCredential().Password

        $domainElement = ''
        if ($accountDomain) {
            $domainElement = "`n    <domain>$(ConvertTo-XmlText $accountDomain)</domain>"
        }
        $serviceAccountBlock = @"

  <serviceaccount>$domainElement
    <user>$(ConvertTo-XmlText $accountName)</user>
    <password>$(ConvertTo-XmlText $plainPassword)</password>
    <allowservicelogon>true</allowservicelogon>
  </serviceaccount>
"@
    }

    $permitSummary = 'all endpoints'
    if ($PermitDomains) { $permitSummary = ($PermitDomains -join ', ') }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Grafana Private Data Source Connect agent service definition.

  Generated by install.ps1. Re-run install.ps1 -Force to regenerate, or edit this file
  and restart the service with: Restart-Service $ServiceName

  Agent version : $resolvedVersion
  SSH mode      : $resolvedSshMode
  Permitted     : $permitSummary

  This file contains the PDC signing token. Its ACL is restricted to SYSTEM and
  Administrators.
-->
<service>
  <id>$(ConvertTo-XmlText $ServiceName)</id>
  <name>$(ConvertTo-XmlText $ServiceDisplayName)</name>
  <description>Maintains an outbound SSH tunnel that lets Grafana Cloud query data sources on this private network.</description>

  <executable>$(ConvertTo-XmlText (Join-Path $InstallDir 'pdc.exe'))</executable>
  <arguments>$(ConvertTo-XmlText $argumentString)</arguments>
  <workingdirectory>$(ConvertTo-XmlText $DataDir)</workingdirectory>
$serviceAccountBlock
  <startmode>Automatic</startmode>
  <!--
    Delayed start so the network stack is up before the first connection attempt.
    Deliberately no <depend> entries: a hard dependency on Dnscache or Tcpip means the
    service refuses to start (error 1068) if an administrator has disabled one of them,
    and it buys nothing here. The agent retries connections internally with a backoff,
    and the onfailure rules below cover a genuine crash.
  -->
  <delayedAutoStart/>

  <!-- Equivalent of systemd Restart=always with a backoff. -->
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>

  <stoptimeout>15 sec</stoptimeout>
  <stopparentprocessfirst>true</stopparentprocessfirst>

  <logpath>$(ConvertTo-XmlText $logDir)</logpath>
  <log mode="roll-by-size-time">
    <sizeThreshold>10240</sizeThreshold>
    <pattern>yyyyMMdd</pattern>
    <autoRollAtTime>00:00:00</autoRollAtTime>
    <zipOlderThanNumDays>14</zipOlderThanNumDays>
  </log>

  <!--
    Credentials are passed as environment variables, not arguments, so that they do not
    show up in the process command line (Get-Process, wmic, Task Manager).
  -->
  <env name="GCLOUD_PDC_SIGNING_TOKEN" value="$(ConvertTo-XmlText $Token)"/>
  <env name="GCLOUD_HOSTED_GRAFANA_ID" value="$(ConvertTo-XmlText $HostedGrafanaId)"/>
  <env name="GCLOUD_PDC_CLUSTER" value="$(ConvertTo-XmlText $Cluster)"/>
</service>
"@

    # UTF-8 without BOM; WinSW's XML parser dislikes a BOM ahead of the declaration.
    [IO.File]::WriteAllText($serviceXml, $xml, (New-Object Text.UTF8Encoding($false)))
    Write-Ok "Wrote $serviceXml"

    # ----------------------------------------------------------------------------------
    # Lock down permissions
    # ----------------------------------------------------------------------------------

    Write-Step "Applying permissions"

    function Set-RestrictedAcl {
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [Parameter(Mandatory)][string]$Path,
            [string]$AdditionalPrincipal
        )

        $item = Get-Item -LiteralPath $Path -Force
        $acl = Get-Acl -LiteralPath $Path

        # Break inheritance and drop the inherited rules (notably BUILTIN\Users:Read,
        # which would otherwise expose the token and make OpenSSH reject the private key
        # as "unprotected"). Passing $false discards the inherited rules rather than
        # converting them to explicit ones.
        $acl.SetAccessRuleProtection($true, $false)

        # Only explicit rules can be removed; attempting to remove an inherited rule
        # throws. Filter defensively in case the protection change left any behind.
        foreach ($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) {
            [void]$acl.RemoveAccessRuleSpecific($rule)
        }

        $inheritance = [Security.AccessControl.InheritanceFlags]::None
        if ($item.PSIsContainer) {
            $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        }

        $principals = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')
        if ($AdditionalPrincipal) { $principals += $AdditionalPrincipal }

        foreach ($principal in $principals) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $principal,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }

        if ($PSCmdlet.ShouldProcess($Path, 'Restrict access to SYSTEM and Administrators')) {
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
    }

    $serviceIdentity = $null
    if ($ServiceAccount) { $serviceIdentity = $ServiceAccount.UserName }

    # The agent generates and rewrites its key pair and certificate at runtime, so the
    # service identity needs write access to the key directory.
    Set-RestrictedAcl -Path $keyDir -AdditionalPrincipal $serviceIdentity
    Set-RestrictedAcl -Path $serviceXml -AdditionalPrincipal $serviceIdentity

    if ($serviceIdentity) {
        Set-RestrictedAcl -Path $logDir -AdditionalPrincipal $serviceIdentity
        Write-Ok "Restricted key store, log directory and service XML to SYSTEM, Administrators and $serviceIdentity"
    }
    else {
        Write-Ok "Restricted key store and service XML to SYSTEM and Administrators"
    }

    # ----------------------------------------------------------------------------------
    # Register and start
    # ----------------------------------------------------------------------------------

    Write-Step "Registering the Windows service"

    $installOutput = & $serviceExe install 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WinSW install failed (exit code $LASTEXITCODE):`n$($installOutput | Out-String)"
    }
    Write-Ok "Service '$ServiceName' registered"

    if ($ServiceAccount) {
        # WinSW only reads the password during install, so remove it from the on-disk
        # config now that registration has succeeded. The credential stays in the SCM's
        # protected LSA secret store.
        $xmlWithoutPassword = [IO.File]::ReadAllText($serviceXml) -replace `
            '(?m)^\s*<password>.*</password>\r?\n', ''
        [IO.File]::WriteAllText($serviceXml, $xmlWithoutPassword, (New-Object Text.UTF8Encoding($false)))
        Write-Ok "Stripped the service account password from the XML"
    }

    Write-Step "Starting the service"
    Start-Service -Name $ServiceName
    Write-Ok "Service started"

    # ----------------------------------------------------------------------------------
    # Verify the tunnel actually came up
    # ----------------------------------------------------------------------------------

    Write-Step "Verifying the connection"

    $outLog = Join-Path $logDir "$ServiceName.out.log"
    $errLog = Join-Path $logDir "$ServiceName.err.log"

    # The two transports signal success differently:
    #
    #   openssh - the gateway prints a banner that the agent relays to its log, and
    #             pdc_agent_ssh_connections is incremented.
    #   gossh   - neither of those happen. A successful connection is entirely silent at
    #             info level, and the only evidence is an observation on the
    #             pdc_agent_ssh_time_to_connect_seconds histogram, labelled gossh.
    #
    # Note the banner says "Datasource", one word (pkg/ssh/ssh.go), even though the
    # published docs render it "Data Source". Match both.
    $successPattern = 'This is Grafana Private Data\s?[Ss]ource Connect!'

    $probeAddr = $MetricsAddr
    if ($probeAddr -match '^:(\d+)$') { $probeAddr = "127.0.0.1:$($Matches[1])" }
    if ($probeAddr -match '^(0\.0\.0\.0|\[::\]):(\d+)$') { $probeAddr = "127.0.0.1:$($Matches[2])" }
    $probeUrl = "http://$probeAddr/metrics"

    $connected = $false
    $crashed = $false

    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1

        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Stopped') {
            $crashed = $true
            break
        }

        if (Test-Path -LiteralPath $outLog) {
            $logText = Get-Content -LiteralPath $outLog -Raw -ErrorAction SilentlyContinue
            if ($logText -and $logText -match $successPattern) {
                $connected = $true
                break
            }
        }

        # The metrics server only starts once the SSH client has started, so a response
        # here is itself meaningful.
        try {
            $metrics = (Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop).Content
            if ($resolvedSshMode -eq 'gossh') {
                if ($metrics -match 'pdc_agent_ssh_time_to_connect_seconds_count\{[^}]*connection="gossh"[^}]*\}\s+([1-9]\d*)') {
                    $connected = $true
                    break
                }
            }
            elseif ($metrics -match '(?m)^pdc_agent_ssh_connections\s+([1-9]\d*)') {
                $connected = $true
                break
            }
        }
        catch {
            # The metrics server is not listening yet, which is the normal case for the
            # first few seconds. Keep polling until the timeout.
            Write-Verbose "Metrics probe not ready: $($_.Exception.Message)"
        }
    }

    Write-Host ""
    if ($connected) {
        Write-Host "SUCCESS: the PDC agent is connected to Grafana Cloud." -ForegroundColor Green
    }
    elseif ($crashed) {
        Write-Host "FAILED: the service stopped shortly after starting. See the logs below." -ForegroundColor Red
    }
    else {
        Write-Host "The service is installed but the connection was not confirmed within 45 seconds." -ForegroundColor Yellow
        Write-Host "This is not necessarily a failure -- check the logs below." -ForegroundColor Yellow

        foreach ($logPath in $outLog, $errLog) {
            if (Test-Path -LiteralPath $logPath) {
                $tail = Get-Content -LiteralPath $logPath -Tail 20 -ErrorAction SilentlyContinue
                if ($tail) {
                    Write-Host ""
                    Write-Host "--- $(Split-Path -Leaf $logPath) (last 20 lines) ---" -ForegroundColor Yellow
                    $tail | ForEach-Object { Write-Host "  $_" }
                }
            }
        }
    }

    Write-Host ""
    Write-Host "Summary" -ForegroundColor Cyan
    Write-Host "  Service      : $ServiceName ($ServiceDisplayName)"
    Write-Host "  Agent        : $resolvedVersion"
    Write-Host "  SSH mode     : $resolvedSshMode"
    Write-Host "  Stack ID     : $HostedGrafanaId"
    Write-Host "  Cluster      : $Cluster"
    Write-Host "  Config       : $serviceXml"
    Write-Host "  Logs         : $logDir"
    Write-Host "  Keys         : $keyDir"
    Write-Host "  Metrics      : http://$MetricsAddr/metrics"
    Write-Host ""
    Write-Host "Useful commands" -ForegroundColor Cyan
    Write-Host "  Get-Service $ServiceName"
    Write-Host "  Restart-Service $ServiceName"
    Write-Host "  Get-Content '$outLog' -Tail 50 -Wait"
    Write-Host "  .\Get-PdcAgentStatus.ps1"
    Write-Host ""
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
