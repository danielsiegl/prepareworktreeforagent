#!/usr/bin/env bash
# Backend side of the vscode-sbx kit:
#   1. reduces the in-sandbox clone to the checked-out branch (once),
#   2. starts an unprivileged sshd that VS Code Remote-SSH on the host connects to,
#   3. installs the Mistral Vibe extension into the VS Code server once Remote-SSH deployed it.
#
# Usage: vscode-sbx-start [--pubkey "<ssh public key>"] [--foreground]
#   --pubkey      public key allowed to log in (also read from $VSCODE_SBX_PUBKEY)
#   --foreground  keep sshd in the foreground (used as the kit ENTRYPOINT)

set -euo pipefail

ssh_port="${VSCODE_SBX_SSH_PORT:-2222}"
extensions=(mistralai.mistral-vibe-code)
state_dir="$HOME/.vscode-sbx"
pubkey=""
foreground=false

while [ $# -gt 0 ]; do
    case "$1" in
        --pubkey) pubkey="$2"; shift 2 ;;
        --foreground) foreground=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
pubkey="${pubkey:-${VSCODE_SBX_PUBKEY:-}}"

mkdir -p "$state_dir"
chmod 700 "$state_dir"

# ---------- locate workspace (sbx starts us inside the clone) ----------
workspace=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$workspace" ]; then
    workspace="/home/agent/workspace"
fi

# ---------- reduce the clone to the current branch; commits stay here until the host fetches them ----------
trim_clone() {
    local branch alternates
    branch=$(git -C "$workspace" rev-parse --abbrev-ref HEAD)

    # sbx makes a full clone (all refs + host remotes); reduce it to the checked-out branch.
    for remote in $(git -C "$workspace" remote); do
        case "$remote" in
            sandbox-*) git -C "$workspace" remote remove "$remote" ;;  # host-local daemons of other sandboxes
            *) git -C "$workspace" remote set-url --push "$remote" "no-push://disabled-in-sandbox" ;;
        esac
    done
    git -C "$workspace" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
    git -C "$workspace" for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags \
        | { grep -vxF -e "refs/heads/$branch" -e "refs/remotes/origin/$branch" || true; } \
        | while IFS= read -r ref; do git -C "$workspace" update-ref --no-deref -d "$ref"; done
    git -C "$workspace" stash clear
    git -C "$workspace" reflog expire --expire=now --all

    # The clone borrows objects from the read-only host repo via alternates, which would keep
    # every host branch readable by hash. Copy in what the branch needs, then cut the link.
    alternates="$(git -C "$workspace" rev-parse --git-path objects/info/alternates)"
    case "$alternates" in /*) ;; *) alternates="$workspace/$alternates" ;; esac
    if [ -s "$alternates" ]; then
        git -C "$workspace" repack -a -d --quiet
        rm -f "$alternates"
    fi
    git -C "$workspace" gc --prune=now --quiet

    if ! git -C "$workspace" config user.name >/dev/null; then
        git -C "$workspace" config user.name "${GIT_AUTHOR_NAME:-VS Code Sandbox Agent}"
    fi
    if ! git -C "$workspace" config user.email >/dev/null; then
        git -C "$workspace" config user.email "${GIT_AUTHOR_EMAIL:-agent@sandbox.local}"
    fi
}

if [ ! -f "$state_dir/clone-trimmed" ] && git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
    trim_clone
    touch "$state_dir/clone-trimmed"
fi

# ---------- unprivileged sshd for VS Code Remote-SSH ----------
if [ ! -f "$state_dir/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "vscode-sbx-host" -f "$state_dir/ssh_host_ed25519_key"
fi
if [ -n "$pubkey" ]; then
    printf '%s\n' "$pubkey" > "$state_dir/authorized_keys"
fi
touch "$state_dir/authorized_keys"
chmod 600 "$state_dir/authorized_keys"

# SSH sessions don't inherit the sandbox environment; carry over the sbx proxy, CA and
# credential placeholders so the VS Code server and Vibe reach the network through the proxy.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
env | grep -E '^(https?_proxy|HTTPS?_PROXY|no_proxy|NO_PROXY|NODE_EXTRA_CA_CERTS|NODE_USE_ENV_PROXY|SSL_CERT_FILE|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|JAVA_TOOL_OPTIONS|MISTRAL_API_KEY|PATH|DOTNET_ROOT|DOTNET_CLI_TELEMETRY_OPTOUT|IS_SANDBOX|BASH_ENV)=' \
    > "$HOME/.ssh/environment" || true
chmod 600 "$HOME/.ssh/environment"

cat > "$state_dir/sshd_config" <<EOF
Port $ssh_port
ListenAddress 0.0.0.0
HostKey $state_dir/ssh_host_ed25519_key
PidFile $state_dir/sshd.pid
AuthorizedKeysFile $state_dir/authorized_keys
AllowUsers agent
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
PermitUserEnvironment yes
# Remote-SSH tunnels to the VS Code server through a local port forward.
AllowTcpForwarding local
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
Subsystem sftp internal-sftp
EOF

# ---------- install extensions into the VS Code server once Remote-SSH deployed it ----------
install_extensions_when_ready() {
    local cli="" ok
    for _ in $(seq 1 360); do
        sleep 5
        cli=$(ls -td "$HOME"/.vscode-server/cli/servers/*/server/bin/code-server \
                     "$HOME"/.vscode-server/bin/*/bin/code-server 2>/dev/null | head -n 1 || true)
        # Wait until Remote-SSH has fully unpacked the server (its bundled node sits next to bin/).
        if [ -z "$cli" ] || [ ! -x "$(dirname "$(dirname "$cli")")/node" ]; then
            continue
        fi
        ok=true
        for ext in "${extensions[@]}"; do
            "$cli" --install-extension "$ext" || ok=false
        done
        if $ok; then
            return 0
        fi
    done
    echo "VS Code server not ready within 30 minutes; extensions not installed."
}

watcher_pid_file="$state_dir/extension-watcher.pid"
if ! { [ -f "$watcher_pid_file" ] && kill -0 "$(cat "$watcher_pid_file")" 2>/dev/null; }; then
    export -f install_extensions_when_ready
    setsid nohup bash -c "$(declare -p extensions); install_extensions_when_ready" \
        > "$state_dir/extensions.log" 2>&1 < /dev/null &
    echo $! > "$watcher_pid_file"
fi

echo "VSCODE_SBX_WORKSPACE=$workspace"
echo "VSCODE_SBX_BRANCH=$(git -C "$workspace" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

if $foreground; then
    echo "sshd listening on port $ssh_port (foreground). Connect with VS Code Remote-SSH."
    exec /usr/sbin/sshd -D -e -f "$state_dir/sshd_config"
fi

if [ -f "$state_dir/sshd.pid" ] && kill -0 "$(cat "$state_dir/sshd.pid")" 2>/dev/null; then
    echo "sshd already running on port $ssh_port."
else
    setsid /usr/sbin/sshd -f "$state_dir/sshd_config" -E "$state_dir/sshd.log" < /dev/null
    echo "sshd started on port $ssh_port."
fi
