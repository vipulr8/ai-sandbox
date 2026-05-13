# Claude state persistence — design

**Date:** 2026-05-13
**Status:** Approved, pending implementation plan

## Goal

Make Claude state persist across container kills without requiring any flag, while preserving the security guarantee that the container is fully isolated from the host's primary `~/.claude/`.

Today, three problems coexist:

1. **`--claude-dir` is required for persistence.** No flag = no state, log in every container start.
2. **`~/.claude.json` is outside the bind-mount.** Even with `--claude-dir`, this file lives at home root, gets restored from periodic backups on next start, and loses any writes between Claude's last backup checkpoint and a hard kill.
3. **The bind-mount gets silently corrupted on every start.** `entrypoint.sh:19-22` merges `container-settings.json` (which has `PreToolUse` hooks pointing at container-only `/opt/ai-sandbox/hooks/...` paths) into the user's `settings.json` and **writes the result back into the bind-mount**. If `--claude-dir` ever points at a host dir also used by host Claude (e.g., the user's `~/.claude` or a symlinked per-account config), the container rewrites that host file with paths that don't exist on the host — leaving host Claude trying to exec a nonexistent hook on every Bash call. The current `--claude-dir` defaults sidestep this only because users typically pass a container-only dir; the bug is one `--claude-dir ~/.claude` away.

After this change:

| Invocation | Persistence |
|------------|-------------|
| `./run.sh ~/myproject` | Full state persists in `~/.ai-sandbox/myproject/` |
| `./run.sh ~/myproject --claude-dir <X>` | Full state persists in `<X>`; `<X>/settings.json` is **never written to** by the container, safe to share with host |

## Non-goals

- **Sharing state with host `~/.claude/`.** Explicitly rejected. The container's whole premise is that AI tools are sandboxed away from host credentials and config; mounting host `~/.claude/` would void that guarantee (the container would gain read/write access to OAuth tokens for every project, the global project list in `.claude.json`, and full session history from outside the sandbox).
- **`docker-compose.yml` parity.** Compose users follow a separate, more advanced flow. Out of scope here; can be added later if asked for.
- **Full README rewrite of the API-key vs enterprise auth modes.** With auto-persistence, both modes collapse into "drop your settings.json in OR run `claude auth login`, both auto-persist" — but that's a broader docs cleanup unrelated to the code fix. We update only the parts of the README that become *factually incorrect* (see Documentation updates below).
- **Migration from older containers.** Treated as a new container; the existing backup-restore code path is removed, not preserved.

## Architecture

Three narrow changes, no new flags, no new abstractions. Each addresses one of the three problems above.

### Change 1: Move container-enforced policies to `/etc/claude-code/managed-settings.json`

Today `container-settings.json` is baked at `/opt/ai-sandbox/settings.json` and merged into `~/.claude/settings.json` on every container start. That merge is the source of problem 3 (writeback into the bind-mount).

Claude Code natively supports a **managed settings layer** at `/etc/claude-code/managed-settings.json` on Linux. It sits at the top of the settings precedence chain (managed > local > project > user) and is read independently — no runtime merge required. Verified at `code.claude.com/docs/en/settings`:

> Managed (highest) — can't be overridden by anything

Hooks and the attribution/`includeCoAuthoredBy` keys we currently set are all valid in managed scope.

**Concretely:**

- `Dockerfile` L127: change `COPY container-settings.json /opt/ai-sandbox/settings.json` to `COPY container-settings.json /etc/claude-code/managed-settings.json` (and `mkdir -p /etc/claude-code` first). The hook-script copy at L125 (`/opt/ai-sandbox/hooks/`) is unchanged; only the JSON moves. The `PreToolUse` hook command path inside the JSON also stays as `/opt/ai-sandbox/hooks/block-remote-publishing.sh`.
- `entrypoint.sh` L8–29 (the entire settings-merge block — `mkdir ~/.claude`, `USER_SETTINGS` detection, `jq -s '.[0] * .[1]'`, the fallback cp): **deleted in full**. User's `settings.json` in the bind-mount is never read or written by the container.
- Container-enforced policies still always win — managed-settings precedence guarantees this without code.

