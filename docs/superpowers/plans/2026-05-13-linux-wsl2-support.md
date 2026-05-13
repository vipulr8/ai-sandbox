# Linux + Windows-via-WSL2 support implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update docs to claim Linux + WSL2 support (with the existing code accommodating both via the dynamic `USER_UID` build arg), add OSS-first setup pages for Linux and Windows-via-WSL2, and produce a verification runbook for an external Linux tester to exercise before the branch is merged.

**Architecture:** Documentation-first change. The launchers, entrypoint, Dockerfile, and managed-settings layer are already platform-agnostic; the macOS-only framing in `README.md` and `CLAUDE.md` is the main constraint to remove. A new verification runbook (kept on this branch only, not merged) gives the external tester a literal command-by-command checklist.

**Tech Stack:** Markdown, Bash. No new code. shellcheck still the only linter.

**Operating rules (carry through every commit):**
- Branch: `feat/linux-wsl2-support` (already created, spec already committed).
- **No git push, no `gh pr create`** — local commits only.
- **No Claude attribution in commit messages.** No `Co-Authored-By: Claude` trailer; no "Generated with Claude" footer.
- The branch stays **unmerged** at the end of this plan. Final task hands off to an external Linux tester via a clearly-scoped runbook; merge happens only after the tester confirms all 8 gates pass.

---

## Task 1: Update `README.md`

Replace the macOS-only framing with a multi-platform support matrix, restructure the Prerequisites and setup sections, and add OSS-first Linux + WSL2 setup pages.

**Files:**
- Modify: `README.md` (callout near line 5, Prerequisites near line 36, Colima section near line 43)

- [ ] **Step 1.1: Replace the macOS-only callout**

In `README.md`, find the existing callout near line 5 that reads:

```
> **Supported platform: macOS only.** The image bakes UID 1000 at build time and relies on Docker Desktop / Colima translating UIDs across the bind-mount boundary. On Linux hosts with UID ≠ 1000, files written into bind-mounted directories will appear owned by 1000 on the host. Linux support is intentionally out of scope.
```

Replace it with this support matrix:

```markdown
> **Supported hosts:** macOS, Linux, and Windows (via WSL2). The image's container user is matched to your host UID at build time (`--build-arg USER_UID=$(id -u)`), so bind-mounts behave correctly on any Unix-like host.
>
> | Host OS | Status | Recommended runtime (OSS) | Alternative |
> |---------|--------|---------------------------|-------------|
> | macOS   | ✓ verified | Colima | Docker Desktop |
> | Linux   | ✓ via WSL2 | Docker Engine | Docker Desktop |
> | Windows | ✓ via WSL2 | Docker Engine inside WSL2 | Docker Desktop (WSL2 backend) |
>
> The Linux row uses "via WSL2" pending external verification on a native Linux host. Once a Linux tester confirms the setup runbook passes, this will become "verified". Docker Desktop is listed as the second option on every row because it carries a commercial-use license tier for organizations >250 employees or >$10M revenue.
```

- [ ] **Step 1.2: Restructure the Prerequisites section**

Find the existing Prerequisites section (around line 36). It currently reads:

```markdown
## Prerequisites

- macOS host
- A container runtime (e.g., [Colima](https://github.com/abiosoft/colima) or Docker Desktop)
- Docker CLI (`brew install docker` on macOS)
- docker-buildx plugin (`brew install docker-buildx` on macOS)
```

Replace the entire section with:

```markdown
## Prerequisites

- A supported host (macOS, Linux, or Windows with WSL2)
- A Docker runtime per the matrix above
- The `docker` CLI and `docker-buildx` plugin (bundled with most installs; if not, see your runtime's docs)
- For VS Code attach mode (`dev.sh`), Microsoft Visual Studio Code with the appropriate remote extension installed (see per-platform setup below)
```

- [ ] **Step 1.3: Rename "Colima setup" to "macOS setup"**

Find the line `## Colima setup` (around line 43) and change it to:

```markdown
## macOS setup
```

The body of that section (about Colima install + sizing) stays unchanged.

- [ ] **Step 1.4: Add "Linux setup" section after the macOS setup section**

Insert the following block immediately after the end of the macOS setup section (i.e., right before whatever next `##` heading currently follows it):

```markdown
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
```

- [ ] **Step 1.5: Add "Windows + WSL2 setup" section after the Linux setup section**

Immediately after the Linux setup section, add:

