#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BASE="ai-sandbox"
CONTAINER_PREFIX="ai-sandbox"

# ── Load .env if present ─────────────────────────────────────────
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a
fi

# ── Helper: derive container name from project path ──────────────
container_name_for() {
    local project_dir
    project_dir="$(basename "$1")"
    echo "${CONTAINER_PREFIX}-${project_dir}"
}

# ── Helper: list running instances ────────────────────────────────
list_instances() {
    local instances
    instances=$(docker ps --filter "name=${CONTAINER_PREFIX}-" --format "{{.Names}}\t{{.Status}}\t{{.Mounts}}" 2>/dev/null)
    if [ -n "$instances" ]; then
        echo "Running ai-sandbox instances:"
        echo "$instances" | while IFS=$'\t' read -r name status _; do
            echo "  - ${name}  (${status})"
        done
        echo ""
    fi
}

# ── Parse arguments ──────────────────────────────────────────────
PROJECT_PATH=""
CLAUDE_VERSION="latest"
CLAUDE_DIR=""

show_help() {
    cat <<EOF
ai-sandbox dev -- One command to start container + VS Code + Claude Code

Usage:
  ./dev.sh <project-path> [options]

Options:
  --claude-dir <path>         Host directory mounted as ~/.claude in the container.
                              Defaults to ~/.ai-sandbox/<project-basename>/ (persistence on by default).
  --claude-version <version>  Claude Code version (default: latest)
  --stop <project-path>       Stop the container for a specific project
  --stop-all                  Stop all ai-sandbox containers
  --list                      List running ai-sandbox instances
  --help                      Show this help

Examples:
  ./dev.sh ~/myproject --claude-dir ~/.ai-sandbox-api --claude-version 2.1.98
  ./dev.sh ~/myproject --claude-dir ~/.ai-sandbox/auth
  ./dev.sh ~/myproject
  ./dev.sh --stop ~/myproject
  ./dev.sh --stop-all
  ./dev.sh --list
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude-dir)
            CLAUDE_DIR="${2:-}"
            if [ -z "$CLAUDE_DIR" ]; then echo "Error: --claude-dir requires a path"; exit 1; fi
            shift 2
            ;;
        --claude-version)
            CLAUDE_VERSION="${2:-}"
            if [ -z "$CLAUDE_VERSION" ]; then echo "Error: --claude-version requires a version"; exit 1; fi
            shift 2
            ;;
        --stop)
            if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
                echo "Error: --stop requires a project path."
                echo "Usage: ./dev.sh --stop /path/to/project"
                echo "       ./dev.sh --stop-all"
                exit 1
            fi
            STOP_PATH="$(cd "$2" && pwd)"
            STOP_NAME="$(container_name_for "$STOP_PATH")"
            echo "Stopping ${STOP_NAME}..."
            docker rm -f "${STOP_NAME}" 2>/dev/null || true
            echo "Stopped."
            exit 0
            ;;
        --stop-all)
            echo "Stopping all ai-sandbox containers..."
            docker ps -aq --filter "name=${CONTAINER_PREFIX}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
            echo "All stopped."
            exit 0
            ;;
        --list)
            list_instances
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            PROJECT_PATH="$1"
            shift
            ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────
if [ -z "$PROJECT_PATH" ]; then
    echo "Error: Please provide a project path."
    echo "Usage: ./dev.sh /path/to/project"
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Error: Directory not found: $PROJECT_PATH"
    exit 1
fi

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
CONTAINER_NAME="$(container_name_for "$PROJECT_PATH")"

# ── Preflight: required host tools ────────────────────────────────
# dev.sh hard-depends on `code` (to attach VS Code) and `xxd` (to hex-encode
# the container name for the vscode-remote:// URI). Fail clean upfront so a
# missing tool doesn't leave a started container the user can't reach.
MISSING=()
command -v docker >/dev/null 2>&1 || MISSING+=("docker (https://docs.docker.com/engine/install/)")
command -v code   >/dev/null 2>&1 || MISSING+=("code (the VS Code CLI; install via VS Code's 'Shell Command: Install code command in PATH')")
command -v xxd    >/dev/null 2>&1 || MISSING+=("xxd (ships with vim; 'brew install vim' on macOS)")
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Error: missing required host tool(s):"
    printf '  - %s\n' "${MISSING[@]}"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not reachable. Start Docker Desktop or run 'colima start', then retry."
    exit 1
fi

# ── Show running instances ────────────────────────────────────────
list_instances

# ── Check if this project already has a running container ─────────
if docker ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
    echo "Container ${CONTAINER_NAME} is already running."
    echo "Open a terminal in VS Code and run: claude"
    exit 0
fi

# Clean up stopped container with same name
if docker ps -aq -f "name=${CONTAINER_NAME}" | grep -q .; then
    docker rm "${CONTAINER_NAME}" >/dev/null 2>&1
fi

# ── Image tag ────────────────────────────────────────────────────
if [ "$CLAUDE_VERSION" = "latest" ]; then
    IMAGE_TAG="latest"
else
    IMAGE_TAG="cc-${CLAUDE_VERSION}"
fi
IMAGE="${IMAGE_BASE}:${IMAGE_TAG}"

