# ai-sandbox

Isolated Docker container for running Claude Code CLI with a full-stack development toolchain.

## What's inside

| Category | Tools |
|----------|-------|
| Languages | Node.js 22 LTS, Python 3.12, Go 1.24, Rust stable |
| AI | Claude Code CLI (latest or pinned) |
| Git | git, gh (GitHub CLI), gitleaks |
| Dev tools | make, gcc, jq, ripgrep, fd, tmux, vim, nano, shellcheck, htop, tree |
| Container | Docker CLI (socket-mount, no daemon) |

Base image: Ubuntu 24.04 LTS. Runs as non-root user `coder` with passwordless sudo.

## Security

The container enforces several security controls out of the box:

| Control | How |
|---------|-----|
| **Filesystem isolation** | Only the mounted project directory is accessible |
| **Gitleaks pre-commit** | Scans every commit for secrets automatically |
| **AI git push blocked** | Claude cannot push (local commits only); users retain full git access |
| **Credential file access blocked** | `.env`, `.pem`, `.key`, `credentials.json`, etc. |
| **System path writes blocked** | `/etc`, `/usr/bin`, `/usr/sbin` are read-only to Claude |
| **GitHub publishing blocked** | `gh pr create`, `gh issue create`, etc. are denied for Claude |
| **Sudo blocked** | Claude cannot escalate privileges |
| **Fresh auth each session** | No host config is mounted; authenticate inside the container |
| **Settings merge** | User-provided settings are merged with container hooks; hooks cannot be overridden |

## Prerequisites

- A container runtime (e.g., [Colima](https://github.com/abapGit/colima), Docker Desktop, or similar)
- Docker CLI (`brew install docker` on macOS)
- docker-buildx plugin (`brew install docker-buildx` on macOS)

## Quick start

```bash
# Build the image
./run.sh --build

# Launch with API key settings file
./run.sh ~/myproject --claude --settings ~/api-settings.json

# Launch with interactive login
./run.sh ~/myproject --claude
```

## Two authentication modes

### Mode 1: API key via settings file

For third-party API key providers. Pass a `settings.json` that contains your API key configuration. The container merges it with its own security hooks (hooks always take priority and cannot be overridden).

Some API key providers require a specific Claude Code version. Use `--claude-version` to pin it.

```bash
# Latest Claude Code + API key settings
./run.sh ~/myproject --claude --settings ~/api-settings.json

# Specific Claude Code version + API key settings
./run.sh ~/myproject --claude --settings ~/api-settings.json --claude-version 1.0.5

# Build a specific version first, then run
./run.sh --build --claude-version 1.0.5
./run.sh ~/myproject --claude --settings ~/api-settings.json --claude-version 1.0.5
```

With `dev.sh` (container + VS Code + Claude Code in one command):

```bash
./dev.sh ~/myproject --settings ~/api-settings.json
./dev.sh ~/myproject --settings ~/api-settings.json --claude-version 1.0.5
```

### Mode 2: Interactive login (enterprise / OAuth)

No settings file needed. Authenticate interactively inside the container each session. Always uses latest Claude Code.

```bash
# Open bash, then authenticate
./run.sh ~/myproject
claude auth login

# Or launch Claude Code directly (it will prompt for login)
./run.sh ~/myproject --claude
```

With `dev.sh`:

```bash
./dev.sh ~/myproject
```

## Usage reference

### run.sh

```
./run.sh [project-path] [options]
```

| Flag | Description |
|------|-------------|
| `--claude` | Launch Claude Code CLI directly instead of bash |
| `--settings <file>` | Pass a settings.json with API key (merged with container hooks) |
| `--claude-version <version>` | Use a specific Claude Code version (default: latest) |
| `--build` | Build or rebuild the Docker image |
| `--help` | Show help |

### dev.sh

Starts the container in the background, opens VS Code attached to it, and launches Claude Code in your terminal.

```
./dev.sh <project-path> [options]
```

| Flag | Description |
|------|-------------|
| `--settings <file>` | Pass a settings.json with API key |
| `--claude-version <version>` | Use a specific Claude Code version (default: latest) |
| `--stop` | Stop the running dev container |
| `--help` | Show help |

Requires VS Code with the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers).

## Claude Code version management

The Claude Code version is baked into the image at build time. Each version gets its own image tag, so switching is fast after the first build.

```bash
# Build with latest (default)
./run.sh --build

# Build with a specific version
./run.sh --build --claude-version 1.0.5

# Run with a specific version (auto-builds if image doesn't exist)
./run.sh ~/myproject --claude --claude-version 1.0.5
```

Images are tagged as:

- `ai-sandbox:latest` for the latest version
- `ai-sandbox:cc-1.0.5` for pinned versions

Auto-update is disabled inside the container. To update, rebuild the image.

## Docker-in-Docker

Mount the host's Docker socket to run Docker commands inside the sandbox:

```bash
DOCKER_SOCKET=1 ./run.sh ~/myproject
```

The script auto-detects socket paths for Colima, `DOCKER_HOST`, and the standard `/var/run/docker.sock`.

> **Note:** This gives the container full access to your host's Docker daemon. Use with care.

## docker-compose

For more structured usage:

```bash
# Bash shell
PROJECT_DIR=~/myproject docker compose run --rm claude

# Claude Code directly
PROJECT_DIR=~/myproject docker compose --profile interactive run --rm claude-interactive
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_DIR` | `.` | Project directory to mount |
| `CLAUDE_VERSION` | `latest` | Claude Code version for build |
| `USER_UID` | `1000` | Container user UID (match your host) |
| `USER_GID` | `1000` | Container user GID (match your host) |

## VS Code integration

A `.devcontainer/devcontainer.json` is included. It auto-installs workspace extensions for Python, Go, Rust, ESLint, Prettier, GitLens, ShellCheck, TOML, YAML, and Docker when VS Code attaches to the container.

## Volume mounts

| Container path | Host source | Purpose |
|----------------|-------------|---------|
| `/home/coder/project` | Your project directory | Working directory for code |
| `/tmp/user-settings.json` | Settings file (if `--settings` used) | API key config (read-only) |

No other host directories are mounted. Claude Code config and auth live inside the container only.

**Colima note:** Only paths under your home directory are mounted into the Colima VM by default.

## Customizing the image

### Build arguments

| ARG | Default | Description |
|-----|---------|-------------|
| `CLAUDE_VERSION` | `latest` | Claude Code npm package version |
| `GO_VERSION` | `1.24.2` | Go version |
| `NODE_MAJOR` | `22` | Node.js major version |
| `GITLEAKS_VERSION` | `8.24.3` | Gitleaks version |
| `USER_NAME` | `coder` | Container username |
| `USER_UID` | `1000` | Container user UID |
| `USER_GID` | `1000` | Container user GID |

### Adding tools

The Dockerfile layers are designed to be independently modifiable. To add or remove language runtimes, comment out or add layers.

## Licensing

All components are open source:

| Component | License |
|-----------|---------|
| Docker CLI | Apache 2.0 |
| docker-buildx | Apache 2.0 |
| Colima | MIT |
| Ubuntu 24.04 | Free (Canonical) |
| Gitleaks | MIT |
| Claude Code CLI | [Anthropic terms](https://www.anthropic.com/terms) |
| Node.js, Python, Go, Rust | Various open source |
