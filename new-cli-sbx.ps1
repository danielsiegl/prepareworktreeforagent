<#
.SYNOPSIS
    Launches a CLI agent (copilot, codex, claude, or vibe) inside a Docker Sandbox (sbx)
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
    The CLI agent to launch. Valid values: copilot, codex, claude, vibe. Note: `sbx` has
    no officially documented built-in template for `vibe` — this script instead uses the
    local sandbox kit built by `build-vibe-sbx-kit.ps1` (run that script first; if the kit
    isn't found, this script exits with an error telling you to build it).

.EXAMPLE
    .\new-cli-sbx.ps1 -repopath "C:\repos\myrepo" -Cli copilot

.EXAMPLE
    .\new-cli-sbx.ps1
    # Prompts interactively for CLI agent selection.

.NOTES
    Once the sandbox starts, ask the agent to create a branch before it starts editing,
    e.g. "Create a branch <branch-name> and make the changes." The agent CANNOT fetch or
    pull its own changes back to the host: your host repo is mounted read-only inside the
    sandbox, so running git fetch/pull from inside the agent session fails. This script
    runs 'git fetch sandbox-<name>' on the host automatically once the sandbox session
    ends, and lists the branches it fetched. After that, check out/merge the branch and
    push to origin with your own credentials. (The agent can also push directly to origin
    itself if you give it push access/credentials, since that goes out over the network
    rather than through the read-only host mount.)
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
    Write-Host ""
    Write-Host "Select CLI agent:" -ForegroundColor Cyan
    Write-Host "  1) copilot"
    Write-Host "  2) codex"
    Write-Host "  3) claude"
    Write-Host "  4) vibe"
    Write-Host ""

    while ($true) {
        Write-Host -NoNewline "Enter 1, 2, 3, or 4: "
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Write-Host $key.Character

        switch ($key.Character) {
            '1' { return $options[0] }
            '2' { return $options[1] }
            '3' { return $options[2] }
            '4' { return $options[3] }
            default { Write-Host "Please press 1, 2, 3, or 4." -ForegroundColor Yellow }
        }
    }
}

function Test-SbxInstalled {
    return [bool](Get-Command -Name "sbx" -ErrorAction SilentlyContinue)
}

function Test-MistralSecretStored {
    # 'sbx secret ls' prints a table; look for a "service" row named "mistral".
    $lines = & sbx secret ls 2>$null
    foreach ($line in $lines) {
        if ($line -match '^\s*\S+\s+service\s+mistral\s') {
            return $true
        }
    }
    return $false
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

$agentArg = $Cli
$pullArgs = @()
if ($Cli -eq "vibe") {
    # 'sbx' has no built-in 'vibe' agent template (its error lists only: claude, codex,
    # copilot, cursor, devin, docker-agent, droid, gemini, kiro, opencode, shell) - passing
    # the plain name "vibe" always fails. Use the local kit built by build-vibe-sbx-kit.ps1
    # instead, referencing it by directory path, which 'sbx' accepts as an explicit kit.
    $vibeKitDir = Join-Path -Path $PSScriptRoot -ChildPath "sbx-kits\mistral-vibe"
    $vibeKitSpec = Join-Path -Path $vibeKitDir -ChildPath "spec.yaml"
    if (-not (Test-Path -LiteralPath $vibeKitSpec)) {
        Write-Error "No local Mistral Vibe sandbox kit found at '$vibeKitDir'. 'sbx' has no built-in 'vibe' agent, so you need to build one first: run '.\build-vibe-sbx-kit.ps1', then re-run this script."
        exit 1
    }
    $agentArg = $vibeKitDir
    # The kit's image is built locally and loaded directly into sbx's own sandbox
    # runtime image store by build-vibe-sbx-kit.ps1 (via 'sbx template load'), not
    # pushed to a registry. Without '--pull never', 'sbx run' defaults to trying to
    # pull it from a registry and fails with "403 Forbidden".
    $pullArgs = @("--pull", "never")
    Write-Host "Using local Mistral Vibe kit: $agentArg" -ForegroundColor Cyan

    if (-not (Test-MistralSecretStored)) {
        Write-Warning "No Mistral API key is stored ('sbx secret ls' has no 'mistral' entry). Vibe will fail to call the Mistral API until you run: sbx secret set mistral"
    }
}

Write-Host "Repository : $repoRoot"
Write-Host "Sandbox    : $sandboxName"

Write-Host "Starting '$Cli' in Docker Sandbox (clone mode) '$sandboxName' for repo '$repoRoot'..."
Write-Host "Note: the agent works on a private in-sandbox clone, isolated from your host repo checkout." -ForegroundColor Cyan
Write-Host "Ask the agent to create a branch before editing, e.g.:" -ForegroundColor Cyan
Write-Host "      Create a branch '$suggestedBranch' and make the changes." -ForegroundColor Cyan
Write-Host "IMPORTANT: the agent cannot fetch/pull its own changes back to this host." -ForegroundColor Yellow
Write-Host "Your host repo is mounted read-only inside the sandbox (/run/sandbox/source)," -ForegroundColor Yellow
Write-Host "so 'git fetch'/'git pull' will fail if the agent runs them itself. This script" -ForegroundColor Yellow
Write-Host "will automatically run 'git fetch' from the host once the sandbox session ends." -ForegroundColor Yellow

& sbx run --clone --name $sandboxName @pullArgs $agentArg $repoRoot
$sbxExitCode = $LASTEXITCODE

Write-Host ""
Write-Host "Sandbox session ended. Fetching the agent's work into this host repo..." -ForegroundColor Cyan

$sandboxRemote = "sandbox-$sandboxName"
& git -C $repoRoot fetch $sandboxRemote 2>&1 | ForEach-Object { Write-Host "  $_" }
$fetchExitCode = $LASTEXITCODE

if ($fetchExitCode -eq 0) {
    Write-Host "Fetched '$sandboxRemote'. Branches available from the sandbox:" -ForegroundColor Green
    $remoteBranches = & git -C $repoRoot branch -r --list "$sandboxRemote/*"
    if ($remoteBranches) {
        $remoteBranches | ForEach-Object { Write-Host "  $($_.Trim())" }
        Write-Host "Check out a branch on the host with, e.g.:" -ForegroundColor Cyan
        Write-Host "      git -C `"$repoRoot`" checkout -b <branch-name> $sandboxRemote/<branch-name>" -ForegroundColor Cyan
        Write-Host "Then push to origin with your own credentials." -ForegroundColor Cyan
    }
    else {
        Write-Warning "No branches found under '$sandboxRemote/'. Did the agent create/commit a branch before the session ended?"
    }
}
else {
    Write-Warning "Automatic 'git fetch $sandboxRemote' failed (exit code $fetchExitCode). The sandbox may have already stopped/been removed."
    Write-Warning "If the sandbox is still running, fetch manually from the host with:"
    Write-Warning "      git fetch $sandboxRemote"
}

if ($sbxExitCode -ne 0) {
    Write-Error "'sbx run' exited with code $sbxExitCode."
    exit $sbxExitCode
}
