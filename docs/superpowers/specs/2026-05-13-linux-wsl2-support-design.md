# Linux + Windows-via-WSL2 support — design

**Date:** 2026-05-13
**Status:** Pending implementation plan; gated on external Linux verification before merge.

## Goal

Officially support running ai-sandbox on Linux hosts and on Windows hosts via WSL2, alongside the existing macOS support. The change is mostly documentation: the code already accommodates non-macOS hosts thanks to the dynamic `USER_UID` build arg, so most of the work is removing inaccurate "macOS only" claims and giving Linux/WSL2 users a setup path.

The work lands on a feature branch (`feat/linux-wsl2-support`) and does **not merge to main** until an external tester running real Linux confirms the verification runbook passes. The repo's primary developer doesn't have a Linux host, so we cannot self-verify; the branch is the artifact handed to the tester.

## Non-goals

- **Native Windows support (PowerShell launchers).** Out of scope. Windows users get supported via WSL2, which IS Linux from Docker's perspective. Native-Windows-no-WSL would require rewriting `run.sh`/`dev.sh` in PowerShell and is a separate, larger project.
- **Distributable prebuilt images with arbitrary-UID support.** The image is still locally-built; `--build-arg USER_UID=$(id -u)` makes the container user match the host user. Linux hosts that build locally inherit this. Pulling a prebuilt image and using it as a different host UID is explicitly out of scope (matches the existing macOS-only policy on this question).
- **Rootless Docker, Podman, or other container runtimes.** Standard Docker Engine (on Linux and inside WSL2) and Colima or Docker Desktop (on macOS) are the targets. Podman would likely work since the launchers only use generic Docker CLI commands, but it's not verified and not part of the runbook.
- **CI for cross-platform.** No automated test matrix; verification is human-driven via the runbook in this spec.
- **`docker-compose.yml` cross-platform polish.** Compose works fine on Linux/WSL2 already; not in scope here.

## Architecture

Three categories of change, each modest.

### (a) Documentation updates

Remove the "macOS only" framing wherever it appears and replace it with a multi-platform support matrix. New setup pages for Linux and Windows + WSL2 parallel the existing Colima page.

**`README.md`:**
- Replace the "Supported platform: macOS only" callout (around line 5) with a support matrix that names the **OSS-friendly runtime** as the primary option on each host:
  ```
  | Host OS | Status | Recommended runtime (OSS) | Alternative |
  |---------|--------|---------------------------|-------------|
  | macOS   | ✓ verified | Colima | Docker Desktop |
  | Linux   | ✓ verified | Docker Engine | Docker Desktop |
  | Windows | ✓ via WSL2 | Docker Engine inside WSL2 | Docker Desktop (WSL2 backend) |
  ```
  The matrix lists the open-source runtime first on every host to match the project's existing posture (Colima leads on macOS already). Docker Desktop is the second column on every row because it carries a commercial-use license for orgs >250 employees or >$10M revenue, which is friction the OSS path avoids.
- Generalize "Prerequisites" to enumerate per-platform install steps. Keep the Colima section under a "macOS setup" heading. Add parallel "Linux setup" and "Windows + WSL2 setup" sections after it.
- **Linux setup page (OSS path primary):** install Docker Engine via the official Docker repos for the user's distro (Debian/Ubuntu: `https://docs.docker.com/engine/install/ubuntu/`; Fedora: `.../install/fedora/`; etc.). Add the user to the `docker` group (`sudo usermod -aG docker $USER` + new shell). Verify with `docker run hello-world`. No UID workarounds needed — `--build-arg USER_UID=$(id -u)` handles it. A short "or use Docker Desktop" note at the end of the section, with the same commercial-license disclaimer.
- **Windows + WSL2 setup page (OSS path primary):** install WSL2 with `wsl --install` from an elevated PowerShell; install a Linux distro (Ubuntu default). Inside the WSL2 shell, install **Docker Engine** the same way as on bare Linux. Start the daemon (`sudo service docker start`, or use systemd-in-WSL2 which is default in modern WSL versions). Install the VS Code **WSL** extension on Windows. **Clone the ai-sandbox repo INSIDE the WSL filesystem** (e.g., `~/code/ai-sandbox`, NOT `/mnt/c/...`) for performance and bind-mount UID consistency. From there, follow the Linux setup steps. A short "or use Docker Desktop with WSL2 backend" alternative note at the end, again flagging the commercial-license consideration.

