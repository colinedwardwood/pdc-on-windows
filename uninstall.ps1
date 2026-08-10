#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the Grafana Private Data Source Connect (PDC) agent Windows service.

.DESCRIPTION
    Stops and deregisters the service, then removes the installed binaries. Data --
    generated SSH keys and rotated logs -- is preserved unless -RemoveData is supplied,
    so that a reinstall reuses the same key pair.

.PARAMETER RemoveData
    Also delete the data directory, including the generated SSH key pair, the signed
    certificate, known_hosts and all logs.

.EXAMPLE
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -RemoveData
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$InstallDir = "$env:ProgramFiles\GrafanaLabs\PDC",
    [string]$DataDir = "$env:ProgramData\GrafanaLabs\PDC",
    [string]$ServiceName = 'grafana-pdc-agent',
    [switch]$RemoveData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    ! $Message" -ForegroundColor Yellow }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run from an elevated PowerShell session (Run as Administrator)."
}

$serviceExe = Join-Path $InstallDir "$ServiceName.exe"
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($service) {
    if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop and deregister the Windows service')) {
        Write-Step "Stopping '$ServiceName'"
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            try {
                $service.WaitForStatus('Stopped', [timespan]::FromSeconds(30))
            }
            catch {
                Write-Note "Service did not stop cleanly within 30 seconds; continuing."
            }
        }
        Write-Ok "Stopped"

        Write-Step "Deregistering the service"
        if (Test-Path -LiteralPath $serviceExe) {
            & $serviceExe uninstall | Out-Null
        }
        else {
            Write-Note "WinSW wrapper missing; falling back to sc.exe delete."
            & sc.exe delete $ServiceName | Out-Null
        }

        # SCM deletion is asynchronous.
        for ($i = 0; $i -lt 30; $i++) {
            if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }

        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
            Write-Note "Service still registered. It is likely marked for deletion; a reboot will clear it."
        }
        else {
            Write-Ok "Deregistered"
        }
    }
}
else {
    Write-Note "Service '$ServiceName' is not registered; nothing to stop."
}

if (Test-Path -LiteralPath $InstallDir) {
    if ($PSCmdlet.ShouldProcess($InstallDir, 'Remove the installation directory')) {
        Write-Step "Removing $InstallDir"
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Write-Ok "Removed"
        }
        catch {
            Write-Note "Could not fully remove $InstallDir : $($_.Exception.Message)"
            Write-Note "A file is probably still locked. Retry after a reboot."
        }
    }
}

if ($RemoveData) {
    if (Test-Path -LiteralPath $DataDir) {
        if ($PSCmdlet.ShouldProcess($DataDir, 'Remove the data directory, including SSH keys and logs')) {
            Write-Step "Removing $DataDir"
            Remove-Item -LiteralPath $DataDir -Recurse -Force
            Write-Ok "Removed keys, certificates and logs"
        }
    }
}
elseif (Test-Path -LiteralPath $DataDir) {
    Write-Note "Kept $DataDir (SSH keys and logs). Re-run with -RemoveData to delete it."
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
