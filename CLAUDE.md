# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`ai-sandbox` is the build system for a security-hardened Docker image that runs Claude Code (and a full-stack dev toolchain) in isolation from the host. There is no application code — the deliverables are a `Dockerfile`, two launcher scripts (`run.sh`, `dev.sh`), an entrypoint, and a set of hooks. Future-Claude is most likely working **on** the sandbox image itself, not in a project running inside it.

## Common commands

```bash
# Build (or rebuild) the default image
./run.sh --build

# Build a version-pinned image; coexists with :latest as a separate tag
./run.sh --build --claude-version 2.1.98

# Sanity-check shell scripts (no test suite — shellcheck is the only linter)
shellcheck run.sh dev.sh entrypoint.sh container-hooks/*.sh container-hooks/git/*

# Smoke-test by running the image against an arbitrary directory
./run.sh /tmp --claude
```

After **any** edit to `Dockerfile`, `entrypoint.sh`, `container-settings.json`, or `container-hooks/`, the image must be rebuilt — running containers and existing tags do not pick up changes. If multiple `--claude-version` tags are in use, rebuild each one (`./run.sh --build && ./run.sh --build --claude-version <X>`).

There is no test suite, no package manifest, and no CI. The image is built locally via `./run.sh --build` (or `./run.sh --build --claude-version <X>` for a pinned tag). There is no published registry image — every user builds from source.

**Scope: macOS hosts only.** The image bakes UID 1000 at build time and there is no runtime UID adaptation. Docker Desktop and Colima translate UIDs across the bind-mount boundary on macOS, so this is invisible there. On Linux hosts with UID ≠ 1000, bind-mounted files would end up owned by 1000 — that case is intentionally out of scope.

## Architecture

### Three launch paths (not two)

- **`run.sh`** — foreground, ephemeral (`docker run --rm -it`). Drops the user into zsh, or with `--claude` straight into the Claude CLI. Container dies on exit.
- **`dev.sh`** — detached (`docker run -d ... sleep infinity`), then attaches VS Code via the `vscode-remote://attached-container+<hex>` URI scheme. Container is named `ai-sandbox-<project-folder>` so multiple projects can run side-by-side; `--list`/`--stop`/`--stop-all` manage them.
- **`docker-compose.yml` + `.devcontainer/devcontainer.json`** — a parallel entrypoint used by `docker compose run` and the VS Code Dev Containers extension. It does **not** share argument parsing or Docker-arg construction with the shell scripts.

Any change to mounts, env vars, or flags needs to land in all three places that apply: `run.sh`, `dev.sh`, and (where relevant) `docker-compose.yml`. It's easy to add a flag to one and silently miss the others.

VS Code extensions follow a **hybrid install model** — most baked at build time for reliability, one (Anthropic's) installed post-attach for an auth-state reason.

**Bake-time path (the 7 non-Claude extensions):** `vscode-extensions.txt` is the single source of truth. `scripts/install-vscode-extensions.sh` is invoked by the Dockerfile (Layer 8.5) to download the Microsoft VS Code Server tarball for the build's target arch and install every listed extension into `/home/coder/.vscode-server/extensions/`. Per-line routing: unversioned and `@latest` lines are batched through one `code-server --install-extension` call (resolving to latest); pinned `@X.Y.Z` lines trigger a direct VSIX download from the marketplace asset endpoint and are installed one-by-one (Microsoft's CLI does not accept `id@version` syntax). Build-time env vars like `${CLAUDE_VERSION}` are expanded by the install script's pure-bash substitution.