**`CLAUDE.md`:**
- Rewrite the "Scope: macOS hosts only" paragraph (line 29). New text describes how `--build-arg USER_UID=$(id -u)` solves the host/container UID matching problem on any Unix-like host, not just macOS — so Linux works by the same mechanism, and WSL2 inherits it because WSL2 is Linux. Note the macOS-specific bonus that Docker Desktop / Colima additionally do user-namespace remapping (which is what makes Mac work even if someone bakes a foreign UID into the image), but the build-arg approach is the primary mechanism that makes all three hosts work today.
- Add a short subsection or paragraph noting the WSL2 performance gotcha: project paths should live inside the WSL filesystem (`/home/user/proj`), not Windows-mounted paths (`/mnt/c/Users/...`), because the latter has slow filesystem performance and inconsistent bind-mount UID semantics.

### (b) Code touches

Two cosmetic touches, no behavioral changes.

**`run.sh:96` and `dev.sh:172`:** the Colima socket-path probe (`$HOME/.colima/default/docker.sock`) is harmless on Linux/WSL2 (the path simply doesn't exist; the next branch in the `elif` chain hits `/var/run/docker.sock`). Add a one-line comment immediately before each probe — e.g., `# macOS Colima fallback (no-op on Linux/WSL2)` — so a future maintainer reading the file doesn't wonder why we're checking a Mac-specific path on what's now a cross-platform project.

No other code changes. The launchers, entrypoint, Dockerfile, hooks, and managed-settings logic are already platform-agnostic at the bash level.

### (c) Verification runbook (new file, branch-only)

A markdown file at `docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md` documents the gate sequence the external tester runs. Each gate has a literal command and an explicit success condition. The runbook is **kept on the feature branch only** — stripped at merge time, since it's a one-time artifact, not load-bearing documentation. (Its history lives in the merge commit anyway.)

Eight gates:

1. **Build** — `./run.sh --build` succeeds; final line `Built ai-sandbox:latest successfully.`
2. **Default-persist project** — `./run.sh ~/test-sandbox` creates `~/.ai-sandbox/test-sandbox/` on host, drops user into zsh in container, clean `exit`.
3. **Symlink correctness** — inside container, `readlink ~/.claude.json` prints `/home/coder/.claude/.claude.json`.
4. **Baked plugin loads** — inside container, `claude` → `/superpowers:brainstorming` slash command activates.
5. **Plugin coexistence** — inside container, `/plugin install commit-commands@claude-plugins-official` then `/plugin list` shows both; restart container with same project path, both still present.
6. **AI git push blocked** — inside container, ask Claude to `git push origin main`; managed-settings `PreToolUse` hook denies with the expected message.
7. **`dev.sh` launches + VS Code attach** — `./dev.sh ~/test-sandbox` opens a VS Code window attached to the container; terminal in VS Code spawns a zsh inside the container; the post-attach Claude Code extension install completes (`/tmp/install-claude-ext.log` inside container shows success).
8. **`dev.sh` management commands** — `./dev.sh --list`, `./dev.sh --stop test-sandbox`, `./dev.sh --stop-all` all return without error.

The runbook also includes a **WSL2 prerequisite** section before Gate 7 documenting the `code` CLI bridge from WSL → Windows VS Code (install the VS Code WSL extension; run `code .` from inside WSL once to register the interop; only then attempt Gate 7). If Gate 7 fails despite this prep, that's a tester-environment problem, not an ai-sandbox bug — flagged in a troubleshooting subsection.

## File changes summary

| File | Change | Size |
|------|--------|------|
| `README.md` | Replace macOS-only callout with support matrix; restructure Prerequisites; add Linux setup + Windows-WSL2 setup sections parallel to Colima setup | ~80 lines net |
| `CLAUDE.md` | Rewrite "Scope: macOS hosts only" paragraph; add WSL2 path note | ~15 lines net |
| `run.sh` | One-line comment before Colima probe at line 96 | +1 line |
| `dev.sh` | One-line comment before Colima probe at line 172 | +1 line |
| `docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md` | New file: 8-gate verification runbook for the external tester | ~120 lines |
| `docs/superpowers/specs/2026-05-13-linux-wsl2-support-design.md` | This spec | (already committed) |
| `docs/superpowers/plans/2026-05-13-linux-wsl2-support.md` | Implementation plan (next step after this spec is approved) | tbd |

No deletions. No security surface changes. No new build dependencies.

## Verification handoff lifecycle

```
You finish branch
       │
       ▼
Branch lives on origin (push to feat/linux-wsl2-support)
       │
       ▼
Hand to Linux tester: branch URL + path to the runbook file
       │
       ▼
Tester runs the 8 gates, reports back each as PASS / FAIL + output
       │
   ┌───┴───┐
   ▼       ▼
 All PASS  Any FAIL
   │       │
   ▼       ▼
Merge     Iterate on branch (fix issue, re-test)
to main         │
   │            └──► (back to tester)
   ▼
Update README support matrix from "via WSL2" annotation to "verified"
Drop the runbook file from main (its content is in the merge commit history)
```

**Branch staleness:** if main moves while waiting for verification, rebase the branch. The doc surfaces (`README.md`, `CLAUDE.md`) are low-conflict; new files under `docs/superpowers/specs/` are zero-conflict.

**If verification reveals a real bug** (e.g., the launchers silently break on a Linux UID mismatch we missed), the fix lands on the branch and the runbook re-runs. No special handling needed.

## Risks

| Risk | Mitigation |
|------|------------|
| The dynamic `USER_UID` build arg works on macOS by accident (UID translation papers over it) and we discover Linux exposes a real issue at runtime | The runbook explicitly tests with a Linux user whose UID is not 1000 in Gate 2 (project state dir creation requires writes inside `~/.ai-sandbox/`, which the container user must own correctly). If this fails, the spec's UID claim is wrong and we'd need a runtime-UID-remap approach (out of current scope). |
| WSL2 specifically has bind-mount UID quirks we don't anticipate | Gate 2 in a WSL2 distro will catch it. Documented troubleshooting steps for known WSL2 gotchas (Windows path vs WSL path, Docker Desktop WSL backend settings) live in the runbook. |
| External tester is slow to respond or vanishes | Branch sits parked. No blocker for main work. Re-recruit. Re-rebase if needed. |
| Claude Code's plugin system behaves differently on Linux | Gates 4 and 5 verify it. Plugins are file-tree-based (skills/, commands/), which is OS-neutral; should "just work". |
| VS Code attach via `dev.sh` doesn't work on WSL2 because the user's VS Code is on Windows but Docker is in the WSL VM | Pre-checked in the WSL2 prerequisite section. If the user has set up the VS Code WSL extension correctly and run `code .` from inside WSL once, the `code --folder-uri vscode-remote://...` invocation in `dev.sh` bridges correctly. |

## Documentation tone

Avoid claiming Linux/WSL2 support in the merged main README **until verification passes**. While on the branch, the support matrix lists Linux and Windows as `✓ via WSL2` to signal intent; the merge commit flips the annotation to `✓ verified`. This keeps the public-facing claim honest at every point in time.

## Security

No changes. The managed-settings architecture, PreToolUse hooks, container isolation, and credential handling are all platform-independent (they live inside the container, which is the same Linux container on any host).
