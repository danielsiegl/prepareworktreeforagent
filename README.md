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

A linked worktree's `.git` is just a pointer file to the *main* repo's
`.git\worktrees\<name>` directory on the host — a path that doesn't exist
inside the sandbox, since only the worktree directory itself is mounted
(not the main repository). This is Docker's own documented ["Host
worktree"](https://docs.docker.com/ai/sandboxes/workflows/git/#host-worktree)
sandbox mode: because git can't resolve that pointer, the agent has **no git
access** there — confirmed by testing, it fails with `fatal: not a git
repository`. No extra kit or workaround is needed to enforce this — the
previous `sbx-kits\git-block` mixin kit (which stubbed out the `git` binary
inside the sandbox) has been removed since it was redundant with this
built-in behavior. Your host's `.git` is never touched and keeps full,
uninterrupted git access to the real worktree the whole time — even while
the sandbox session is still running — and file edits the agent makes
inside the sandbox show up there immediately (verified: no sync delay).
Review, stage, and commit the changes yourself on the host whenever you
like, e.g.:

```powershell
git -C <worktree-path> status
git -C <worktree-path> add -A
git -C <worktree-path> commit -m "..."
```

Then push to `origin` with your own credentials when ready.

Both modes reuse the same sandbox name (`<repo>-<cli>`), so switching modes
for the same repo+CLI (e.g. `worktree` then `clone`) could otherwise make
`sbx run` try to attach to the previous mode's stale sandbox — whose
workspace (a host worktree directory) may since have been removed, failing
with `422 Unprocessable Entity: workspace directory "..." no longer exists
on the host`. The script checks `sbx ls --json` before each run and
automatically removes (`sbx rm`) any existing sandbox of that name whose
workspace is missing or doesn't match the mode you're starting, so a fresh
sandbox is created instead.

> [!NOTE]
> **Why not `sbx run --branch`?** A few blog posts/articles about Docker
> Sandboxes mention a `--branch`/`--worktree` flag that has `sbx` create and
> manage the host worktree itself (under a `.sbx\` folder, cleaned up
> automatically by `sbx rm`). That flag **does not exist** in the installed
> `sbx` CLI used/tested with this repo (`v0.47.0` — confirmed by inspecting
> the full `sbx run --help` output, which has no `--branch`/`--worktree`
> flag). It may be a future/experimental feature not yet released, or
> specific to a different build. If a future `sbx` version ships it, it
> could replace this script's own worktree creation (`worktree-lib.ps1`) —
> but until then, this script manages the worktree itself and relies on
> `sbx`'s documented host-worktree git-blocking behavior, exactly as
> described above.

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
> read-only), and git is disabled for the agent *inside the sandbox only*
> (see above) — your host's `.git` is never modified, so there's nothing to
> fetch and nothing blocking you from using git on the worktree from the
> host at any time, including while the sandbox is still running. The
> agent's file edits sit in the host worktree as uncommitted changes.
> Review, stage, and commit them yourself on the host, then push to `origin`
> when ready.

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

`sbx` has no officially built-in agent template for Mistral Vibe. This repo
ships a hand-authored kit, checked into source control, based on Docker's
guide
([Run Mistral Vibe in a Docker Sandbox](https://docs.docker.com/guides/mistral-vibe-sandbox/)):

- `sbx-kits\mistral-vibe\Dockerfile` — installs `mistral-vibe` and the .NET
  SDK on top of the `docker/sandbox-templates:shell` base image, pinned via
  `ARG VIBE_VERSION` / `ARG DOTNET_VERSION` defaults. The .NET SDK is
  installed system-wide via Microsoft's `dotnet-install.sh` script (not
  `apt`, whose feed often lags behind the newest Ubuntu base images), so the
  agent can build/run/test .NET projects inside the sandbox.
- `sbx-kits\mistral-vibe\spec.yaml` — wires the image to the Mistral API
  through the sandbox proxy, declares the sandbox's network policy, sets
  `sandbox.entrypoint: ["vibe", "--agent", "auto-approve"]` (required —
  without it `sbx run` attaches a plain shell instead of starting `vibe`),
  and names the image tag to build/load in its `sandbox.image:` field.

This one-time setup script only **builds** from those checked-in files — it
does not generate or edit them:

```powershell
.\build-vibe-sbx-kit.ps1 [-Force]
```

It:

1. Reads the image tag to build from `spec.yaml`'s `sandbox.image:` field
   (e.g. `sbx-mistral-vibe:2.26.0-dotnet10.0`), so the Dockerfile and
   spec.yaml stay the single source of truth for versions — no script
   parameters to keep in sync with them.
2. Checks `sbx template ls` to see whether that tag is **already loaded**
   into `sbx`'s own sandbox runtime image store, and if so asks before
   spending several minutes rebuilding it (pass `-Force` to always rebuild).
   Checking only whether the kit files exist on disk isn't enough — the store
   can be emptied independently (Docker Desktop reset, `sbx template rm`, a
   new machine) while the kit files stay behind.
3. Builds the image **locally only** — single platform, no registry push.
4. Loads the built image into `sbx`'s own sandbox runtime image store via
   `docker save` + `sbx template load`. This step is required: `sbx`'s
   `sandboxd` keeps a private image store that is **not** the same as
   Docker Desktop's regular image list, so a plain `docker build` is
   otherwise invisible to `sbx run` (it fails with `403 Forbidden: pull
   failed for image "sbx-mistral-vibe:<tag>"`, since `sbx` tries to pull
   the tag from a registry that doesn't have it).
5. Checks `sbx secret ls` and tells you whether a Mistral API key is
   already stored before asking whether to run `sbx secret set mistral` —
   so the sandbox proxy can inject your key without it ever entering the VM.

> [!NOTE]
> **Bumping versions** (a new `mistral-vibe` release, a new .NET SDK
> version, or any other change to the image): hand-edit
> `sbx-kits\mistral-vibe\Dockerfile`'s `ARG` defaults, and update the
> matching `image:` tag in `sbx-kits\mistral-vibe\spec.yaml` to a new value
> (so a stale image cached under the old tag is never silently reused).
> Then run `.\build-vibe-sbx-kit.ps1 -Force`. These files are checked into
> git as plain, lintable Dockerfile/YAML — no PowerShell string-escaping
> involved.

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
> hand-editing the Dockerfile/spec.yaml to bump a version), or run the kit
> directly with `sbx run --clone --pull never .\sbx-kits\mistral-vibe ...`.

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
# Builds + loads the image from the checked-in sbx-kits\mistral-vibe\{Dockerfile,spec.yaml}
```

## SmartGit Integration

This is how to call the PowerShell script from SmartGit:

Open Edit, Preferences, Tools and create a new entry or copy the "Open in Powershell" entry and start from there. (you need to adapt the path to the script)

SmartGit help page for this section: [Preferences -> Tools](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Preferences/Tools.html).

```cmd
cmd.exe 
/c start pwsh.exe -NoExit "C:\repos\your-user\prepareworktreeforagent\new-cli-worktree.ps1" -repopath "${filePath}"
```
