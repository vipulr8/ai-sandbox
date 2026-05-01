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
CLAUDE_DIR=""

show_help() {
    cat <<EOF
ai-sandbox -- Claude Code Dev Sandbox

Usage:
  ./run.sh [project-path] [options]

Options:
  --claude                    Launch Claude Code CLI directly instead of zsh
  --claude-dir <path>         Mount a host directory as Claude config (~/.claude inside container)
  --claude-version <version>  Use a specific Claude Code version (default: latest)
  --build                     Build or rebuild the Docker image
  --help                      Show this help

Environment variables:
  DOCKER_SOCKET               Set to 1 to mount Docker socket into container

Examples:
  ./run.sh ~/myproject --claude --claude-dir ~/.ai-sandbox-api
  ./run.sh ~/myproject --claude --claude-dir ~/.ai-sandbox/auth
  ./run.sh ~/myproject --claude --claude-dir ~/.ai-sandbox-api --claude-version 2.1.98
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

# Mount Claude config directory if provided
if [ -n "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd || echo "$CLAUDE_DIR")"
    mkdir -p "$CLAUDE_DIR"
    DOCKER_ARGS+=(-v "$CLAUDE_DIR:/home/coder/.claude")
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
    exec docker run "${DOCKER_ARGS[@]}" "${IMAGE}" zsh
fi
