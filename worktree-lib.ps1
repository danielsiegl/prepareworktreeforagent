<#
.SYNOPSIS
    Shared git-worktree helper functions used by new-cli-worktree.ps1 and start-sbx.ps1.

.DESCRIPTION
    Dot-source this file to get access to Normalize-PathForComparison,
    Get-RegisteredWorktrees, and New-Worktree-ForBranch. These functions create (or reuse)
    a git branch/worktree in a sibling directory next to a repository root, and are kept
    in one place so both scripts stay in sync.
#>

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

function New-Worktree-ForBranch {
    # Creates (or reuses) a git branch/worktree named '$NewBranch' in a sibling directory
    # next to '$RepoRoot' (e.g. '<repo>-<new-branch>'). Returns the worktree path on
    # success, or $null (after writing an error) on failure.
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$CurrentBranch,
        [Parameter(Mandatory = $true)][string]$NewBranch
    )

    $parentDir = Split-Path -Path $RepoRoot -Parent
    $repoName = Split-Path -Path $RepoRoot -Leaf
    $worktreeDir = Join-Path -Path $parentDir -ChildPath "$repoName-$NewBranch"

    $registeredWorktrees = Get-RegisteredWorktrees -RepoRoot $RepoRoot
    $branchRef = "refs/heads/$NewBranch"
    $normalizedTarget = Normalize-PathForComparison -Path $worktreeDir

    $existingWorktreeByPath = $registeredWorktrees |
        Where-Object { (Normalize-PathForComparison -Path $_.Path) -eq $normalizedTarget } |
        Select-Object -First 1

    $existingWorktreeByBranch = $registeredWorktrees |
        Where-Object { $_.Branch -eq $branchRef } |
        Select-Object -First 1

    if ($existingWorktreeByPath) {
        Write-Host "Reusing existing worktree at '$($existingWorktreeByPath.Path)'."
        return $existingWorktreeByPath.Path
    }

    if (Test-Path -LiteralPath $worktreeDir) {
        Write-Error "Target directory exists but is not a registered git worktree: $worktreeDir"
        return $null
    }

    if ($existingWorktreeByBranch) {
        Write-Host "Reusing existing worktree for '$NewBranch' at '$($existingWorktreeByBranch.Path)'."
        return $existingWorktreeByBranch.Path
    }

    & git -C $RepoRoot show-ref --verify --quiet "refs/heads/$NewBranch"
    $branchExists = ($LASTEXITCODE -eq 0)

    if ($branchExists) {
        Write-Host "Branch exists, creating worktree on '$NewBranch' at '$worktreeDir'."
        # Redirect stdout through Write-Host so the function (which is called for its
        # return value) doesn't leak git's own output into that return value.
        & git -C $RepoRoot worktree add "$worktreeDir" "$NewBranch" 2>&1 | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host "Creating branch '$NewBranch' from '$CurrentBranch' and adding worktree at '$worktreeDir'."
        & git -C $RepoRoot worktree add -b "$NewBranch" "$worktreeDir" "$CurrentBranch" 2>&1 | ForEach-Object { Write-Host "  $_" }
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create worktree."
        return $null
    }

    return $worktreeDir
}
