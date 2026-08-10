<#
    Configuration file for install.ps1.

    Usage:
        .\install.ps1 -ConfigFile .\examples\config.example.psd1

    Any key here maps to the install.ps1 parameter of the same name. Parameters passed
    explicitly on the command line take precedence over values in this file.

    This file contains a credential. Restrict its ACL and keep it out of source control.
#>
@{
    # ---- Required -------------------------------------------------------------------

    # Grafana Cloud access policy token with the pdc-signing:write scope.
    Token           = 'glc_REPLACE_ME'

    # Numeric stack ID. Grafana Cloud portal -> your stack -> Details.
    HostedGrafanaId = '123456'

    # PDC cluster for your stack, shown on the Private Data Source Connect setup page.
    Cluster         = 'prod-eu-west-2'

    # ---- SSH transport --------------------------------------------------------------

    # auto    : OpenSSH if ssh.exe >= 9.2 is present, otherwise the built-in Go client
    # gossh   : always the built-in Go client (no OpenSSH dependency)
    # openssh : always ssh.exe (fails if below 9.2)
    SshMode         = 'auto'

    # Parallel SSH connections. Only honoured in openssh mode; the Go client uses one.
    # The cap is 50 across every agent on your stack.
    Connections     = 1

    # ---- Access control -------------------------------------------------------------

    # Restrict which endpoints Grafana Cloud may reach through the tunnel. Omit or leave
    # empty to allow all. Entries are host:port.
    # PermitDomains = @('mysql.corp.local:3306', 'postgres.corp.local:5432')

    # ---- Operations -----------------------------------------------------------------

    LogLevel        = 'info'

    # Prometheus metrics endpoint. Loopback by default; widen it only if something on
    # another host needs to scrape this agent.
    MetricsAddr     = '127.0.0.1:8090'

    # Pin a release instead of tracking latest, e.g. 'v0.0.63'.
    AgentVersion    = 'latest'

    # ---- Paths ----------------------------------------------------------------------

    # InstallDir  = 'C:\Program Files\GrafanaLabs\PDC'
    # DataDir     = 'C:\ProgramData\GrafanaLabs\PDC'
    # ServiceName = 'grafana-pdc-agent'
}
