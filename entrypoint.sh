#!/bin/bash
set -e

# ── 2. Docker socket permissions ──────────────────────────────────
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    if ! getent group "$DOCKER_GID" >/dev/null 2>&1; then
        sudo groupadd -g "$DOCKER_GID" docker-host 2>/dev/null || true
    fi
    DOCKER_GROUP=$(getent group "$DOCKER_GID" | cut -d: -f1)
    if ! id -nG "$(whoami)" | grep -qw "$DOCKER_GROUP"; then
        sudo usermod -aG "$DOCKER_GROUP" "$(whoami)" 2>/dev/null || true
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
