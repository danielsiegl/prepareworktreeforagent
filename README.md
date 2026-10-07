# prepareworktreeforagent

![Maintained](https://img.shields.io/badge/maintained-yes-brightgreen.svg)

Scripts that prepare an isolated environment for an AI coding agent (GitHub
Copilot, OpenAI Codex, Anthropic Claude, or Mistral Vibe). The `worktree`
scripts create a new branch on top of your current feature branch and check
it out as a separate git worktree, then launch the chosen CLI agent inside
that directory. `start-sbx.ps1` instead launches the agent inside a Docker
Sandbox, and supports two modes: an isolated **clone** mode (no host
worktree) or a **worktree** mode (mounts a host git worktree, like the
`worktree` scripts) — see below.

The following scripts are available:

| Script | Platform |
|---|---|
| `new-cli-worktree.ps1` | Windows (PowerShell) |
| `new-cli-worktree.sh` | Linux / macOS / WSL (Bash) |
| `start-sbx.ps1` | Windows (PowerShell) — runs the agent inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/), in either clone mode (no host worktree) or worktree mode (mounts a host git worktree) |
| `start-vibe-sbx.ps1` | Windows (PowerShell) — shortcut for `start-sbx.ps1 -Cli vibe` |
| `build-vibe-sbx-kit.ps1` | Windows (PowerShell) — one-time setup: builds a local Docker Sandbox image/kit for Mistral Vibe, since `sbx` has no built-in template for it |
| `worktree-lib.ps1` | Windows (PowerShell) — shared helper module (not run directly) with the git worktree create/reuse logic used by both `new-cli-worktree.ps1` and `start-sbx.ps1` (worktree mode) |

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

### PowerShell with Docker Sandboxes (`start-sbx.ps1`)

```powershell
.\start-sbx.ps1 [-repopath <path>] [-Cli <copilot|codex|claude|vibe>] [-Mode <clone|worktree>]
```

Starts the CLI agent inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
(`sbx`), using one of two mount modes. If `-Mode` is omitted, the script
prompts interactively (like it does for `-Cli`).

#### `-Mode clone` (isolated in-sandbox clone)

`sbx` mounts your repository read-only and the agent does its real work on a
private clone that lives on the sandbox's own (Linux) filesystem —
avoiding the slow file I/O you get when an agent repeatedly reads/writes a
Windows (NTFS) path through a filesystem passthrough. Because the clone
itself provides isolation (the agent creates its own branch inside it),
**no host git worktree is created** for this mode.

#### `-Mode worktree` (host git worktree)

The script creates (or reuses) a git branch/worktree on the host named
`<current-branch>-<cli>` in a sibling directory — the same logic
`new-cli-worktree.ps1` uses (shared via `worktree-lib.ps1`) — then runs
`sbx run` **without** `--clone`, mounting that worktree directory directly.
The agent's commits land straight on the host worktree's branch, so there's
no post-session `git fetch` step: just push from the host worktree directly
when you're ready.

`vibe` doesn't use a `sbx`-builtin agent template (there isn't one). Instead,
this script automatically uses the local sandbox kit built by
`build-vibe-sbx-kit.ps1` (see below), referencing it by path, e.g.
`sbx run --clone --name <name> .\sbx-kits\mistral-vibe <repoRoot>`. **Run
`build-vibe-sbx-kit.ps1` once before using `-Cli vibe` / `new-cli-vibe.ps1`
for the first time** — if the kit isn't found, the script exits with an
error telling you to build it first, instead of trying (and failing) with a
plain `vibe` agent name. Before launching, the script also checks `sbx
secret ls` and prints a warning if no Mistral API key is stored, since
`vibe` will otherwise fail to call the Mistral API. It also checks `sbx
template ls` to confirm the kit's image is actually loaded into sbx's
sandbox runtime image store (not just that the kit files exist on disk) and
warns if it's missing — e.g. after a Docker Desktop reset — telling you to
re-run `build-vibe-sbx-kit.ps1`.

`sbx run --clone` requires the *main* repository working directory — it
refuses to run from a linked git worktree (e.g. one created by
`new-cli-worktree.ps1`). If `-repopath` points at such a worktree, the script
automatically resolves it to the main repository root before starting the
sandbox (this resolution applies to both modes — `worktree` mode's own
branch/worktree is created from that resolved main repo root).

In `clone` mode, after the sandbox starts, tell the agent which branch to
create, e.g.:

> Create a branch `my-feature-copilot` and make the changes.

In `worktree` mode, the branch/worktree is already created and checked out
before the agent starts, so no such instruction is needed.

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
> This applies to **`clone` mode only**. The agent **cannot** fetch or pull
> its own changes back to your host. Your host repo is mounted **read-only**
> inside the sandbox (at `/run/sandbox/source`), so running `git
> fetch`/`git pull` from inside the agent session fails with something like
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
>
> In **`worktree` mode**, the worktree directory is mounted directly (not
> read-only), so the agent's commits land straight on that branch — no
> post-session fetch step is needed. Push to `origin` from the host worktree
> yourself when ready.

### `start-vibe-sbx.ps1` — shortcut for Mistral Vibe

```powershell
.\start-vibe-sbx.ps1 [-repopath <path>] [-Mode <clone|worktree>]
```

