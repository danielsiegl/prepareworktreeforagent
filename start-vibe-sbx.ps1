<#
.SYNOPSIS
    Shortcut for 'start-sbx.ps1 -Cli vibe': launches Mistral Vibe inside a Docker
    Sandbox (sbx) using clone mode, without prompting for a CLI agent.

.DESCRIPTION
    Thin wrapper around start-sbx.ps1 that preselects the 'vibe' CLI agent, so you
    don't need to pass '-Cli vibe' or answer the interactive menu. All other behavior
    (sbx auto-install, clone-mode launch, automatic post-run 'git fetch' of the agent's
    branch) is identical to start-sbx.ps1 — see its help for details:

        Get-Help .\start-sbx.ps1 -Full

    Note: 'sbx' has no officially documented built-in template for 'vibe'. Unless you've
    built a local sandbox image/kit for it (see build-vibe-sbx-kit.ps1 and
    https://docs.docker.com/guides/mistral-vibe-sandbox/), 'sbx run' may fail to resolve
    'vibe' as a plain agent name.

.PARAMETER repopath
    Path to the git repository (or one of its worktrees). Defaults to the current
    working directory. Forwarded to start-sbx.ps1.

.EXAMPLE
    .\start-vibe-sbx.ps1

.EXAMPLE
    .\start-vibe-sbx.ps1 -repopath "C:\repos\myrepo"
#>
param(
    [string]$repopath
)

$sbxScript = Join-Path -Path $PSScriptRoot -ChildPath "start-sbx.ps1"

if (-not (Test-Path -LiteralPath $sbxScript)) {
    Write-Error "Could not find 'start-sbx.ps1' next to this script at '$sbxScript'."
    exit 1
}

& $sbxScript -repopath $repopath -Cli vibe
exit $LASTEXITCODE
