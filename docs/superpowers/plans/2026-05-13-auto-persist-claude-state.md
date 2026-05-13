# Auto-persist Claude state — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude state persist across container kills with no flag required, eliminate the bind-mount writeback bug, and close the `.claude.json` data-loss gap.

**Architecture:** Three independent changes, each in its own commit so failures bisect cleanly. (1) Move container-enforced policies from `/opt/ai-sandbox/settings.json` (runtime-merged) to `/etc/claude-code/managed-settings.json` (Claude Code's native managed-settings layer) — this alone fixes the bind-mount writeback bug and makes the entrypoint merge dead code. (2) Default `--claude-dir` to `$HOME/.ai-sandbox/<project-basename>/` in both launchers so persistence is on by default. (3) Symlink `~/.claude.json` into the bind-mount so its writes persist atomically instead of via periodic backup checkpoints.

**Tech Stack:** Bash, Docker, jq, shellcheck. No application code, no test suite — verification is shellcheck + empirical container smoke tests. Spec: `docs/superpowers/specs/2026-05-13-claude-state-persistence-design.md`.

**Operating rules (carry through every commit):**
- Branch: `feat/auto-persist-claude-state` (already created).
- **No git push, no `gh pr create`** — local commits only; user publishes themselves.
- **No Claude attribution in commit messages.** No `Co-Authored-By: Claude` trailer, no "Generated with Claude" footer.
- After **any** edit to `Dockerfile`, `entrypoint.sh`, `container-settings.json`, or `container-hooks/`, rebuild with `./run.sh --build` before the next behavioral test.
- `shellcheck` runs against `run.sh`, `dev.sh`, `entrypoint.sh`, `container-hooks/*.sh`, `container-hooks/git/*` (per `CLAUDE.md`).

---

## Task 1: Move container-enforced policies to `/etc/claude-code/managed-settings.json`

This task alone fixes problem 3 (bind-mount writeback). After it lands, the existing entrypoint settings-merge block becomes dead code (the file it reads no longer exists at the source path), but we leave the dead code in place until Task 2 so this commit is a single concern.

**Files:**
- Modify: `Dockerfile:124-127` (the "Container hooks and settings" block)
- Read but don't modify in this task: `container-settings.json`, `entrypoint.sh`

- [ ] **Step 1.1: Edit `Dockerfile` to move the managed settings file**

Open `Dockerfile`. Replace lines 124-127:

```dockerfile
# ── Container hooks and settings ─────────────────────────────────
COPY container-hooks/ /opt/ai-sandbox/hooks/
RUN chmod +x /opt/ai-sandbox/hooks/*.sh
COPY container-settings.json /opt/ai-sandbox/settings.json
```

with:

```dockerfile
# ── Container hooks and managed settings ─────────────────────────
# Hooks stay in /opt/ai-sandbox/hooks/; the managed-settings JSON
# lives at Claude Code's native managed-scope path so it is loaded
# at the top of the precedence chain without any runtime merge.
COPY container-hooks/ /opt/ai-sandbox/hooks/
RUN chmod +x /opt/ai-sandbox/hooks/*.sh
RUN mkdir -p /etc/claude-code
COPY container-settings.json /etc/claude-code/managed-settings.json
```

Do NOT change `container-settings.json` — the hook command path inside it is still `/opt/ai-sandbox/hooks/block-remote-publishing.sh` and that path is unchanged.

- [ ] **Step 1.2: Rebuild the image**

Run:
```bash
./run.sh --build
```
Expected: build succeeds; no errors related to `/etc/claude-code/`.

- [ ] **Step 1.3: Verify the managed-settings file is at the expected path inside the image**

Run:
```bash
docker run --rm ai-sandbox:latest ls -la /etc/claude-code/managed-settings.json /opt/ai-sandbox/settings.json 2>&1
```
Expected:
- `/etc/claude-code/managed-settings.json` exists and has the same content as `container-settings.json`.
- `/opt/ai-sandbox/settings.json` does NOT exist (the line that created it is gone). The `ls` will report "No such file or directory" for that path — that's the desired state.

- [ ] **Step 1.4: Verify the PreToolUse hook still fires (Change 1 gate, part a)**

```bash
mkdir -p /tmp/sandbox-gate1
echo '{}' > /tmp/sandbox-gate1/settings.json   # benign user settings to ensure the bind-mount has a file
./run.sh /tmp/sandbox-gate1 --claude-dir /tmp/sandbox-gate1
```

Inside the container, ask the *Claude CLI* (not the shell) to try a `git push`. The simplest way: type `claude` then prompt it with "run `git push origin main`". Confirm the request is denied with the "Blocked: git push and remote modifications are not allowed in ai-sandbox" message from `block-remote-publishing.sh`.

If the hook does NOT fire: STOP. The managed-settings layer is not honoring hooks the way the docs claim. Re-read `code.claude.com/docs/en/settings`, then fall back per Change 1 in the spec: keep a small entrypoint merge but write the merged result to a container-only path (e.g., `/tmp/claude-merged-settings.json`) and never touch the bind-mount. The rest of the plan still applies.

Exit the container (Ctrl-D or `exit`).

- [ ] **Step 1.5: Verify attribution is still enforced (Change 1 gate, part b)**

Re-launch:
```bash
./run.sh /tmp/sandbox-gate1 --claude-dir /tmp/sandbox-gate1
```

Inside the container:
```bash
cd /tmp
git init gate-test && cd gate-test
git config user.email "test@test"
git config user.name "test"
git commit --allow-empty -m "test attribution"
git log -1 --format='%B'
```
Expected: the commit message body has no `Co-Authored-By: Claude` trailer, no "Generated with Claude" footer. If a trailer appears: STOP — `attribution`/`includeCoAuthoredBy` aren't honored in managed scope, fall back per Step 1.4's fallback path.

Exit the container.

- [ ] **Step 1.6: Verify the bind-mount is now untouched (Change 1 gate, part c — the bug-fix proof)**

```bash
rm -rf /tmp/sandbox-gate1
mkdir -p /tmp/sandbox-gate1
cat > /tmp/sandbox-gate1/settings.json <<'EOF'
{"foo": "bar", "hooks": {"PreToolUse": []}}
EOF
CHECKSUM_BEFORE=$(shasum -a 256 /tmp/sandbox-gate1/settings.json)

./run.sh /tmp/sandbox-gate1 --claude-dir /tmp/sandbox-gate1
# Inside the container: do nothing, just exit immediately with Ctrl-D.

CHECKSUM_AFTER=$(shasum -a 256 /tmp/sandbox-gate1/settings.json)
echo "BEFORE: $CHECKSUM_BEFORE"
echo "AFTER:  $CHECKSUM_AFTER"
```

Expected: BEFORE and AFTER checksums are **identical**. This is the proof that the bind-mount-writeback bug is fixed. If they differ, the entrypoint is still touching the file — investigate before continuing.

- [ ] **Step 1.7: Commit**

```bash
git add Dockerfile
git commit -m "Move container-enforced settings to /etc/claude-code/managed-settings.json

Claude Code's native managed-settings layer sits above all other
settings scopes and is read directly, eliminating the runtime jq merge
that previously wrote container-only hook paths back into the
user-owned settings.json inside the bind-mount.

The merge code in entrypoint.sh is now dead (its source file is gone)
and is removed in the next commit."
```

---

## Task 2: Remove dead settings-merge + backup-restore code from `entrypoint.sh`

After Task 1, lines 4-29 (the settings-merge block) and lines 31-40 (the `.claude.json` backup-restore block) are dead code. Task 3 replaces the backup-restore mechanism with a symlink — but the deletion is conceptually a separate cleanup, so we land it on its own.

**Files:**
- Modify: `entrypoint.sh` (delete lines 4-40, keeping the shebang and `set -e`)

- [ ] **Step 2.1: Edit `entrypoint.sh` — delete the two dead blocks**

Open `entrypoint.sh`. Delete everything between `set -e` (line 2) and `# ── 2. Docker socket permissions ──...` (line 42, soon to be renumbered). After the edit, the top of the file reads:

```bash
#!/bin/bash
set -e

# ── 1. Docker socket permissions ──────────────────────────────────
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
    ...
```

Also renumber the remaining section comments so they're sequential:
- `# ── 2. Docker socket permissions` → `# ── 1. Docker socket permissions`
- `# ── 3. Auth status` → `# ── 2. Auth status`
- `# ── 4. Environment summary` → `# ── 3. Environment summary`
- `# ── 5. VS Code Server settings` → `# ── 4. VS Code Server settings`
- `# ── 6. Run command` → `# ── 5. Run command`

(Task 3 will re-introduce a `# ── 1. Claude state symlink` section before the socket block and bump these numbers back up by one. If that double-renumber feels wasteful, skip the renumber here and let Task 3 do both at once. Either ordering is fine; the constraint is that section numbers are sequential at every commit.)

- [ ] **Step 2.2: shellcheck**

Run:
```bash
shellcheck entrypoint.sh
```
Expected: clean (no warnings or errors). If any appear from surrounding code touched by removed neighbors, fix in this commit.

- [ ] **Step 2.3: Rebuild**

```bash
./run.sh --build
```
Expected: success.

- [ ] **Step 2.4: Regression check — container still starts, hook still fires**

```bash
./run.sh /tmp/sandbox-gate1 --claude-dir /tmp/sandbox-gate1
```
Inside the container, ask Claude to `git push origin main`. Confirm it's still denied (managed-settings is doing all the work now). Exit.

- [ ] **Step 2.5: Commit**

```bash
git add entrypoint.sh
git commit -m "Remove dead settings-merge and .claude.json backup-restore blocks

The settings-merge block became dead code in the previous commit when
container-settings.json moved out of /opt/ai-sandbox/. The
backup-restore block is replaced by a direct symlink in the next
commit. No behavioral change here; pure cleanup."
```

---

## Task 3: Symlink `~/.claude.json` into the bind-mounted `~/.claude/`

Claude Code reads and writes `~/.claude.json` at home root, but only `~/.claude/` is bind-mounted. The previous design copied a backup back on startup, losing any writes between checkpoints. This task makes every write flow directly into the bind-mount via a symlink.

**Files:**
- Modify: `entrypoint.sh` (add a new `# ── 1. Claude state symlink` block right after `set -e`)

- [ ] **Step 3.1: Add the symlink block to `entrypoint.sh`**

Open `entrypoint.sh`. Right after `set -e` (line 2), insert:

```bash

# ── 1. Claude state symlink ───────────────────────────────────────
# Claude Code expects ~/.claude.json at the home root, but only
# ~/.claude/ is bind-mounted to the host. Symlinking the home-root
# file into the bind-mount makes every read/write persist directly,
# replacing the previous periodic-backup-and-restore mechanism.
ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"
```

Then bump the existing section numbers back up by one (if you didn't already renumber in Task 2):
- `# ── 1. Docker socket permissions` → `# ── 2. Docker socket permissions`
- `# ── 2. Auth status` → `# ── 3. Auth status`
- `# ── 3. Environment summary` → `# ── 4. Environment summary`
- `# ── 4. VS Code Server settings` → `# ── 5. VS Code Server settings`
- `# ── 5. Run command` → `# ── 6. Run command`

- [ ] **Step 3.2: shellcheck**

```bash
shellcheck entrypoint.sh
```
Expected: clean.

- [ ] **Step 3.3: Rebuild**

```bash
./run.sh --build
```
Expected: success.

- [ ] **Step 3.4: Verify the symlink is in place (Change 3 correctness check)**

```bash
mkdir -p /tmp/sandbox-symlink
./run.sh /tmp/sandbox-symlink --claude-dir /tmp/sandbox-symlink
```
Inside the container, run:
```bash
readlink ~/.claude.json
readlink -f ~/.claude.json
```
Expected:
- `readlink ~/.claude.json` prints `/home/coder/.claude/.claude.json`.
- `readlink -f ~/.claude.json` prints the resolved absolute path under `/home/coder/.claude/.claude.json` (the file may not exist yet — that's fine, the symlink is what matters).

- [ ] **Step 3.5: Atomic-rename gate (Change 3 risk verification)**

Still inside the container from Step 3.4, run:
```bash
claude
```
At the Claude prompt, make any change that causes a `.claude.json` write — e.g., type `/model` and pick a different model, or use `/memory` to add a memory. Then `/exit` Claude and `exit` the container.

On the host:
```bash
ls -la /tmp/sandbox-symlink/.claude.json
file /tmp/sandbox-symlink/.claude.json
```
Expected: the file exists on the host (proving the write went through the symlink into the bind-mount) and `file` reports a regular JSON file there.

Re-launch:
```bash
./run.sh /tmp/sandbox-symlink --claude-dir /tmp/sandbox-symlink
```
Inside the container:
```bash
readlink ~/.claude.json
```
Expected: still prints `/home/coder/.claude/.claude.json` — the symlink **survived** the write. If instead the symlink became a regular file (Claude used atomic-rename), the test fails: roll the commit, and switch to the file-bind-mount fallback per the spec's "Risk: atomic-rename writes" section (`touch "$CLAUDE_DIR/.claude.json"` in both launchers + an extra `-v "$CLAUDE_DIR/.claude.json:/home/coder/.claude.json"` flag, instead of the symlink).

Then verify the change persisted: launch `claude` again, confirm the model selection or memory you set in the previous session is still there. Exit.

- [ ] **Step 3.6: Commit**

```bash
git add entrypoint.sh
git commit -m "Symlink ~/.claude.json into the bind-mount

Claude Code writes ~/.claude.json at home root, but only ~/.claude/
is bind-mounted to the host. The symlink makes every write persist
atomically, replacing the previous periodic-backup-and-restore that
could lose writes between checkpoints on hard kills."
```

---

## Task 4: Default `--claude-dir` in `run.sh`

Make persistence the default. If `--claude-dir` isn't passed, default it to `$HOME/.ai-sandbox/<project-basename>/`.

**Files:**
- Modify: `run.sh:153-158` (the Claude-config-mount block)

- [ ] **Step 4.1: Edit `run.sh` to default `CLAUDE_DIR`**

Open `run.sh`. Replace the existing block at lines 153-158:

```bash
# Mount Claude config directory if provided
if [ -n "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd || echo "$CLAUDE_DIR")"
    mkdir -p "$CLAUDE_DIR"
    DOCKER_ARGS+=(-v "$CLAUDE_DIR:/home/coder/.claude")
fi
```

with:

```bash
# Default --claude-dir to a per-project state dir under $HOME so
# Claude credentials and session history persist across container
# restarts without requiring any explicit flag.
if [ -z "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$HOME/.ai-sandbox/$(basename "$PROJECT_PATH")"
fi
mkdir -p "$CLAUDE_DIR"
CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd)"
DOCKER_ARGS+=(-v "$CLAUDE_DIR:/home/coder/.claude")
```

Note the restructuring: the conditional `mkdir -p` + `cd` from the old block is now unconditional, since `CLAUDE_DIR` is always set after the default-assignment. The bind-mount is also unconditional now.

- [ ] **Step 4.2: shellcheck**

```bash
shellcheck run.sh
```
Expected: clean.

- [ ] **Step 4.3: Verify default path is created on host**

```bash
rm -rf "$HOME/.ai-sandbox/persist-test"   # clean slate
mkdir -p /tmp/persist-test
./run.sh /tmp/persist-test
# Inside the container, immediately Ctrl-D / exit.

ls -la "$HOME/.ai-sandbox/persist-test/"
```
Expected: the directory exists on the host (proving the default kicked in). It may be empty or may have `.credentials.json` etc. depending on whether you have auth state — the existence of the dir is what matters.

- [ ] **Step 4.4: Verify explicit override still works**

```bash
rm -rf /tmp/explicit-dir
./run.sh /tmp/persist-test --claude-dir /tmp/explicit-dir
# Ctrl-D / exit.
ls -la /tmp/explicit-dir
ls -la "$HOME/.ai-sandbox/persist-test/"
```
Expected: `/tmp/explicit-dir` exists (the override was honored); the default `$HOME/.ai-sandbox/persist-test/` is **not** modified by this run (mtime stays whatever it was from Step 4.3).

- [ ] **Step 4.5: Commit**

```bash
git add run.sh
git commit -m "Default --claude-dir to ~/.ai-sandbox/<project> in run.sh

Persistence is now on by default. Without --claude-dir, state lives
in a per-project dir under \$HOME so credentials and session history
survive container kills. Explicit --claude-dir <path> still overrides."
```

---

## Task 5: Default `--claude-dir` in `dev.sh`

Mirror Task 4 in the dev-mode launcher. Same logic, different array name.

**Files:**
- Modify: `dev.sh:178-184` (the Claude-config-mount block)

- [ ] **Step 5.1: Edit `dev.sh` to default `CLAUDE_DIR`**

Open `dev.sh`. Replace the existing block at lines 178-184:

```bash
# ── Claude config directory mount ─────────────────────────────────
CLAUDE_DIR_ARGS=()
if [ -n "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd || echo "$CLAUDE_DIR")"
    mkdir -p "$CLAUDE_DIR"
    CLAUDE_DIR_ARGS=(-v "$CLAUDE_DIR:/home/coder/.claude")
fi
```

with:

```bash
# ── Claude config directory mount ─────────────────────────────────
# Default to a per-project state dir under $HOME so Claude
# credentials and session history persist across container restarts
# without requiring any explicit flag.
if [ -z "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$HOME/.ai-sandbox/$(basename "$PROJECT_PATH")"
fi
mkdir -p "$CLAUDE_DIR"
CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd)"
CLAUDE_DIR_ARGS=(-v "$CLAUDE_DIR:/home/coder/.claude")
```

The `CLAUDE_DIR_ARGS` array remains (other call sites in `dev.sh` use it that way at line 196). It's just always populated now.

- [ ] **Step 5.2: shellcheck**

```bash
shellcheck dev.sh
```
Expected: clean.

- [ ] **Step 5.3: Verify default path in dev mode**

```bash
rm -rf "$HOME/.ai-sandbox/dev-persist-test"
mkdir -p /tmp/dev-persist-test
./dev.sh /tmp/dev-persist-test &
DEV_PID=$!
sleep 5
ls -la "$HOME/.ai-sandbox/dev-persist-test/"
./dev.sh --stop dev-persist-test
wait $DEV_PID 2>/dev/null || true
```
Expected: the directory exists on the host. If `./dev.sh --stop <basename>` isn't supported by the current `dev.sh`, substitute `docker rm -f ai-sandbox-dev-persist-test`.

- [ ] **Step 5.4: Commit**

```bash
git add dev.sh
git commit -m "Default --claude-dir to ~/.ai-sandbox/<project> in dev.sh

Mirror the run.sh default so VS Code attach mode gets the same
auto-persistence. Same explicit-override semantics."
```

---

## Task 6: Update `README.md`

Two factual statements become wrong with this change. Both are user-facing.

**Files:**
- Modify: `README.md:81` (the `--claude-dir` description paragraph)
- Modify: `README.md:115-122` (the "Ephemeral mode" section)
- Modify: `README.md:285-292` (the "Volume mounts" section)

- [ ] **Step 6.1: Rewrite the `--claude-dir` description**

Open `README.md`. Replace line 81:

```
Use `--claude-dir` to mount any host directory as `~/.claude` inside the container. This is where Claude stores credentials, settings, and session history. The entrypoint merges any `settings.json` found in the directory with container security hooks (hooks always take priority).
```

with:

```
Use `--claude-dir` to override the auto-default state directory. By default, persistence is on: state goes to `~/.ai-sandbox/<project-basename>/` on the host. Pass `--claude-dir <path>` to point it somewhere else (e.g., to share credentials across projects). The container never modifies `settings.json` inside this directory — its own enforcement settings live in a separate managed-settings file inside the image.
```

- [ ] **Step 6.2: Replace the "Ephemeral mode" section**

Replace lines 115-122:

```markdown
### Ephemeral mode

No `--claude-dir` — nothing persists. Log in every time.

```bash
./run.sh ~/myproject --claude
./dev.sh ~/myproject
```
```

with:

```markdown
### Auto-persist mode (default)

No flag needed — state lives in `~/.ai-sandbox/<project-basename>/` on your host. Log in once per project, session history and credentials persist across container restarts.

```bash
./run.sh ~/myproject --claude
./dev.sh ~/myproject
```

To wipe state for a single project: `rm -rf ~/.ai-sandbox/<project-basename>`.
```

- [ ] **Step 6.3: Update the Volume mounts table**

Replace lines 285-292:

```markdown
## Volume mounts

| Container path | Host source | When | Purpose |
|----------------|-------------|------|---------|
| `/home/coder/project` | Your project directory | Always | Working directory for code |
| `/home/coder/.claude` | `--claude-dir` path | `--claude-dir` used | Persistent config, credentials, session history |

The entrypoint merges any `settings.json` found in the mounted directory with container security hooks on every startup. Hooks always take priority and cannot be overridden.
```

with:

```markdown
## Volume mounts

| Container path | Host source | When | Purpose |
|----------------|-------------|------|---------|
| `/home/coder/project` | Your project directory | Always | Working directory for code |
| `/home/coder/.claude` | `--claude-dir` path (default: `~/.ai-sandbox/<project-basename>/`) | Always | Persistent config, credentials, session history |

Container-enforced settings (PreToolUse hooks, attribution-stripping) live inside the image at `/etc/claude-code/managed-settings.json` and take precedence over any user settings via Claude Code's native managed-settings layer. The container does not read or modify `settings.json` inside the bind-mounted `--claude-dir`.
```

- [ ] **Step 6.4: Verify docs read correctly**

Render or skim `README.md`. Confirm:
- The `--claude-dir` description (around line 81) reads coherently with the new persistence default.
- "Auto-persist mode" replaces "Ephemeral mode" cleanly.
- The Volume mounts table no longer claims a runtime settings-merge happens.

- [ ] **Step 6.5: Commit**

```bash
git add README.md
git commit -m "README: document auto-persist default and managed-settings layer

The 'Ephemeral mode' section described pre-change behavior. Auto-
persist is now the default; --claude-dir overrides the path.
Container-enforced settings move out of the runtime jq merge into
Claude Code's native managed-settings location."
```

---

## Task 7: Update `CLAUDE.md`

Three sections describe code that no longer exists. They're the load-bearing docs for future-Claude-working-on-this-repo, so accuracy matters.

**Files:**
- Modify: `CLAUDE.md:53-64` (the "Settings merge (the security-critical bit)" section)
- Modify: `CLAUDE.md:74-93` (the "Entrypoint responsibilities" section)

- [ ] **Step 7.1: Rewrite the "Settings merge" section**

Open `CLAUDE.md`. Replace the entire `### Settings merge (the security-critical bit)` section (lines 53 through line 64, ending with the closing of the merge-semantics paragraph that begins "The right operand wins…") with:

```markdown
### Managed settings (the security-critical bit)

`container-settings.json` is baked into the image at `/etc/claude-code/managed-settings.json` — Claude Code's native managed-settings location on Linux. The managed-settings layer sits at the top of Claude Code's settings precedence chain (managed > local > project > user), so the container's `PreToolUse` hooks and attribution-stripping config always win, with no runtime merge required.

Two consequences of using the native layer instead of a runtime `jq` merge:

1. **The container never reads or writes `settings.json` inside the bind-mounted `~/.claude/`.** A user-owned `settings.json` in `--claude-dir` is invisible to the container. This means it is safe to point `--claude-dir` at a host-shared Claude config directory; an earlier merge-and-write-back design would have corrupted that file with container-only hook paths.
2. **Container enforcement is structurally stronger than before.** It's applied by Claude Code's settings loader directly, not by an entrypoint script whose correctness depends on `jq` semantics and operand ordering. Any new top-level key added to `container-settings.json` automatically takes precedence over user config.

When extending the container's enforced policies, edit `container-settings.json` directly. Hook command paths inside that JSON still point at `/opt/ai-sandbox/hooks/...` since that's where `container-hooks/` is copied at build time (Dockerfile L125).
```

- [ ] **Step 7.2: Rewrite the "Entrypoint responsibilities" section**

Replace the entire `### Entrypoint responsibilities` section (lines 74 through the end of the volume-mounts paragraph at line 93) with:

```markdown
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

`--claude-dir` is the single mount point for all Claude state. With auto-persist defaults, no flag is required for state to survive container restarts.
```

- [ ] **Step 7.3: Verify the section sequencing is intact**

Open `CLAUDE.md` and check that after Step 7.2 the document still flows: the `## Conventions worth knowing` section that comes after Volume mounts in the original is still in place at the bottom.

- [ ] **Step 7.4: Commit**

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: describe managed-settings layer and new entrypoint flow

Rewrites the 'Settings merge' section to describe the managed-
settings location instead of the deleted jq merge, and the
'Entrypoint responsibilities' section to describe the slimmed-down
entrypoint (symlink + socket fix + VS Code settings, nothing else)."
```

---

## Task 8: Final sanity sweep

Run the spec's full testing matrix from scratch against the merged result.

**Files:** none modified in this task.

- [ ] **Step 8.1: shellcheck all shell sources**

```bash
shellcheck run.sh dev.sh entrypoint.sh container-hooks/*.sh container-hooks/git/*
```
Expected: clean across the board.

- [ ] **Step 8.2: Clean rebuild from scratch**

```bash
docker image rm ai-sandbox:latest 2>/dev/null || true
./run.sh --build
```
Expected: build succeeds. Re-verify image present: `docker image inspect ai-sandbox:latest >/dev/null && echo OK`.

- [ ] **Step 8.3: Run spec Testing items 3-9**

Walk through items 3, 4, 5, 6, 7, 8, 9 from the spec's `## Testing` section. Each maps to a Task you already verified individually; the point here is to run them in sequence against the *final* image to catch any cross-Task regression.

In order:
- **Spec test 3 (managed-settings enforcement):** repeat Step 1.4 and 1.5.
- **Spec test 4 (bind-mount integrity):** repeat Step 1.6.
- **Spec test 5 (default-path smoke):** repeat Step 4.3.
- **Spec test 6 (symlink correctness):** repeat Step 3.4.
- **Spec test 7 (atomic-rename gate):** repeat Step 3.5.
- **Spec test 8 (explicit override):** repeat Step 4.4.
- **Spec test 9 (host isolation preserved):** confirm that `ls -la ~/.claude/` mtimes are unchanged across an entire sandbox session — i.e., a `./run.sh /tmp/foo` run never touches host `~/.claude/` regardless of any other state.

Any failure: STOP, identify which Task introduced the regression (commit history is the bisect target), fix, re-run from Step 8.1.

- [ ] **Step 8.4: Quick visual diff of the branch vs `main`**

```bash
git log --oneline main..HEAD
git diff main --stat
```
Expected: 7 commits, one per Task. Stat should show changes confined to: `Dockerfile`, `entrypoint.sh`, `run.sh`, `dev.sh`, `README.md`, `CLAUDE.md`. No other files touched (other than `docs/superpowers/specs/...` and `docs/superpowers/plans/...` which the user will add separately if desired).

- [ ] **Step 8.5: Hand off**

Branch is ready for the user to review and (if they choose) merge or push themselves. Per the operating rules in the header, **do not run `git push` or `gh pr create`** — report completion and stop.

---

## Risk register

| Risk | Mitigation | Where addressed |
|------|------------|-----------------|
| Managed-settings doesn't honor `attribution` or `includeCoAuthoredBy` keys | Verified empirically before deleting the merge code; fallback is documented in Task 1 (write merge result to a container-only path, never the bind-mount) | Task 1.4 / 1.5 |
| Claude Code uses atomic-rename when writing `.claude.json`, breaking the symlink | Verified by manual rewrite test; documented fallback to a docker file-level bind-mount per spec's "Risk: atomic-rename writes" | Task 3.5 |
| Existing users have state in pre-change locations (`~/.ai-sandbox-api/`, `~/.ai-sandbox/auth/`) | Out of scope (spec: "Migration from older containers" is a non-goal). They keep working — `--claude-dir` still accepts those paths verbatim. | Spec non-goal |
| Per-project dir explodes in size over time | Acceptable — user controls cleanup via `rm -rf ~/.ai-sandbox/<project>` (documented in README Step 6.2) | Documented |
