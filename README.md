# prepareworktreeforagent

Scripts that prepare a Git worktree for an AI coding agent (GitHub Copilot, OpenAI Codex, Anthropic Claude, or Mistral Vibe). They create a new branch on top of your current feature branch and check it out as a separate worktree, then launch the chosen CLI agent inside that directory.

Two versions are available:

| Script | Platform |
|---|---|
| `new-cli-worktree.ps1` | Windows (PowerShell) |
| `new-cli-worktree.sh` | Linux / macOS / WSL (Bash) |
| `start-sbx.ps1` | Windows (PowerShell) — runs the agent inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) instead of directly on the host, no host worktree needed |
| `start-vibe-sbx.ps1` | Windows (PowerShell) — shortcut for `start-sbx.ps1 -Cli vibe` |
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

### PowerShell with Docker Sandboxes (`start-sbx.ps1`)

```powershell
.\start-sbx.ps1 [-repopath <path>] [-Cli <copilot|codex|claude|vibe>]
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

### `start-vibe-sbx.ps1` — shortcut for Mistral Vibe

```powershell
.\start-vibe-sbx.ps1 [-repopath <path>]
```

Thin wrapper that calls `start-sbx.ps1 -Cli vibe` for you, so you don't
need to pass `-Cli vibe` or answer the interactive CLI-agent menu. Everything
else (sbx auto-install, clone-mode launch, automatic post-run `git fetch`) is
identical to `start-sbx.ps1` — see above.

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

`start-sbx.ps1` instead launches the agent inside a Docker Sandbox, with no
host worktree step — see above.

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

## VS Code in a Docker sandbox

`new-vscode-sbx.ps1` (PowerShell 7 / `pwsh`) runs the agent inside a [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`) microVM in **clone mode**. Only the **VS Code window** runs on your machine.