```markdown
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
```

- [ ] **Step 1.6: Verify no stale "macOS only" references remain**

Run:
```bash
grep -ni "macos only\|macos host\|linux support is intentionally" README.md
```
Expected: no output (all stale claims replaced).

```bash
grep -n "^## " README.md
```
Expected: the `##`-level sections appear in this order:
- (whatever precedes it)
- `## What's inside` (or similar) — pre-existing
- `## Prerequisites`
- `## macOS setup`
- `## Linux setup`
- `## Windows + WSL2 setup`
- (whatever follows — likely `## Quickstart` or similar)

- [ ] **Step 1.7: Commit**

```bash
git add README.md
git status   # confirm only README.md staged
git commit -m "$(cat <<'EOF'
README: document Linux + Windows-via-WSL2 support, OSS-first setup

Replaces the macOS-only callout with a multi-platform support matrix
that leads with the open-source runtime on every host (Colima on
Mac, Docker Engine on Linux, Docker Engine inside WSL2 on Windows).
Adds parallel macOS / Linux / Windows-WSL2 setup sections covering
runtime install, user-group setup, VS Code extension prerequisites,
and the WSL2 'clone inside WSL filesystem' gotcha.

Linux row is marked 'via WSL2' as a placeholder until external
verification confirms the runbook gates pass on a native Linux host.
EOF
)"
```

Verify with `git log -1 --format='%B'` that the commit has no Claude attribution.

---

## Task 2: Update `CLAUDE.md`

Rewrite the "Scope: macOS hosts only" paragraph to reflect cross-platform support, and add a WSL2 path note.

**Files:**
- Modify: `CLAUDE.md` (the "Scope:" paragraph at line 29 and the "Conventions worth knowing" UID bullet near line 111)

- [ ] **Step 2.1: Replace the "Scope" paragraph**

Find the paragraph in `CLAUDE.md` (around line 29) that reads:

```
**Scope: macOS hosts only.** The image bakes UID 1000 at build time and there is no runtime UID adaptation. Docker Desktop and Colima translate UIDs across the bind-mount boundary on macOS, so this is invisible there. On Linux hosts with UID ≠ 1000, bind-mounted files would end up owned by 1000 — that case is intentionally out of scope.
```

Replace it with:

```markdown
**Scope: macOS, Linux, and Windows (via WSL2).** The container user `coder` is created at build time with UID/GID matching the host user, via `--build-arg USER_UID=$(id -u)` in `run.sh` and `dev.sh`. This means bind-mounts behave correctly regardless of host UID on any Unix-like host. macOS Docker Desktop / Colima additionally do user-namespace remapping (so a Mac would still work even if someone baked a foreign UID into the image), but the build-arg approach is the primary mechanism — and it's what makes Linux and WSL2 work too, with no extra magic. Native Windows (PowerShell launchers, no WSL2) is explicitly out of scope; Windows users go through WSL2.

**WSL2 note:** project paths and the ai-sandbox repo itself should live inside the WSL filesystem (e.g., `/home/user/code/proj`), not under Windows-mounted paths like `/mnt/c/...`. The latter has slow filesystem performance and inconsistent bind-mount UID semantics across the Windows/WSL boundary.
```

- [ ] **Step 2.2: Update the UID bullet in "Conventions worth knowing"**

Find the bullet near line 111 that reads:

```
- The container user `coder` is hardcoded to UID/GID 1000 at image build time. There is no runtime adaptation. `run.sh` and `dev.sh` pass `--build-arg USER_UID=$(id -u)` so the locally-built image matches the host user. macOS Docker Desktop / Colima translate UIDs across the bind-mount boundary, which is why this is fine on the supported platform.
```

Replace it with:

```markdown
- The container user `coder` is created at build time with UID/GID matching the host user via `--build-arg USER_UID=$(id -u)` passed by `run.sh` and `dev.sh`. There is no runtime UID adaptation; if you pull a prebuilt image (we don't distribute any) instead of building locally, you'd see UID-ownership mismatches on Linux/WSL2 where the macOS user-namespace-remap trick doesn't paper over them.
```

- [ ] **Step 2.3: Verify**

```bash
grep -ni "macos hosts only\|hardcoded to UID/GID 1000" CLAUDE.md
```
Expected: no output (both stale claims gone).

```bash
grep -ni "Linux and Windows (via WSL2)\|WSL2 note" CLAUDE.md
```
Expected: at least two matches (the new framings).

