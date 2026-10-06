<#
.SYNOPSIS
    Creates or reuses a git worktree and launches a CLI agent (copilot, codex, or claude)
    inside a Docker Sandbox (sbx) using clone mode for best performance.

.DESCRIPTION
    Given a repository path and a CLI agent name, this script creates a new git branch
    and worktree (or reuses an existing one) on the host, then starts the selected CLI
    agent inside a Docker Sandbox (`sbx`) in clone mode. In clone mode, the host worktree
    is mounted read-only and the agent does its real work on a private clone that lives
    on the sandbox's own (Linux) filesystem. This avoids the slow file I/O that occurs
    when an agent/container repeatedly reads and writes a Windows (NTFS) path through a
    filesystem passthrough.

    If the `sbx` CLI is not installed, the script attempts to install it via winget
    (`winget install -h Docker.sbx`).

.PARAMETER repopath
    Path to the git repository. Defaults to the current working directory.

.PARAMETER Cli
    The CLI agent to launch. Valid values: copilot, codex, claude.

.EXAMPLE
    .\new-cli-worktree-sbx.ps1 -repopath "C:\repos\myrepo" -Cli copilot

.EXAMPLE
    .\new-cli-worktree-sbx.ps1
    # Prompts interactively for CLI agent selection.

.NOTES
    After the agent finishes its work inside the sandbox clone, fetch the results back
    to the host with:
        git fetch sandbox-<branch>
        git log sandbox-<branch>/<branch>
    or ask the agent to push the branch to origin directly.
#>
param(
    [string]$repopath,
    [ValidateSet("copilot", "codex", "claude")]
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
    $options = @("copilot", "codex", "claude")
    Write-Host ""
    Write-Host "Select CLI agent:" -ForegroundColor Cyan
    Write-Host "  1) copilot"
    Write-Host "  2) codex"
    Write-Host "  3) claude"
    Write-Host ""

    while ($true) {
        Write-Host -NoNewline "Enter 1, 2, or 3: "
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Write-Host $key.Character

        switch ($key.Character) {
            '1' { return $options[0] }
            '2' { return $options[1] }
            '3' { return $options[2] }
            default { Write-Host "Please press 1, 2, or 3." -ForegroundColor Yellow }
        }
    }
}

function Test-SbxInstalled {
    return [bool](Get-Command -Name "sbx" -ErrorAction SilentlyContinue)
}

function Install-SbxIfMissing {
    if (Test-SbxInstalled) {
        return $true
    }

    Write-Host "The 'sbx' CLI (Docker Sandboxes) was not found on PATH. Attempting to install it..." -ForegroundColor Yellow

    $winget = Get-Command -Name "winget" -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Error "winget was not found on PATH, so 'sbx' could not be installed automatically. Install it manually: https://docs.docker.com/ai/sandboxes/install/"
        return $false
    }

    & winget install -h Docker.sbx
    $installExitCode = $LASTEXITCODE

    if (Test-SbxInstalled) {
        Write-Host "'sbx' installed successfully." -ForegroundColor Green
        return $true
    }

    if ($installExitCode -ne 0) {
        Write-Error "Failed to install 'sbx' via winget (exit code $installExitCode)."
    }
    else {
        Write-Warning "'sbx' install command completed, but 'sbx' is still not visible on PATH in this process."
    }
    Write-Warning "Please restart your shell (so PATH changes take effect) and re-run this script."
    return $false
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

if (-not (Install-SbxIfMissing)) {
    exit 1
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
$parentDir = Split-Path -Path $repoRoot -Parent
$repoName = Split-Path -Path $repoRoot -Leaf
$worktreeDir = Join-Path -Path $parentDir -ChildPath "$repoName-$newBranch"

function Normalize-PathForComparison {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\\').ToLowerInvariant()
}

function Get-RegisteredWorktrees {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $porcelain = & git -C $RepoRoot worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $entries = @()
    $current = $null
    foreach ($line in $porcelain) {
        if ($line.StartsWith("worktree ")) {
            if ($null -ne $current) {
                $entries += [pscustomobject]$current
            }
            $current = @{
                Path = $line.Substring(9).Trim()
                Branch = $null
            }
            continue
        }

        if ($null -ne $current -and $line.StartsWith("branch ")) {
            $current.Branch = $line.Substring(7).Trim()
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line) -and $null -ne $current) {
            $entries += [pscustomobject]$current
            $current = $null
        }
    }

    if ($null -ne $current) {
        $entries += [pscustomobject]$current
    }

    return $entries
}

$registeredWorktrees = Get-RegisteredWorktrees -RepoRoot $repoRoot
$branchRef = "refs/heads/$newBranch"
$normalizedTarget = Normalize-PathForComparison -Path $worktreeDir

$existingWorktreeByPath = $registeredWorktrees |
    Where-Object { (Normalize-PathForComparison -Path $_.Path) -eq $normalizedTarget } |
    Select-Object -First 1

$existingWorktreeByBranch = $registeredWorktrees |
    Where-Object { $_.Branch -eq $branchRef } |
    Select-Object -First 1

$worktreeToUse = $null

if ($existingWorktreeByPath) {
    $worktreeToUse = $existingWorktreeByPath.Path
    Write-Host "Reusing existing worktree at '$worktreeToUse'."
}
elseif (Test-Path -LiteralPath $worktreeDir) {
    Write-Error "Target directory exists but is not a registered git worktree: $worktreeDir"
    exit 1
}
elseif ($existingWorktreeByBranch) {
    $worktreeToUse = $existingWorktreeByBranch.Path
    Write-Host "Reusing existing worktree for '$newBranch' at '$worktreeToUse'."
}
else {
    & git -C $repoRoot show-ref --verify --quiet "refs/heads/$newBranch"
    $branchExists = ($LASTEXITCODE -eq 0)

    if ($branchExists) {
        Write-Host "Branch exists, creating worktree on '$newBranch' at '$worktreeDir'."
        & git -C $repoRoot worktree add "$worktreeDir" "$newBranch"
    }
    else {
        Write-Host "Creating branch '$newBranch' from '$currentBranch' and adding worktree at '$worktreeDir'."
        & git -C $repoRoot worktree add -b "$newBranch" "$worktreeDir" "$currentBranch"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create worktree."
        exit 1
    }

    $worktreeToUse = $worktreeDir
}

Write-Host "Done."
Write-Host "Repository : $repoRoot"
Write-Host "Branch     : $newBranch"
Write-Host "Worktree   : $worktreeToUse"

$sandboxName = ($newBranch -replace '[^a-zA-Z0-9_.-]', '-')

Write-Host "Starting '$Cli' in Docker Sandbox (clone mode) '$sandboxName' for worktree '$worktreeToUse'..."
Write-Host "Note: the agent works on a private in-sandbox clone. Host files stay read-only until you run:" -ForegroundColor Cyan
Write-Host "      git fetch sandbox-$sandboxName" -ForegroundColor Cyan

& sbx run --clone --name $sandboxName $Cli $worktreeToUse
$sbxExitCode = $LASTEXITCODE

if ($sbxExitCode -ne 0) {
    Write-Error "'sbx run' exited with code $sbxExitCode."
    exit $sbxExitCode
}