**Post-attach path (Anthropic's `anthropic.claude-code` only):** `dev.sh`, after `code --folder-uri ...`, runs `docker exec -d` with a polling loop that waits up to 120s for `~/.vscode-server/bin/<sha>/bin/code-server` (installed by VS Code itself on first attach), then runs `--install-extension anthropic.claude-code[@${CLAUDE_VERSION}] --force` once. Output goes to `/tmp/install-claude-ext.log` in the container. The reason this extension is NOT baked: bake-time install (via the standalone code-server tarball) skips the extension's install hook, leaving its API-mode auth state uninitialized — symptom is the extension prompting to log in even when the CLI is happy. Re-running the install via VS Code's *own* code-server fires the hook and initializes auth from `settings.json`'s env block. If a future Claude extension version stops needing this hook, move it back into `vscode-extensions.txt`.

`.devcontainer/devcontainer.json` keeps a parallel `extensions` array (bare IDs, no versions) for the Dev Containers "Reopen in Container" flow's documented contract — it must be kept in sync with `vscode-extensions.txt` plus `anthropic.claude-code` (since the Claude extension still needs to land somehow when used via Dev Containers, which doesn't run dev.sh's post-attach loop). Adding a non-Claude extension means: one line in `vscode-extensions.txt`, one entry in `.devcontainer/devcontainer.json`'s array, rebuild the image.

### Image tagging

`ai-sandbox:latest` is the default. `--claude-version <X>` produces `ai-sandbox:cc-<X>`. They are independent images that share lower Docker layers; only the Claude Code npm install layer differs. The launcher auto-builds whichever tag is requested if missing.

### Baked Claude plugins

`claude-plugins.txt` (repo root) enumerates Claude Code plugins to bake into the image. Format: `<name> <git-url> [<ref-or-sha>]`, one per line; empty lines and `#`-comments are ignored. At build time, `scripts/install-claude-plugins.sh` (invoked by Dockerfile Layer 7.5) clones each plugin into `/opt/ai-sandbox/plugins/<name>/` and pins to the optional sha for reproducibility.

The installer also generates `/usr/local/bin/claude` — a 5-line wrapper that exec's the real Claude CLI, prepending one `--plugin-dir /opt/ai-sandbox/plugins/<name>` flag for each baked plugin. Because `/usr/local/bin` precedes `/usr/bin` and Node global-install paths on Debian, the wrapper transparently shadows the npm-installed `claude` for interactive shells, the VS Code extension, and any other caller.

User-installed plugins via the `/plugin install foo` slash command continue to write to `~/.claude/plugins/` (the per-project bind-mount with auto-persist defaults) and are loaded by Claude's default scan. The baked set and the per-project set coexist; baked plugins always load, user-installed ones persist per-project.

To add a baked plugin: append a line to `claude-plugins.txt` and rebuild. The installer reads the file at build time only — no runtime re-scan. To remove or change a sha, same flow: edit the file, rebuild.

`OpenSpec` is a separate concern. It's an npm CLI (`@fission-ai/openspec`) installed globally in the same Dockerfile layer. It is NOT a Claude plugin — it provides its own slash commands once a user runs `openspec init` inside a project (which writes files into the project tree). Don't conflate it with the plugin baking machinery.

### Managed settings (the security-critical bit)

`container-settings.json` is baked into the image at `/etc/claude-code/managed-settings.json` — Claude Code's native managed-settings location on Linux. The managed-settings layer sits at the top of Claude Code's settings precedence chain (managed > local > project > user), so the container's `PreToolUse` hooks and attribution-stripping config always win, with no runtime merge required.

Two consequences of using the native layer instead of a runtime `jq` merge:

1. **The container never reads or writes `settings.json` inside the bind-mounted `~/.claude/`.** A user-owned `settings.json` in `--claude-dir` is invisible to the container. This means it is safe to point `--claude-dir` at a host-shared Claude config directory; an earlier merge-and-write-back design would have corrupted that file with container-only hook paths.
2. **Container enforcement is structurally stronger than before.** It's applied by Claude Code's settings loader directly, not by an entrypoint script whose correctness depends on `jq` semantics and operand ordering. Any new top-level key added to `container-settings.json` automatically takes precedence over user config.

When extending the container's enforced policies, edit `container-settings.json` directly. Hook command paths inside that JSON still point at `/opt/ai-sandbox/hooks/...` since that's where `container-hooks/` is copied at build time (the `COPY container-hooks/ /opt/ai-sandbox/hooks/` directive in the Dockerfile).

### Two layers of hooks

Two unrelated systems both live under `container-hooks/` and shouldn't be conflated:

1. **Claude Code `PreToolUse` hook** (`block-remote-publishing.sh`) — invoked by the Claude CLI on every `Bash` tool call. Reads JSON from stdin, emits a JSON `permissionDecision: "deny"` for any command starting with `git push`, `git remote add|set-url`, or the GitHub-publishing `gh` subcommands (`pr create|merge|comment`, `issue create|comment`, `release create`, `repo create|delete`). Other tool calls and other Bash commands are passed through.
2. **Global git hooks** (`container-hooks/git/pre-commit`, `commit-msg`) — wired up at image build via `git config --system core.hooksPath /opt/ai-sandbox/git-hooks`. `pre-commit` runs `gitleaks protect --staged`; `commit-msg` strips Claude/Anthropic `Co-Authored-By` and "Generated with Claude" lines from commit messages.

**The PreToolUse hook only blocks the AI**, not the human user running `git push` directly inside the container — and that's by design (the human can publish; the AI can't).

