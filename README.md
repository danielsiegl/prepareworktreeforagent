# prepareworktreeforagent

![Maintained](https://img.shields.io/badge/maintained-yes-brightgreen.svg)

Scripts that prepare an isolated environment for an AI coding agent (GitHub
Copilot, OpenAI Codex, Anthropic Claude, or Mistral Vibe). The `worktree`
scripts create a new branch on top of your current feature branch and check
it out as a separate git worktree, then launch the chosen CLI agent inside
that directory. `new-cli-sbx.ps1` instead launches the agent inside an
isolated Docker Sandbox and creates no git worktree at all — see below.

The following scripts are available:

| Script | Platform |
|---|---|
| `new-cli-worktree.ps1` | Windows (PowerShell) |
| `new-cli-worktree.sh` | Linux / macOS / WSL (Bash) |
| `new-cli-sbx.ps1` | Windows (PowerShell) — runs the agent inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) instead of directly on the host, no host worktree needed |
| `new-cli-vibe.ps1` | Windows (PowerShell) — shortcut for `new-cli-sbx.ps1 -Cli vibe` |
| `build-vibe-sbx-kit.ps1` | Windows (PowerShell) — one-time setup: builds a local Docker Sandbox image/kit for Mistral Vibe, since `sbx` has no built-in template for it |

## Usage

### PowerShell (Windows)

```powershell
.\new-cli-worktree.ps1 [-repopath <path>] [-Cli <copilot|codex|claude|vibe>]
```

If `-repopath` is omitted, the script uses the current working directory.  
If `-Cli` is omitted, the script prompts interactively.
CLIs that are not installed are marked as unavailable and cannot be selected.

#### Parameters

- `-repopath <path>`: Path to the git repository to use.
- `-Cli <copilot|codex|claude|vibe>`: CLI agent to start.

### Bash (Linux / macOS / WSL)

```bash
./new-cli-worktree.sh [-p <path>] [-c <copilot|codex|claude|vibe>]
```

If `-p` is omitted, the script uses the current working directory.  
If `-c` is omitted, the script prompts interactively.
CLIs that are not installed are marked as unavailable and cannot be selected.

#### Options

- `-p <path>`: Path to the git repository to use.
- `-c <copilot|codex|claude|vibe>`: CLI agent to start.

### PowerShell with Docker Sandboxes (`new-cli-sbx.ps1`)

```powershell
.\new-cli-sbx.ps1 [-repopath <path>] [-Cli <copilot|codex|claude|vibe>]
```

Instead of creating a git worktree on the host and launching the CLI agent
there, this script starts it inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
(`sbx`) using **clone mode**. `sbx` mounts your repository read-only and the
agent does its real work on a private clone that lives on the sandbox's own
(Linux) filesystem — avoiding the slow file I/O you get when an agent
repeatedly reads/writes a Windows (NTFS) path through a filesystem
passthrough. Because the clone itself provides isolation (the agent creates
its own branch inside it), **no host git worktree is created** for this
script.

`vibe` is passed straight through like the other agents, but unlike
`copilot`/`codex`/`claude`, `sbx` has no officially documented built-in
template for it — `sbx run` may fail to resolve it unless you've set up a
custom kit yourself.

`sbx run --clone` requires the *main* repository working directory — it
refuses to run from a linked git worktree (e.g. one created by
`new-cli-worktree.ps1`). If `-repopath` points at such a worktree, the script
automatically resolves it to the main repository root before starting the
sandbox.

After the sandbox starts, tell the agent which branch to create, e.g.:

> Create a branch `my-feature-copilot` and make the changes.

If the `sbx` CLI isn't installed, the script installs it automatically via:

```powershell
winget install -h Docker.sbx
```

Normally a fresh `winget install` isn't visible on `PATH` until you restart
your shell. To avoid that, the script re-reads the Machine/User `PATH` from
the registry right after installing (and falls back to searching the
`WindowsApps`/`WinGet` install folders for `sbx.exe`), so it can usually find
and use `sbx` immediately in the same session. If it still can't be found,
the script asks you to restart your shell and re-run it.

You still need to run `sbx login` yourself at least once (interactive
browser login; not automated by this script).

> [!IMPORTANT]
> The agent **cannot** fetch or pull its own changes back to your host. Your
> host repo is mounted **read-only** inside the sandbox (at
> `/run/sandbox/source`), so running `git fetch`/`git pull` from inside the
> agent session fails with something like
> `error: cannot open '.git/FETCH_HEAD': Read-only file system`. Don't ask
> the agent to run these — the script handles it for you instead: once the
> sandbox session ends, it automatically runs `git fetch sandbox-<name>` on
> the host and lists the branches it fetched, e.g.:
>
> ```powershell
> git checkout -b <branch-name> sandbox-<name>/<branch-name>
> ```
>
> Then push to `origin` on the host with your own credentials — or give the
> agent push access so it can push the branch to `origin` directly from
> inside the sandbox (that goes out over the network, not through the
> read-only host mount, so it works).

### `new-cli-vibe.ps1` — shortcut for Mistral Vibe

```powershell
.\new-cli-vibe.ps1 [-repopath <path>]
```

