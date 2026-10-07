<#
.SYNOPSIS
    Shortcut for 'start-sbx.ps1 -Cli vibe': launches Mistral Vibe inside a Docker
    Sandbox (sbx), without prompting for a CLI agent.

.DESCRIPTION
    Thin wrapper around start-sbx.ps1 that preselects the 'vibe' CLI agent, so you
    don't need to pass '-Cli vibe' or answer the interactive menu. All other behavior
    (sbx auto-install, clone/worktree mode launch, automatic post-run 'git fetch' of the
    agent's branch in clone mode) is identical to start-sbx.ps1 — see its help for
    details:

        Get-Help .\start-sbx.ps1 -Full

    Note: 'sbx' has no officially documented built-in template for 'vibe'. Unless you've
    built a local sandbox image/kit for it (see build-vibe-sbx-kit.ps1 and
    https://docs.docker.com/guides/mistral-vibe-sandbox/), 'sbx run' may fail to resolve
    'vibe' as a plain agent name.

.PARAMETER repopath
    Path to the git repository (or one of its worktrees). Defaults to the current
    working directory. Forwarded to start-sbx.ps1.

.PARAMETER Mode
    How the repository is made available to the sandbox. Valid values: clone, worktree.
    Forwarded to start-sbx.ps1. If omitted, start-sbx.ps1 prompts interactively.

.EXAMPLE
    .\start-vibe-sbx.ps1

.EXAMPLE
    .\start-vibe-sbx.ps1 -repopath "C:\repos\myrepo" -Mode worktree
#>
param(
    [string]$repopath,
    [ValidateSet("clone", "worktree")]
    [string]$Mode
)

$sbxScript = Join-Path -Path $PSScriptRoot -ChildPath "start-sbx.ps1"

if (-not (Test-Path -LiteralPath $sbxScript)) {
    Write-Error "Could not find 'start-sbx.ps1' next to this script at '$sbxScript'."
    exit 1
}

# Only pass '-Mode' through when the caller supplied it, so omitting it still triggers
# start-sbx.ps1's interactive prompt instead of being forwarded as an empty string.
$forwardArgs = @{
    repopath = $repopath
    Cli      = "vibe"
}
if ($Mode) {
    $forwardArgs["Mode"] = $Mode
}

& $sbxScript @forwardArgs
exit $LASTEXITCODE
