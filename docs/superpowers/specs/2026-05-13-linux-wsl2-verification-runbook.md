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

**Expected:** the log file exists and the last line reads `[HH:MM:SS] Done (exit 0).` (the exact timestamp varies; what matters is the `exit 0`). A non-zero exit code means the extension install failed; report the full log contents.

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
