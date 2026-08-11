# PDC on Windows

[![test](https://github.com/colinedwardwood/pdc-on-windows/actions/workflows/test.yml/badge.svg)](https://github.com/colinedwardwood/pdc-on-windows/actions/workflows/test.yml)

Deploy the [Grafana Private Data Source Connect](https://grafana.com/docs/grafana-cloud/observe-and-act/connect-externally-hosted/private-data-source-connect/configure-pdc/)
agent as a proper Windows service — the equivalent of running it under systemd on Linux.

Starts on boot, restarts on failure with a backoff, rotates its own logs, runs under an
account you choose, and shows up in `services.msc`.

```powershell
.\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-eu-west-2'
```

---

## Why a wrapper is needed

`pdc.exe` is a plain console program. It does not implement the Windows Service Control
Manager protocol, so registering it directly:

```powershell
sc.exe create grafana-pdc-agent binPath= "C:\...\pdc.exe"   # don't do this
```

produces **"Error 1053: The service did not respond to the start or control request in a
timely fashion"**. The SCM starts the process, waits for it to check in, never hears back,
and kills it.

This repo uses [WinSW](https://github.com/winsw/winsw), a small supervisor that speaks SCM
and manages `pdc.exe` as a child process. The mapping to a systemd unit is close:

| systemd | WinSW |
| --- | --- |
| `Restart=always` | `<onfailure action="restart"/>`, three escalating delays |
| `RestartSec=10` | `delay="10 sec"` |
| `WantedBy=multi-user.target` | `<startmode>Automatic</startmode>` |
| `After=network-online.target` | `<delayedAutoStart/>` |
| `User=` / `Group=` | `<serviceaccount>` |
| `Environment=` | `<env name= value=/>` |
| `journalctl -u` | rotating logs in `C:\ProgramData\GrafanaLabs\PDC\logs` |

---

## The OpenSSH problem, and how this avoids it

The PDC agent normally shells out to `ssh.exe`, and Grafana requires **OpenSSH 9.2 or
newer**. That is a real obstacle on Windows: stock Windows Server 2022 ships OpenSSH
**8.1p1**, well below the minimum.

Don't assume, though — check the box you are actually deploying to:

```powershell
ssh -V
```

A patched or managed image may be far ahead of the stock build. GitHub's `windows-2022`
runner image, for instance, carries `OpenSSH_for_Windows_9.5p2`, not the 8.1p1 that
Server 2022 ships with. The installer detects the real version at install time rather
than inferring it from the OS version.

OpenSSH is installed by default only from Windows Server 2025 onward; on earlier
releases it is an optional feature, and the in-box build is generally too old.
Microsoft's newer builds are published on the
[Win32-OpenSSH releases page](https://github.com/PowerShell/Win32-OpenSSH/releases), but
every one of them — including 9.8 and 10.0 — is tagged **"Preview"**, which is awkward to
push through enterprise change control.

The agent has a second, less-documented transport: **`-use-gossh`**, a pure-Go SSH client
built into the binary. Combined with the fact that the agent already generates its
ed25519 key pair in Go rather than shelling out to `ssh-keygen`, this means the agent can
run on Windows with **no external dependency at all** — no OpenSSH, no PuTTY, nothing.

`install.ps1` defaults to `-SshMode auto`:

- `ssh.exe` present and **>= 9.2** → uses OpenSSH
- otherwise → uses the built-in Go client

Force it either way with `-SshMode gossh` or `-SshMode openssh`.

### Trade-offs of the Go client

| | OpenSSH | Go client (`-use-gossh`) |
| --- | --- | --- |
| External dependency | ssh.exe >= 9.2 | none |
| `-connections` (parallel tunnels) | supported | **ignored — always 1** |
| Endpoint restriction | `-ssh-flag "-o PermitRemoteOpen=..."` | `-permit-domains` |
| Documented by Grafana | yes | not really |

If you need more than one tunnel for throughput, you need OpenSSH 9.2+. Otherwise the Go
client is the path of least resistance on Windows, and it is what this installer picks by
default on anything older than Server 2025.

---

## Requirements

- Windows Server 2016+ or Windows 10 1607+, x64 / x86 / ARM64
- Windows PowerShell 5.1 (in-box) or PowerShell 7+
- An elevated PowerShell session
- Outbound HTTPS (443) and SSH (22) to your PDC cluster
- A Grafana Cloud access policy token with the **`pdc-signing:write`** scope

No .NET install is needed. The installer uses the ~650 KB WinSW `.NET461` build, and
.NET Framework 4.6.2+ has been in-box since Server 2016 / Windows 10 1607.

---

## Install

Find your **stack ID** and **cluster** on the Private Data Source Connect page in your
Grafana Cloud stack.

```powershell
# Simplest case
.\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-eu-west-2'

# Restrict which endpoints Grafana Cloud may reach, and turn up logging
.\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-us-east-0' `
    -PermitDomains 'mysql.corp.local:3306','postgres.corp.local:5432' `
    -LogLevel debug

# Run under a domain service account instead of LocalSystem
$cred = Get-Credential CORP\svc-pdc
.\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-eu-west-2' `
    -ServiceAccount $cred

# Keep settings in a file instead of on the command line
Copy-Item .\examples\config.example.psd1 .\pdc.config.psd1
# edit pdc.config.psd1
.\install.ps1 -ConfigFile .\pdc.config.psd1
```

Re-running is safe: pass `-Force` to reinstall over an existing service. The generated
SSH key pair in the data directory is preserved.

### Key parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `-Token` | *required* | Access policy token, `pdc-signing:write` scope |
| `-HostedGrafanaId` | *required* | Numeric stack ID |
| `-Cluster` | *required* | e.g. `prod-eu-west-2` |
| `-SshMode` | `auto` | `auto` / `gossh` / `openssh` |
| `-Connections` | `1` | OpenSSH mode only; 50 max across all your agents |
| `-PermitDomains` | *(all)* | `host:port` entries |
| `-MetricsAddr` | `127.0.0.1:8090` | Prometheus endpoint |
| `-LogLevel` | `info` | `debug` maps to `ssh -vvv` |
| `-AgentVersion` | `latest` | Pin with e.g. `v0.0.63` |
| `-ServiceAccount` | LocalSystem | `[pscredential]` |
| `-RegionFormat` | off | Newer `...-api.<cluster>.<domain>` URL scheme |
| `-InstallDir` | `%ProgramFiles%\GrafanaLabs\PDC` | |
| `-DataDir` | `%ProgramData%\GrafanaLabs\PDC` | Keys and logs |
| `-Force` | off | Reinstall over an existing service |

### Air-gapped install

Download the two artifacts on a connected machine, copy them across, and point the
installer at them:

```powershell
.\install.ps1 -Token 'glc_...' -HostedGrafanaId '123456' -Cluster 'prod-eu-west-2' `
    -AgentArchive 'D:\pdc-agent_Windows_x86_64.zip' `
    -WinSwBinary  'D:\WinSW.NET461.exe'
```

- Agent: <https://github.com/grafana/pdc-agent/releases/latest>
- WinSW: <https://github.com/winsw/winsw/releases/tag/v2.12.0> (`WinSW.NET461.exe`)

---

## Layout

```
C:\Program Files\GrafanaLabs\PDC\
    pdc.exe                     the agent
    grafana-pdc-agent.exe       WinSW wrapper
    grafana-pdc-agent.xml       service definition (contains the token; ACL'd)

C:\ProgramData\GrafanaLabs\PDC\
    keys\
        grafana_pdc             generated ed25519 private key
        grafana_pdc.pub
        grafana_pdc-cert.pub    short-lived certificate, auto-renewed
        known_hosts
    logs\
        grafana-pdc-agent.out.log    agent output, rotated daily / at 10 MB
        grafana-pdc-agent.err.log
        grafana-pdc-agent.wrapper.log
```

---

## Operating it

```powershell
# Health check: service, connectivity, certificate, metrics, recent logs
.\Get-PdcAgentStatus.ps1

# Standard service control
Get-Service grafana-pdc-agent
Restart-Service grafana-pdc-agent
Stop-Service grafana-pdc-agent

# Follow the log (the systemd 'journalctl -fu' equivalent)
Get-Content 'C:\ProgramData\GrafanaLabs\PDC\logs\grafana-pdc-agent.out.log' -Tail 50 -Wait
```

A healthy startup logs `This is Grafana Private Datasource Connect!` — but **only in
OpenSSH mode**. The Go client connects silently; use `Get-PdcAgentStatus.ps1`, which knows
the difference and checks the right signal for each transport.

### Changing configuration

Edit `grafana-pdc-agent.xml` and restart the service, or re-run `install.ps1 -Force` with
new parameters.

### Monitoring

The agent exposes Prometheus metrics on `-MetricsAddr` (loopback by default):

| Metric | Meaning |
| --- | --- |
| `pdc_agent_agent_info` | version, SSH version, stack ID |
| `pdc_agent_ssh_connections` | open tunnels — **OpenSSH mode only** |
| `pdc_agent_ssh_time_to_connect_seconds` | connection latency; `connection="gossh"` in Go mode |
| `pdc_agent_ssh_restarts_total` | reconnection churn |
| `pdc_agent_tcp_connections_total` | per-target success/failure to your data sources |

To scrape it with Grafana Alloy, point a `prometheus.scrape` at
`127.0.0.1:8090` and tail `C:\ProgramData\GrafanaLabs\PDC\logs\*.out.log` with
`loki.source.file`.

---

## Security notes

- The signing token is passed to the agent as an **environment variable**, not a
  command-line argument, so it does not appear in the process list (`Get-Process`,
  `wmic process`, Task Manager).
- The token does still sit in `grafana-pdc-agent.xml`. The installer breaks ACL
  inheritance on that file and on the key directory, leaving access to **SYSTEM and
  Administrators** only. Anyone with administrative rights on the host can read it — as is
  true of any secret on any machine.
- Breaking inheritance on the key directory matters for a second reason: OpenSSH refuses
  to use a private key that other users can read. Go's `os.WriteFile(…, 0600)` does not
  translate to a Windows ACL, so without this the key would inherit `BUILTIN\Users: Read`
  and `ssh.exe` would reject it.
- With `-ServiceAccount`, the password is written to the XML only for the duration of
  registration, then stripped. The credential lives on in the SCM's protected LSA store.
- The account is granted **Log on as a service** automatically.
- Prefer a token scoped to `pdc-signing:write` and nothing else.

---

## Uninstall

```powershell
.\uninstall.ps1                 # remove service and binaries, keep keys and logs
.\uninstall.ps1 -RemoveData     # remove everything
```

---

## Troubleshooting

Start with `.\Get-PdcAgentStatus.ps1`. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
for specific failures.

---

## Testing

CI runs the full install/uninstall cycle on **Server 2022** and **Server 2025** on every
push. Because GitHub patches OpenSSH on both images, neither one presents a version below
9.2, so a separate job stubs `ssh.exe` to pin the 9.2 boundary exactly — 8.1 and 9.1 must
select gossh, 9.2 and 9.8 must select OpenSSH, and a missing `ssh.exe` must select gossh.
That tests the installer's decision logic rather than whatever the runner image happens
to ship. CI asserts that:

- auto-detection picks the transport matching the actual OpenSSH version
- the service registers with `StartMode=Auto` and restart-on-failure actions
- the key path is forward-slash normalised
- the token is in `<env>`, never in `<arguments>`
- ACL inheritance is broken on the key store and service XML, with no access for
  `Users` / `Everyone` / `Authenticated Users`
- WinSW parses the generated config and log rotation is active
- `-Connections` is suppressed in gossh mode, and `PermitRemoteOpen` is formatted
  correctly in OpenSSH mode
- requesting `-SshMode openssh` below 9.2 is refused rather than half-installed
- `uninstall.ps1 -RemoveData` leaves nothing behind

The `live` job connects to a real Grafana Cloud stack when the `PDC_TOKEN`,
`PDC_STACK_ID` and `PDC_CLUSTER` repository secrets are set, and is skipped otherwise.

---

## Notes on the agent's behaviour

A couple of things worth knowing if you deviate from this installer:

- **Use forward slashes in `-ssh-key-file`.** `pkg/ssh/ssh.go` and
  `pkg/ssh/keymanager.go` import Go's `path` package, not `path/filepath`, so the key
  directory is derived by splitting on `/`. A normal Windows backslash path collapses that
  directory to an empty string: `known_hosts` is written to the working directory and
  `UserKnownHostsFile` is passed to `ssh.exe` as `/known_hosts`. This installer normalises
  the path.
- **The default key location is user-relative.** It resolves under `os.UserHomeDir()`,
  which for a LocalSystem service is
  `C:\Windows\System32\config\systemprofile\.ssh\`. This installer sets an explicit path
  under `ProgramData` instead.
- **The success banner reads "Datasource", one word**, in the source
  (`ssh.SuccessfulConnectionResponse`), even though the published documentation renders it
  "Data Source". Match both if you are grepping for it.
- **The agent's own OpenSSH version check silently fails on Windows.** `ssh -V` on
  Windows emits a trailing `\r`, which the agent's parser rejects, so it logs
  `unable to retrieve SSH version for validation / failed to parse OpenSSH version`
  and carries on. Observed on Server 2025 with OpenSSH 9.5p2:

  ```
  level=warn caller=ssh.go:475 msg="unable to retrieve SSH version for validation"
      err="failed to parse OpenSSH version"
  ```

  The practical effect is that the built-in 9.2 enforcement does not actually protect you
  on Windows — the agent will happily start against an OpenSSH that is too old and then
  fail later in a less obvious way. `install.ps1` does its own version detection up front
  for exactly this reason.

---

## References

- [Configure PDC](https://grafana.com/docs/grafana-cloud/observe-and-act/connect-externally-hosted/private-data-source-connect/configure-pdc/)
- [grafana/pdc-agent](https://github.com/grafana/pdc-agent)
- [WinSW](https://github.com/winsw/winsw) · [XML reference](https://github.com/winsw/winsw/blob/v2.12.0/doc/xmlConfigFile.md)
- [Win32-OpenSSH releases](https://github.com/PowerShell/Win32-OpenSSH/releases)
