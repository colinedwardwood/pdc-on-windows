# Troubleshooting

Run `.\Get-PdcAgentStatus.ps1` first. It checks the service, outbound reachability, the
SSH transport, the certificate, the metrics endpoint and the recent log, and prints a
summary of what is wrong.

```powershell
.\Get-PdcAgentStatus.ps1
.\Get-PdcAgentStatus.ps1 -Tail 100    # more log context
```

For anything unexplained, turn up logging and watch it live:

```powershell
# Set -log.level debug in the XML, or reinstall with -LogLevel debug
notepad 'C:\Program Files\GrafanaLabs\PDC\grafana-pdc-agent.xml'
Restart-Service grafana-pdc-agent
Get-Content 'C:\ProgramData\GrafanaLabs\PDC\logs\grafana-pdc-agent.out.log' -Tail 50 -Wait
```

---

## Error 1053 — "the service did not respond in a timely fashion"

You registered `pdc.exe` directly with `sc.exe` or `New-Service`. It is a console
program and does not implement the SCM protocol, so the SCM gives up waiting for it to
check in.

Use `install.ps1`, which puts WinSW in front of it. See the README.

---

## "OpenSSH version must be greater or equal to 9.2, current version: 8.1"

The in-box OpenSSH on your Windows build is too old. Three options, best first:

1. **Switch to the built-in Go SSH client** — no OpenSSH required at all:

   ```powershell
   .\install.ps1 -Token 'glc_...' -HostedGrafanaId '...' -Cluster '...' -SshMode gossh -Force
   ```

2. **Upgrade OpenSSH** from [Win32-OpenSSH releases](https://github.com/PowerShell/Win32-OpenSSH/releases)
   (note every build is tagged "Preview"), then reinstall with `-SshMode openssh`. Confirm
   with `ssh -V` in a *new* shell — `$env:PATH` is cached per process, and the SCM's copy
   only refreshes on reboot or service restart.

3. **Bypass the check** with `-skip-ssh-validation` in the XML `<arguments>`. Not
   recommended: the minimum exists because older clients lack SSH features PDC relies on.

---

## Service starts, then stops immediately

Check `grafana-pdc-agent.err.log` and `grafana-pdc-agent.wrapper.log`.

Common causes:

| Log line | Cause |
| --- | --- |
| `401` / `403` from the signing API | Token is wrong, expired, or lacks `pdc-signing:write` |
| `no such host` | Wrong `-Cluster`, or DNS is blocked |
| `i/o timeout` on port 22 | Firewall or proxy blocking the SSH gateway |
| `invalid SSH version` | See the OpenSSH section above |
| `cannot initialise PDC client` | Malformed stack ID or cluster |

Verify the token independently:

```powershell
$id      = '123456'
$cluster = 'prod-eu-west-2'
$token   = 'glc_...'
Invoke-WebRequest -Method POST -UseBasicParsing `
  -Uri "https://private-datasource-connect-api-$cluster.grafana.net/pdc/api/v1/sign-public-key" `
  -Headers @{ Authorization = "Bearer $id`:$token" }
```

A `400` means the token authenticated (it rejected the empty body). A `401` means the
token itself is bad.

---

## "limit of connections for stack and network reached"

You are at the 50-connection cap across every agent on the stack. Reduce `-Connections`,
retire agents you are no longer using, or ask Grafana Support to raise the limit.

---

## The tunnel is up but Grafana Cloud cannot query the data source

The tunnel terminates on *this* host, so the data source must be reachable **from here**:

```powershell
Test-NetConnection -ComputerName mysql.corp.local -Port 3306
```

If you set `-PermitDomains`, the entry must match exactly what the Grafana data source
points at. `mysql.corp.local:3306` does not permit `10.0.0.5:3306` — the agent compares
the literal host string, then `host:port`.

`Get-PdcAgentStatus.ps1` surfaces per-target failures from
`pdc_agent_tcp_connections_total{status="failure"}`, which usually pinpoints this.

---

## `known_hosts` appears in the wrong place, or key handling misbehaves

You are passing `-ssh-key-file` with backslashes. The agent derives the key directory by
splitting the path on `/` (it uses Go's `path`, not `path/filepath`), so a backslash path
yields an empty directory: `known_hosts` lands in the working directory and
`UserKnownHostsFile` becomes `/known_hosts`.

Use forward slashes:

```xml
<arguments>-ssh-key-file C:/ProgramData/GrafanaLabs/PDC/keys/grafana_pdc ...</arguments>
```

`install.ps1` does this for you.

---

## OpenSSH mode: "UNPROTECTED PRIVATE KEY FILE" or permission errors on the key

`ssh.exe` refuses a private key that other users can read. The agent writes the key with
Go's `0600` mode, which is a no-op for Windows ACLs — the file simply inherits whatever
the parent directory grants, typically including `BUILTIN\Users: Read`.

Re-apply the restricted ACL:

```powershell
$keyDir = 'C:\ProgramData\GrafanaLabs\PDC\keys'
icacls $keyDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F'
Restart-Service grafana-pdc-agent
```

Add the service account too if you are not running as LocalSystem. `install.ps1` does
this at install time.

---

## Keys are created somewhere unexpected

Without an explicit `-ssh-key-file`, the agent defaults to `~/.ssh/grafana_pdc`, resolved
via `os.UserHomeDir()`. For a LocalSystem service that is
`C:\Windows\System32\config\systemprofile\.ssh\` — confusing, and easy to lose track of.
Always set the path explicitly, as `install.ps1` does.

---

## Metrics endpoint not responding

`http://127.0.0.1:8090/metrics` only starts serving **after** the SSH client has started.
If it never comes up, the agent never connected — look at the log rather than the metrics.

If you changed `-MetricsAddr` to a non-loopback address, allow it through the firewall:

```powershell
New-NetFirewallRule -DisplayName 'PDC agent metrics' -Direction Inbound `
    -Protocol TCP -LocalPort 8090 -Action Allow
```

---

## Service is stuck "marked for deletion"

An open handle — usually `services.msc` or an SCM snap-in — is pinning the record. Close
those windows; if it persists, reboot. `uninstall.ps1` warns when it sees this.

---

## Log files are growing without bound

Rotation is configured in the XML (`roll-by-size-time`: 10 MB, daily, zipped after 14
days). If you replaced that block, check it still parses — WinSW silently falls back to
`append` mode on an invalid `<log>` section. `grafana-pdc-agent.wrapper.log` records the
parse error.

---

## Collecting a support bundle

```powershell
$out = "$env:TEMP\pdc-support-$(Get-Date -f yyyyMMdd-HHmmss)"
New-Item -ItemType Directory $out -Force | Out-Null

Copy-Item 'C:\ProgramData\GrafanaLabs\PDC\logs\*' $out -ErrorAction SilentlyContinue
.\Get-PdcAgentStatus.ps1 -Tail 200 *>&1 | Out-File "$out\status.txt"

# Redact the token before sharing
(Get-Content 'C:\Program Files\GrafanaLabs\PDC\grafana-pdc-agent.xml') `
    -replace '(GCLOUD_PDC_SIGNING_TOKEN" value=")[^"]*', '$1REDACTED' |
    Out-File "$out\service.xml"

Compress-Archive "$out\*" "$out.zip"
Write-Host "Support bundle: $out.zip"
```

Check `service.xml` before sending it anywhere.
