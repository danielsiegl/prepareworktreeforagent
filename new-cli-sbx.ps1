<#
.SYNOPSIS
    Launches a CLI agent (copilot, codex, or claude) inside a Docker Sandbox (sbx)
    using clone mode for isolation and good performance.

.DESCRIPTION
    Given a repository path and a CLI agent name, this script starts the selected CLI
    agent inside a Docker Sandbox (`sbx`) in clone mode. In clone mode, `sbx` mounts
    your repository read-only and the agent does its real work on a private clone that
    lives on the sandbox's own (Linux) filesystem. This avoids the slow file I/O that
    occurs when an agent/container repeatedly reads and writes a Windows (NTFS) path
    through a filesystem passthrough, and it gives the agent its own isolated branch/
    worktree inside the sandbox clone — so no git worktree needs to be created on the
    host.

    `sbx --clone` requires the *main* repository working directory (not a linked git
    worktree). If `-repopath` points at a linked worktree, the script automatically
    resolves it to the main repository root.

    If the `sbx` CLI is not installed, the script attempts to install it via winget
    (`winget install -h Docker.sbx`).

.PARAMETER repopath
    Path to the git repository (or one of its worktrees). Defaults to the current
    working directory.

.PARAMETER Cli
    The CLI agent to launch. Valid values: copilot, codex, claude.

.EXAMPLE
    .\new-cli-sbx.ps1 -repopath "C:\repos\myrepo" -Cli copilot

.EXAMPLE
    .\new-cli-sbx.ps1
    # Prompts interactively for CLI agent selection.

.NOTES
    Once the sandbox starts, ask the agent to create a branch before it starts editing,
    e.g. "Create a branch <branch-name> and make the changes." After the agent is done,
    fetch its branch back to the host with:
        git fetch sandbox-<name>
        git log sandbox-<name>/<branch-name>
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

function Update-SessionPathFromRegistry {
    # winget updates the Machine/User PATH in the registry, but the current PowerShell
    # process keeps the PATH it started with. Re-read both and merge them into $env:PATH
    # so a newly installed CLI (e.g. sbx) can be found without restarting the shell.
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $combined = @($machinePath, $userPath, $env:Path) -join ';'

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $deduped = @()
    foreach ($entry in $combined -split ';') {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($seen.Add($entry)) {
            $deduped += $entry
        }
    }

    $env:Path = $deduped -join ';'
}

function Find-SbxExecutable {
    # Fallback for when the registry PATH hasn't been updated yet either: winget typically
    # installs CLI shims under the WindowsApps links folder or the package's own install dir.
    $candidateDirs = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages")
    )

    foreach ($dir in $candidateDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $found = Get-ChildItem -LiteralPath $dir -Filter "sbx.exe" -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return $null
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

    # winget only updates PATH in the registry; refresh this process's PATH so we can
    # pick up 'sbx' immediately instead of requiring the user to restart their shell.
    Update-SessionPathFromRegistry

    if (Test-SbxInstalled) {
        Write-Host "'sbx' installed successfully." -ForegroundColor Green
        return $true
    }

    $sbxPath = Find-SbxExecutable
    if ($sbxPath) {
        Write-Host "'sbx' installed successfully (found at '$sbxPath')." -ForegroundColor Green
        $sbxDir = Split-Path -Path $sbxPath -Parent
        if ($env:Path -notlike "*$sbxDir*") {
            $env:Path = "$env:Path;$sbxDir"
        }
        return $true
    }

    if ($installExitCode -ne 0) {
        Write-Error "Failed to install 'sbx' via winget (exit code $installExitCode)."
    }
    else {
        Write-Warning "'sbx' install command completed, but 'sbx' could not be located in this process."
    }
    Write-Warning "Please restart your shell (so PATH changes take effect) and re-run this script."
    return $false
}

function Get-MainRepoRoot {
    # 'sbx run --clone' refuses to run from a linked git worktree. Resolve whatever
    # path we were given (main repo or a linked worktree) to the main repository's
    # working directory, which is the parent of the shared ("common") .git directory.
    param([Parameter(Mandatory = $true)][string]$Path)

    $commonGitDir = (& git -C $Path rev-parse --path-format=absolute --git-common-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $commonGitDir) {
        return $null
    }

    $commonGitDir = $commonGitDir.Trim()
    return (Split-Path -Path $commonGitDir -Parent)
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

$repoRoot = Get-MainRepoRoot -Path $repopath
if (-not $repoRoot -or -not (Test-Path -LiteralPath $repoRoot)) {
    Write-Error "Current directory is not inside a git repository."
    exit 1
}

$currentBranch = (& git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $currentBranch) {
    $currentBranch = "work"
}
$currentBranch = $currentBranch.Trim()
if ($currentBranch -eq "HEAD") {
    $currentBranch = "work"
}

$repoName = Split-Path -Path $repoRoot -Leaf
$suggestedBranch = "$currentBranch-$Cli"
$sandboxName = ("$repoName-$Cli" -replace '[^a-zA-Z0-9_.-]', '-')

Write-Host "Repository : $repoRoot"
Write-Host "Sandbox    : $sandboxName"

Write-Host "Starting '$Cli' in Docker Sandbox (clone mode) '$sandboxName' for repo '$repoRoot'..."
Write-Host "Note: the agent works on a private in-sandbox clone, isolated from your host working tree." -ForegroundColor Cyan
Write-Host "Ask the agent to create a branch before editing, e.g.:" -ForegroundColor Cyan
Write-Host "      Create a branch '$suggestedBranch' and make the changes." -ForegroundColor Cyan
Write-Host "When it's done, fetch the branch back to the host with:" -ForegroundColor Cyan
Write-Host "      git fetch sandbox-$sandboxName" -ForegroundColor Cyan

& sbx run --clone --name $sandboxName $Cli $repoRoot
$sbxExitCode = $LASTEXITCODE

if ($sbxExitCode -ne 0) {
    Write-Error "'sbx run' exited with code $sbxExitCode."
    exit $sbxExitCode
}
