<#
.SYNOPSIS
    Creates or reuses a git worktree and launches a CLI agent (copilot, codex, claude, or vibe).

.DESCRIPTION
    Given a repository path and a CLI agent name, this script creates a new git branch
    and worktree (or reuses an existing one) and then starts the selected CLI agent
    inside that worktree directory.

.PARAMETER repopath
    Path to the git repository. Defaults to the current working directory.

.PARAMETER Cli
    The CLI agent to launch. Valid values: copilot, codex, claude, vibe.

.EXAMPLE
    .\new-cli-worktree.ps1 -repopath "C:\repos\myrepo" -Cli copilot

.EXAMPLE
    .\new-cli-worktree.ps1
    # Prompts interactively for CLI agent selection.
#>
param(
    [string]$repopath,
    [ValidateSet("copilot", "codex", "claude", "vibe")]
    [string]$Cli
)

function Show-Rabbit {
    Write-Host @"
 (\_/)
 ('.')
 (")(")
"@
}

function Show-Cat {
    Write-Host @"
  /\_/\
 ( o.o )
  > ^ <
"@
}

function Show-RandomMascot {
    if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) {
        Show-Cat
    }
    else {
        Show-Rabbit
    }
}

function Read-CliChoice {
    $options = @("copilot", "codex", "claude", "vibe")
    $availableOptions = @{}
    foreach ($option in $options) {
        $availableOptions[$option] = [bool](Get-Command -Name $option -ErrorAction SilentlyContinue)
    }

    Write-Host ""
    Write-Host "Select CLI agent:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $options.Count; $i++) {
        $label = $options[$i]
        if (-not $availableOptions[$label]) {
            $label += " (not available)"
        }
        Write-Host "  $($i + 1)) $label"
    }
    Write-Host ""

    if (-not ($availableOptions.Values -contains $true)) {
        Write-Error "None of the supported CLI agents are available on PATH."
        exit 1
    }

    while ($true) {
        Write-Host -NoNewline "Enter 1, 2, 3, or 4: "
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Write-Host $key.Character

        switch ($key.Character) {
            '1' { $selectedOption = $options[0] }
            '2' { $selectedOption = $options[1] }
            '3' { $selectedOption = $options[2] }
            '4' { $selectedOption = $options[3] }
            default { Write-Host "Please press 1, 2, 3, or 4." -ForegroundColor Yellow }
        }

        if ($key.Character -notin @('1', '2', '3', '4')) {
            continue
        }
        if ($availableOptions[$selectedOption]) {
            return $selectedOption
        }
        Write-Host "$selectedOption is not available on PATH. Choose an installed CLI agent." -ForegroundColor Yellow
    }
}

if ([string]::IsNullOrWhiteSpace($repopath)) {
    $repopath = (Get-Location).Path
}

Show-RandomMascot
Write-Output "Using git repo $repopath"
Set-Location $repopath

if (-not $Cli) {
    $Cli = Read-CliChoice
}


$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    Write-Error "Current directory is not inside a git repository."
    exit 1
}

$repoRoot = $repoRoot.Trim()
$currentBranch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $currentBranch) {
    Write-Error "Failed to determine current branch."
    exit 1
}

$currentBranch = $currentBranch.Trim()
if ($currentBranch -eq "HEAD") {
    Write-Error "Repository is in detached HEAD state. Check out a branch first."
    exit 1
}

$newBranch = "$currentBranch-$Cli"

# Shared with start-sbx.ps1: Normalize-PathForComparison, Get-RegisteredWorktrees,
# and New-Worktree-ForBranch.
. (Join-Path -Path $PSScriptRoot -ChildPath "worktree-lib.ps1")

$worktreeToUse = New-Worktree-ForBranch -RepoRoot $repoRoot -CurrentBranch $currentBranch -NewBranch $newBranch
if (-not $worktreeToUse) {
    exit 1
}

Write-Host "Done."
Write-Host "Repository : $repoRoot"
Write-Host "Branch     : $newBranch"
Write-Host "Worktree   : $worktreeToUse"

$cliCommand = switch ($Cli) {
    "codex" { "codex" }
    "claude" { "claude" }
    "vibe" { "vibe" }
    default { "copilot" }
}
$cliExecutable = Get-Command -Name $cliCommand -ErrorAction SilentlyContinue

if (-not $cliExecutable) {
    Write-Warning "CLI command '$cliCommand' was not found on PATH."
    Write-Warning "Worktree is ready at: $worktreeToUse"
    exit 0
}

Write-Host "Starting '$cliCommand' in '$worktreeToUse'..."
Push-Location -LiteralPath $worktreeToUse
try {
    & $cliCommand
}
finally {
    Pop-Location
}
