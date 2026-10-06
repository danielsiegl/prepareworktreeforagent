<#
.SYNOPSIS
    Creates or re-attaches a Docker sandbox (sbx, clone mode) running JetBrains Rider
    as a remote-dev backend with Mistral Vibe as agent.

.DESCRIPTION
    The sandbox gets a private clone of the current branch only. Rider runs inside the
    sandbox and only its remote-dev port is published on 127.0.0.1, so you work through
    JetBrains Gateway / Client. Commits made inside the sandbox are fetched back with
    'git fetch sandbox-<name>'.

.PARAMETER repopath
    Path to the git repository. Defaults to the current working directory.

.PARAMETER Memory
    Memory limit for the sandbox (e.g. 8g). Defaults to 8g.

.PARAMETER Port
    Host port (on 127.0.0.1) to publish the Rider remote-dev port on. Defaults to 5990.

.EXAMPLE
    .\new-rider-sbx.ps1 -repopath "C:\repos\myrepo"

.EXAMPLE
    .\new-rider-sbx.ps1 -Memory 12g -Port 5991
#>
param(
    [string]$repopath,
    [string]$Memory = "8g",
    [int]$Port = 5990
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

if ([string]::IsNullOrWhiteSpace($repopath)) {
    $repopath = (Get-Location).Path
}

Show-RandomMascot
Write-Output "Using git repo $repopath"
Set-Location $repopath

if (-not (Get-Command -Name sbx -ErrorAction SilentlyContinue)) {
    Write-Error "Docker Sandboxes CLI 'sbx' was not found on PATH."
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

# sbx clone mode only works on the main checkout, not on a linked worktree.
$gitDir = (& git -C $repoRoot rev-parse --absolute-git-dir).Trim()
$commonDir = (& git -C $repoRoot rev-parse --path-format=absolute --git-common-dir).Trim()
if ([System.IO.Path]::GetFullPath($gitDir) -ne [System.IO.Path]::GetFullPath($commonDir)) {
    Write-Error "'$repoRoot' is a linked git worktree. sbx clone mode requires the main checkout."
    exit 1
}

if (& git -C $repoRoot status --porcelain) {
    Write-Warning "The working tree has uncommitted changes. The sandbox clones committed state only;"
    Write-Warning "commit (or stash) first if the agent should see them."
}

$repoName = Split-Path -Path $repoRoot -Leaf
$sandboxName = ("rider-$repoName-$currentBranch".ToLowerInvariant() -replace '[^a-z0-9-]', '-') -replace '-+', '-'
$kitPath = Join-Path -Path $PSScriptRoot -ChildPath "rider-sbx"
Write-Host "Repository : $repoRoot"
Write-Host "Branch     : $currentBranch"
Write-Host "Sandbox    : $sandboxName"
Write-Host "Rider port : 127.0.0.1:$Port"

if (-not (& sbx secret ls 2>$null | Select-String -Pattern '\bmistral\b' -Quiet)) {
    Write-Warning "No 'mistral' secret stored. Vibe will not be able to reach the Mistral API."
    Write-Warning "Store one with: sbx secret set mistral"
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Paste the 'Join link' (tcp://127.0.0.1:$Port#...) printed below into JetBrains Gateway"
Write-Host "     ('Connect to running IDE'). Rider needs a minute to start the first time."
Write-Host "  2. Let Mistral Vibe work in Rider's AI chat and commit inside the sandbox."
Write-Host "  3. On the host: git fetch sandbox-$sandboxName"
Write-Host "                  git log $currentBranch..sandbox-$sandboxName/$currentBranch"
Write-Host "  4. Only after fetching: sbx rm $sandboxName"
Write-Host "  Detach with Ctrl-\ to keep the IDE running; re-run this script to re-attach."
Write-Host ""

$existing = & sbx ls 2>$null | Select-String -Pattern "(^|\s)$([regex]::Escape($sandboxName))(\s|$)" -Quiet
if ($existing) {
    Write-Host "Re-attaching to existing sandbox '$sandboxName'..."
    & sbx run --name $sandboxName --env "RIDER_SBX_HOST_PORT=$Port"
}
else {
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        Write-Error "Port $Port is already in use (another sandbox? check 'sbx ls'). Pick a free one with -Port."
        exit 1
    }

    # sbx's global policy allows the common forges; deny them so work only leaves via 'git fetch sandbox-<name>'.
    $forgeHosts = @(
        "github.com", "*.github.com", "githubusercontent.com", "*.githubusercontent.com",
        "gitlab.com", "*.gitlab.com", "bitbucket.org", "*.bitbucket.org",
        "dev.azure.com", "*.dev.azure.com", "*.visualstudio.com"
    )
    $denyArgs = $forgeHosts | ForEach-Object { "--deny-network", $_ }

    Write-Host "Creating sandbox '$sandboxName' (clone mode) from kit '$kitPath'..."
    & sbx run --clone --name $sandboxName `
        --publish "127.0.0.1:${Port}:5990" `
        --memory $Memory `
        --env "RIDER_SBX_HOST_PORT=$Port" `
        @denyArgs `
        $kitPath $repoRoot
}