- [ ] **Step 2.4: Commit**

```bash
git add CLAUDE.md
git status   # confirm only CLAUDE.md staged
git commit -m "$(cat <<'EOF'
CLAUDE.md: describe cross-platform support and WSL2 path gotcha

Updates the 'Scope' paragraph to reflect that --build-arg USER_UID
is what makes bind-mounts work on every supported host (not the
macOS-only user-namespace remap). Updates the 'Conventions worth
knowing' bullet about the container user with the same framing.
Adds a WSL2 note about keeping project paths inside the WSL
filesystem.
EOF
)"
```

Verify no Claude attribution.

---

## Task 3: Add explanatory comments to the Colima socket probes

Cosmetic touches in `run.sh` and `dev.sh` so a future maintainer reading the file doesn't wonder why a cross-platform project checks a Mac-specific Colima path.

**Files:**
- Modify: `run.sh:96` (line of the `$HOME/.colima/default/docker.sock` probe)
- Modify: `dev.sh:172` (same probe)

- [ ] **Step 3.1: Add comment in `run.sh`**

Open `run.sh`. Find the line (around 96):

```bash
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
```

Add a comment line immediately ABOVE it (preserving indentation), so the block reads:

```bash
    # macOS Colima fallback (no-op on Linux/WSL2 — the path doesn't exist)
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
```

- [ ] **Step 3.2: Add the same comment in `dev.sh`**

Open `dev.sh`. Find the line (around 172):

```bash
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
```

Add the same comment immediately ABOVE it:

```bash
    # macOS Colima fallback (no-op on Linux/WSL2 — the path doesn't exist)
    elif [ -S "$HOME/.colima/default/docker.sock" ]; then
```

- [ ] **Step 3.3: shellcheck**

```bash
shellcheck run.sh dev.sh 2>&1 | grep -v "SC1091" | grep -vE "^For more information:|shellcheck.net|^$" || echo "shellcheck clean (only pre-existing SC1091 .env notes filtered)"
```
Expected: clean (only pre-existing SC1091 info notes about `.env`).

- [ ] **Step 3.4: Commit**

```bash
git add run.sh dev.sh
git status   # confirm only run.sh and dev.sh staged
git commit -m "$(cat <<'EOF'
run.sh, dev.sh: note Colima probe is macOS-specific

The $HOME/.colima/default/docker.sock probe is harmless on Linux
and WSL2 (the path simply doesn't exist, and the next elif catches
/var/run/docker.sock), but a one-line comment makes the intent
obvious to a future maintainer reading the script on a Linux box.

No behavioral change.
EOF
)"
```

Verify no Claude attribution.

---

## Task 4: Write the verification runbook

A new file at `docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md` that an external Linux tester executes. Stays on the branch only — stripped at merge time.

**Files:**
- Create: `docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md`

- [ ] **Step 4.1: Write the runbook file**

Create the file with this exact content:

```markdown
# Linux + WSL2 verification runbook

This file lives on the `feat/linux-wsl2-support` branch only and is stripped before merge to `main`. Its purpose is to give an external tester running real Linux (or WSL2) a literal command-by-command checklist for verifying that ai-sandbox works as documented on their platform.

## Before you start

- You need a Linux host (any modern distribution) OR a Windows host with WSL2 + an Ubuntu distribution.
- Install Docker Engine per the README's Linux setup or Windows + WSL2 setup section.
- For WSL2: you must have installed the VS Code WSL extension AND run `code .` from inside the WSL shell at least once.
- Check out this branch: `git checkout feat/linux-wsl2-support`.

## How to report results

For each gate below, run the listed command(s) and either:

- `PASS` — the success condition was met. Just say "Gate N: PASS".
- `FAIL` — paste the full command output and any error message.

You can report inline, in a GitHub issue, in a chat message — whatever is easiest. The format we care about is:

```
Gate 1: PASS
Gate 2: PASS
Gate 3: FAIL
  Command: <command>
  Output: <full output verbatim>
