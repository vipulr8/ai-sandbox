# ai-sandbox

Isolated Docker container for running Claude Code with a full-stack development toolchain. Security-hardened: AI tools are sandboxed to the project directory with no access to host config, credentials, or system files.

> **Supported platform: macOS only.** The image bakes UID 1000 at build time and relies on Docker Desktop / Colima translating UIDs across the bind-mount boundary. On Linux hosts with UID ≠ 1000, files written into bind-mounted directories will appear owned by 1000 on the host. Linux support is intentionally out of scope.

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
| **AI git push blocked** | PreToolUse hook denies any `git push` / `git remote add\|set-url` Bash command from Claude. Users running `git push` themselves inside the container are unaffected. |
| **AI GitHub publishing blocked** | Same hook denies `gh pr create\|merge\|comment`, `gh issue create\|comment`, `gh release create`, `gh repo create\|delete` from Claude. |
| **Gitleaks pre-commit** | Wired up at build via `git config --system core.hooksPath`. Scans every commit for secrets automatically. |
| **Commit message scrubbing** | `commit-msg` git hook strips Claude/Anthropic `Co-Authored-By` and "Generated with Claude" lines. |
| **Managed settings** | Container-enforced settings (PreToolUse hooks, attribution) live at `/etc/claude-code/managed-settings.json`, Claude Code's native managed-settings location. The managed layer sits at the top of Claude Code's settings precedence chain, so container policies always win — without merging into or overwriting your `--claude-dir` `settings.json`. |
| **Host VS Code isolation** | Settings sync blocked; Copilot blocked; extension versions pinned. |

Earlier image versions also tried to block `.env` / `*.key` file reads, system-path writes, `sudo`, and access to `~/.gnupg` / `~/.kube` / `~/.claude/` etc. Those were removed: in container isolation they protected against threats that don't exist (host creds aren't reachable; project files are intentionally visible) while creating friction for normal Claude Code operations (`Update plan` writes to `~/.claude/`, projects often have legitimate `.env` files). The remote-publishing block is the one that actually matters — it's the only operation that escapes the sandbox.

## Prerequisites

- macOS host
- A container runtime (e.g., [Colima](https://github.com/abiosoft/colima) or Docker Desktop)
- Docker CLI (`brew install docker` on macOS) — Docker Desktop bundles the CLI; Colima users install it separately
- BuildKit (bundled with Docker Desktop; included via `docker-buildx` if you installed `docker` standalone for Colima)

## Colima setup

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

## Quick start

```bash
# Build the image (one-time, ~5–10 min; produces a ~4 GB image)
./run.sh --build

# Run against a project
./run.sh ~/myproject --claude --claude-dir ~/.my-claude-config
```

`--build` builds from source against the current working tree. Re-run it whenever you've edited the `Dockerfile`, `entrypoint.sh`, `container-hooks/`, or `container-settings.json`. There is no published image — local build is the only path.

## Authentication

Use `--claude-dir` to override the auto-default state directory. By default, persistence is on: state goes to `~/.ai-sandbox/<project-basename>/` on the host. Pass `--claude-dir <path>` to point it somewhere else — for example, point multiple projects at the *same* host directory (e.g., `~/.ai-sandbox/shared`) to share one logged-in session across all of them. The container never modifies `settings.json` inside this directory — its own enforcement settings live in a separate managed-settings file inside the image.

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

```text
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
| `CLAUDE_DIR` | `$HOME/.ai-sandbox/compose` | Host directory for persistent Claude state (credentials, session history). Mirrors `--claude-dir` in `run.sh`/`dev.sh`. |
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

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `Error: Docker daemon is not reachable` | Start your container runtime: `colima start` (Colima) or open Docker Desktop. The launchers refuse to proceed until `docker info` succeeds. |
| `dev.sh` says `missing required host tool: xxd` | Install vim (`brew install vim` on macOS) — `xxd` ships with it and `dev.sh` needs it to hex-encode the container name for the VS Code attach URI. |
| `dev.sh` says `missing required host tool: code` | Install VS Code and run *Shell Command: Install 'code' command in PATH* from the Command Palette. |
| VS Code attaches, but the Claude Code extension isn't installed yet | The Claude extension installs **post-attach** (see `dev.sh`). Watch the install log: `docker exec ai-sandbox-<project> cat /tmp/install-claude-ext.log` |
| Claude keeps asking me to log in every time | You're probably running ephemerally without `--claude-dir`. The default `--claude-dir ~/.ai-sandbox/<project>` should persist; check that the directory exists and is writable on the host. |
| Build fails partway through with `permission denied` or Colima OOM | Bump the Colima VM: `colima stop && colima start --cpu 4 --memory 12 --disk 60`. A full build needs ~8 GB of headroom. |
| `docker ps` from inside the container shows `permission denied` after first launch | Only happens with `DOCKER_SOCKET=1`. The entrypoint adds `coder` to the host socket's group and re-execs via `sg`. If the warning persists, open a fresh shell inside the container: `docker exec -it ai-sandbox-<project> zsh`. |
| Want to wipe one project's state and start fresh | `rm -rf ~/.ai-sandbox/<project-basename>`. To wipe everything: `rm -rf ~/.ai-sandbox`. |
| Want to free disk: drop old image tags | `docker rmi ai-sandbox:cc-<old-version>`. The `:latest` tag and any version-pinned tags are independent images that share base layers; removing one does not break the others. |

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
