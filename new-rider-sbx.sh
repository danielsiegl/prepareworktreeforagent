#!/usr/bin/env bash
# Creates or re-attaches a Docker sandbox (sbx, clone mode) running JetBrains Rider
# as a remote-dev backend with Mistral Vibe as agent.
#
# Usage: ./new-rider-sbx.sh [-p <repopath>] [-m <memory>] [-P <port>]
#   -p  Path to the git repository (default: current directory)
#   -m  Sandbox memory limit (default: 8g)
#   -P  Host port on 127.0.0.1 for the Rider remote-dev port (default: 5990)

set -euo pipefail

show_rabbit() {
    printf ' (\\_/)\n ('"'"'.'"'"'.)\n (")(")
\n'
}

show_cat() {
    printf '  /\\_/\\\n ( o.o )\n  > ^ <\n'
}

show_random_mascot() {
    if (( RANDOM % 2 )); then
        show_cat
    else
        show_rabbit
    fi
}

# ---------- parse arguments ----------
repopath=""
memory="8g"
port="5990"

while getopts ":p:m:P:" opt; do
    case $opt in
        p) repopath="$OPTARG" ;;
        m) memory="$OPTARG" ;;
        P) port="$OPTARG" ;;
        \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
        :)  echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
    esac
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kit_path="$script_dir/rider-sbx"

# Content hash of the kit: sbx can reuse a stale kit image after script edits; a new kitRevision forces the rebuild.
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
kit_revision=$(cd "$kit_path" && find . -maxdepth 1 -type f | LC_ALL=C sort | while IFS= read -r f; do sha256 "$f"; done \
    | cut -d' ' -f1 | tr -d '\n' | sha256 | cut -c1-12)

# ---------- set repo path ----------
if [ -z "$repopath" ]; then
    repopath="$(pwd)"
fi

show_random_mascot
echo "Using git repo $repopath"
cd "$repopath"

if ! command -v sbx >/dev/null 2>&1; then
    echo "Error: Docker Sandboxes CLI 'sbx' was not found on PATH." >&2
    exit 1
fi

# ---------- validate git repo ----------
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: current directory is not inside a git repository." >&2
    exit 1
}
repo_root="${repo_root%$'\r'}"

current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    echo "Error: failed to determine current branch." >&2
    exit 1
}
current_branch="${current_branch%$'\r'}"

if [ "$current_branch" = "HEAD" ]; then
    echo "Error: repository is in detached HEAD state. Check out a branch first." >&2
    exit 1
fi

# sbx clone mode only works on the main checkout, not on a linked worktree.
git_dir=$(git -C "$repo_root" rev-parse --absolute-git-dir)
common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)
if [ "${git_dir%$'\r'}" != "${common_dir%$'\r'}" ]; then
    echo "Error: '$repo_root' is a linked git worktree. sbx clone mode requires the main checkout." >&2
    exit 1
fi

if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then
    echo "Warning: the working tree has uncommitted changes. The sandbox clones committed state only;" >&2
    echo "Warning: commit (or stash) first if the agent should see them." >&2
fi

# ---------- derive names ----------
repo_name=$(basename "$repo_root")
sandbox_name=$(printf 'rider-%s-%s' "$repo_name" "$current_branch" \
    | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g')

echo "Repository : $repo_root"
echo "Branch     : $current_branch"
echo "Sandbox    : $sandbox_name"
echo "Rider port : 127.0.0.1:$port"

if ! sbx secret ls 2>/dev/null | grep -qw mistral; then
    echo "Warning: no 'mistral' secret stored. Vibe will not be able to reach the Mistral API." >&2
    echo "Warning: store one with: sbx secret set mistral" >&2
fi

printf '\n\033[0;36mNext steps:\033[0m\n'
echo "  1. Paste the 'Join link' (tcp://127.0.0.1:$port#...) printed below into JetBrains Gateway"
echo "     ('Connect to running IDE'). Rider needs a minute to start the first time."
echo "  2. Let Mistral Vibe work in Rider's AI chat and commit inside the sandbox."
echo "  3. On the host: git fetch sandbox-$sandbox_name"
echo "                  git log $current_branch..sandbox-$sandbox_name/$current_branch"
echo "  4. Only after fetching: sbx rm $sandbox_name"
echo "  Detach with Ctrl-\\ to keep the IDE running; re-run this script to re-attach."
echo ""

# ---------- create or re-attach ----------
if sbx ls 2>/dev/null | grep -qE "(^|[[:space:]])${sandbox_name}([[:space:]]|$)"; then
    echo "Re-attaching to existing sandbox '$sandbox_name'..."
    exec sbx run --name "$sandbox_name" --env "RIDER_SBX_HOST_PORT=$port"
fi

# sbx's global policy allows the common forges; deny them so work only leaves via 'git fetch sandbox-<name>'.
forge_hosts=(
    github.com '*.github.com' githubusercontent.com '*.githubusercontent.com'
    gitlab.com '*.gitlab.com' bitbucket.org '*.bitbucket.org'
    dev.azure.com '*.dev.azure.com' '*.visualstudio.com'
)
deny_args=()
for h in "${forge_hosts[@]}"; do
    deny_args+=(--deny-network "$h")
done

echo "Creating sandbox '$sandbox_name' (clone mode) from kit '$kit_path'..."
exec sbx run --clone --name "$sandbox_name" \
    --publish "127.0.0.1:${port}:5990" \
    --memory "$memory" \
    --env "RIDER_SBX_HOST_PORT=$port" \
    --kit-arg "kitRevision=$kit_revision" \
    "${deny_args[@]}" \
    "$kit_path" "$repo_root"
