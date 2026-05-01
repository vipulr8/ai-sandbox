#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BASE="ai-sandbox"
CONTAINER_PREFIX="ai-sandbox"

# ── Load .env if present ─────────────────────────────────────────
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
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
SETTINGS_FILE=""

show_help() {
    cat <<EOF
ai-sandbox dev -- One command to start container + VS Code + Claude Code

Usage:
  ./dev.sh <project-path> [options]

Options:
  --settings <file>           Pass a settings.json with API key
  --claude-version <version>  Claude Code version (default: latest)
  --stop <project-path>       Stop the container for a specific project
  --stop-all                  Stop all ai-sandbox containers
  --list                      List running ai-sandbox instances
  --help                      Show this help

Examples:
  ./dev.sh ~/myproject --settings ~/api-settings.json
  ./dev.sh ~/myproject
  ./dev.sh --stop ~/myproject
  ./dev.sh --stop-all
  ./dev.sh --list
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

# ── Show running instances ────────────────────────────────────────
list_instances

# ── Check if this project already has a running container ─────────
if docker ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
    echo "Container ${CONTAINER_NAME} is already running."
    echo "Attaching Claude Code..."
    echo ""
    docker exec -it "${CONTAINER_NAME}" claude
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
echo "Starting container: ${CONTAINER_NAME}"
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
echo "  (Use ./dev.sh --stop $(basename "$PROJECT_PATH") to shut down)"
echo ""
docker exec -it "${CONTAINER_NAME}" claude
