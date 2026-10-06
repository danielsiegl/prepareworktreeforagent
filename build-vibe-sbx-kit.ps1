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

.PARAMETER VibeVersion
    The 'mistral-vibe' PyPI package version to pin in the Dockerfile. Defaults to
    "2.24.5". Check https://pypi.org/project/mistral-vibe/ for newer releases.

.PARAMETER ImageTag
    The local Docker image tag to build and reference from the kit's spec.yaml.
    Defaults to "sbx-mistral-vibe:local". No registry/namespace is used or required
    since this is a local-only build.

.PARAMETER Force
    Rebuild and reload the image even if 'sbx template ls' shows it's already loaded
    into sbx's sandbox runtime image store. Without this switch, the script detects an
    already-loaded image and asks before spending several minutes rebuilding it.

.EXAMPLE
    .\build-vibe-sbx-kit.ps1

.EXAMPLE
    .\build-vibe-sbx-kit.ps1 -VibeVersion "2.25.0" -ImageTag "sbx-mistral-vibe:local"

.NOTES
    Prerequisites: Docker Desktop/Engine running, 'sbx' installed and signed in, and a
    Mistral API key (https://console.mistral.ai/). After this script finishes, run:

        sbx kit validate .\sbx-kits\mistral-vibe
        sbx run .\sbx-kits\mistral-vibe --name mistral-vibe --pull never .
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

function Write-KitFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

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
  entrypoint: ["vibe", "--agent", "auto-approve"]

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

Write-KitFile -Path $dockerfilePath -Content $dockerfileContent
Write-KitFile -Path $specPath -Content $specContent

$skipBuild = $false
if (-not $Force -and (Test-SbxTemplateLoaded -ImageTag $ImageTag)) {
    Write-Host ""
    Write-Host "Image '$ImageTag' is already loaded into sbx's template store ('sbx template ls')." -ForegroundColor Green
    Write-Host -NoNewline "Rebuild and reload it anyway, e.g. to pick up a new -VibeVersion? (y/N): "
    $rebuildAnswer = Read-Host
    if ($rebuildAnswer -notmatch '^(y|yes)$') {
        $skipBuild = $true
        Write-Host "Skipping build/save/load -- using the already-loaded image." -ForegroundColor Yellow
    }
}

if (-not $skipBuild) {
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
