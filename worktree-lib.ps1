<#
.SYNOPSIS
    Shared helper functions used by new-cli-worktree.ps1, start-sbx.ps1, and
    build-vibe-sbx-kit.ps1.

.DESCRIPTION
    Dot-source this file to get access to Normalize-PathForComparison,
    Get-RegisteredWorktrees, and New-Worktree-ForBranch (git worktree create/reuse
    logic shared by new-cli-worktree.ps1 and start-sbx.ps1), plus Get-SpecImageTag and
    Test-SbxTemplateLoaded (sbx kit image-tag helpers shared by start-sbx.ps1 and
    build-vibe-sbx-kit.ps1). Kept in one place so all scripts stay in sync.
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

function Get-SpecImageTag {
    # Extracts the 'sandbox.image:' value from an sbx kit's spec.yaml without a full
    # YAML parser (the file has a known, simple shape). Shared by start-sbx.ps1 (to
    # find the vibe kit's image tag before running it) and build-vibe-sbx-kit.ps1 (to
    # derive the tag to build/load from the checked-in spec.yaml, instead of taking it
    # as a script parameter).
    param(
        [Parameter(Mandatory = $true)][string]$SpecPath
    )

    if (-not (Test-Path -LiteralPath $SpecPath)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $SpecPath) {
        if ($line -match '^\s*image:\s*(\S+)\s*$') {
            return $Matches[1]
        }
    }
    return $null
}

function Test-SbxTemplateLoaded {
    # 'sbx' keeps its own private image store (separate from Docker Desktop's regular
    # image list) populated via 'sbx template load'. Checking only whether the kit's
    # spec.yaml exists on disk is not enough -- the store can be emptied independently
    # (e.g. 'sbx template rm', a Docker Desktop reset, or a fresh machine) while the kit
    # files stay on disk, which reproduces the old "403 Forbidden: pull failed" error.
    # 'sbx template ls' prints: REPOSITORY  TAG  IMAGE ID  FLAVOR  CREATED
    param(
        [Parameter(Mandatory = $true)][string]$ImageTag
    )

    $repo, $tag = $ImageTag -split ':', 2
    if (-not $tag) { $tag = "latest" }

    $lines = & sbx template ls 2>$null
    foreach ($line in $lines) {
        $cols = $line -split '\s+'
        if ($cols.Count -lt 2) { continue }
        # The store namespaces local builds under a registry-style prefix, e.g.
        # 'docker.io/library/sbx-mistral-vibe' for a plain 'sbx-mistral-vibe' tag, so
        # match on the repository *suffix* rather than requiring an exact string match.
        if (($cols[0] -eq $repo -or $cols[0].EndsWith("/$repo")) -and $cols[1] -eq $tag) {
            return $true
        }
    }
    return $false
}
