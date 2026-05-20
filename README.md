# prepareworktreeforagent

A PowerShell script that prepares a Git worktree for an AI coding agent (GitHub Copilot, OpenAI Codex, or Anthropic Claude). It creates a new branch on top of your current feature branch and checks it out as a separate worktree, then launches the chosen CLI agent inside that directory.

## Usage

```powershell
.\new-cli-worktree.ps1 [-repopath <path>] [-Cli <copilot|codex|claude>] [-CodexInContainer] [-CodexContainerImage <image>]
```

If `-repopath` is omitted or empty, the script uses the current working directory.
If `-Cli` is omitted, the script will prompt you interactively.

### Parameters

- `-repopath <path>`: Path to the git repository to use.
- `-Cli <copilot|codex|claude>`: CLI agent to start.
- `-CodexInContainer`: (Codex only) Runs Codex via Docker with the created worktree mounted to `/workspace`.
- `-CodexContainerImage <image>`: Docker image to use with `-CodexInContainer` (default: `my-codex-image`).

## What it does

1. Detects the current git repository root and active branch.
2. Creates a new branch named `<current-branch>-<cli>` (e.g. `my-feature-copilot`).
3. Adds a git worktree for that branch in a sibling directory named `<repo>-<cli>` (e.g. `../myrepo-copilot`).
4. Launches the selected CLI agent (`copilot`, `codex`, or `claude`) inside the new worktree directory.
   - Optionally, `codex` can be launched inside a Docker container with the worktree bind-mounted.

## Requirements

- Git must be installed and available on `PATH`.
- At least one of the supported CLI tools must be installed:
  - [GitHub Copilot CLI](https://githubnext.com/projects/copilot-cli) (`copilot`)
  - [OpenAI Codex CLI](https://github.com/openai/codex) (`codex`)
  - [Claude CLI](https://github.com/anthropics/claude-code) (`claude`)

## Example

```powershell
# From inside your feature branch
.\new-cli-worktree.ps1 -Cli copilot
# Creates branch 'my-feature-copilot' and opens Copilot in ../myrepo-copilot
```

```powershell
# Run Codex in Docker using the generated worktree bind mount
.\new-cli-worktree.ps1 -Cli codex -CodexInContainer -CodexContainerImage my-codex-image
```

## Docker image for Codex

This repository includes a `Dockerfile` for the `my-codex-image` example used above.

```bash
docker build -t my-codex-image .
```

## SmartGit Integration

This is how to call the script from SmartGit:

Open Edit, Preferences, Tools and Create a new entry or copy the "Open in Powershell" and start from there.

SmartGit help page for this section: [Preferences -> Tools](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Preferences/Tools.html).

```cmd
cmd.exe 
/c start pwsh.exe -NoExit "C:\repos\your-user\prepareworktreeforagent\new-cli-worktree.ps1" -repopath "${filePath}"
```