**Verification gate for this change:** before deleting the merge block, build the image with the JSON at `/etc/claude-code/managed-settings.json` and confirm that (a) the `PreToolUse` hook still blocks `git push` from inside the container, and (b) the `attribution`/`includeCoAuthoredBy` settings still take effect (commit a test commit and confirm no `Co-Authored-By: Claude` trailer). If either fails — e.g., some setting key turns out not to be honored in managed scope — fall back to keeping a much smaller entrypoint merge for just that key, but **write the merged result to a container-only path** (e.g., `/tmp/claude-merged-settings.json`) and never touch `$HOME/.claude/settings.json`. This preserves the bind-mount-write fix even in the fallback.

### Change 2: Default per-project state dir

`run.sh` and `dev.sh` already accept `--claude-dir <path>`. If absent, both now default it to:

```
$HOME/.ai-sandbox/$(basename "$PROJECT_PATH")
```

`mkdir -p` on the host before the docker invocation. The existing `-v "$CLAUDE_DIR:/home/coder/.claude"` line is unchanged.

Why per-project (not a single shared dir): Claude Code keys per-project state by the *container* path (`/home/coder/project`), which is identical across every container we launch. A single shared dir would therefore mix session histories from unrelated projects into one project bucket. Per-project dirs avoid that collision.

Power users keep `--claude-dir <path>` as an explicit override (e.g., to share auth across projects, or pin to a specific filesystem location). After Change 1, pointing `--claude-dir` at a host-shared dir is safe — the container will not modify `settings.json` inside it.

### Change 3: Symlink `.claude.json` into the bind mount

`entrypoint.sh` adds one line where the deleted merge block used to live:

```sh
ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"
```

Claude Code opens `~/.claude.json` at home root. With the symlink in place, every read and write flows into `~/.claude/.claude.json` — which is the bind-mounted dir, persisted on the host.

The previous backup-restore block (`entrypoint.sh:31-40`) is **deleted**. The legacy `/tmp/user-settings.json` fallback is gone too — it was part of the merge block, which is deleted wholesale by Change 1.

### Risk: atomic-rename writes

The symlink approach works as long as Claude Code writes `~/.claude.json` directly (`open(O_WRONLY|O_CREAT|O_TRUNC) → write → close`). It breaks silently if Claude uses an atomic-rename pattern (write to `~/.claude.json.tmp`, then `rename()` over `~/.claude.json`) — `rename` would replace the symlink with a regular file in container-only home, and persistence would be lost without any error.

**Verification gate (first step of implementation):** strace or just observe behavior in a running container by modifying `.claude.json` via Claude and inspecting whether the symlink survives on the next container start. If it survives, ship as designed. If it doesn't, fall back to a docker file-level bind-mount: `touch "$CLAUDE_DIR/.claude.json"` in the launchers, plus `-v "$CLAUDE_DIR/.claude.json:/home/coder/.claude.json"`. The fallback is 4 lines per launcher and zero entrypoint changes; it's the safer Plan B but adds maintenance surface, so we prefer the symlink if it works.

## File changes summary

| File | Change | Lines |
|------|--------|-------|
| `Dockerfile` | Change destination of `COPY container-settings.json` from `/opt/ai-sandbox/settings.json` to `/etc/claude-code/managed-settings.json` (with `mkdir -p` for the dir) | ~2 |
| `run.sh` | Default `$CLAUDE_DIR` if unset; `mkdir -p` before docker invocation | ~5 |
| `dev.sh` | Same default logic, mirror `run.sh` | ~5 |
| `entrypoint.sh` | Delete the entire settings-merge block (L8-29); delete the backup-restore block (L31-40); add one `ln -sf` line for `.claude.json` | net −31, +1 |
| `README.md` | Rewrite "Ephemeral mode" → "Auto-persist mode"; note default path in volume mounts table; note that `settings.json` in `--claude-dir` is now user-owned and never modified by the container | ~12 |
| `CLAUDE.md` | Rewrite "Settings merge" section: no runtime merge — managed-settings layer enforces policies; user settings in bind-mount are untouched. Remove backup-restore and `/tmp/user-settings.json` references. Add symlink note. | ~15 |

No new files. No flag changes. No docker-compose changes. The security surface is **strengthened** (one new class of bug — bind-mount writeback — eliminated; managed-settings enforcement is structurally stronger than runtime merge).

## Documentation updates

Three places carry factual claims that this change invalidates and that must be corrected in the same commit:

