#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BASE="ai-sandbox"
CONTAINER_NAME="ai-sandbox-dev"

# ── Load .env if present ─────────────────────────────────────────
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# ── Parse arguments ──────────────────────────────────────────────
PROJECT_PATH=""
CLAUDE_VERSION="latest"
SETTINGS_FILE=""

show_help() {
    cat <<EOF
ai-sandbox dev -- One command to start container + VS Code + Claude Code

Usage:
  ./dev.sh <project-path> [options]

Options:
  --settings <file>           Pass a settings.json with API key
  --claude-version <version>  Claude Code version (default: latest)
  --stop                      Stop the running dev container
  --help                      Show this help

Examples:
  ./dev.sh ~/myproject --settings ~/api-settings.json
  ./dev.sh ~/myproject
  ./dev.sh --stop
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings)
            SETTINGS_FILE="$2"
            shift 2
            ;;
        --claude-version)
            CLAUDE_VERSION="$2"
            shift 2
            ;;
        --stop)
            echo "Stopping ${CONTAINER_NAME}..."
            docker stop "${CONTAINER_NAME}" 2>/dev/null || true
            echo "Stopped."
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

# ── Image tag ────────────────────────────────────────────────────
if [ "$CLAUDE_VERSION" = "latest" ]; then
    IMAGE_TAG="latest"
else
    IMAGE_TAG="cc-${CLAUDE_VERSION}"
fi
IMAGE="${IMAGE_BASE}:${IMAGE_TAG}"

# ── Auto-build if needed ─────────────────────────────────────────
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Image ${IMAGE} not found, building..."
    docker build \
        --build-arg "CLAUDE_VERSION=${CLAUDE_VERSION}" \
        --build-arg "USER_UID=$(id -u)" \
        --build-arg "USER_GID=$(id -g)" \
        -t "${IMAGE}" \
        "$SCRIPT_DIR"
fi

# ── Stop existing container if running ────────────────────────────
if docker ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
    echo "Stopping existing ${CONTAINER_NAME}..."
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1
fi

# ── Detect Docker socket ─────────────────────────────────────────
DOCKER_SOCK_ARGS=()
if [ "${DOCKER_SOCKET:-0}" = "1" ]; then
    if [ -n "${DOCKER_HOST:-}" ]; then
        DOCKER_SOCK_ARGS=(-v "${DOCKER_HOST#unix://}:/var/run/docker.sock")
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
        DOCKER_SOCK_ARGS=(-v "$HOME/.colima/default/docker.sock:/var/run/docker.sock")
    elif [ -S /var/run/docker.sock ]; then
        DOCKER_SOCK_ARGS=(-v "/var/run/docker.sock:/var/run/docker.sock")
    fi
fi

# ── Settings file mount ───────────────────────────────────────────
SETTINGS_ARGS=()
if [ -n "$SETTINGS_FILE" ]; then
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "Error: Settings file not found: $SETTINGS_FILE"
        exit 1
    fi
    SETTINGS_FILE="$(cd "$(dirname "$SETTINGS_FILE")" && pwd)/$(basename "$SETTINGS_FILE")"
    SETTINGS_ARGS=(-v "${SETTINGS_FILE}:/tmp/user-settings.json:ro")
fi

# ── Start container in background ─────────────────────────────────
echo "Starting container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    --hostname ai-sandbox \
    -v "${PROJECT_PATH}:/home/coder/project" \
    -e "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}" \
    -e "DISABLE_AUTOUPDATER=1" \
    -e "TERM=${TERM:-xterm-256color}" \
    "${DOCKER_SOCK_ARGS[@]+"${DOCKER_SOCK_ARGS[@]}"}" \
    "${SETTINGS_ARGS[@]+"${SETTINGS_ARGS[@]}"}" \
    -w /home/coder/project \
    "${IMAGE}" \
    sleep infinity >/dev/null

echo "Container running: ${CONTAINER_NAME}"

# ── Open VS Code attached to container ────────────────────────────
CONTAINER_HEX=$(printf '%s' "${CONTAINER_NAME}" | xxd -p | tr -d '\n')
VSCODE_URI="vscode-remote://attached-container+${CONTAINER_HEX}/home/coder/project"

echo "Opening VS Code..."
code --folder-uri "${VSCODE_URI}" 2>/dev/null || {
    echo "Warning: 'code' CLI not found. Open VS Code manually:"
    echo "  1. Open VS Code"
    echo "  2. Cmd+Shift+P > 'Dev Containers: Attach to Running Container'"
    echo "  3. Select '${CONTAINER_NAME}'"
}

# ── Start Claude Code in an interactive terminal ──────────────────
echo ""
echo "Launching Claude Code..."
echo "  (VS Code is opening in the background)"
echo "  (Use ./dev.sh --stop to shut down when done)"
echo ""
docker exec -it "${CONTAINER_NAME}" claude