...
```

---

## Gate 1: Image builds successfully

```bash
./run.sh --build
```

**Expected:** the final line of output is `Built ai-sandbox:latest successfully.` and the exit code is 0.

---

## Gate 2: Default-persist project launches

```bash
mkdir -p ~/test-sandbox
./run.sh ~/test-sandbox
```

**Expected:**
- A directory `~/.ai-sandbox/test-sandbox/` is created on the host (the default state dir).
- The container drops you into a `zsh` prompt with hostname `ai-sandbox` and working directory `/home/coder/project`.
- A banner shows the bundled tooling versions (Node, Python, Go, Rust, Claude, Gitleaks).

Inside the container, run `exit` to clean up. The container is `--rm` so it disappears.

Then on the host:

```bash
ls -la ~/.ai-sandbox/test-sandbox/
```

**Expected:** the directory exists and is owned by you (not root, not UID 1000 unless your host UID is 1000).

---

## Gate 3: Symlink correctness

```bash
./run.sh ~/test-sandbox
```

Inside the container:

```bash
readlink ~/.claude.json
```

**Expected output:** `/home/coder/.claude/.claude.json`

Type `exit` to leave.

---

## Gate 4: Baked plugin loads

```bash
./run.sh ~/test-sandbox --claude
```

This launches Claude Code directly instead of the shell. Once Claude's prompt appears, type:

```
/superpowers:brainstorming
```

**Expected:** Claude responds following the brainstorming skill's instructions — i.e., it explicitly says it's using the brainstorming skill and starts asking clarifying questions, or describes the skill's workflow.

If you see "unknown skill" or similar, the `--plugin-dir` wrapper injection isn't working.

Type `/exit` to leave Claude, then `exit` to leave the container.

---

## Gate 5: Plugin coexistence with user-installed

```bash
./run.sh ~/test-sandbox --claude
```

At the Claude prompt:

```
/plugin install commit-commands@claude-plugins-official
```

Wait for the install to complete (Claude will print success).

Then:

```
/plugin list
```

**Expected:** both `superpowers` (baked) and `commit-commands` (just installed) appear in the list.

Exit Claude and the container. Re-launch the SAME project:

```bash
./run.sh ~/test-sandbox --claude
```

At the Claude prompt:

```
/plugin list
```

**Expected:** both plugins still appear — `superpowers` is re-injected by the wrapper, and `commit-commands` persists in the bind-mounted `~/.claude/plugins/`.

Exit Claude and the container.

---

## Gate 6: AI git push is blocked

```bash
cd ~/test-sandbox
git init   # if not already a git repo
git config user.email t@t && git config user.name t
cd -
./run.sh ~/test-sandbox --claude
```

At the Claude prompt:

```
Please run: git push origin main
```

**Expected:** Claude responds that the command was denied. The denial message contains the text "Blocked: git push and remote modifications are not allowed in ai-sandbox" (the PreToolUse hook output from `/opt/ai-sandbox/hooks/block-remote-publishing.sh`).

Exit Claude and the container.

---

## Gate 7: dev.sh launches VS Code attached to container

This gate requires the VS Code WSL extension (if on WSL2) or VS Code Dev Containers extension (on native Linux) to be installed.

```bash
./dev.sh ~/test-sandbox
```

**Expected:**
- A VS Code window opens with the title bar showing "Container ai-sandbox-test-sandbox" (or similar).
- The file tree on the left shows the contents of `/home/coder/project/` inside the container.
- Opening a Terminal in VS Code (Ctrl+\`) gives you a zsh prompt inside the container.

Inside that terminal:

```bash
ls /tmp/install-claude-ext.log
cat /tmp/install-claude-ext.log
```

**Expected:** the log file exists and ends with a success message confirming the Claude Code extension installed via the post-attach loop.

Verify in VS Code: open the Extensions panel (Ctrl+Shift+X). The "Claude Code" extension should appear in the installed list under "Container".

Close the VS Code window. The container keeps running detached.

---

## Gate 8: dev.sh management commands

```bash
./dev.sh --list
```

**Expected:** shows `ai-sandbox-test-sandbox` as a running container.

```bash
./dev.sh --stop test-sandbox
```

**Expected:** prints a confirmation; the container is stopped.

```bash
./dev.sh --list
```

**Expected:** no longer shows the container.

```bash
./dev.sh ~/test-sandbox
# (a second VS Code window may open; you can ignore it)
./dev.sh --stop-all
```

**Expected:** all ai-sandbox containers are stopped. `./dev.sh --list` shows nothing.

---

## Cleanup

```bash
rm -rf ~/test-sandbox
rm -rf ~/.ai-sandbox/test-sandbox
docker image rm ai-sandbox:latest   # optional, if you want to reclaim disk
```

---

## What to report

Paste your results, ideally in the format described in "How to report results" at the top. If any gate fails, the project will iterate on the branch and ping you for a re-run. Once all 8 gates pass, the branch merges to main and Linux + WSL2 support becomes official.

If you hit issues that look like environment problems rather than ai-sandbox bugs (e.g., Docker isn't installed correctly, WSL2 systemd quirks, VS Code WSL extension not set up), please describe them — we'll add notes to the README's troubleshooting section. But don't block the gate report on resolving environment issues.
```

