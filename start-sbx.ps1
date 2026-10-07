<#
.SYNOPSIS
    Launches a CLI agent (copilot, codex, claude, or vibe) inside a Docker Sandbox (sbx)
    using either clone mode or worktree mode.

.DESCRIPTION
    Given a repository path and a CLI agent name, this script starts the selected CLI
    agent inside a Docker Sandbox (`sbx`), using one of two mount modes:

    - `clone` (default-offered, isolation/performance focused): `sbx` mounts your
      repository read-only and the agent does its real work on a private clone that
      lives on the sandbox's own (Linux) filesystem. This avoids the slow file I/O that
      occurs when an agent/container repeatedly reads and writes a Windows (NTFS) path
      through a filesystem passthrough, and it gives the agent its own isolated branch/
      worktree inside the sandbox clone — so no git worktree needs to be created on the
      host. `sbx --clone` requires the *main* repository working directory (not a linked
      git worktree). If `-repopath` points at a linked worktree, the script automatically
      resolves it to the main repository root.

    - `worktree` (host worktree, like new-cli-worktree.ps1): the script creates (or
      reuses) a git branch/worktree on the host named `<current-branch>-<cli>` in a
      sibling directory, then runs `sbx run` *without* `--clone`, mounting only that
      worktree directory (not the main repository). A linked worktree's `.git` is just
      a pointer file to the *main* repo's `.git\worktrees\<name>` directory on the host —
      a path that doesn't exist inside the sandbox, since only the worktree directory
      itself is mounted. This is Docker's documented "Host worktree" sandbox mode: because
      git can't resolve that pointer, the agent has no git access (confirmed by testing:
      it fails with `fatal: not a git repository`), with no extra kit required. The host
      keeps full, uninterrupted git access to the real worktree the whole time, and
      file edits made inside the sandbox show up immediately on the host (verified: no
      sync delay). Review, stage, and commit the changes yourself on the host whenever
      you like.

    If the `sbx` CLI is not installed, the script attempts to install it via winget
    (`winget install -h Docker.sbx`).

.PARAMETER repopath
    Path to the git repository (or one of its worktrees). Defaults to the current
    working directory.

.PARAMETER Cli
    The CLI agent to launch. Valid values: copilot, codex, claude, vibe. Note: `sbx` has
    no officially documented built-in template for `vibe` — this script instead uses the
    local sandbox kit built by `build-vibe-sbx-kit.ps1`. If that kit's image isn't found
    yet, this script builds it automatically before continuing.

.PARAMETER Mode
    How the repository is made available to the sandbox. Valid values: clone, worktree.
    - clone: isolated in-sandbox clone (default sbx behavior); no host worktree created;
      the agent can use git inside the sandbox.
    - worktree: creates/reuses a host git worktree (like new-cli-worktree.ps1) and mounts
      it directly, without `--clone`. Git is unusable for the agent inside the sandbox
      because only the worktree directory is mounted (the `.git` pointer can't be
      resolved there) — no extra kit needed; the host keeps full, untouched git access
      to the worktree the whole time.
    If omitted, the script prompts interactively.

.EXAMPLE
    .\start-sbx.ps1 -repopath "C:\repos\myrepo" -Cli copilot -Mode clone

.EXAMPLE
    .\start-sbx.ps1 -Cli copilot -Mode worktree

.EXAMPLE
    .\start-sbx.ps1
    # Prompts interactively for CLI agent and mode selection.

.NOTES
    In clone mode, once the sandbox starts, ask the agent to create a branch before it
    starts editing, e.g. "Create a branch <branch-name> and make the changes." The agent
    CANNOT fetch or pull its own changes back to the host: your host repo is mounted
    read-only inside the sandbox, so running git fetch/pull from inside the agent session
    fails. This script runs 'git fetch sandbox-<name>' on the host automatically once the
    sandbox session ends, and lists the branches it fetched. After that, check out/merge
    the branch and push to origin with your own credentials. (The agent can also push
    directly to origin itself if you give it push access/credentials, since that goes out
    over the network rather than through the read-only host mount.)

    In worktree mode, the host worktree/branch is created before the sandbox starts.
    Only that worktree directory is mounted into the sandbox (not the main repository),
    so the agent's git commands fail to resolve the worktree's `.git` pointer file and
    it has no git access there — the agent only edits files, it cannot run git itself in
    this mode. This is Docker's documented "Host worktree" sandbox behavior; no extra kit
    is needed to enforce it. The host's `.git` stays completely untouched, so you can use
    git on the worktree from the host at any time, even while the sandbox is still
    running, and the agent's file edits show up there immediately (no sync delay).
    Review, stage, commit, and push the resulting file changes yourself on the host
    whenever you like.
