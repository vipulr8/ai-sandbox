#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BASE="ai-sandbox"

# ── Load .env if present (git-ignored, never committed) ──────────
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
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
  --claude-dir <path>         Host directory mounted as ~/.claude in the container.
                              Defaults to ~/.ai-sandbox/<project-basename>/ (persistence on by default).
  --claude-version <version>  Use a specific Claude Code version (default: latest)
  --build                     Build or rebuild the Docker image locally
  --help                      Show this help

Environment variables:
  DOCKER_SOCKET               Set to 1 to mount Docker socket into container
  AWS_SSO                     Set to 1 to mount ~/.aws (reuse host AWS SSO login)
  AWS_DIR                     Override AWS config dir source (default: ~/.aws)
  GH_AUTH                     Set to 1 to inject host 'gh auth token' as GH_TOKEN

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
# Order matters: /var/run/docker.sock is preferred because it works on
# both Docker Desktop (real socket there) and Colima (a symlink to the
# home-dir socket that Colima's Lima fileshare recognizes specially).
# Bind-mounting the home-dir socket directly does NOT work on Colima:
# Lima's sshfs/9p fileshare doesn't preserve socket semantics, so the
# socket file appears inside the container but writes never reach the
# daemon. Falls back to the home path only when /var/run is unavailable.
detect_docker_sock() {
    if [ -n "${DOCKER_HOST:-}" ]; then
        echo "${DOCKER_HOST#unix://}"
    elif [ -S /var/run/docker.sock ]; then
        echo "/var/run/docker.sock"
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
        echo "$HOME/.colima/default/docker.sock"
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

# ── Preflight: Docker daemon ──────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: 'docker' CLI not found in PATH. Install Docker (Docker Desktop or 'brew install docker' with Colima)."
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not reachable. Start Docker Desktop or run 'colima start', then retry."
    exit 1
fi

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

# ── Acquire image ─────────────────────────────────────────────────
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Image ${IMAGE} not found, building..."
    build_image
fi

# ── Docker run args ───────────────────────────────────────────────
DOCKER_ARGS=(
    --rm -it
    --name "ai-sandbox-run-$(basename "$PROJECT_PATH")-$$"
    --hostname ai-sandbox
    -v "${PROJECT_PATH}:/home/coder/project"
    -e "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}"
    -e "DISABLE_AUTOUPDATER=1"
    -e "TERM=${TERM:-xterm-256color}"
    -w /home/coder/project
)

# Default --claude-dir to a per-project state dir under $HOME so
# Claude credentials and session history persist across container
# restarts without requiring any explicit flag.
if [ -z "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$HOME/.ai-sandbox/$(basename "$PROJECT_PATH")"
fi
mkdir -p "$CLAUDE_DIR"
CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd)"
DOCKER_ARGS+=(-v "$CLAUDE_DIR:/home/coder/.claude")

# Optional Docker socket mount
if [ "${DOCKER_SOCKET:-0}" = "1" ]; then
    SOCK=$(detect_docker_sock)
    if [ -n "$SOCK" ]; then
        DOCKER_ARGS+=(-v "${SOCK}:/var/run/docker.sock")
    else
        echo "Warning: Docker socket not found, skipping mount."
    fi
fi

# Optional AWS SSO config/cache passthrough (host login, shared cache).
# Enable with AWS_SSO=1; override source dir with AWS_DIR. Read-write so the
# container can cache derived role credentials under ~/.aws/cli/cache/.
if [ "${AWS_SSO:-0}" = "1" ]; then
    AWS_HOST_DIR="${AWS_DIR:-$HOME/.aws}"
    if [ -d "$AWS_HOST_DIR" ]; then
        AWS_HOST_DIR="$(cd "$AWS_HOST_DIR" && pwd)"
        DOCKER_ARGS+=(-v "$AWS_HOST_DIR:/home/coder/.aws")
    else
        echo "Warning: AWS_SSO=1 but $AWS_HOST_DIR not found, skipping AWS mount."
    fi
fi

# Optional GitHub CLI auth passthrough — reuse the host's gh login.
# Enable with GH_AUTH=1. `gh auth token` resolves from Keychain or hosts.yml.
# `-e GH_TOKEN` (no value) reads from this script's env so the token stays out
# of the docker run argv / ps / shell history (note: it is still visible via
# `docker inspect`, which reports resolved env values).
if [ "${GH_AUTH:-0}" = "1" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "Warning: GH_AUTH=1 but 'gh' not found in PATH, skipping."
    else
        GH_TOKEN_VALUE="$(gh auth token 2>/dev/null || true)"
        if [ -n "$GH_TOKEN_VALUE" ]; then
            export GH_TOKEN="$GH_TOKEN_VALUE"
            DOCKER_ARGS+=(-e GH_TOKEN)
        else
            echo "Warning: GH_AUTH=1 but no host gh token found (run 'gh auth login'), skipping."
        fi
    fi
fi

# ── Launch ────────────────────────────────────────────────────────
if [ "$LAUNCH_CLAUDE" = true ]; then
    exec docker run "${DOCKER_ARGS[@]}" "${IMAGE}" claude
else
    exec docker run "${DOCKER_ARGS[@]}" "${IMAGE}" zsh
fi
