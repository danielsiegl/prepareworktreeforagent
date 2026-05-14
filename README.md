# prepareworktreeforagent

A PowerShell script that prepares a Git worktree for an AI coding agent (GitHub Copilot, OpenAI Codex, or Anthropic Claude). It creates a new branch on top of your current feature branch and checks it out as a separate worktree, then launches the chosen CLI agent inside that directory.

## Issue 

* can't handle existing worktree:
pwsh C:\repos\danielsiegl\prepareworktreeforagent\new-cli-worktree.ps1 -repopath "C:\repos\danielsiegl\ai-commit-message-benchmarks"
* update docs
* if repopath is not set we should use the current location


## Usage

```powershell
.\new-cli-worktree.ps1 [-Cli <copilot|codex|claude>]
```

If `-Cli` is omitted, the script will prompt you interactively.

## What it does

1. Detects the current git repository root and active branch.
2. Creates a new branch named `<current-branch>-<cli>` (e.g. `my-feature-copilot`).
3. Adds a git worktree for that branch in a sibling directory named `<repo>-<cli>` (e.g. `../myrepo-copilot`).
4. Launches the selected CLI agent (`copilot`, `codex`, or `claude`) inside the new worktree directory.

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