#>
param(
    [string]$repopath,
    [ValidateSet("copilot", "codex", "claude", "vibe")]
    [string]$Cli,
    [ValidateSet("clone", "worktree")]
    [string]$Mode
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

function Read-ModeChoice {
    Write-Host ""
    Write-Host "Select sandbox mode:" -ForegroundColor Cyan
    Write-Host "  1) clone    - isolated in-sandbox clone (no host worktree, fast); agent can use git"
    Write-Host "  2) worktree - mount a host git worktree (like new-cli-worktree.ps1); git is disabled"
    Write-Host "                for the agent in this mode (host keeps full git access throughout)"
    Write-Host ""

    while ($true) {
        Write-Host -NoNewline "Enter 1 or 2: "
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Write-Host $key.Character

        switch ($key.Character) {
            '1' { return "clone" }
            '2' { return "worktree" }
            default { Write-Host "Please press 1 or 2." -ForegroundColor Yellow }
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

# Shared with new-cli-worktree.ps1: Normalize-PathForComparison, Get-RegisteredWorktrees,
# and New-Worktree-ForBranch (used below for worktree mode).
. (Join-Path -Path $PSScriptRoot -ChildPath "worktree-lib.ps1")

if ([string]::IsNullOrWhiteSpace($repopath)) {
    $repopath = (Get-Location).Path
}

Show-RandomMascot
Write-Output "Using git repo $repopath"
Set-Location $repopath

if (-not $Cli) {
    $Cli = Read-CliChoice
}

if (-not $Mode) {
    $Mode = Read-ModeChoice
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

$mountPath = $repoRoot
$cloneArgs = @("--clone")
if ($Mode -eq "worktree") {
    $worktreeDir = New-Worktree-ForBranch -RepoRoot $repoRoot -CurrentBranch $currentBranch -NewBranch $suggestedBranch
    if (-not $worktreeDir) {
        exit 1
    }
    $mountPath = $worktreeDir
    $cloneArgs = @()
}

$agentArg = $Cli
$pullArgs = @()
if ($Cli -eq "vibe") {
    # 'sbx' has no built-in 'vibe' agent template (its error lists only: claude, codex,
    # copilot, cursor, devin, docker-agent, droid, gemini, kiro, opencode, shell) - passing
    # the plain name "vibe" always fails. Use the local kit built by build-vibe-sbx-kit.ps1
    # instead, referencing it by directory path, which 'sbx' accepts as an explicit kit.
    $vibeKitDir = Join-Path -Path $PSScriptRoot -ChildPath "sbx-kits\mistral-vibe"
    $vibeKitSpec = Join-Path -Path $vibeKitDir -ChildPath "spec.yaml"
    $vibeImageTag = Get-SpecImageTag -SpecPath $vibeKitSpec
    if (-not (Test-SbxTemplateLoaded -ImageTag $vibeImageTag)) {
        Write-Host "No local Mistral Vibe sandbox image found. 'sbx' has no built-in 'vibe' agent, so building one now via '.\build-vibe-sbx-kit.ps1'..." -ForegroundColor Yellow
        $buildScript = Join-Path -Path $PSScriptRoot -ChildPath "build-vibe-sbx-kit.ps1"
        & $buildScript
        $buildKitExitCode = $LASTEXITCODE
        $vibeImageTag = Get-SpecImageTag -SpecPath $vibeKitSpec
        if ($buildKitExitCode -ne 0 -or -not (Test-Path -LiteralPath $vibeKitSpec) -or -not (Test-SbxTemplateLoaded -ImageTag $vibeImageTag)) {
            Write-Error "Failed to build the Mistral Vibe sandbox kit. Run '.\build-vibe-sbx-kit.ps1' manually to see the error, then re-run this script."
            exit 1
        }
    }
    $agentArg = $vibeKitDir
    # The kit's image is built locally and loaded directly into sbx's own sandbox
    # runtime image store by build-vibe-sbx-kit.ps1 (via 'sbx template load'), not
    # pushed to a registry. Without '--pull never', 'sbx run' defaults to trying to
    # pull it from a registry and fails with "403 Forbidden".
    $pullArgs = @("--pull", "never")
    Write-Host "Using local Mistral Vibe kit: $agentArg" -ForegroundColor Cyan

    # The spec.yaml file existing on disk doesn't guarantee the image it references is
    # still loaded into sbx's own image store -- that store can be emptied independently
    # (Docker Desktop reset, 'sbx template rm', a fresh machine) while the kit files
    # stay behind, which reproduces the old "403 Forbidden: pull failed" error.
    $vibeImageTag = Get-SpecImageTag -SpecPath $vibeKitSpec
    if ($vibeImageTag -and -not (Test-SbxTemplateLoaded -ImageTag $vibeImageTag)) {
        Write-Warning "Kit found at '$vibeKitDir', but image '$vibeImageTag' isn't in sbx's template store ('sbx template ls' has no matching entry). 'sbx run --pull never' will fail until you rebuild/reload it: run '.\build-vibe-sbx-kit.ps1'."
    }

    if (-not (Test-MistralSecretStored)) {
        Write-Warning "No Mistral API key is stored ('sbx secret ls' has no 'mistral' entry). Vibe will fail to call the Mistral API until you run: sbx secret set mistral"
        Write-Warning "Get a key at: https://chat.mistral.ai/code/extensions?focus=key"
    }
}

Write-Host "Repository : $repoRoot"
Write-Host "Sandbox    : $sandboxName"
Write-Host "Mode       : $Mode"

if ($Mode -eq "worktree") {
    Write-Host "Starting '$Cli' in Docker Sandbox (worktree mode) '$sandboxName', mounting worktree '$mountPath'..."
    Write-Host "Note: the agent works directly on the host worktree/branch '$suggestedBranch' - no '--clone' is used." -ForegroundColor Cyan
    Write-Host "Since the worktree is mounted directly (not read-only), the agent's edits land" -ForegroundColor Cyan
    Write-Host "directly on this branch - no post-session 'git fetch' step is needed." -ForegroundColor Cyan
    Write-Host "Only the worktree directory is mounted, so git itself can't resolve its '.git'" -ForegroundColor Cyan
    Write-Host "pointer inside the sandbox - the agent just edits files; your host keeps full git" -ForegroundColor Cyan
    Write-Host "access to this worktree the whole time - review and commit the changes yourself" -ForegroundColor Cyan
    Write-Host "whenever you like, even while the sandbox is still running." -ForegroundColor Cyan
}
else {
    Write-Host "Starting '$Cli' in Docker Sandbox (clone mode) '$sandboxName' for repo '$repoRoot'..."
    Write-Host "Note: the agent works on a private in-sandbox clone, isolated from your host repo checkout." -ForegroundColor Cyan
    Write-Host "Ask the agent to create a branch before editing, e.g.:" -ForegroundColor Cyan
    Write-Host "      Create a branch '$suggestedBranch' and make the changes." -ForegroundColor Cyan
    Write-Host "IMPORTANT: the agent cannot fetch/pull its own changes back to this host." -ForegroundColor Yellow
    Write-Host "Your host repo is mounted read-only inside the sandbox (/run/sandbox/source)," -ForegroundColor Yellow
    Write-Host "so 'git fetch'/'git pull' will fail if the agent runs them itself. This script" -ForegroundColor Yellow
    Write-Host "will automatically run 'git fetch' from the host once the sandbox session ends." -ForegroundColor Yellow
}

& sbx run @cloneArgs --name $sandboxName @pullArgs $agentArg $mountPath
$sbxExitCode = $LASTEXITCODE

if ($Mode -eq "worktree") {
    Write-Host ""
    Write-Host "Sandbox session ended. The host worktree is unchanged and ready to use:" -ForegroundColor Cyan
    Write-Host "      $mountPath (branch '$suggestedBranch')" -ForegroundColor Cyan
    Write-Host "Git was disabled for the agent, so any changes are uncommitted file edits." -ForegroundColor Cyan
    Write-Host "Review, stage, and commit them yourself, e.g.:" -ForegroundColor Cyan
    Write-Host "      git -C `"$mountPath`" status" -ForegroundColor Cyan
    Write-Host "      git -C `"$mountPath`" add -A; git -C `"$mountPath`" commit -m `"...`"" -ForegroundColor Cyan
    Write-Host "Then push to origin with your own credentials." -ForegroundColor Cyan
}
else {
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
}

if ($sbxExitCode -ne 0) {
    Write-Error "'sbx run' exited with code $sbxExitCode."
    exit $sbxExitCode
}
