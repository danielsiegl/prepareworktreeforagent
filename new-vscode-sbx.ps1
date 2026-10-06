<#
.SYNOPSIS
    Creates or restarts a Docker sandbox (sbx, clone mode) with the VS Code backend and
    Mistral Vibe inside, and opens the local VS Code window on it via Remote-SSH.

.DESCRIPTION
    The sandbox gets a private clone of the current branch only. Only the VS Code window
    runs on the host; the VS Code server, its extension host, the Mistral Vibe extension
    and all terminals run in the sandbox, reached over SSH on 127.0.0.1. Commits made in
    the sandbox are fetched back with 'git fetch sandbox-<name>'.

.PARAMETER repopath
    Path to the git repository. Defaults to the current working directory.

.PARAMETER Memory
    Memory limit for the sandbox (e.g. 8g). Defaults to 8g.

.PARAMETER Port
    Host port (on 127.0.0.1) for the sandbox's SSH server. Defaults to 2222.

.EXAMPLE
    .\new-vscode-sbx.ps1 -repopath "C:\repos\myrepo"

.EXAMPLE
    .\new-vscode-sbx.ps1 -Memory 12g -Port 2223
#>
param(
    [string]$repopath,
    [string]$Memory = "8g",
    [int]$Port = 2222
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

if ($PSVersionTable.PSEdition -ne "Core") {
    Write-Warning "This script is tested with PowerShell 7 (pwsh); you are running Windows PowerShell $($PSVersionTable.PSVersion)."
    Write-Warning "If anything fails, re-run it with: pwsh -File `"$PSCommandPath`""
}

Write-Output "Using git repo $repopath"
Set-Location $repopath

foreach ($tool in @("sbx", "code", "ssh-keygen")) {
    if (-not (Get-Command -Name $tool -ErrorAction SilentlyContinue)) {
        Write-Error "'$tool' was not found on PATH."
        exit 1
    }
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
$sandboxName = ("vscode-$repoName-$currentBranch".ToLowerInvariant() -replace '[^a-z0-9-]', '-') -replace '-+', '-'
$kitPath = Join-Path -Path $PSScriptRoot -ChildPath "vscode-sbx"

# Content hash of the kit: sbx can reuse a stale kit image after script edits; a new kitRevision forces the rebuild.
$kitFileHashes = (Get-ChildItem -LiteralPath $kitPath -File | Sort-Object Name |
    ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ""
$kitRevision = (Get-FileHash -Algorithm SHA256 -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::ASCII.GetBytes($kitFileHashes)))).Hash.Substring(0, 12).ToLowerInvariant()

Write-Host "Repository : $repoRoot"
Write-Host "Branch     : $currentBranch"
Write-Host "Sandbox    : $sandboxName"
Write-Host "SSH port   : 127.0.0.1:$Port"

if (-not (& sbx secret ls 2>$null | Select-String -Pattern '\bmistral\b' -Quiet)) {
    Write-Warning "No 'mistral' secret stored. Mistral Vibe will not be able to reach the Mistral API."
    Write-Warning "Store one with: sbx secret set mistral"
}

# ---------- SSH key + host entry (kept apart from your own keys and hosts) ----------
$sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
$sbxSshDir = Join-Path -Path $sshDir -ChildPath "vscode-sbx"
New-Item -ItemType Directory -Force -Path $sbxSshDir | Out-Null

$keyPath = Join-Path -Path $sbxSshDir -ChildPath "id_ed25519"
if (-not (Test-Path -LiteralPath $keyPath)) {
    # Windows PowerShell (and pwsh in Legacy argument mode) drops an empty "" argument for
    # native commands, so the empty passphrase has to be passed as a literal '""' there.
    $emptyPassphrase = if ($PSNativeCommandArgumentPassing -and $PSNativeCommandArgumentPassing -ne "Legacy") { "" } else { '""' }
    & ssh-keygen -q -t ed25519 -N $emptyPassphrase -C "vscode-sbx" -f $keyPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create SSH key '$keyPath'."
        exit 1
    }
}
$publicKey = (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()
$knownHostsPath = Join-Path -Path $sbxSshDir -ChildPath "known_hosts_$sandboxName"

# ---------- create sandbox (first run) ----------
$existing = & sbx ls 2>$null | Select-String -Pattern "(^|\s)$([regex]::Escape($sandboxName))(\s|$)" -Quiet
if (-not $existing) {
    # sbx's global policy allows the common forges; deny them so work only leaves via 'git fetch sandbox-<name>'.
    # (No '*.visualstudio.com': marketplace.visualstudio.com serves the VS Code extensions.)
    $forgeHosts = @(
        "github.com", "*.github.com", "githubusercontent.com", "*.githubusercontent.com",
        "gitlab.com", "*.gitlab.com", "bitbucket.org", "*.bitbucket.org",
        "dev.azure.com", "*.dev.azure.com"
    )
    $denyArgs = $forgeHosts | ForEach-Object { "--deny-network", $_ }

    Write-Host "Creating sandbox '$sandboxName' (clone mode) from kit '$kitPath'..."
    & sbx run --detached --clone --name $sandboxName `
        --publish "127.0.0.1:${Port}:2222" `
        --memory $Memory `
        --kit-arg "kitRevision=$kitRevision" `
        @denyArgs `
        $kitPath $repoRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create sandbox '$sandboxName'."
        exit 1
    }
    # New sandbox, new SSH host key.
    Remove-Item -LiteralPath $knownHostsPath -Force -ErrorAction SilentlyContinue
}

