# ai-sandbox

Isolated Docker container for running Claude Code with a full-stack development toolchain. Security-hardened: AI tools are sandboxed to the project directory with no access to host config, credentials, or system files.

## What's inside

| Category | Tools |
|----------|-------|
| Languages | Node.js 22 LTS, Python 3.12, Go 1.24, Rust stable, OpenJDK 21 |
| Python | uv (package manager), ruff (linter/formatter) |
| AI | Claude Code CLI + VS Code extension (version-pinned) |
| Git | git, gh (GitHub CLI), gitleaks |
| Shell | zsh (default) with starship prompt, autosuggestions, syntax highlighting, history search |
| Dev tools | make, gcc, jq, ripgrep, fd, tmux, vim, nano, shellcheck, htop, tree |
| Container | Docker CLI (socket-mount, no daemon) |

Base image: Ubuntu 24.04 LTS. Runs as non-root user `coder` with passwordless sudo.

## Security

| Control | How |
|---------|-----|
| **Filesystem isolation** | Only the mounted project directory is accessible |
| **Gitleaks pre-commit** | Scans every commit for secrets automatically |
| **Commit message scrubbing** | AI attribution lines stripped from commits |
| **AI git push blocked** | Claude cannot push (local commits only); users retain full git access |
| **AI GitHub publishing blocked** | `gh pr create`, `gh issue create`, etc. denied for Claude |
| **Credential file access blocked** | `.env`, `.pem`, `.key`, `credentials.json`, etc. |
| **System path writes blocked** | `/etc`, `/usr/bin`, `/usr/sbin` read-only to Claude |
| **Sudo blocked** | Claude cannot escalate privileges |
| **Auth isolation** | Enterprise credentials stored at `~/.ai-sandbox/auth/`, separate from host Claude config |
| **Settings merge** | User settings merged with container hooks; hooks cannot be overridden |
| **Host VS Code isolation** | Settings sync blocked; Copilot blocked; extension versions pinned |

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

For third-party API key providers. Pass a `settings.json` that contains your API key configuration. Session history is persisted at `~/.ai-sandbox-api/` on the host.

The container merges your settings with its own security hooks (hooks always take priority and cannot be overridden). Some API key providers require a specific Claude Code version — use `--claude-version` to pin it.

```bash
# Latest Claude Code + API key settings
./run.sh ~/myproject --claude --settings ~/api-settings.json

# Specific Claude Code version + API key settings
./run.sh ~/myproject --claude --settings ~/api-settings.json --claude-version 1.0.5

# Build a specific version first, then run
./run.sh --build --claude-version 1.0.5
./run.sh ~/myproject --claude --settings ~/api-settings.json --claude-version 1.0.5
```

With `dev.sh` (container + VS Code in one command):

```bash
./dev.sh ~/myproject --settings ~/api-settings.json
./dev.sh ~/myproject --settings ~/api-settings.json --claude-version 1.0.5
```

To wipe API session history:

```bash
rm -rf ~/.ai-sandbox-api
```

### Mode 2: Interactive login (enterprise / OAuth)

No settings file needed. Just log in once — credentials and session history are persisted at `~/.ai-sandbox/auth/` on the host.

```bash
# First time — will prompt for login
./run.sh ~/myproject
claude auth login

# Next time — auto-authenticated, no login needed
./run.sh ~/myproject --claude
```

With `dev.sh`:

```bash
# First time — log in via VS Code terminal
./dev.sh ~/myproject

# Next time — just works
./dev.sh ~/myproject
```

To wipe saved credentials and history:

```bash
rm -rf ~/.ai-sandbox
```

## Usage reference

### run.sh

```
./run.sh [project-path] [options]
```

| Flag | Description |
|------|-------------|
| `--claude` | Launch Claude Code CLI directly instead of zsh shell |
| `--settings <file>` | Pass a settings.json with API key (merged with container hooks) |
| `--claude-version <version>` | Use a specific Claude Code version (default: latest) |
| `--build` | Build or rebuild the Docker image |
| `--help` | Show help |