- [ ] **Step 4.2: Verify file presence**

```bash
ls docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md
wc -l docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md
```
Expected: file exists and is approximately 150–200 lines.

```bash
grep -c '^## Gate ' docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md
```
Expected: `8` (exactly 8 gate headings).

- [ ] **Step 4.3: Commit**

```bash
git add docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md
git status   # confirm only the runbook file staged
git commit -m "$(cat <<'EOF'
Add Linux + WSL2 verification runbook for external tester

Step-by-step gate sequence the external Linux tester runs before
we merge this branch. Eight gates cover build, default-persist
project, .claude.json symlink, baked plugin loading, plugin
coexistence, managed-settings hook denial of AI git push, dev.sh
VS Code attach, and dev.sh management commands. Includes WSL2
prerequisite notes.

This file stays on the branch only and is stripped before the
merge to main; its content is preserved in the merge commit
history.
EOF
)"
```

Verify no Claude attribution.

---

## Task 5: Final sanity sweep + handoff prep

**Files:** none modified.

- [ ] **Step 5.1: Shellcheck**

```bash
shellcheck run.sh dev.sh entrypoint.sh container-hooks/block-remote-publishing.sh scripts/install-claude-plugins.sh scripts/install-vscode-extensions.sh 2>&1 | grep -v "SC1091" | grep -vE "^For more information:|shellcheck.net|^$" || echo "shellcheck clean (only pre-existing SC1091 .env notes filtered)"
```
Expected: clean.

- [ ] **Step 5.2: Cross-reference check**

```bash
grep -ni "macos only\|linux support is intentionally" README.md CLAUDE.md
```
Expected: NO matches. Any survivor is a leftover that needs fixing.

```bash
grep -n "^## " README.md
```
Expected: heading sequence reads ... `## Prerequisites`, `## macOS setup`, `## Linux setup`, `## Windows + WSL2 setup`, ...

- [ ] **Step 5.3: Branch summary**

```bash
git log --oneline main..HEAD
git diff main --stat
```
Expected: 6 commits (spec + plan + 4 implementation tasks). Stat should show changes to: `README.md`, `CLAUDE.md`, `run.sh`, `dev.sh`, the spec file, the plan file, and the new runbook file. NO other files touched.

- [ ] **Step 5.4: Hand-off note**

Don't commit anything in this step. Print a clear summary to the report that tells the controller:

1. **Branch:** `feat/linux-wsl2-support` (local; you push it when ready).
2. **Status:** all docs and code touches done; verification runbook ready.
3. **What's NEXT (human action):**
   - Push the branch to your remote.
   - Forward the branch URL + the path `docs/superpowers/specs/2026-05-13-linux-wsl2-verification-runbook.md` to a Linux tester.
   - Wait for their report.
   - If all 8 gates PASS: merge to main, then in a follow-up commit on main, flip the README support matrix Linux row from "✓ via WSL2" to "✓ verified" and delete the runbook file.
   - If any gate FAILS: iterate on the branch, re-test.

## Risk register

| Risk | Mitigation |
|------|------------|
| The verification runbook misses a real platform-specific issue | The runbook covers the 8 gates that exercise build, persistence, plugins, hooks, AND dev.sh. If a tester finds an issue outside these gates, they're encouraged to flag it as a troubleshooting note. We iterate. |
| Branch goes stale waiting for the tester | Doc-heavy branch; conflicts on `README.md`/`CLAUDE.md` from main are easy to resolve. The runbook file is at a unique path with zero conflict risk. Rebase against main if needed. |
| External tester reports gate failure but the failure is in their environment, not our project | Runbook explicitly tells the tester to report environment-issue suspicions as separate notes, not as gate failures. We triage. |
| README support matrix says "verified" but it isn't yet | The runbook plan flips that annotation to "verified" only in a POST-merge commit, after the tester confirms. The branch's README has the Linux row as "✓ via WSL2" to be honest about what's actually verified at every point in time. |
