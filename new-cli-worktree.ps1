param(
    [ValidateSet("copilot", "codex", "claude")]
    [string]$Cli
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
$parentDir = Split-Path -Path $repoRoot -Parent
$repoName = Split-Path -Path $repoRoot -Leaf
$worktreeDir = Join-Path -Path $parentDir -ChildPath "$repoName-$Cli"

if (Test-Path -LiteralPath $worktreeDir) {
    Write-Error "Target worktree directory already exists: $worktreeDir"
    exit 1
}

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

Write-Host "Done."
Write-Host "Repository : $repoRoot"
Write-Host "Branch     : $newBranch"
Write-Host "Worktree   : $worktreeDir"

$cliCommand = switch ($Cli) {
    "codex" { "codex" }
    "claude" { "claude" }
    default { "copilot" }
}
$cliExecutable = Get-Command -Name $cliCommand -ErrorAction SilentlyContinue

if (-not $cliExecutable) {
    Write-Warning "CLI command '$cliCommand' was not found on PATH."
    Write-Warning "Worktree was created successfully at: $worktreeDir"
    exit 0
}

Write-Host "Starting '$cliCommand' in '$worktreeDir'..."
Push-Location -LiteralPath $worktreeDir
try {
    & $cliCommand
}
finally {
    Pop-Location
}