**Why so minimal?** Earlier versions of the hooks also blocked file patterns (`.env`, `*.pem`, `*.key`, `credentials.json`, etc.), credential paths (`~/.gnupg`, `~/.kube`, `~/.aws/`, `~/.claude/` itself, etc.), and system-path writes. All of those were removed because the container is otherwise an isolated sandbox: host secrets aren't reachable by default (nothing host-sensitive is mounted unless the user explicitly opts in via `AWS_SSO=1` or `GH_AUTH=1`), the project files are *intentionally* visible, and Claude Code legitimately writes to `~/.claude/` for plans/memory/sessions. The blocklists were creating friction (broke `Update plan`, prevented commits whose messages mentioned `.env`, etc.) without protecting against threats that exist in this environment. Remote-publishing is the only operation that actually escapes the sandbox, so it's the only one still blocked.

### Entrypoint responsibilities

PID 1 runs `entrypoint.sh` directly as the `coder` user — the Dockerfile's final `USER` directive sets that. There is no root phase, no `gosu`, no `usermod`. Each container start:

1. **`.claude.json` symlink** — `ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"` so writes by Claude Code at home root flow into the bind-mounted `~/.claude/` and persist on the host.
2. **Docker socket group fix** — if `/var/run/docker.sock` is mounted, ensure the `coder` user is in a group matching the socket's GID (uses `sudo` since `coder` has passwordless sudo).
3. **Auth status print** + environment summary banner.
4. **VS Code Server settings** — write `~/.vscode-server/data/Machine/settings.json` to disable settings sync, block Copilot, pin terminal to zsh, set Monokai theme.
5. `exec "$@"` (the CMD — defaults to `zsh`).

The entrypoint does **not** read, merge, or write any user-owned `settings.json`. Container-enforced settings are at `/etc/claude-code/managed-settings.json` (Dockerfile-baked), loaded directly by Claude Code via the managed-settings layer.

### Volume mounts

| Container path | Source | Notes |
|----------------|--------|-------|
| `/home/coder/project` | `--` positional arg | working dir; required |
| `/home/coder/.claude` | `--claude-dir` (defaults to `$HOME/.ai-sandbox/<project-basename>/`) | persists credentials, settings, session history, `.claude.json` (via symlink) |
| `/var/run/docker.sock` | env `DOCKER_SOCKET=1` | optional; auto-detects Colima/`DOCKER_HOST`/standard paths |
| `/home/coder/.aws` | env `AWS_SSO=1` (source `AWS_DIR`, default `~/.aws`) | optional; reuse host AWS SSO login + cached token (read-write) |

`--claude-dir` is the single mount point for all Claude state. With auto-persist defaults, no flag is required for state to survive container restarts.

## Conventions worth knowing

- The container user `coder` is hardcoded to UID/GID 1000 at image build time. There is no runtime adaptation. `run.sh` and `dev.sh` pass `--build-arg USER_UID=$(id -u)` so the locally-built image matches the host user. macOS Docker Desktop / Colima translate UIDs across the bind-mount boundary, which is why this is fine on the supported platform.
- `.env` next to the launcher scripts is auto-sourced by both `run.sh` and `dev.sh` (`set -a; source .env; set +a`). It is git-ignored — use it for `ANTHROPIC_MODEL`, `DOCKER_SOCKET`, `AWS_SSO`/`AWS_DIR` (mount `~/.aws` to reuse host AWS SSO), `GH_AUTH` (inject host `gh auth token` as `GH_TOKEN`), etc.
- The Dockerfile is organized into numbered "Layer N" comment blocks. Reordering them changes Docker's build cache invalidation behavior; keep slow/stable layers (apt, Go, Rust, Node) above fast-changing ones (Claude CLI install, hooks copy).
- Auto-update is disabled inside the image (`DISABLE_AUTOUPDATER=1` env, `extensions.autoUpdate: false` for VS Code). To upgrade Claude Code, rebuild with a new `--claude-version`. Don't add update logic to the running container.