Thin wrapper that calls `new-cli-sbx.ps1 -Cli vibe` for you, so you don't
need to pass `-Cli vibe` or answer the interactive CLI-agent menu. Everything
else (sbx auto-install, clone-mode launch, automatic post-run `git fetch`) is
identical to `new-cli-sbx.ps1` — see above.

### `build-vibe-sbx-kit.ps1` — one-time setup for Mistral Vibe

`sbx` has no officially built-in agent template for Mistral Vibe. This
one-time setup script follows Docker's guide
([Run Mistral Vibe in a Docker Sandbox](https://docs.docker.com/guides/mistral-vibe-sandbox/))
to build your own local image and kit:

```powershell
.\build-vibe-sbx-kit.ps1 [-VibeVersion <version>] [-ImageTag <tag>] [-Force]
```

It:

1. Writes a pinned `Dockerfile` (installs `mistral-vibe` on top of the
   `docker/sandbox-templates:shell` base image) and a kit `spec.yaml`
   (wires the image to the Mistral API through the sandbox proxy, and
   declares the sandbox's network policy) under
   `sbx-kits\mistral-vibe\`.
2. Builds the image **locally only** — single platform, no registry push,
   tagged `sbx-mistral-vibe:local` by default (override with `-ImageTag`).
3. Optionally runs `sbx secret set mistral` so the sandbox proxy can inject
   your Mistral API key without it ever entering the VM.

It does **not** run `sbx kit validate` or `sbx run` automatically — it
prints the exact commands to run yourself once you're ready:

```powershell
sbx kit validate .\sbx-kits\mistral-vibe
sbx run .\sbx-kits\mistral-vibe --name mistral-vibe .
```

Prerequisites: Docker Desktop/Engine running, `sbx` installed and signed in,
and a [Mistral API key](https://console.mistral.ai/).

> [!NOTE]
> Wiring `new-cli-sbx.ps1`'s/`new-cli-vibe.ps1`'s `vibe` option to use this
> kit automatically (instead of passing the plain agent name `vibe`, which
> `sbx run` can't resolve on its own) isn't done yet — run the kit directly
> with `sbx run .\sbx-kits\mistral-vibe ...` for now.

## What `new-cli-worktree.ps1` / `new-cli-worktree.sh` do

1. Detects the current git repository root and active branch.
2. Creates a new branch named `<current-branch>-<cli>` (e.g. `my-feature-copilot`).
3. Adds a git worktree for that branch in a sibling directory named `<repo>-<new-branch>` (e.g. `../myrepo-my-feature-copilot`).
4. Reuses the existing worktree if it was already created previously.
5. Launches the selected CLI agent (`copilot`, `codex`, `claude`, or `vibe`) inside the new worktree directory.

`new-cli-sbx.ps1` instead launches the agent inside a Docker Sandbox, with no
host worktree step — see above.

## Requirements

- Git must be installed and available on `PATH`.
- For `new-cli-sbx.ps1` / `new-cli-vibe.ps1`: the [Docker Sandboxes `sbx` CLI](https://docs.docker.com/ai/sandboxes/install/)
  (auto-installed via `winget` if missing) and a one-time `sbx login`.
- For `build-vibe-sbx-kit.ps1`: Docker Desktop/Engine running, `sbx` installed
  and signed in, and a [Mistral API key](https://console.mistral.ai/).
- At least one of the supported CLI tools must be installed:
  - [GitHub Copilot CLI](https://githubnext.com/projects/copilot-cli) (`copilot`)
  - [OpenAI Codex CLI](https://github.com/openai/codex) (`codex`)
  - [Claude CLI](https://github.com/anthropics/claude-code) (`claude`)
  - [Mistral Vibe CLI](https://github.com/mistralai/mistral-vibe) (`vibe`)

## Examples

```powershell
# PowerShell — from inside your feature branch
.\new-cli-worktree.ps1 -Cli copilot
# Creates branch 'my-feature-copilot' and opens Copilot in ../myrepo-my-feature-copilot
```

```bash
# Bash — from inside your feature branch
./new-cli-worktree.sh -c copilot
# Creates branch 'my-feature-copilot' and opens Copilot in ../myrepo-my-feature-copilot
```

```powershell
# PowerShell + Docker Sandboxes — from inside your repo
.\new-cli-sbx.ps1 -Cli copilot
# Starts Copilot inside a Docker Sandbox (clone mode) named '<repo>-copilot';
# ask the agent to create its own branch, e.g. 'my-feature-copilot'
```

```powershell
# PowerShell + Docker Sandboxes — Mistral Vibe shortcut
.\new-cli-vibe.ps1
# Same as '.\new-cli-sbx.ps1 -Cli vibe', no CLI-agent prompt
```

```powershell
# One-time setup: build a local sbx image/kit for Mistral Vibe
.\build-vibe-sbx-kit.ps1
# Writes sbx-kits\mistral-vibe\{Dockerfile,spec.yaml} and builds the image locally
```

## SmartGit Integration

This is how to call the PowerShell script from SmartGit:

Open Edit, Preferences, Tools and create a new entry or copy the "Open in Powershell" entry and start from there. (you need to adapt the path to the script)

SmartGit help page for this section: [Preferences -> Tools](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Preferences/Tools.html).

```cmd
cmd.exe 
/c start pwsh.exe -NoExit "C:\repos\your-user\prepareworktreeforagent\new-cli-worktree.ps1" -repopath "${filePath}"
```