### dev.sh

Starts the container in the background and opens VS Code attached to it. Open a terminal in VS Code and run `claude` to start.

```
./dev.sh <project-path> [options]
```

| Flag | Description |
|------|-------------|
| `--settings <file>` | Pass a settings.json with API key |
| `--claude-version <version>` | Use a specific Claude Code version (default: latest) |
| `--stop <project-path>` | Stop the container for a specific project |
| `--stop-all` | Stop all ai-sandbox containers |
| `--list` | List running ai-sandbox instances |
| `--help` | Show help |

Multiple projects can run simultaneously — each gets its own container named `ai-sandbox-<project-folder>`. If a project's container is already running, `dev.sh` reattaches instead of creating a duplicate.

```bash
# Run two projects at once
./dev.sh ~/project-a --settings ~/api-settings.json
./dev.sh ~/project-b

# List running instances
./dev.sh --list

# Stop one project
./dev.sh --stop ~/project-a

# Stop all
./dev.sh --stop-all
```

Requires VS Code with the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers).

### VS Code inside the container

When using `dev.sh`, VS Code runs attached to the container with:

- **Monokai** theme
- **zsh** as default terminal
- **Host settings sync disabled** — container has its own isolated settings
- **GitHub Copilot blocked** from running inside the container
- **Claude Code extension** pinned to `--claude-version` (if specified)
- **Extension auto-update disabled**

The devcontainer.json includes these workspace extensions: Python, debugpy, Ruff, Terraform, YAML, JSON, GitLens.

> **Important:** After changing the Dockerfile or entrypoint, rebuild all image versions you use:
> ```bash
> ./run.sh --build
> ./run.sh --build --claude-version 1.0.5
> ```

## Claude Code version management

The Claude Code version is baked into the image at build time. Each version gets its own image tag. Multiple versions can coexist — they share cached layers (Ubuntu, Go, Rust, Node, etc.) so only the Claude Code layer differs.

```bash
# Build both versions
./run.sh --build                        # -> ai-sandbox:latest
./run.sh --build --claude-version 2.1.98  # -> ai-sandbox:cc-2.1.98

# Run different versions on different projects
./dev.sh ~/project-a --settings ~/api-settings.json --claude-version 2.1.98
./dev.sh ~/project-b

# See all built images
docker images ai-sandbox
```

Images are tagged as:

- `ai-sandbox:latest` for the latest version
- `ai-sandbox:cc-<version>` for pinned versions (e.g., `ai-sandbox:cc-2.1.98`)

Auto-update is disabled inside the container. To update, rebuild the image.

## Shell environment

The container uses **zsh** as the default shell with:

- **Starship** prompt (fast, minimal, Rust-based)
- **zsh-autosuggestions** — ghost text from history as you type
- **zsh-syntax-highlighting** — colors commands green/red (valid/invalid)
- **zsh-history-substring-search** — up/down arrows filter history by what you've typed
- **zsh-completions** — extra tab completions for many tools
- History: 10k entries, deduplication, shared across sessions

Vim is configured with syntax highlighting, line numbers, and the desert colorscheme.

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
# Shell
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

## Volume mounts

| Container path | Host source | When | Purpose |
|----------------|-------------|------|---------|
| `/home/coder/project` | Your project directory | Always | Working directory for code |
| `/home/coder/.claude` | `~/.ai-sandbox/auth/` | Enterprise mode | Persistent credentials + session history |
| `/home/coder/.claude` | `~/.ai-sandbox-api/` | API key mode | Persistent session history |
| `/tmp/user-settings.json` | Settings file | API key mode | API key config (read-only) |

The entrypoint overwrites `settings.json` with container security hooks on every startup, regardless of what's in the mounted directory.

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
| Starship | ISC |
| uv, ruff | MIT (Astral) |
| Claude Code CLI | [Anthropic terms](https://www.anthropic.com/terms) |
| Node.js, Python, Go, Rust, OpenJDK | Various open source |
