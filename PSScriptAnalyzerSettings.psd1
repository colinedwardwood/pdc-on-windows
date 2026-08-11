<#
    PSScriptAnalyzer configuration.

    CI treats every remaining Error and Warning as a build failure, so anything excluded
    here is a deliberate, justified decision rather than accumulated noise.
#>
@{
    ExcludeRules = @(
        # PSAvoidUsingWriteHost
        #
        # These are interactive console tools, not library functions. install.ps1 and
        # Get-PdcAgentStatus.ps1 report progress and health to a human operator using
        # colour to distinguish OK / WARN / FAIL, which is precisely what Write-Host is
        # for. Switching to Write-Output would put that chatter on the success stream and
        # corrupt the return value of anything that dot-sources or captures these
        # scripts; Write-Information would require operators to pass
        # -InformationAction Continue to see any output at all.
        #
        # The one real consequence -- Write-Host writes to the information stream (6) in
        # PowerShell 7, so `2>&1` does not capture it -- is handled where it matters:
        # CI and the support-bundle snippet in docs/TROUBLESHOOTING.md both use `*>&1`.
        'PSAvoidUsingWriteHost'
    )
}
