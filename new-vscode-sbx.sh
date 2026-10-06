#!/usr/bin/env bash
# Creates or restarts a Docker sandbox (sbx, clone mode) with the VS Code backend and
# Mistral Vibe inside, and opens the local VS Code window on it via Remote-SSH.
#
# Usage: ./new-vscode-sbx.sh [-p <repopath>] [-m <memory>] [-P <port>]
#   -p  Path to the git repository (default: current directory)
#   -m  Sandbox memory limit (default: 8g)
#   -P  Host port on 127.0.0.1 for the sandbox's SSH server (default: 2222)

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
port="2222"

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
kit_path="$script_dir/vscode-sbx"

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

for tool in sbx code ssh-keygen; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '$tool' was not found on PATH." >&2
        exit 1
    fi
done

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
sandbox_name=$(printf 'vscode-%s-%s' "$repo_name" "$current_branch" \
    | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g')

echo "Repository : $repo_root"
echo "Branch     : $current_branch"
echo "Sandbox    : $sandbox_name"
echo "SSH port   : 127.0.0.1:$port"

if ! sbx secret ls 2>/dev/null | grep -qw mistral; then
    echo "Warning: no 'mistral' secret stored. Mistral Vibe will not be able to reach the Mistral API." >&2
    echo "Warning: store one with: sbx secret set mistral" >&2
fi

# ---------- SSH key + host entry (kept apart from your own keys and hosts) ----------
ssh_dir="$HOME/.ssh"
sbx_ssh_dir="$ssh_dir/vscode-sbx"
mkdir -p "$sbx_ssh_dir"
chmod 700 "$ssh_dir" "$sbx_ssh_dir"

key_path="$sbx_ssh_dir/id_ed25519"
if [ ! -f "$key_path" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "vscode-sbx" -f "$key_path"
fi
public_key=$(cat "$key_path.pub")
known_hosts_path="$sbx_ssh_dir/known_hosts_$sandbox_name"

# ---------- create sandbox (first run) ----------
if ! sbx ls 2>/dev/null | grep -qE "(^|[[:space:]])${sandbox_name}([[:space:]]|$)"; then
    # sbx's global policy allows the common forges; deny them so work only leaves via 'git fetch sandbox-<name>'.
    # (No '*.visualstudio.com': marketplace.visualstudio.com serves the VS Code extensions.)
    forge_hosts=(
        github.com '*.github.com' githubusercontent.com '*.githubusercontent.com'
        gitlab.com '*.gitlab.com' bitbucket.org '*.bitbucket.org'
        dev.azure.com '*.dev.azure.com'
    )
    deny_args=()
    for h in "${forge_hosts[@]}"; do
        deny_args+=(--deny-network "$h")
    done

    echo "Creating sandbox '$sandbox_name' (clone mode) from kit '$kit_path'..."
    sbx run --detached --clone --name "$sandbox_name" \
        --publish "127.0.0.1:${port}:2222" \
        --memory "$memory" \
        --kit-arg "kitRevision=$kit_revision" \
        "${deny_args[@]}" \
        "$kit_path" "$repo_root"
    # New sandbox, new SSH host key.
    rm -f "$known_hosts_path"
fi

# ---------- start the backend (sshd + extension installer) ----------
echo "Starting VS Code backend in '$sandbox_name'..."
start_output=$(sbx exec "$sandbox_name" vscode-sbx-start --pubkey "$public_key" 2>&1) || {
    printf '%s\n' "$start_output" >&2
    echo "Error: failed to start the VS Code backend in '$sandbox_name'." >&2
    exit 1
}
printf '%s\n' "$start_output" | sed 's/^/  /'
workspace=$(printf '%s\n' "$start_output" | sed -n 's/^VSCODE_SBX_WORKSPACE=//p' | head -n 1 | tr -d '\r')

cat > "$sbx_ssh_dir/$sandbox_name.conf" <<EOF
Host $sandbox_name
    HostName 127.0.0.1
    Port $port
    User agent
    IdentityFile "$key_path"
    IdentitiesOnly yes
    UserKnownHostsFile "$known_hosts_path"
    StrictHostKeyChecking accept-new
EOF

# Make ~/.ssh/config include the sandbox host entries (Include must precede any Host block).
ssh_config="$ssh_dir/config"
include_line="Include vscode-sbx/*.conf"
touch "$ssh_config"
if ! grep -qxF "$include_line" "$ssh_config"; then
    echo "Adding '$include_line' to the top of $ssh_config"
    { printf '%s\n\n' "$include_line"; cat "$ssh_config"; } > "$ssh_config.tmp"
    mv "$ssh_config.tmp" "$ssh_config"
    chmod 600 "$ssh_config"
fi

# ---------- open VS Code on the sandbox ----------
if ! code --list-extensions 2>/dev/null | grep -qx 'ms-vscode-remote.remote-ssh'; then
    echo "Installing the VS Code Remote - SSH extension..."
    code --install-extension ms-vscode-remote.remote-ssh >/dev/null
fi

printf '\n\033[0;36mNext steps:\033[0m\n'
echo "  1. VS Code opens '$workspace' in the sandbox (choose 'Linux' if asked for the platform)."
echo "     The Mistral Vibe extension is installed into the sandbox automatically;"
echo "     run 'Developer: Reload Window' if it does not show up after the first connect."
echo "  2. Let Mistral Vibe work and commit inside the sandbox."
echo "  3. On the host: git fetch sandbox-$sandbox_name"
echo "                  git log $current_branch..sandbox-$sandbox_name/$current_branch"
echo "  4. Pause with 'sbx stop $sandbox_name'; re-run this script to continue."
echo "     Only after fetching: sbx rm $sandbox_name"
echo ""

code --folder-uri "vscode-remote://ssh-remote+${sandbox_name}${workspace}"
