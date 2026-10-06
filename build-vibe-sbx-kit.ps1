<#
.SYNOPSIS
    Builds a local Docker Sandbox (sbx) image and kit for Mistral Vibe.

.DESCRIPTION
    'sbx' has no officially built-in agent template for Mistral Vibe (unlike
    copilot/codex/claude). This script follows Docker's guide
    (https://docs.docker.com/guides/mistral-vibe-sandbox/) to build your own:

      1. Writes a pinned Dockerfile (installs 'mistral-vibe' on top of the
         'docker/sandbox-templates:shell' base image) and a kit 'spec.yaml'
         (wires the image to the Mistral API through the sandbox proxy, and
         declares the sandbox's network policy) under:

             sbx-kits\mistral-vibe\Dockerfile
             sbx-kits\mistral-vibe\spec.yaml

      2. Builds the image locally (single platform, no registry push) and
         tags it with -ImageTag.

      3. Optionally runs 'sbx secret set mistral' so the sandbox proxy can
         inject your Mistral API key without it ever entering the VM.

    It does NOT run 'sbx kit validate' or 'sbx run' automatically -- it prints
    the exact commands for you to run yourself once you're ready.

.PARAMETER VibeVersion
    The 'mistral-vibe' PyPI package version to pin in the Dockerfile. Defaults to
    "2.24.5". Check https://pypi.org/project/mistral-vibe/ for newer releases.

.PARAMETER ImageTag
    The local Docker image tag to build and reference from the kit's spec.yaml.
    Defaults to "sbx-mistral-vibe:local". No registry/namespace is used or required
    since this is a local-only build.

.PARAMETER Force
    Overwrite an existing Dockerfile/spec.yaml under sbx-kits\mistral-vibe without
    prompting. Without this switch, the script asks before overwriting files that
    already exist (in case you've hand-customized them).

.EXAMPLE
    .\build-vibe-sbx-kit.ps1

.EXAMPLE
    .\build-vibe-sbx-kit.ps1 -VibeVersion "2.25.0" -ImageTag "sbx-mistral-vibe:local" -Force

.NOTES
    Prerequisites: Docker Desktop/Engine running, 'sbx' installed and signed in, and a
    Mistral API key (https://console.mistral.ai/). After this script finishes, run:

        sbx kit validate .\sbx-kits\mistral-vibe
        sbx run .\sbx-kits\mistral-vibe --name mistral-vibe .
#>
param(
    [string]$VibeVersion = "2.24.5",
    [string]$ImageTag = "sbx-mistral-vibe:local",
    [switch]$Force
)

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

function Write-KitFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][bool]$ForceOverwrite
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not $ForceOverwrite) {
            Write-Host -NoNewline "'$Path' already exists. Overwrite? (y/N): "
            $answer = Read-Host
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host "Keeping existing '$Path'." -ForegroundColor Yellow
                return
            }
        }
    }

    Set-Content -LiteralPath $Path -Value $Content -NoNewline
    Write-Host "Wrote '$Path'." -ForegroundColor Green
}

if (-not (Test-SbxInstalled)) {
    Write-Error "The 'sbx' CLI (Docker Sandboxes) was not found on PATH. Install it first, e.g. 'winget install -h Docker.sbx' (see new-cli-sbx.ps1), or: https://docs.docker.com/ai/sandboxes/install/"
    exit 1
}

if (-not (Test-DockerInstalled)) {
    Write-Error "The 'docker' CLI was not found on PATH. Install/start Docker Desktop (or Docker Engine) first: https://docs.docker.com/get-started/get-docker/"
    exit 1
}

if (-not (Test-DockerDaemonRunning)) {
    Write-Error "The 'docker' CLI is installed, but the Docker daemon isn't reachable (is Docker Desktop running?). Start Docker Desktop and wait for it to finish starting, then re-run this script."
    exit 1
}

$kitDir = Join-Path -Path $PSScriptRoot -ChildPath "sbx-kits\mistral-vibe"
New-Item -ItemType Directory -Path $kitDir -Force | Out-Null

$dockerfilePath = Join-Path -Path $kitDir -ChildPath "Dockerfile"
$specPath = Join-Path -Path $kitDir -ChildPath "spec.yaml"

$dockerfileContent = @"
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=docker/sandbox-templates:shell
FROM `${BASE_IMAGE}

# Pin the agent version for reproducible sandboxes.
# Check https://pypi.org/project/mistral-vibe/ and bump as needed.
ARG VIBE_VERSION=$VibeVersion

# Install Vibe as the non-root agent user. The socks extra is installed
# explicitly so the agent works through the sandbox proxy.
USER agent
RUN uv tool install "mistral-vibe==`${VIBE_VERSION}" --with "httpx[socks]" \
    && vibe --version

CMD ["vibe", "--agent", "auto-approve"]
"@

$specContent = @"
schemaVersion: "2"
kind: sandbox
name: mistral-vibe
displayName: Mistral Vibe

sandbox:
  image: $ImageTag

agentInstructions:
  filename: AGENTS.md
  content: |
    You are running inside an isolated Docker Sandbox microVM.
    Network access is restricted to the Mistral API. Prefer tools and
    packages already available in the workspace.

permissions:
  network:
    allow:
      - "api.mistral.ai:443"

credentials:
  - service: mistral
    apiKey:
      name: MISTRAL_API_KEY
      inject:
        - domain: api.mistral.ai
          scheme: bearer
"@

Write-KitFile -Path $dockerfilePath -Content $dockerfileContent -ForceOverwrite:$Force.IsPresent
Write-KitFile -Path $specPath -Content $specContent -ForceOverwrite:$Force.IsPresent

Write-Host ""
Write-Host "Building local image '$ImageTag' (VIBE_VERSION=$VibeVersion)..." -ForegroundColor Cyan
& docker build -t $ImageTag --build-arg "VIBE_VERSION=$VibeVersion" $kitDir
$buildExitCode = $LASTEXITCODE

if ($buildExitCode -ne 0) {
    Write-Error "'docker build' failed with exit code $buildExitCode."
    exit $buildExitCode
}

Write-Host "Image '$ImageTag' built successfully." -ForegroundColor Green

Write-Host ""
Write-Host -NoNewline "Store/update the Mistral API key now via 'sbx secret set mistral'? (y/N): "
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
Write-Host "      sbx run `"$kitDir`" --name mistral-vibe ." -ForegroundColor Cyan
