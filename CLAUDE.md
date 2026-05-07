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

There is no test suite and no package manifest. CI lives in `.github/workflows/publish.yml` — it builds the image multi-arch (amd64/arm64) and pushes to `ghcr.io/vipulr8/ai-sandbox` on pushes to `main`, on `cc-*`/`v*` tags, on a weekly schedule, and on `workflow_dispatch`. End users can either pull from GHCR (`./run.sh --pull` / `./dev.sh --pull`) or build locally (`./run.sh --build`).

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

### Settings merge (the security-critical bit)

`container-settings.json` is baked into the image at `/opt/ai-sandbox/settings.json` and contains the `PreToolUse` hooks plus attribution-stripping config. On every container start, `entrypoint.sh` merges any user-provided `settings.json` (from a `--claude-dir` mount or legacy `/tmp/user-settings.json`) with the container settings using:

```sh
jq -s '.[0] * .[1]' "$USER_SETTINGS" /opt/ai-sandbox/settings.json
```

The right operand wins in jq's `*` merge — so **container values always override user-provided values for the same keys**. The merge is recursive for objects but **replace-wins for arrays**, which is what makes the security guarantee actually hold: `hooks.PreToolUse` is a JSON array, so a user-supplied `PreToolUse` array is wholly replaced by the container's array (not concatenated, not deduped). Any new top-level key added to `container-settings.json` automatically takes precedence over user config. Don't reverse the operand order, and don't switch to a different merge tool without preserving both the right-wins-on-scalars and replace-wins-on-arrays behavior.

### Two layers of hooks

Two unrelated systems both live under `container-hooks/` and shouldn't be conflated:

1. **Claude Code `PreToolUse` hooks** (`block-credentials.sh`, `block-sensitive-paths.sh`) — invoked by the Claude CLI itself on every `Read|Bash|Edit|Write|Grep|Glob` tool call. They read JSON from stdin (`tool_name`, `tool_input.file_path`/`tool_input.command`) and emit a JSON `permissionDecision: "deny"` to block. They enforce the credential-file blocklist, system-path write block, `sudo`-block, `git push`-block, and `gh pr create`-block.
2. **Global git hooks** (`container-hooks/git/pre-commit`, `commit-msg`) — wired up at image build via `git config --system core.hooksPath /opt/ai-sandbox/git-hooks`. `pre-commit` runs `gitleaks protect --staged`; `commit-msg` strips Claude/Anthropic `Co-Authored-By` and "Generated with Claude" lines from commit messages.

The git-push and `gh` blocks live in the Claude `PreToolUse` hook, not in git hooks — they only block the AI, not the human user running git directly inside the container.

`block-credentials.sh` matches its blocklist with bash `case *"$pattern"*` — that's **substring** match, not glob. So `.env` matches `.environment.txt`, `*.key` matches `monkey.txt`, etc. This is intentionally over-broad (fail-closed) and the `.env.*` / `secrets/` / `.aws/` entries rely on substring semantics to work at all. Don't "fix" it by switching to glob matching without rewriting the entries — you'd silently un-block real credential paths.

### Entrypoint responsibilities

PID 1 runs `entrypoint.sh` directly as the `coder` user — the Dockerfile's final `USER` directive sets that. There is no root phase, no `gosu`, no `usermod`. Each container start:

1. **Settings merge** — if a user `settings.json` is present (mounted via `--claude-dir` at `~/.claude/settings.json`, or the legacy `/tmp/user-settings.json` path), merge it with `/opt/ai-sandbox/settings.json` via `jq -s '.[0] * .[1]'`. Otherwise copy the container settings as-is.
2. **`.claude.json` restore** — if `$HOME/.claude.json` is missing, restore from the largest file in `$HOME/.claude/backups/`. Claude Code expects this file at the home root, but only `~/.claude` is bind-mounted, so backups live under the mount and are copied back on startup.
3. **Docker socket group fix** — if `/var/run/docker.sock` is mounted, ensure the `coder` user is in a group matching the socket's GID (uses `sudo` since `coder` has passwordless sudo).
4. **Auth status print** + environment summary banner.
5. **VS Code Server settings** — write `~/.vscode-server/data/Machine/settings.json` to disable settings sync, block Copilot, pin terminal to zsh, set Monokai theme.
6. `exec "$@"` (the CMD — defaults to `zsh`).

### Volume mounts

| Container path | Source | Notes |
|----------------|--------|-------|
| `/home/coder/project` | `--` positional arg | working dir; required |
| `/home/coder/.claude` | `--claude-dir` | optional; persists credentials, settings, session history, `.claude.json` backups |
| `/var/run/docker.sock` | env `DOCKER_SOCKET=1` | optional; auto-detects Colima/`DOCKER_HOST`/standard paths |

`--claude-dir` is the single mount point for all Claude state. There is no longer a separate `--settings` flag (commit `c0e4027` replaced it); the entrypoint still has a fallback that reads `/tmp/user-settings.json` for backwards compat but new code should not rely on it.

## Conventions worth knowing

- The container user `coder` is hardcoded to UID/GID 1000 at image build time. There is no runtime adaptation. For local builds, `run.sh` and `dev.sh` still pass `--build-arg USER_UID=$(id -u)` so the locally-built image matches the host user. The registry image (built in CI) is always 1000. macOS Docker Desktop / Colima translate UIDs across the bind-mount boundary, which is why this is fine on the supported platform.
- `.env` next to the launcher scripts is auto-sourced by both `run.sh` and `dev.sh` (`set -a; source .env; set +a`). It is git-ignored — use it for `ANTHROPIC_MODEL`, `DOCKER_SOCKET`, etc.
- The Dockerfile is organized into numbered "Layer N" comment blocks. Reordering them changes Docker's build cache invalidation behavior; keep slow/stable layers (apt, Go, Rust, Node) above fast-changing ones (Claude CLI install, hooks copy).
- Auto-update is disabled inside the image (`DISABLE_AUTOUPDATER=1` env, `extensions.autoUpdate: false` for VS Code). To upgrade Claude Code, rebuild with a new `--claude-version`. Don't add update logic to the running container.
