<#
.SYNOPSIS
    Builds the local Docker Sandbox (sbx) image for Mistral Vibe from its checked-in kit.

.DESCRIPTION
    'sbx' has no officially built-in agent template for Mistral Vibe (unlike
    copilot/codex/claude). This repo ships a hand-authored kit under
    'sbx-kits\mistral-vibe\' (based on Docker's guide,
    https://docs.docker.com/guides/mistral-vibe-sandbox/):

        sbx-kits\mistral-vibe\Dockerfile   installs 'mistral-vibe' and the .NET SDK
                                           on top of the 'docker/sandbox-templates:shell'
                                           base image, pinned via ARG defaults.
        sbx-kits\mistral-vibe\spec.yaml    wires the image to the Mistral API through
                                           the sandbox proxy, declares the sandbox's
                                           network policy, and names the image tag to
                                           build/load (the 'sandbox.image:' field).

    This script does NOT generate those files -- it only builds from them:

      1. Reads the image tag to build from 'spec.yaml' (via the shared
         Get-SpecImageTag helper in worktree-lib.ps1), so the Dockerfile and
         spec.yaml stay the single source of truth for versions.

      2. Builds the image locally (single platform, no registry push) with that tag.

      3. Loads the built image into sbx's own sandbox runtime image store via
         'docker save' + 'sbx template load'. This step is required: sbx's
         sandboxd keeps a private image store that is NOT the same as Docker
         Desktop's regular image list, so a plain 'docker build' is otherwise
         invisible to 'sbx run' (it fails with a 403 trying to pull the local
         tag from a registry that doesn't have it).

      4. Optionally runs 'sbx secret set mistral' so the sandbox proxy can
         inject your Mistral API key without it ever entering the VM.

    It does NOT run 'sbx kit validate' or 'sbx run' automatically -- it prints
    the exact commands for you to run yourself once you're ready.

    To bump the 'mistral-vibe' package version, the .NET SDK version, or any other
    part of the image: edit 'sbx-kits\mistral-vibe\Dockerfile' directly (its ARG
    defaults), and update the matching 'image:' tag in 'spec.yaml' to a new value
    (so a stale cached image under the old tag is never silently reused) -- then
    run this script with -Force.

.PARAMETER Force
    Rebuild and reload the image even if 'sbx template ls' shows it's already loaded
    into sbx's sandbox runtime image store. Without this switch, the script detects an
    already-loaded image and asks before spending several minutes rebuilding it.

.EXAMPLE
    .\build-vibe-sbx-kit.ps1

.EXAMPLE
    .\build-vibe-sbx-kit.ps1 -Force
    # Forces a rebuild, e.g. after hand-editing the Dockerfile/spec.yaml to bump a
    # version.

.NOTES
    Prerequisites: Docker Desktop/Engine running, 'sbx' installed and signed in, and a
    Mistral API key (https://console.mistral.ai/). After this script finishes, run:

        sbx kit validate .\sbx-kits\mistral-vibe
        sbx run .\sbx-kits\mistral-vibe --name mistral-vibe --pull never .
#>
param(
    [switch]$Force
)

. (Join-Path -Path $PSScriptRoot -ChildPath "worktree-lib.ps1")

function Test-SbxInstalled {
    return [bool](Get-Command -Name "sbx" -ErrorAction SilentlyContinue)
}

function Test-DockerInstalled {
    return [bool](Get-Command -Name "docker" -ErrorAction SilentlyContinue)
}

function Test-DockerDaemonRunning {
    # 'docker' can be on PATH while Docker Desktop's engine isn't running (e.g. the
    # named pipe 'dockerDesktopLinuxEngine' doesn't exist yet). 'docker info' is a
    # cheap way to confirm the daemon is actually reachable before attempting a build.
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
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

if (-not (Test-SbxInstalled)) {
    Write-Error "The 'sbx' CLI (Docker Sandboxes) was not found on PATH. Install it first, e.g. 'winget install -h Docker.sbx' (see new-cli-sbx.ps1), or: https://docs.docker.com/ai/sandboxes/install/"
    exit 1
}

if (-not (Test-DockerInstalled)) {
    Write-Error "The 'docker' CLI was not found on PATH. Install/start Docker Desktop (or Docker Engine) first: https://docs.docker.com/get-started/get-docker/"
    exit 1
}

$kitDir = Join-Path -Path $PSScriptRoot -ChildPath "sbx-kits\mistral-vibe"
$dockerfilePath = Join-Path -Path $kitDir -ChildPath "Dockerfile"
$specPath = Join-Path -Path $kitDir -ChildPath "spec.yaml"

if (-not (Test-Path -LiteralPath $dockerfilePath) -or -not (Test-Path -LiteralPath $specPath)) {
    Write-Error "Checked-in kit files are missing: expected '$dockerfilePath' and '$specPath'. These are tracked in git (not generated) -- restore them with 'git checkout -- sbx-kits\mistral-vibe' or re-clone the repo."
    exit 1
}

$ImageTag = Get-SpecImageTag -SpecPath $specPath
if (-not $ImageTag) {
    Write-Error "Could not find a 'sandbox.image:' value in '$specPath'."
    exit 1
}

$skipBuild = $false
if (-not $Force -and (Test-SbxTemplateLoaded -ImageTag $ImageTag)) {
    Write-Host ""
    Write-Host "Image '$ImageTag' is already loaded into sbx's template store ('sbx template ls')." -ForegroundColor Green
    Write-Host -NoNewline "Rebuild and reload it anyway? (y/N): "
    $rebuildAnswer = Read-Host
    if ($rebuildAnswer -notmatch '^(y|yes)$') {
        $skipBuild = $true
        Write-Host "Skipping build/save/load -- using the already-loaded image." -ForegroundColor Yellow
    }
}

if (-not $skipBuild) {
    Write-Host ""
    Write-Host "Building local image '$ImageTag' from '$kitDir'..." -ForegroundColor Cyan
    & docker build -t $ImageTag $kitDir
    $buildExitCode = $LASTEXITCODE

    if ($buildExitCode -ne 0) {
        Write-Error "'docker build' failed with exit code $buildExitCode."
        exit $buildExitCode
    }

    Write-Host "Image '$ImageTag' built successfully." -ForegroundColor Green

    Write-Host ""
    Write-Host "Loading '$ImageTag' into sbx's sandbox runtime image store..." -ForegroundColor Cyan
    $tarPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "sbx-mistral-vibe-$([guid]::NewGuid().ToString('N')).tar"
    try {
        & docker save -o $tarPath $ImageTag
        $saveExitCode = $LASTEXITCODE
        if ($saveExitCode -ne 0) {
            Write-Error "'docker save' failed with exit code $saveExitCode."
            exit $saveExitCode
        }

        & sbx template load $tarPath
        $loadExitCode = $LASTEXITCODE
        if ($loadExitCode -ne 0) {
            Write-Error "'sbx template load' failed with exit code $loadExitCode."
            exit $loadExitCode
        }
    }
    finally {
        Remove-Item -LiteralPath $tarPath -ErrorAction SilentlyContinue
    }

    Write-Host "Image '$ImageTag' is now available to sbx (sandbox runtime image store)." -ForegroundColor Green
}

Write-Host ""
if (Test-MistralSecretStored) {
    Write-Host "A Mistral API key is already stored ('sbx secret ls' shows 'mistral')." -ForegroundColor Green
    Write-Host "Get a new one at: https://chat.mistral.ai/code/extensions?focus=key" -ForegroundColor Yellow
    Write-Host -NoNewline "Replace/update it now via 'sbx secret set mistral'? (y/N): "
}
else {
    Write-Host "No Mistral API key is currently stored." -ForegroundColor Yellow
    Write-Host "Get one at: https://chat.mistral.ai/code/extensions?focus=key" -ForegroundColor Yellow
    Write-Host -NoNewline "Store it now via 'sbx secret set mistral'? (y/N): "
}
$secretAnswer = Read-Host
if ($secretAnswer -match '^(y|yes)$') {
    & sbx secret set mistral
}
else {
    Write-Host "Skipped. Run 'sbx secret set mistral' yourself before first use." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Kit ready at '$kitDir'. Next steps:" -ForegroundColor Cyan
Write-Host "      sbx kit validate `"$kitDir`"" -ForegroundColor Cyan
Write-Host "      sbx run `"$kitDir`" --name mistral-vibe --pull never ." -ForegroundColor Cyan
Write-Host "(--pull never is required: the image was loaded directly into sbx's" -ForegroundColor DarkGray
Write-Host " sandbox runtime store above, not pushed to a registry.)" -ForegroundColor DarkGray