# ── Acquire image ─────────────────────────────────────────────────
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Image ${IMAGE} not found, building..."
    docker build \
        --build-arg "CLAUDE_VERSION=${CLAUDE_VERSION}" \
        --build-arg "USER_UID=$(id -u)" \
        --build-arg "USER_GID=$(id -g)" \
        -t "${IMAGE}" \
        "$SCRIPT_DIR"
fi

# ── Detect Docker socket ─────────────────────────────────────────
# Prefer /var/run/docker.sock: works on Docker Desktop (real socket)
# and on Colima (symlink to the home-dir socket that Colima's Lima
# fileshare recognizes specially). The home-path is only used as a
# last resort — bind-mounting it directly breaks docker-in-container
# on Colima because Lima's sshfs/9p doesn't preserve socket semantics.
DOCKER_SOCK_ARGS=()
if [ "${DOCKER_SOCKET:-0}" = "1" ]; then
    if [ -n "${DOCKER_HOST:-}" ]; then
        DOCKER_SOCK_ARGS=(-v "${DOCKER_HOST#unix://}:/var/run/docker.sock")
    elif [ -S /var/run/docker.sock ]; then
        DOCKER_SOCK_ARGS=(-v "/var/run/docker.sock:/var/run/docker.sock")
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
        DOCKER_SOCK_ARGS=(-v "$HOME/.colima/default/docker.sock:/var/run/docker.sock")
    fi
fi

# ── Claude config directory mount ─────────────────────────────────
# Default to a per-project state dir under $HOME so Claude
# credentials and session history persist across container restarts
# without requiring any explicit flag.
if [ -z "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$HOME/.ai-sandbox/$(basename "$PROJECT_PATH")"
fi
mkdir -p "$CLAUDE_DIR"
CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd)"
CLAUDE_DIR_ARGS=(-v "$CLAUDE_DIR:/home/coder/.claude")

# ── Start container in background ─────────────────────────────────
echo "Starting container: ${CONTAINER_NAME}"
docker run -d \
    --name "${CONTAINER_NAME}" \
    --hostname ai-sandbox \
    -v "${PROJECT_PATH}:/home/coder/project" \
    -e "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}" \
    -e "DISABLE_AUTOUPDATER=1" \
    -e "TERM=${TERM:-xterm-256color}" \
    "${DOCKER_SOCK_ARGS[@]+"${DOCKER_SOCK_ARGS[@]}"}" \
    "${CLAUDE_DIR_ARGS[@]+"${CLAUDE_DIR_ARGS[@]}"}" \
    -w /home/coder/project \
    "${IMAGE}" \
    sleep infinity >/dev/null

# ── Open VS Code attached to container ────────────────────────────
CONTAINER_HEX=$(printf '%s' "${CONTAINER_NAME}" | xxd -p | tr -d '\n')
VSCODE_URI="vscode-remote://attached-container+${CONTAINER_HEX}/home/coder/project"

echo "Opening VS Code..."
code --folder-uri "${VSCODE_URI}" 2>/dev/null || {
    echo "Warning: 'code' CLI not found. Attach manually in VS Code."
}

# ── Install Claude extension post-attach ──────────────────────────
# The 7 non-Claude extensions are baked into the image (see vscode-extensions.txt).
# Anthropic's extension is intentionally NOT baked: bake-time install skips the
# extension's install hook, leaving API-mode auth state uninitialized. Installing
# via VS Code's own code-server post-attach re-fires the hook and initializes
# auth from settings.json's env block.
if [ "$CLAUDE_VERSION" = "latest" ]; then
    CLAUDE_EXT="anthropic.claude-code"
else
    CLAUDE_EXT="anthropic.claude-code@${CLAUDE_VERSION}"
fi

# `docker exec -d` runs detached (returns immediately). The bash -c body uses
# escaped \$ for variables that should be evaluated when each loop iteration
# runs — NOT at script-write time.
docker exec -d "${CONTAINER_NAME}" bash -c "
LOG=/tmp/install-claude-ext.log
: > \"\$LOG\"
echo \"[\$(date +%T)] Polling for VS Code Server's code-server (up to 120s)\" >> \"\$LOG\"
for attempt in \$(seq 1 24); do
    CLI=\$(ls ~/.vscode-server/bin/*/bin/code-server 2>/dev/null | head -1)
    if [ -n \"\$CLI\" ]; then
        echo \"[\$(date +%T)] Installing ${CLAUDE_EXT} via \$CLI\" >> \"\$LOG\"
        \"\$CLI\" --install-extension ${CLAUDE_EXT} --force >> \"\$LOG\" 2>&1
        echo \"[\$(date +%T)] Done (exit \$?).\" >> \"\$LOG\"
        exit 0
    fi
    sleep 5
done
echo \"[\$(date +%T)] Gave up after 120s — VS Code Server's code-server never appeared.\" >> \"\$LOG\"
exit 1
"
echo "Claude extension install scheduled (post-attach). Logs: docker exec ${CONTAINER_NAME} cat /tmp/install-claude-ext.log"

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "Ready! Open a terminal in VS Code and run: claude"
echo "Stop with: ./dev.sh --stop $PROJECT_PATH"
