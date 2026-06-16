# prepareworktreeforagent

Scripts that prepare a Git worktree for an AI coding agent (GitHub Copilot, OpenAI Codex, or Anthropic Claude). They create a new branch on top of your current feature branch and check it out as a separate worktree, then launch the chosen CLI agent inside that directory.

Two versions are available:

| Script | Platform |
|---|---|
| `new-cli-worktree.ps1` | Windows (PowerShell) |
| `new-cli-worktree.sh` | Linux / macOS / WSL (Bash) |

## Usage

### PowerShell (Windows)

```powershell
.\new-cli-worktree.ps1 [-repopath <path>] [-Cli <copilot|codex|claude>]
```

If `-repopath` is omitted, the script uses the current working directory.  
If `-Cli` is omitted, the script prompts interactively.

#### Parameters

- `-repopath <path>`: Path to the git repository to use.
- `-Cli <copilot|codex|claude>`: CLI agent to start.

### Bash (Linux / macOS / WSL)

```bash
./new-cli-worktree.sh [-p <path>] [-c <copilot|codex|claude>]
```

If `-p` is omitted, the script uses the current working directory.  
If `-c` is omitted, the script prompts interactively.

#### Options

- `-p <path>`: Path to the git repository to use.
- `-c <copilot|codex|claude>`: CLI agent to start.

## What it does

1. Detects the current git repository root and active branch.
2. Creates a new branch named `<current-branch>-<cli>` (e.g. `my-feature-copilot`).
3. Adds a git worktree for that branch in a sibling directory named `<repo>-<new-branch>` (e.g. `../myrepo-my-feature-copilot`).
4. Reuses the existing worktree if it was already created previously.
5. Launches the selected CLI agent (`copilot`, `codex`, or `claude`) inside the new worktree directory.

## Requirements

- Git must be installed and available on `PATH`.
- At least one of the supported CLI tools must be installed:
  - [GitHub Copilot CLI](https://githubnext.com/projects/copilot-cli) (`copilot`)
  - [OpenAI Codex CLI](https://github.com/openai/codex) (`codex`)
  - [Claude CLI](https://github.com/anthropics/claude-code) (`claude`)

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

## SmartGit Integration

This is how to call the PowerShell script from SmartGit:

Open Edit, Preferences, Tools and create a new entry or copy the "Open in Powershell" entry and start from there.

SmartGit help page for this section: [Preferences -> Tools](https://docs.syntevo.com/SmartGit/Latest/Manual/GUI/Preferences/Tools.html).

```cmd
cmd.exe 
/c start pwsh.exe -NoExit "C:\repos\your-user\prepareworktreeforagent\new-cli-worktree.ps1" -repopath "${filePath}"
```
