#!/usr/bin/env bash
# Creates or reuses a git worktree and launches a CLI agent (copilot, codex, or claude).
#
# Usage: ./new-cli-worktree.sh [-p <repopath>] [-c <cli>]
#   -p  Path to the git repository (default: current directory)
#   -c  CLI agent to launch: copilot | codex | claude

set -euo pipefail

show_rabbit() {
    printf ' (\\_/)\n ('"'"'.'"'"'.)\n (")(")
\n'
}

show_cat() {
    printf '  /\\_/\\\n ( o.o )\n  > ^ <\n'
}

read_cli_choice() {
    echo ""
    printf '\033[0;36mSelect CLI agent:\033[0m\n'
    echo "  1) copilot"
    echo "  2) codex"
    echo "  3) claude"
    echo ""

    while true; do
        printf 'Enter 1, 2, or 3: '
        # Read a single character without requiring Enter
        if [ -t 0 ]; then
            old_tty=$(stty -g)
            stty raw -echo
            key=$(dd bs=1 count=1 2>/dev/null)
            stty "$old_tty"
            echo "$key"
        else
            read -r key
        fi

        case "$key" in
            1) echo "copilot"; return ;;
            2) echo "codex";   return ;;
            3) echo "claude";  return ;;
            *) printf '\033[0;33mPlease press 1, 2, or 3.\033[0m\n' ;;
        esac
    done
}

normalize_path() {
    # Resolve to absolute path, strip trailing slashes, lowercase
    local p
    p=$(realpath -m "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1")
    echo "${p%/}" | tr '[:upper:]' '[:lower:]'
}

# ---------- parse arguments ----------
repopath=""
cli_arg=""

while getopts ":p:c:" opt; do
    case $opt in
        p) repopath="$OPTARG" ;;
        c) cli_arg="$OPTARG" ;;
        \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
        :)  echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
    esac
done

# ---------- set repo path ----------
if [ -z "$repopath" ]; then
    repopath="$(pwd)"
fi

show_rabbit
show_cat
echo "Using git repo $repopath"
cd "$repopath"

# ---------- choose CLI ----------
if [ -z "$cli_arg" ]; then
    cli_arg=$(read_cli_choice)
fi

case "$cli_arg" in
    copilot|codex|claude) ;;
    *) echo "Invalid CLI '$cli_arg'. Choose copilot, codex, or claude." >&2; exit 1 ;;
esac

# ---------- validate git repo ----------
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: current directory is not inside a git repository." >&2
    exit 1
}
repo_root="${repo_root%$'\r'}"   # strip Windows CR if running under WSL with a Windows git

current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    echo "Error: failed to determine current branch." >&2
    exit 1
}
current_branch="${current_branch%$'\r'}"

if [ "$current_branch" = "HEAD" ]; then
    echo "Error: repository is in detached HEAD state. Check out a branch first." >&2
    exit 1
fi

# ---------- derive names ----------
new_branch="${current_branch}-${cli_arg}"
parent_dir=$(dirname "$repo_root")
repo_name=$(basename "$repo_root")
worktree_dir="${parent_dir}/${repo_name}-${new_branch}"

# ---------- inspect registered worktrees ----------
get_worktree_path_for_branch() {
    # Returns the worktree path registered for refs/heads/<branch>, or empty string
    local branch_ref="refs/heads/$1"
    local current_path=""
    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            current_path="${line#worktree }"
        elif [[ "$line" == "branch $branch_ref" ]]; then
            echo "$current_path"
            return
        fi
    done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
}

get_worktree_branch_for_path() {
    # Returns the branch registered for the given worktree path, or empty string
    local target
    target=$(normalize_path "$1")
    local current_path="" current_branch_ref=""
    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            current_path="${line#worktree }"
            current_branch_ref=""
        elif [[ "$line" == branch\ * ]]; then
            current_branch_ref="${line#branch }"
        elif [[ -z "$line" ]]; then
            if [ "$(normalize_path "$current_path")" = "$target" ]; then
                echo "$current_branch_ref"
                return
            fi
        fi
    done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
    # handle last block (no trailing blank line)
    if [ "$(normalize_path "$current_path")" = "$target" ]; then
        echo "$current_branch_ref"
    fi
}

worktree_to_use=""

existing_by_path=$(get_worktree_branch_for_path "$worktree_dir")
if [ -n "$existing_by_path" ]; then
    worktree_to_use="$worktree_dir"
    echo "Reusing existing worktree at '$worktree_to_use'."
elif [ -e "$worktree_dir" ]; then
    echo "Error: target directory exists but is not a registered git worktree: $worktree_dir" >&2
    exit 1
else
    existing_by_branch=$(get_worktree_path_for_branch "$new_branch")
    if [ -n "$existing_by_branch" ]; then
        worktree_to_use="$existing_by_branch"
        echo "Reusing existing worktree for '$new_branch' at '$worktree_to_use'."
    else
        if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$new_branch" 2>/dev/null; then
            echo "Branch exists, creating worktree on '$new_branch' at '$worktree_dir'."
            git -C "$repo_root" worktree add "$worktree_dir" "$new_branch"
        else
            echo "Creating branch '$new_branch' from '$current_branch' and adding worktree at '$worktree_dir'."
            git -C "$repo_root" worktree add -b "$new_branch" "$worktree_dir" "$current_branch"
        fi
        worktree_to_use="$worktree_dir"
    fi
fi

echo "Done."
echo "Repository : $repo_root"
echo "Branch     : $new_branch"
echo "Worktree   : $worktree_to_use"

# ---------- launch CLI ----------
cli_command="$cli_arg"

if ! command -v "$cli_command" >/dev/null 2>&1; then
    echo "Warning: CLI command '$cli_command' was not found on PATH." >&2
    echo "Warning: Worktree is ready at: $worktree_to_use" >&2
    exit 0
fi

echo "Starting '$cli_command' in '$worktree_to_use'..."
cd "$worktree_to_use"
exec "$cli_command"
