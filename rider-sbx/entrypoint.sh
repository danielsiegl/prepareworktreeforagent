#!/usr/bin/env bash
# Entrypoint of the rider-sbx kit: hardens the in-sandbox clone and starts the
# Rider remote-dev backend. The only thing exposed is the remote-dev port (5990);
# connect to it with JetBrains Gateway / Client on the host.

set -euo pipefail

port="${RIDER_SBX_PORT:-5990}"
state_dir="$HOME/.cache/rider-sbx"
mkdir -p "$state_dir"

# ---------- locate workspace (sbx starts us inside the clone) ----------
workspace=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$workspace" ]; then
    workspace="/home/agent/workspace"
fi
echo "Workspace : $workspace"

# ---------- harden the clone: only the current branch, commits stay here until the host fetches them ----------
if git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$workspace" rev-parse --abbrev-ref HEAD)

    # sbx makes a full clone (all refs + host remotes); reduce it to the checked-out branch.
    for remote in $(git -C "$workspace" remote); do
        case "$remote" in
            sandbox-*) git -C "$workspace" remote remove "$remote" ;;  # host-local daemons of other sandboxes
            *) git -C "$workspace" remote set-url --push "$remote" "no-push://disabled-in-sandbox" ;;
        esac
    done
    git -C "$workspace" for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags \
        | { grep -vxF -e "refs/heads/$branch" -e "refs/remotes/origin/$branch" || true; } \
        | while IFS= read -r ref; do git -C "$workspace" update-ref --no-deref -d "$ref"; done
    git -C "$workspace" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
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
        git -C "$workspace" config user.name "${GIT_AUTHOR_NAME:-Rider Sandbox Agent}"
    fi
    if ! git -C "$workspace" config user.email >/dev/null; then
        git -C "$workspace" config user.email "${GIT_AUTHOR_EMAIL:-agent@sandbox.local}"
    fi

    echo "Branch    : $branch (other branches, tags and remotes removed from the clone)"
fi

# ---------- start Rider remote-dev backend ----------
# Host port the launcher published (passed with -e); used to make the join link pasteable on the host.
host_port="${RIDER_SBX_HOST_PORT:-$port}"

echo "Starting Rider remote-dev backend on port $port (host: 127.0.0.1:$host_port) ..."
echo "Paste the 'Join link' below into JetBrains Gateway ('Connect to running IDE')."
echo "Detach with Ctrl-\\ to leave the IDE running."
echo ""

/opt/rider/bin/remote-dev-server.sh run "$workspace" --listenOn 0.0.0.0 --port "$port" 2>&1 \
    | sed -u -e "s#tcp://0\.0\.0\.0:$port#tcp://127.0.0.1:$host_port#g" -e '/^Gateway link: .*type=ssh/d' \
    | tee "$state_dir/backend.log"
