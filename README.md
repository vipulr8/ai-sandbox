# ai-sandbox

Isolated Docker container for running Claude Code with a full-stack development toolchain. Security-hardened: AI tools are sandboxed to the project directory with no access to host config, credentials, or system files.

> **Supported hosts:** macOS, Linux, and Windows (via WSL2). The image's container user is matched to your host UID at build time (`--build-arg USER_UID=$(id -u)`), so bind-mounts behave correctly on any Unix-like host.
>
> | Host OS | Status | Recommended runtime (OSS) | Alternative |
> |---------|--------|---------------------------|-------------|
> | macOS   | ✓ verified | Colima | Docker Desktop |
> | Linux   | ◇ pending verification | Docker Engine | Docker Desktop |
> | Windows | ◇ pending verification (WSL2 only) | Docker Engine inside WSL2 | Docker Desktop (WSL2 backend) |
>
> Linux and Windows rows are marked "pending verification" until an external tester confirms the setup runbook passes on each. Once verified, the rows become "✓ verified". Windows is supported via WSL2 only; native Windows (PowerShell launchers, no WSL2) is out of scope. Docker Desktop is listed as the second option on every row because it carries a commercial-use license tier for organizations >250 employees or >$10M revenue.

## What's inside

| Category | Tools |
|----------|-------|
| Languages | Node.js 22 LTS, Python 3.12, Go 1.24, Rust stable, OpenJDK 21 |
| Python | uv (package manager), ruff (linter/formatter) |
| AI | Claude Code CLI + VS Code extension (version-pinned); superpowers plugin (brainstorming, plan-writing, TDD, debugging); openspec CLI |
| Git | git, gh (GitHub CLI), gitleaks |
| Shell | zsh (default) with starship prompt, autosuggestions, syntax highlighting, history search |
| Dev tools | make, gcc, jq, ripgrep, fd, tmux, vim, nano, shellcheck, htop, tree |
| Container | Docker CLI (socket-mount, no daemon) |

Base image: Ubuntu 24.04 LTS. Runs as non-root user `coder` with passwordless sudo.

## Security

The container itself is the primary isolation boundary — host secrets (SSH keys, GPG keys, AWS / kube credentials, etc.) aren't visible inside unless you mount them. On top of that, the image adds:

| Control | How |
|---------|-----|
| **AI git push blocked** | PreToolUse hook denies any `git push` / `git remote add|set-url` Bash command from Claude. Users running `git push` themselves inside the container are unaffected. |
| **AI GitHub publishing blocked** | Same hook denies `gh pr create|merge|comment`, `gh issue create|comment`, `gh release create`, `gh repo create|delete` from Claude. |
| **Gitleaks pre-commit** | Wired up at build via `git config --system core.hooksPath`. Scans every commit for secrets automatically. |
| **Commit message scrubbing** | `commit-msg` git hook strips Claude/Anthropic `Co-Authored-By` and "Generated with Claude" lines. |
| **Managed settings** | Container-enforced settings (PreToolUse hooks, attribution) live at `/etc/claude-code/managed-settings.json`, Claude Code's native managed-settings location. The managed layer sits at the top of Claude Code's settings precedence chain, so container policies always win — without merging into or overwriting your `--claude-dir` `settings.json`. |
| **Host VS Code isolation** | Settings sync blocked; Copilot blocked; extension versions pinned. |

Earlier image versions also tried to block `.env` / `*.key` file reads, system-path writes, `sudo`, and access to `~/.gnupg` / `~/.kube` / `~/.claude/` etc. Those were removed: in container isolation they protected against threats that don't exist (host creds aren't reachable; project files are intentionally visible) while creating friction for normal Claude Code operations (`Update plan` writes to `~/.claude/`, projects often have legitimate `.env` files). The remote-publishing block is the one that actually matters — it's the only operation that escapes the sandbox.

## Prerequisites

