#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BASE="ai-sandbox"

# ── Load .env if present (git-ignored, never committed) ──────────
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# ── Parse arguments ───────────────────────────────────────────────
PROJECT_PATH=""
LAUNCH_CLAUDE=false
BUILD_ONLY=false
CLAUDE_VERSION="latest"
SETTINGS_FILE=""

show_help() {
    cat <<EOF
ai-sandbox -- Claude Code Dev Sandbox

Usage:
  ./run.sh [project-path]                         Bash shell in sandbox
  ./run.sh [project-path] --claude                Launch Claude Code directly
  ./run.sh [project-path] --claude-version 1.0.5  Use specific Claude Code version
  ./run.sh [project-path] --settings path/to/settings.json  Use API key from settings file
  ./run.sh --build                                Build image (latest)
  ./run.sh --build --claude-version 1.0.5         Build with specific version
  ./run.sh --help                                 Show this help

Authentication:
  --settings <file>       Pass a settings.json with API key (third-party provider)
  (no flag)               Authenticate interactively inside the container

Environment variables:
  DOCKER_SOCKET           Set to 1 to mount Docker socket into container

Examples:
  ./run.sh ~/myproject --claude --settings ~/api-settings.json
  ./run.sh ~/myproject --claude
  ./run.sh ~/myproject
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude)
            LAUNCH_CLAUDE=true
            shift
            ;;
        --claude-version)
            CLAUDE_VERSION="$2"
            shift 2
            ;;
        --settings)
            SETTINGS_FILE="$2"
            shift 2
            ;;
        --build)
            BUILD_ONLY=true
            shift
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

# ── Image tag ─────────────────────────────────────────────────────
if [ "$CLAUDE_VERSION" = "latest" ]; then
    IMAGE_TAG="latest"
else
    IMAGE_TAG="cc-${CLAUDE_VERSION}"
fi
IMAGE="${IMAGE_BASE}:${IMAGE_TAG}"

# ── Detect Docker socket (Colima-aware) ───────────────────────────
detect_docker_sock() {
    if [ -n "${DOCKER_HOST:-}" ]; then
        echo "${DOCKER_HOST#unix://}"
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
        echo "$HOME/.colima/default/docker.sock"
    elif [ -S /var/run/docker.sock ]; then
        echo "/var/run/docker.sock"
    else
        echo ""
    fi
}

# ── Build ─────────────────────────────────────────────────────────
build_image() {
    echo "Building ${IMAGE} (Claude Code ${CLAUDE_VERSION})..."
    docker build \
        --build-arg "CLAUDE_VERSION=${CLAUDE_VERSION}" \
        --build-arg "USER_UID=$(id -u)" \
        --build-arg "USER_GID=$(id -g)" \
        -t "${IMAGE}" \
        "$SCRIPT_DIR"
    echo "Built ${IMAGE} successfully."
}

if [ "$BUILD_ONLY" = true ]; then
    build_image
    exit 0
fi

# ── Validate project path ────────────────────────────────────────
if [ -z "$PROJECT_PATH" ]; then
    echo "Error: Please provide a project path."
    echo "Usage: ./run.sh /path/to/project [--claude]"
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Error: Directory not found: $PROJECT_PATH"
    exit 1
fi

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

# ── Auto-build if image doesn't exist ─────────────────────────────
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Image ${IMAGE} not found, building..."
    build_image
fi

# ── Docker run args ───────────────────────────────────────────────
DOCKER_ARGS=(
    --rm -it
    --name "ai-sandbox-$$"
    --hostname ai-sandbox
    -v "${PROJECT_PATH}:/home/coder/project"
    -e "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}"
    -e "DISABLE_AUTOUPDATER=1"
    -e "TERM=${TERM:-xterm-256color}"
    -w /home/coder/project
)

# Mount settings file if provided (read-only)
if [ -n "$SETTINGS_FILE" ]; then
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "Error: Settings file not found: $SETTINGS_FILE"
        exit 1
    fi
    SETTINGS_FILE="$(cd "$(dirname "$SETTINGS_FILE")" && pwd)/$(basename "$SETTINGS_FILE")"
    DOCKER_ARGS+=(-v "${SETTINGS_FILE}:/tmp/user-settings.json:ro")
fi

# Optional Docker socket mount
if [ "${DOCKER_SOCKET:-0}" = "1" ]; then
    SOCK=$(detect_docker_sock)
    if [ -n "$SOCK" ]; then
        DOCKER_ARGS+=(-v "${SOCK}:/var/run/docker.sock")
    else
        echo "Warning: Docker socket not found, skipping mount."
    fi
fi

# ── Launch ────────────────────────────────────────────────────────
if [ "$LAUNCH_CLAUDE" = true ]; then
    exec docker run "${DOCKER_ARGS[@]}" "${IMAGE}" claude
else
    exec docker run "${DOCKER_ARGS[@]}" "${IMAGE}" bash
fi