- The VS Code server, its extension host, the **Mistral Vibe** extension (`mistralai.mistral-vibe-code`) and every terminal run in the sandbox. The window connects to them with [Remote - SSH](https://code.visualstudio.com/docs/remote/ssh) on a port bound to `127.0.0.1`.
- The sandbox works on a private clone that is reduced to the **current branch**. Your host working tree is never written.
- Push URLs are disabled, and GitHub, GitLab, Bitbucket and Azure DevOps are blocked. Work leaves the sandbox only when **you fetch it**.

```powershell
.\new-vscode-sbx.ps1 [-repopath <path>] [-Memory 8g] [-Port 2222]
```

### Workflow

1. Store your Mistral key once: `sbx secret set mistral`. The sbx proxy injects it, so it never enters the sandbox.
2. **Commit first.** The sandbox clones committed state only, and the script warns if the working tree has uncommitted changes.
3. Run the script from your feature branch. It does the following:
   - creates the sandbox `vscode-<repo>-<branch>`; the first run builds the kit from `vscode-sbx/`, which takes a few minutes,
   - starts an SSH server inside the sandbox,
   - writes an SSH host entry with the same name under `~/.ssh/vscode-sbx/`,
   - installs Remote - SSH if missing,
   - opens VS Code on the sandbox.
4. Choose **Linux** if VS Code asks for the remote platform. The Mistral Vibe extension is installed into the sandbox automatically on the first connect. Run *Developer: Reload Window* if it doesn't show up straight away.
5. Let Vibe work and commit inside the sandbox.
6. Fetch the result on the host:
   ```bash
   git fetch sandbox-vscode-<repo>-<branch>
   git log <branch>..sandbox-vscode-<repo>-<branch>/<branch>
   git merge sandbox-vscode-<repo>-<branch>/<branch>   # or cherry-pick
   ```
7. Pause with `sbx stop <name>` and re-run the script to continue. Run `sbx rm <name>` **only after fetching**, because it deletes the in-sandbox clone.

**Stale kit image:** sbx sometimes reuses a cached kit image after files in `vscode-sbx/` changed. The script detects this and prints a warning. To rebuild, first fetch any work. Then run `sbx rm <name>`, find the `sbx-kit-src vscode-sbx-*` images with `sbx template ls` and remove them with `sbx template rm`, and re-run the script.

### What the script changes on your machine

- `~/.ssh/vscode-sbx/`: a dedicated key pair (`id_ed25519`), one `<sandbox>.conf` host entry per sandbox, and per-sandbox `known_hosts_*` files.
- `~/.ssh/config`: the line `Include vscode-sbx/*.conf` is added once at the top. Nothing else in the file is touched.

### Kit (`vscode-sbx/`)

| File | Purpose |
|---|---|
| `vscode-sbx.dockerfile` | Ubuntu 24.04 + OpenSSH server + .NET SDK + Mistral Vibe CLI, user `agent` (UID 1000) |
| `vscode-sbx.yaml` | sbx descriptor: network allowlist (VS Code server/marketplace, Mistral, NuGet) and Mistral credential injection |
| `vscode-sbx-start.sh` | Trims the clone to the current branch, starts an unprivileged `sshd` (key-only, port 2222) with the sbx proxy environment, and installs Mistral Vibe into the VS Code server once Remote - SSH has deployed it |

The limitations listed for the Rider variant below apply here too: the read-only host mount at `/run/sandbox/source`, and the fact that the network allowlist adds to sbx's global policy. The VS Code launcher doesn't block `*.visualstudio.com`, because `marketplace.visualstudio.com` serves the extensions.

## Rider in a Docker sandbox

`new-rider-sbx.ps1` gives stronger isolation than a worktree. It starts JetBrains Rider inside a [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`) microVM in **clone mode**.

- The sandbox gets a private Git clone of the **current branch**. Your host working tree is never written.
- Rider runs there as a **remote-dev backend**. The only thing published is its UI port on `127.0.0.1`, and you work through JetBrains Gateway / Client.
- **Mistral Vibe** is registered as an ACP agent (`vibe-acp`) in Rider's AI chat, so all agentic work happens inside the sandbox.
- Push URLs inside the clone are disabled and git forges are blocked. Work leaves the sandbox only when **you fetch it**.

```powershell
.\new-rider-sbx.ps1 [-repopath <path>] [-Memory 8g] [-Port 5990]
```

### Workflow

1. Store your Mistral key once: `sbx secret set mistral`. The proxy injects it, so it never enters the sandbox.
2. Run the script from your feature branch. The first run builds the kit from `rider-sbx/`, which takes a few minutes.
3. Paste the `Join link: tcp://127.0.0.1:<Port>#…` from the output into JetBrains Gateway (*Connect to running IDE*).
4. Let Vibe work in Rider and commit inside the sandbox.
5. Fetch the result on the host:
   ```bash
   git fetch sandbox-rider-<repo>-<branch>
   git log <branch>..sandbox-rider-<repo>-<branch>/<branch>
   git merge sandbox-rider-<repo>-<branch>/<branch>   # or cherry-pick
   ```
6. Detach with `Ctrl-\` to leave the IDE running, and re-run the script to re-attach. Run `sbx rm <name>` **only after fetching**, because it deletes the in-sandbox clone.

### Requirements

- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`).
- JetBrains Gateway or Toolbox with a Rider license. The license is checked on the client side.
- A Mistral API key.
- The script must run from the repository's main checkout, because sbx clone mode does not support linked worktrees.

### Kit (`rider-sbx/`)

| File | Purpose |
|---|---|
| `rider-sbx.dockerfile` | Ubuntu 24.04 + .NET SDK + Rider + Mistral Vibe, user `agent` (UID 1000) |
| `rider-sbx.yaml` | sbx descriptor: build args (`riderVersion`, `dotnetChannel`), network allowlist (JetBrains, NuGet, Mistral only), Mistral credential injection |
| `entrypoint.sh` | Disables push URLs, sets the git identity, starts `remote-dev-server.sh` on port 5990 |
| `acp.json` | Registers `vibe-acp` as an agent in Rider's AI chat |

You can override the kit args, for example `sbx run … --kit-arg riderVersion=2026.1 ./rider-sbx .`.

### Known limitations

- sbx makes a *full* clone, including all branches, tags and the host's remotes, and it borrows objects from the host repo through git alternates. On every start, `entrypoint.sh` reduces the clone to the checked-out branch, copies in the objects that branch needs and removes the alternates link. After that, other branches are not reachable from the agent's working repository.
- sbx still mounts the host repository **read-only** at `/run/sandbox/source`, including `.git`, and not even root inside the VM can unmount it. A process that deliberately reads that path can see other branches, but it can't modify them. Rider and Vibe work only in the trimmed clone.
- The kit's network allowlist **adds to** sbx's global allow policy; it doesn't replace it. That global policy already permits github.com and the other common forges. The launcher blocks GitHub, GitLab, Bitbucket and Azure DevOps (including subdomains) with `--deny-network`. If you run `sbx run ./rider-sbx` by hand, add those flags yourself. Other hosts on the global list stay reachable; tighten them with `sbx policy`.
- Rider needs plenty of RAM. Raise `-Memory` for large solutions.

## SmartGit Integration

This is how to call the PowerShell script from SmartGit:

Open Edit, Preferences, Tools and create a new entry or copy the "Open in Powershell" entry and start from there. (you need to adapt the path to the script)

SmartGit help page for this section: [Preferences -> Tools](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Preferences/Tools.html).

```cmd
cmd.exe 
/c start pwsh.exe -NoExit "C:\repos\your-user\prepareworktreeforagent\new-cli-worktree.ps1" -repopath "${filePath}"
```