# ---------- start the backend (sshd + extension installer) ----------
Write-Host "Starting VS Code backend in '$sandboxName'..."
$startOutput = & sbx exec $sandboxName vscode-sbx-start --pubkey $publicKey 2>&1
$startOutput | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to start the VS Code backend in '$sandboxName'."
    exit 1
}
$workspace = ($startOutput | Select-String -Pattern '^VSCODE_SBX_WORKSPACE=(.+)$' | Select-Object -First 1).Matches.Groups[1].Value.Trim()

$hostConfigPath = Join-Path -Path $sbxSshDir -ChildPath "$sandboxName.conf"
$hostConfig = @"
Host $sandboxName
    HostName 127.0.0.1
    Port $Port
    User agent
    IdentityFile "$keyPath"
    IdentitiesOnly yes
    UserKnownHostsFile "$knownHostsPath"
    StrictHostKeyChecking accept-new
"@
Set-Content -LiteralPath $hostConfigPath -Value $hostConfig -Encoding ascii

# Make ~/.ssh/config include the sandbox host entries (Include must precede any Host block).
$sshConfigPath = Join-Path -Path $sshDir -ChildPath "config"
$includeLine = "Include vscode-sbx/*.conf"
$sshConfig = if (Test-Path -LiteralPath $sshConfigPath) { Get-Content -LiteralPath $sshConfigPath -Raw } else { "" }
if ($sshConfig -notmatch [regex]::Escape($includeLine)) {
    Write-Host "Adding '$includeLine' to the top of $sshConfigPath"
    Set-Content -LiteralPath $sshConfigPath -Value ("$includeLine`n`n" + $sshConfig) -Encoding ascii -NoNewline
}

# ---------- open VS Code on the sandbox ----------
if (-not (& code --list-extensions 2>$null | Select-String -Pattern '^ms-vscode-remote\.remote-ssh$' -Quiet)) {
    Write-Host "Installing the VS Code Remote - SSH extension..."
    & code --install-extension ms-vscode-remote.remote-ssh | Out-Null
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. VS Code opens '$workspace' in the sandbox (choose 'Linux' if asked for the platform)."
Write-Host "     The Mistral Vibe extension is installed into the sandbox automatically;"
Write-Host "     run 'Developer: Reload Window' if it does not show up after the first connect."
Write-Host "  2. Let Mistral Vibe work and commit inside the sandbox."
Write-Host "  3. On the host: git fetch sandbox-$sandboxName"
Write-Host "                  git log $currentBranch..sandbox-$sandboxName/$currentBranch"
Write-Host "  4. Pause with 'sbx stop $sandboxName'; re-run this script to continue."
Write-Host "     Only after fetching: sbx rm $sandboxName"
Write-Host ""

& code --folder-uri "vscode-remote://ssh-remote+$sandboxName$workspace"