Thin wrapper that calls `start-sbx.ps1 -Cli vibe` for you, so you don't
need to pass `-Cli vibe` or answer the interactive CLI-agent menu. `-Mode`
is forwarded to `start-sbx.ps1` as-is (and, like there, prompts interactively
if omitted). Everything else (sbx auto-install, clone/worktree mode launch,
automatic post-run `git fetch` in clone mode) is identical to
`start-sbx.ps1` — see above.

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
2. Checks `sbx template ls` to see whether `-ImageTag` is **already loaded**
   into `sbx`'s own sandbox runtime image store, and if so asks before
   spending several minutes rebuilding it (pass `-Force` to always rebuild).
   Checking only whether the kit files exist on disk isn't enough — the store
   can be emptied independently (Docker Desktop reset, `sbx template rm`, a
   new machine) while the kit files stay behind.
3. Builds the image **locally only** — single platform, no registry push,
   tagged `sbx-mistral-vibe:<VibeVersion>` by default, e.g.
   `sbx-mistral-vibe:2.25.8` (override with `-ImageTag`). The tag is
   version-qualified rather than a floating `:local` tag so that bumping
   `-VibeVersion` always builds/loads a genuinely new image instead of
   silently reusing a stale image cached under the same tag.
4. Loads the built image into `sbx`'s own sandbox runtime image store via
   `docker save` + `sbx template load`. This step is required: `sbx`'s
   `sandboxd` keeps a private image store that is **not** the same as
   Docker Desktop's regular image list, so a plain `docker build` is
   otherwise invisible to `sbx run` (it fails with `403 Forbidden: pull
   failed for image "sbx-mistral-vibe:<tag>"`, since `sbx` tries to pull
   the tag from a registry that doesn't have it).
5. Sets `sandbox.entrypoint: ["vibe", "--agent", "auto-approve"]` in the
   generated `spec.yaml`. This is required: without it, `sbx run` attaches a
   plain shell instead of starting `vibe` (the Docker image's own `CMD` is
   not enough — `sbx` needs the kit's `entrypoint` field to know what to
   launch as the interactive agent session).
6. Checks `sbx secret ls` and tells you whether a Mistral API key is
   already stored before asking whether to run `sbx secret set mistral` —
   so the sandbox proxy can inject your key without it ever entering the VM.

It does **not** run `sbx kit validate` or `sbx run` automatically — it
prints the exact commands to run yourself once you're ready:

```powershell
sbx kit validate .\sbx-kits\mistral-vibe
sbx run .\sbx-kits\mistral-vibe --name mistral-vibe --pull never .
```

`--pull never` is required: the image was loaded directly into `sbx`'s
sandbox runtime store above, not pushed to a registry, so the default
`--pull always`/`missing` policies would still try (and fail) to pull it.

Prerequisites: Docker Desktop/Engine running, `sbx` installed and signed in,
and a [Mistral API key](https://chat.mistral.ai/code/extensions?focus=key).

> [!NOTE]
> You normally don't need to run this script yourself: `start-sbx.ps1 -Cli
> vibe` and `start-vibe-sbx.ps1` build this kit automatically the first
> time they can't find its image, then use it (referencing
> `sbx-kits\mistral-vibe` by path, with `--pull never`, instead of passing
> the plain agent name `vibe`, which `sbx run` can't resolve on its own).
> You can still run this script manually to rebuild the kit (e.g. after
> bumping `-VibeVersion`), or run the kit directly with
> `sbx run --clone --pull never .\sbx-kits\mistral-vibe ...`.

## What `new-cli-worktree.ps1` / `new-cli-worktree.sh` do

1. Detects the current git repository root and active branch.
2. Creates a new branch named `<current-branch>-<cli>` (e.g. `my-feature-copilot`).
3. Adds a git worktree for that branch in a sibling directory named `<repo>-<new-branch>` (e.g. `../myrepo-my-feature-copilot`).
4. Reuses the existing worktree if it was already created previously.
5. Launches the selected CLI agent (`copilot`, `codex`, `claude`, or `vibe`) inside the new worktree directory.

`start-sbx.ps1` instead launches the agent inside a Docker Sandbox. In
`clone` mode (the isolation/performance-focused default it offers), no host
worktree step happens — see above. In `worktree` mode, it performs steps 1–4
above itself (via the shared `worktree-lib.ps1` module — the same git
branch/worktree create-or-reuse logic as `new-cli-worktree.ps1`) before
mounting that worktree into the sandbox without `--clone`.

## Requirements

- Git must be installed and available on `PATH`.
- For `start-sbx.ps1` / `start-vibe-sbx.ps1`: the [Docker Sandboxes `sbx` CLI](https://docs.docker.com/ai/sandboxes/install/)
  (auto-installed via `winget` if missing) and a one-time `sbx login`.
- For `build-vibe-sbx-kit.ps1`: Docker Desktop/Engine running, `sbx` installed
  and signed in, and a [Mistral API key](https://chat.mistral.ai/code/extensions?focus=key).
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
.\start-sbx.ps1 -Cli copilot -Mode clone
# Starts Copilot inside a Docker Sandbox (clone mode) named '<repo>-copilot';
# ask the agent to create its own branch, e.g. 'my-feature-copilot'
```

```powershell
# PowerShell + Docker Sandboxes — worktree mode
.\start-sbx.ps1 -Cli copilot -Mode worktree
# Creates/reuses branch 'my-feature-copilot' + worktree ../myrepo-my-feature-copilot
# on the host, then mounts it into the sandbox (no --clone, no post-run fetch needed)
```

```powershell
# PowerShell + Docker Sandboxes — Mistral Vibe shortcut
.\start-vibe-sbx.ps1
# Same as '.\start-sbx.ps1 -Cli vibe', no CLI-agent prompt; prompts for -Mode if omitted
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