| File | Current statement | Required edit |
|------|-------------------|---------------|
| `README.md` — "Ephemeral mode" section | "No `--claude-dir` — nothing persists. Log in every time." | Rewrite as "Auto-persist mode (default): state lives in `~/.ai-sandbox/<project>/`. Pass `--claude-dir <path>` to override." |
| `README.md` — Volume mounts table | `--claude-dir` listed as optional with no default | Note the auto-default path and that the container never writes to `settings.json` inside it. |
| `CLAUDE.md` — "Settings merge (the security-critical bit)" section | Describes runtime `jq -s` merge with right-operand-wins semantics, baked-in `/opt/ai-sandbox/settings.json` | Rewrite: container-enforced policies live in `/etc/claude-code/managed-settings.json` (managed-settings precedence, no merge). User `settings.json` in the bind-mount is read-only from the container's perspective. Remove the merge-semantics paragraph. |
| `CLAUDE.md` — entrypoint responsibilities section | References `/tmp/user-settings.json` legacy fallback and "restore from largest backup" and the settings merge step | Remove all three — describe the new responsibilities only: socket-group fix, VS Code Server settings write, `.claude.json` symlink. |

No other docs touched. The "API key mode" / "Enterprise / OAuth mode" sections in the README continue to work as written (their `--claude-dir <path>` examples remain valid).

## Testing

No test suite exists; verification is empirical, identical to the existing pattern:

1. **`shellcheck`** clean on `run.sh`, `dev.sh`, `entrypoint.sh` (run via the container image, per `CLAUDE.md`).
2. **Rebuild:** `./run.sh --build` succeeds.
3. **Managed-settings enforcement (Change 1 gate):** Inside a freshly built container, run `git push origin main` (after staging a fake commit). The container `PreToolUse` hook must still deny it via the managed-settings layer. Then run `git commit --allow-empty -m "test"` and inspect the resulting commit — no `Co-Authored-By: Claude` trailer (attribution still enforced). If either check fails, see Change 1 fallback.
4. **Bind-mount integrity (Change 1 gate):** `./run.sh /tmp/persist-test --claude-dir /tmp/shared-claude` after pre-seeding `/tmp/shared-claude/settings.json` with arbitrary user content. After container start AND after container exit, the file's contents and mtime are unchanged. **This is the test that proves the bug is fixed.**
5. **Default-path smoke (Change 2):** `./run.sh /tmp/persist-test` (after `mkdir -p /tmp/persist-test`). Confirm `~/.ai-sandbox/persist-test/` is created on host; auth/credentials land inside on next `claude` invocation.
6. **Symlink correctness (Change 3):** Inside the container, `readlink -f ~/.claude.json` resolves to `/home/coder/.claude/.claude.json`.
7. **Atomic-rename check (Change 3 gate):** Modify `.claude.json` from inside Claude (e.g., create a todo, change a project setting). Exit container. Re-launch. Confirm change persisted AND `readlink ~/.claude.json` is still a symlink. If both hold, design ships. If symlink became a regular file, switch to file-bind-mount fallback (see Change 3 Risk).
8. **Explicit override still works:** `./run.sh ~/myproject --claude-dir /tmp/explicit-dir` mounts `/tmp/explicit-dir`, ignores the auto-default.
9. **Host isolation preserved:** Host `~/.claude/` is untouched after any container run (verify via `ls -la ~/.claude/` mtimes).

## Security

This change strengthens the sandbox's default posture without weakening any control:

- The auto-default dir (`~/.ai-sandbox/<project>/`) lives **outside** the user's primary `~/.claude/`. The container never reads from or writes to the user's host Claude state.
- Container `PreToolUse` hooks and attribution/`includeCoAuthoredBy` enforcement still always win — managed-settings sits above all other scopes in Claude Code's native precedence chain, so the "container wins on conflicts" guarantee is **stronger** than before (enforced by the client's settings loader instead of by a runtime jq merge that could be bypassed if entrypoint logic broke).
- The bind-mount writeback bug (problem 3 in Goal) is eliminated: the container no longer reads or writes the user's `settings.json` inside `--claude-dir`. Sharing `--claude-dir` with a host-side Claude config is now safe.
- Per-project isolation is now the default rather than opt-in — sessions and credentials for project A are inaccessible to a container running project B.

The only new attack surface is the new dir itself, which inherits the same permissions model as any other dotfile in `$HOME` (user-only, 0700 by default for new dirs Claude creates).
