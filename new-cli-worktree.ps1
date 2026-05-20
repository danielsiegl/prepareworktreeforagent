<#
.SYNOPSIS
    Creates or reuses a git worktree and launches a CLI agent (copilot, codex, or claude).

.DESCRIPTION
    Given a repository path and a CLI agent name, this script creates a new git branch
    and worktree (or reuses an existing one) and then starts the selected CLI agent
    inside that worktree directory.

.PARAMETER repopath
    Path to the git repository. Defaults to the current working directory.

.PARAMETER Cli
    The CLI agent to launch. Valid values: copilot, codex, claude.

.PARAMETER CodexInContainer
    When set together with -Cli codex, runs Codex via Docker with the generated worktree bind-mounted to /workspace.

.PARAMETER CodexContainerImage
    Docker image used when -CodexInContainer is set. Defaults to 'my-codex-image'.

.EXAMPLE
    .\new-cli-worktree.ps1 -repopath "C:\repos\myrepo" -Cli copilot

.EXAMPLE
    .\new-cli-worktree.ps1
    # Prompts interactively for CLI agent selection.
#>
param(
    [string]$repopath,
    [ValidateSet("copilot", "codex", "claude")]
    [string]$Cli,
    [switch]$CodexInContainer,
    [string]$CodexContainerImage = "my-codex-image"
)

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

if ([string]::IsNullOrWhiteSpace($repopath)) {
    $repopath = (Get-Location).Path
}

Write-Output "Using git repo $repopath"
Set-Location $repopath

if (-not $Cli) {
    $Cli = Read-CliChoice
}

if ($CodexInContainer -and $Cli -ne "codex") {
    Write-Error "-CodexInContainer can only be used with -Cli codex."
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
$worktreeDir = Join-Path -Path $parentDir -ChildPath "$repoName-$Cli"

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

$cliCommand = switch ($Cli) {
    "codex" { "codex" }
    "claude" { "claude" }
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
    if ($Cli -eq "codex" -and $CodexInContainer) {
        $dockerExecutable = Get-Command -Name docker -ErrorAction SilentlyContinue
        if (-not $dockerExecutable) {
            Write-Error "Docker command 'docker' was not found on PATH."
            exit 1
        }

        $resolvedWorktree = (Resolve-Path -LiteralPath $worktreeToUse).Path
        $dockerArgs = @(
            "run", "--rm", "-it"
        )

        $idExecutable = Get-Command -Name id -ErrorAction SilentlyContinue
        if ($idExecutable) {
            $uid = (& id -u 2>$null)
            $gid = (& id -g 2>$null)
            if ($LASTEXITCODE -eq 0 -and $uid -match '^\d+$' -and $gid -match '^\d+$') {
                $dockerArgs += @("--user", "$uid`:$gid")
            }
            else {
                Write-Warning "Unable to resolve numeric uid/gid via 'id'; running container without --user override."
            }
        }
        else {
            Write-Warning "Command 'id' was not found; running container without --user override."
        }

        $dockerArgs += @(
            "--workdir", "/workspace",
            "--mount", "type=bind,src=$resolvedWorktree,dst=/workspace",
            "--mount", "type=volume,src=codex-home,dst=/home/codex",
            "-e", "HOME=/home/codex"
        )

        if ($env:OPENAI_API_KEY) {
            $dockerArgs += @("-e", "OPENAI_API_KEY")
        }

        $dockerArgs += @($CodexContainerImage, "codex")
        & docker @dockerArgs
    }
    else {
        & $cliCommand
    }
}
finally {
    Pop-Location
}