- A supported host (macOS, Linux, or Windows with WSL2)
- A Docker runtime per the matrix above
- The `docker` CLI and `docker-buildx` plugin (bundled with most installs; if not, see your runtime's docs)
- For VS Code attach mode (`dev.sh`), Microsoft Visual Studio Code with the appropriate remote extension installed (see per-platform setup below)

## macOS setup

Skip this section if you're on Docker Desktop. Colima defaults to a **2 GiB / 2 CPU** VM, which is tight for a full Node + Go + Rust + Python toolchain plus VS Code Server. Bump it before first use:

```bash
brew install colima docker

# Start with a reasonable budget; saved to ~/.colima/default/colima.yaml,
# so future `colima start` calls reuse it.
colima start --cpu 4 --memory 12 --disk 60

# Verify
docker info --format '{{.MemTotal}}'   # ~12.8e9 bytes for --memory 12
```

Pick numbers that fit your Mac's physical RAM — Colima reserves whatever you allocate. To change later:

```bash
colima stop                                 # WARNING: kills running containers
colima start --cpu 6 --memory 16            # new sizing, persisted
```

Colima auto-starts on login if you ran `brew services start colima`; otherwise `colima start` (no args) brings up the VM with your saved profile.

## Linux setup

The OSS-friendly default. The launchers don't need a GUI runtime; install Docker Engine directly from the official Docker repos.

### Install Docker Engine

Follow the official Docker installation guide for your distribution:

- **Debian/Ubuntu:** https://docs.docker.com/engine/install/ubuntu/
- **Fedora/CentOS/RHEL:** https://docs.docker.com/engine/install/fedora/
- **Other distros:** https://docs.docker.com/engine/install/

Then add your user to the `docker` group so you don't need `sudo` for every container command:

```bash
sudo usermod -aG docker $USER
newgrp docker   # or log out and back in
docker run hello-world   # should succeed without sudo
```

No UID workaround is needed. The launchers pass `--build-arg USER_UID=$(id -u)` to `docker build`, so the locally-built image's container user matches your host user regardless of whether your UID is 1000 or something else.

### VS Code (for dev.sh)

Install Visual Studio Code from your distro's package manager or from https://code.visualstudio.com. Install the **Dev Containers** extension (`ms-vscode-remote.remote-containers`). The `code` CLI ships with VS Code and lands on `$PATH` automatically on Linux.

### Or: use Docker Desktop

Docker Desktop is available for Linux and works identically. It carries a commercial-use license for organizations >250 employees OR >$10M annual revenue. The launchers don't care which Docker runtime is running.

## Windows + WSL2 setup

On Windows, ai-sandbox runs inside a WSL2 Linux distribution. The launchers and Docker both live inside WSL2; your Windows VS Code attaches to containers via WSL2 transparently.

### 1. Install WSL2

From an elevated PowerShell:

```powershell
wsl --install
```

This installs WSL2 plus an Ubuntu distribution by default. Restart when prompted, then open the Ubuntu shell from the Start menu.

### 2. Install Docker Engine inside WSL2

Inside the WSL2 Ubuntu shell, follow the [Linux setup](#linux-setup) instructions. The same `apt`-based Docker Engine install works because WSL2 IS Linux from Docker's perspective.

Start the Docker daemon:

```bash
sudo service docker start
```

Modern WSL versions (0.67.6+) include systemd support enabled by default, so `systemctl enable docker` makes it autostart. Older WSL setups need a shell-rc hook or manual start each session.

### 3. Install VS Code with the WSL extension (required for dev.sh)

On the Windows side, install Visual Studio Code from https://code.visualstudio.com. Then install the **WSL** extension (`ms-vscode-remote.remote-wsl`) and the **Dev Containers** extension (`ms-vscode-remote.remote-containers`).

Inside the WSL2 shell, run `code .` at least once. This bootstraps the WSL→Windows VS Code bridge that `dev.sh` relies on for the container-attach URI scheme.

### 4. Clone the repo inside WSL2

Critical: clone ai-sandbox AND your project repositories INSIDE the WSL2 filesystem:

```bash
# Inside the WSL2 shell:
mkdir -p ~/code
cd ~/code
git clone <ai-sandbox-repo-url>
```

Do **not** clone into a Windows-mounted path like `/mnt/c/Users/...`. Those paths have slow filesystem performance and inconsistent bind-mount UID semantics across the Windows/WSL boundary. Keep all of your dev work native to WSL2.

From this point on, use the launcher scripts (`./run.sh`, `./dev.sh`) inside the WSL2 shell exactly as on Linux.

### Or: use Docker Desktop with WSL2 backend

Docker Desktop with WSL2 integration enabled is a more polished but commercial alternative — Docker Desktop installs in Windows and exposes the daemon to your WSL2 distros. Same license tier as elsewhere (free for personal/small business, paid for orgs >250 employees or >$10M revenue).

## Quick start

```bash
# Build the image (one-time, ~5–10 min)
./run.sh --build

# Run against a project
./run.sh ~/myproject --claude --claude-dir ~/.my-claude-config
```

`--build` builds from source against the current working tree. Re-run it whenever you've edited the `Dockerfile`, `entrypoint.sh`, `container-hooks/`, or `container-settings.json`. There is no published image — local build is the only path.

## Authentication

Use `--claude-dir` to override the auto-default state directory. By default, persistence is on: state goes to `~/.ai-sandbox/<project-basename>/` on the host. Pass `--claude-dir <path>` to point it somewhere else (e.g., to share credentials across projects). The container never modifies `settings.json` inside this directory — its own enforcement settings live in a separate managed-settings file inside the image.

### API key mode

Put your `settings.json` with the API key in a directory and point `--claude-dir` at it. Some providers require a specific Claude Code version — use `--claude-version` to pin it.

```bash
# Create a directory for API key config + session history
mkdir -p ~/.ai-sandbox-api
# Put your settings.json with API key there
cp ~/my-api-settings.json ~/.ai-sandbox-api/settings.json

# Run with it
./run.sh ~/myproject --claude --claude-dir ~/.ai-sandbox-api --claude-version 2.1.98
./dev.sh ~/myproject --claude-dir ~/.ai-sandbox-api --claude-version 2.1.98
```

### Enterprise / OAuth mode

Point `--claude-dir` at a directory for persistent credentials. Log in once, it persists.

```bash
# Create a directory for enterprise credentials
mkdir -p ~/.ai-sandbox/auth

# First time — log in
./run.sh ~/myproject --claude-dir ~/.ai-sandbox/auth
# Inside container: claude auth login

# Next time — auto-authenticated
./run.sh ~/myproject --claude --claude-dir ~/.ai-sandbox/auth
./dev.sh ~/myproject --claude-dir ~/.ai-sandbox/auth
```

### Auto-persist mode (default)

No flag needed — state lives in `~/.ai-sandbox/<project-basename>/` on your host. Log in once per project, session history and credentials persist across container restarts.

```bash
./run.sh ~/myproject --claude
./dev.sh ~/myproject
```

To wipe state for a single project: `rm -rf ~/.ai-sandbox/<project-basename>`.

### Wipe credentials

```bash
# API key mode
rm -rf ~/.ai-sandbox-api

# Enterprise mode
rm -rf ~/.ai-sandbox/auth
```

## Usage reference

### run.sh

```
./run.sh [project-path] [options]
```

| Flag | Description |
|------|-------------|
| `--claude` | Launch Claude Code CLI directly instead of zsh shell |
| `--claude-dir <path>` | Mount a host directory as Claude config (`~/.claude` inside container) |
| `--claude-version <version>` | Use a specific Claude Code version (default: latest) |
| `--build` | Build or rebuild the Docker image locally |
| `--help` | Show help |

### dev.sh

Starts the container in the background and opens VS Code attached to it. Open a terminal in VS Code and run `claude` to start.

```
./dev.sh <project-path> [options]
```

| Flag | Description |
|------|-------------|
| `--claude-dir <path>` | Mount a host directory as Claude config |
| `--claude-version <version>` | Use a specific Claude Code version (default: latest) |
| `--stop <project-path>` | Stop the container for a specific project |
| `--stop-all` | Stop all ai-sandbox containers |
| `--list` | List running ai-sandbox instances |
| `--help` | Show help |

Multiple projects can run simultaneously — each gets its own container named `ai-sandbox-<project-folder>`. If a project's container is already running, `dev.sh` reattaches instead of creating a duplicate.

```bash
# Run two projects at once
./dev.sh ~/project-a --claude-dir ~/.ai-sandbox-api --claude-version 2.1.98
./dev.sh ~/project-b --claude-dir ~/.ai-sandbox/auth

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

Extensions installed in the container: Python, debugpy, Ruff, Terraform, YAML, JSON, GitLens, Claude Code.

The first 7 are **baked into the image** at build time (single source of truth: `vscode-extensions.txt`) so they're present the moment the container starts. The Claude Code extension is installed **post-attach** by `dev.sh` (`docker exec -d ... code-server --install-extension --force`) so its install hook fires inside VS Code Server's running context — that path initializes the extension's auth state from your `settings.json` env block, which the bake-time install path skips. Watch the install with:

```bash
docker exec ai-sandbox-<project> cat /tmp/install-claude-ext.log
```

Pinned versions of the Claude extension are honored: `--claude-version 2.1.98` installs `anthropic.claude-code@2.1.98`.

> **Important:** After changing the Dockerfile or entrypoint, rebuild all image versions you use:
> ```bash
> ./run.sh --build
> ./run.sh --build --claude-version 2.1.98
> ```

## Claude Code version management

The Claude Code version is baked into the image at build time. Each version gets its own image tag. Multiple versions can coexist — they share cached layers (Ubuntu, Go, Rust, Node, etc.) so only the Claude Code layer differs.

```bash
# Build both versions
./run.sh --build                          # -> ai-sandbox:latest
./run.sh --build --claude-version 2.1.98  # -> ai-sandbox:cc-2.1.98

# Run different versions on different projects
./dev.sh ~/project-a --claude-dir ~/.ai-sandbox-api --claude-version 2.1.98
./dev.sh ~/project-b --claude-dir ~/.ai-sandbox/auth

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
# Build the image (first run)
docker compose build

# Shell
PROJECT_DIR=~/myproject docker compose run --rm claude

# Claude Code directly
PROJECT_DIR=~/myproject docker compose --profile interactive run --rm claude-interactive
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_DIR` | `.` | Project directory to mount |
| `CLAUDE_VERSION_TAG` | `latest` | Tag suffix used in the image name (`ai-sandbox:<tag>`) |
| `CLAUDE_VERSION` | `latest` | Claude Code version baked in at build time |
| `USER_UID` | `1000` | Container user UID (build-time only; runtime is hardcoded to 1000) |
| `USER_GID` | `1000` | Container user GID (build-time only; runtime is hardcoded to 1000) |

## Volume mounts

| Container path | Host source | When | Purpose |
|----------------|-------------|------|---------|
| `/home/coder/project` | Your project directory | Always | Working directory for code |
| `/home/coder/.claude` | `--claude-dir` path (default: `~/.ai-sandbox/<project-basename>/`) | Always | Persistent config, credentials, session history |

Container-enforced settings (PreToolUse hooks, attribution-stripping) live inside the image at `/etc/claude-code/managed-settings.json` and take precedence over any user settings via Claude Code's native managed-settings layer. The container does not read or modify `settings.json` inside the bind-mounted `--claude-dir`.

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

### Baked Claude plugins

Plugins listed in `claude-plugins.txt` (repo root) are git-cloned at build time into `/opt/ai-sandbox/plugins/<name>/` and loaded automatically by every `claude` invocation via `--plugin-dir`. To add a plugin, append a line to that file in the format `<name> <git-url> [<ref-or-sha>]` and rebuild. Pinning to a sha gives reproducible builds; omit the third column to track `main`.

User-installed plugins via `/plugin install foo` are unaffected — they continue to write to `~/.claude/plugins/` (the per-project state dir on host) and coexist with the baked set.

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
