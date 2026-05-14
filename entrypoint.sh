#!/bin/bash
set -e

# ── 1. Claude state symlink ───────────────────────────────────────
# Claude Code expects ~/.claude.json at the home root, but only
# ~/.claude/ is bind-mounted to the host. Symlinking the home-root
# file into the bind-mount makes every read/write persist directly,
# replacing the previous periodic-backup-and-restore mechanism.
ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"

# ── 2. Docker socket permissions ──────────────────────────────────
# When DOCKER_SOCKET=1 mounts the host's docker socket, the socket's GID
# inside the container may not be one `coder` already belongs to. We
# add a matching group and put `coder` in it — but `usermod -aG` alone
# is not enough: PID 1's supplementary groups were frozen at container
# start, so the current process won't see the new group. After the
# group is added we re-exec the entrypoint via `sg` so the docker
# group is active for the rest of the entrypoint and for the CMD.
# AISBX_DOCKER_GROUP_APPLIED guards against re-entry.
if [ -S /var/run/docker.sock ] && [ -z "${AISBX_DOCKER_GROUP_APPLIED:-}" ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    if ! id -G | tr ' ' '\n' | grep -qx "$DOCKER_GID"; then
        if ! getent group "$DOCKER_GID" >/dev/null 2>&1; then
            sudo groupadd -g "$DOCKER_GID" docker-host 2>/dev/null || true
        fi
        DOCKER_GROUP=$(getent group "$DOCKER_GID" | cut -d: -f1)
        if [ -n "$DOCKER_GROUP" ] && ! id -nG "$(whoami)" | grep -qw "$DOCKER_GROUP"; then
            sudo usermod -aG "$DOCKER_GROUP" "$(whoami)" 2>/dev/null || true
        fi
        if [ -n "$DOCKER_GROUP" ] && command -v sg >/dev/null 2>&1; then
            export AISBX_DOCKER_GROUP_APPLIED=1
            exec sg "$DOCKER_GROUP" -c "exec $(printf '%q ' "$0" "$@")"
        fi
    fi
fi

# ── 3. Auth status ────────────────────────────────────────────────
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "* ANTHROPIC_API_KEY is set"
else
    echo "! No API key detected. Run: claude auth login"
fi

# ── 4. Environment summary ────────────────────────────────────────
echo ""
echo "=== ai-sandbox ==="
printf "  Node.js:  %s\n" "$(node --version 2>/dev/null || echo 'n/a')"
printf "  Python:   %s\n" "$(python3 --version 2>/dev/null | awk '{print $2}' || echo 'n/a')"
printf "  Go:       %s\n" "$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || echo 'n/a')"
printf "  Rust:     %s\n" "$(rustc --version 2>/dev/null | awk '{print $2}' || echo 'n/a')"
printf "  Claude:   %s\n" "$(claude --version 2>/dev/null || echo 'n/a')"
printf "  Gitleaks: %s\n" "$(gitleaks version 2>/dev/null || echo 'n/a')"
if [ -S /var/run/docker.sock ]; then
    printf "  Docker:   %s\n" "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo 'socket mounted')"
fi
echo "  AI Push:  BLOCKED (AI commits are local only)"
echo "================="
echo ""

# ── 5. VS Code Server settings ────────────────────────────────────
# Disable settings sync entirely so host settings don't leak in.
# Write settings after a delay so they apply after VS Code initializes.
mkdir -p "$HOME/.vscode-server/data/Machine"
cat > "$HOME/.vscode-server/data/Machine/settings.json" <<'VSSETTINGS'
{
    "settingsSync.ignoredSettings": ["*"],
    "settings.experimental.enableRemoteSettingsSync": false,
    "terminal.integrated.defaultProfile.linux": "zsh",
    "terminal.integrated.profiles.linux": {
        "zsh": { "path": "/usr/bin/zsh" },
        "bash": null
    },
    "workbench.colorTheme": "Monokai",
    "telemetry.telemetryLevel": "off",
    "extensions.autoUpdate": false,
    "extensions.autoCheckUpdates": false,
    "remote.extensionKind": {
        "anthropic.claude-code": ["workspace"],
        "GitHub.copilot": ["ui"],
        "GitHub.copilot-chat": ["ui"]
    }
}
VSSETTINGS

export SHELL=/usr/bin/zsh

# ── 6. Run command ────────────────────────────────────────────────
exec "$@"
