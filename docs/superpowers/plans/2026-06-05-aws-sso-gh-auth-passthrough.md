# AWS SSO + gh auth passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user reuse their host AWS SSO session and host GitHub CLI login inside the sandbox via two opt-in `.env` toggles, with zero per-container login.

**Architecture:** Launcher plumbing only — no Dockerfile or entrypoint changes (`gh` and AWS CLI v2 are already in the image). `run.sh` and `dev.sh` gain two guarded blocks: mount `~/.aws/` when `AWS_SSO=1`, and inject the host's `gh auth token` as `GH_TOKEN` when `GH_AUTH=1`. `docker-compose.yml` gets best-effort parity. Toggles mirror the existing `DOCKER_SOCKET=1` convention (off by default, read from the auto-sourced `.env`).

**Tech Stack:** Bash launcher scripts, Docker CLI, `gh` CLI, AWS CLI v2, docker-compose.

**Verification model:** There is no test suite — `shellcheck` is the only linter, plus manual smoke tests. Each task's cycle is: edit → `shellcheck` → manual verify (where applicable) → commit. Spec reference: `docs/superpowers/specs/2026-06-05-aws-sso-gh-auth-passthrough-design.md`.

---

### Task 1: `run.sh` — AWS mount + GH_TOKEN injection + help

**Files:**
- Modify: `run.sh` (insert after the Docker-socket block at `run.sh:182-190`; help text at `run.sh:37-38`)

- [ ] **Step 1: Add the two guarded blocks after the Docker-socket mount**

Insert immediately after the closing `fi` of the `# Optional Docker socket mount` block (currently `run.sh:190`), before the `# ── Launch ──` comment:

```bash
# Optional AWS SSO config/cache passthrough (host login, shared cache).
# Enable with AWS_SSO=1; override source dir with AWS_DIR. Read-write so the
# container can cache derived role credentials under ~/.aws/cli/cache/.
if [ "${AWS_SSO:-0}" = "1" ]; then
    AWS_HOST_DIR="${AWS_DIR:-$HOME/.aws}"
    if [ -d "$AWS_HOST_DIR" ]; then
        AWS_HOST_DIR="$(cd "$AWS_HOST_DIR" && pwd)"
        DOCKER_ARGS+=(-v "$AWS_HOST_DIR:/home/coder/.aws")
    else
        echo "Warning: AWS_SSO=1 but $AWS_HOST_DIR not found, skipping AWS mount."
    fi
fi

# Optional GitHub CLI auth passthrough — reuse the host's gh login.
# Enable with GH_AUTH=1. `gh auth token` resolves from Keychain or hosts.yml.
# `-e GH_TOKEN` (no value) reads from this script's env so the token stays out
# of the docker run argv / docker inspect.
if [ "${GH_AUTH:-0}" = "1" ] && command -v gh >/dev/null 2>&1; then
    GH_TOKEN_VALUE="$(gh auth token 2>/dev/null || true)"
    if [ -n "$GH_TOKEN_VALUE" ]; then
        export GH_TOKEN="$GH_TOKEN_VALUE"
        DOCKER_ARGS+=(-e GH_TOKEN)
    else
        echo "Warning: GH_AUTH=1 but no host gh token found (run 'gh auth login'), skipping."
    fi
fi
```

- [ ] **Step 2: Document the toggles in `--help`**

In `show_help()`, the "Environment variables:" section currently lists only `DOCKER_SOCKET` (around `run.sh:37-38`). Change it to:

```bash
Environment variables:
  DOCKER_SOCKET               Set to 1 to mount Docker socket into container
  AWS_SSO                     Set to 1 to mount ~/.aws (reuse host AWS SSO login)
  AWS_DIR                     Override AWS config dir source (default: ~/.aws)
  GH_AUTH                     Set to 1 to inject host 'gh auth token' as GH_TOKEN
```

- [ ] **Step 3: Lint**

Run: `shellcheck run.sh`
Expected: no output (exit 0). The `${AWS_SSO:-0}` defaults and `export GH_TOKEN` + `-e GH_TOKEN` pattern are shellcheck-clean.

- [ ] **Step 4: Verify default-off behavior**

Run: `./run.sh /tmp` then inside the container run `env | grep -c GH_TOKEN` (expect `0`) and `ls /home/coder/.aws 2>&1` (expect "No such file or directory"). Exit the container.
Expected: no GH_TOKEN, no AWS mount — isolation unchanged when toggles are unset.

- [ ] **Step 5: Verify gh on (requires host `gh auth login` done)**

Run: `GH_AUTH=1 ./run.sh /tmp`, then inside run `gh auth status`.
Expected: reports logged in. In a separate host shell, `docker inspect $(docker ps -q --filter name=ai-sandbox-run) | grep -c '<your-token-substring>'` → `0` (token absent from argv). Exit the container.

- [ ] **Step 6: Verify AWS on (requires host `aws sso login` done)**

Run: `AWS_SSO=1 ./run.sh /tmp`, then inside run `aws sts get-caller-identity`.
Expected: returns your SSO identity JSON with no in-container browser prompt. Exit the container.

- [ ] **Step 7: Commit**

```bash
git add run.sh
git commit -m "run.sh: add opt-in AWS SSO mount and gh token passthrough"
```

---

### Task 2: `dev.sh` — same two blocks (array-spliced) + help

**Files:**
- Modify: `dev.sh` (new arrays after the socket block at `dev.sh:193-202`; splice into `docker run -d` at `dev.sh:217-228`; help at `dev.sh:48-55`)

- [ ] **Step 1: Add AWS and gh arg arrays after the Docker-socket detection block**

Insert immediately after the closing `fi` of the `DOCKER_SOCK_ARGS` block (currently `dev.sh:202`), before the `# ── Claude config directory mount ──` comment:

```bash
# ── Optional AWS SSO config/cache passthrough ────────────────────
# Enable with AWS_SSO=1; override source with AWS_DIR (default ~/.aws).
# Read-write so the container can cache derived role credentials.
AWS_ARGS=()
if [ "${AWS_SSO:-0}" = "1" ]; then
    AWS_HOST_DIR="${AWS_DIR:-$HOME/.aws}"
    if [ -d "$AWS_HOST_DIR" ]; then
        AWS_HOST_DIR="$(cd "$AWS_HOST_DIR" && pwd)"
        AWS_ARGS=(-v "$AWS_HOST_DIR:/home/coder/.aws")
    else
        echo "Warning: AWS_SSO=1 but $AWS_HOST_DIR not found, skipping AWS mount."
    fi
fi

# ── Optional GitHub CLI auth passthrough ─────────────────────────
# Enable with GH_AUTH=1. Reuses the host gh login; `-e GH_TOKEN` (no value)
# reads from this script's env to keep the token out of docker inspect.
GH_ARGS=()
if [ "${GH_AUTH:-0}" = "1" ] && command -v gh >/dev/null 2>&1; then
    GH_TOKEN_VALUE="$(gh auth token 2>/dev/null || true)"
    if [ -n "$GH_TOKEN_VALUE" ]; then
        export GH_TOKEN="$GH_TOKEN_VALUE"
        GH_ARGS=(-e GH_TOKEN)
    else
        echo "Warning: GH_AUTH=1 but no host gh token found (run 'gh auth login'), skipping."
    fi
fi
```

- [ ] **Step 2: Splice the new arrays into the `docker run -d` invocation**

In the `docker run -d \` block (currently `dev.sh:217-228`), add two lines using the same empty-safe expansion already used for `DOCKER_SOCK_ARGS` and `CLAUDE_DIR_ARGS`. After the existing `"${CLAUDE_DIR_ARGS[@]+"${CLAUDE_DIR_ARGS[@]}"}" \` line, add:

```bash
    "${AWS_ARGS[@]+"${AWS_ARGS[@]}"}" \
    "${GH_ARGS[@]+"${GH_ARGS[@]}"}" \
```

(Placement before the `-w /home/coder/project \` line is fine; arg order doesn't matter to `docker run`.)

- [ ] **Step 3: Document the toggles in `--help`**

`dev.sh`'s `show_help()` has no "Environment variables:" section today (it ends the Options block before Examples, around `dev.sh:54-56`). Add one after the last option line (`--help` / before `Examples:`):

```bash
Environment variables:
  DOCKER_SOCKET               Set to 1 to mount Docker socket into container
  AWS_SSO                     Set to 1 to mount ~/.aws (reuse host AWS SSO login)
  AWS_DIR                     Override AWS config dir source (default: ~/.aws)
  GH_AUTH                     Set to 1 to inject host 'gh auth token' as GH_TOKEN
```

- [ ] **Step 4: Lint**

Run: `shellcheck dev.sh`
Expected: no output (exit 0).

- [ ] **Step 5: Verify dev.sh parity (gh + AWS)**

Run: `GH_AUTH=1 AWS_SSO=1 ./dev.sh /tmp`. When VS Code attaches, open its integrated terminal and run `gh auth status` and `aws sts get-caller-identity`.
Expected: gh reports logged in; aws returns the SSO identity. Then `./dev.sh --stop /tmp`.

- [ ] **Step 6: Commit**

```bash
git add dev.sh
git commit -m "dev.sh: add opt-in AWS SSO mount and gh token passthrough"
```

---

### Task 3: `docker-compose.yml` — best-effort parity

**Files:**
- Modify: `docker-compose.yml` (volumes block `docker-compose.yml:19-32`; environment block `docker-compose.yml:34-38`)

- [ ] **Step 1: Add a commented AWS volume next to the commented docker-socket volume**

In the `claude` service `volumes:` list, after the existing commented Docker-socket lines (currently `docker-compose.yml:31-32`), add:

```yaml
      # Optional: AWS SSO config/cache (host login, shared cache). Compose
      # equivalent of AWS_SSO=1. Uncomment to enable. $HOME (not ~) required.
      # - ${AWS_DIR:-${HOME}/.aws}:/home/coder/.aws
```

- [ ] **Step 2: Add GH_TOKEN passthrough to the environment list**

In the `claude` service `environment:` list (currently `docker-compose.yml:35-38`), after the `TERM` line, add:

```yaml
      # gh auth: compose can't run `gh auth token` itself. Export it first:
      #   export GH_TOKEN=$(gh auth token)   # then: docker compose run --rm claude
      - GH_TOKEN=${GH_TOKEN:-}
```

- [ ] **Step 3: Validate compose file syntax**

Run: `docker compose config >/dev/null`
Expected: exit 0, no errors (the `${GH_TOKEN:-}` and commented volume parse cleanly). The `claude-interactive` service extends `claude`, so it inherits the env automatically.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "docker-compose: best-effort AWS mount + GH_TOKEN passthrough"
```

---

### Task 4: Documentation — CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (volume table `CLAUDE.md:101-105`; security note `CLAUDE.md:85`; conventions `CLAUDE.md:112`)

- [ ] **Step 1: Add an `~/.aws` row to the Volume mounts table**

After the `/var/run/docker.sock` row (`CLAUDE.md:105`), add:

```markdown
| `/home/coder/.aws` | env `AWS_SSO=1` (source `AWS_DIR`, default `~/.aws`) | optional; reuse host AWS SSO login + cached token (read-write) |
```

- [ ] **Step 2: Soften the "host secrets aren't reachable" claim**

In the `**Why so minimal?**` paragraph (`CLAUDE.md:85`), the clause "host secrets aren't reachable (not mounted)" is now conditionally false. Change that clause to:

```markdown
host secrets aren't reachable by default (nothing host-sensitive is mounted unless the user explicitly opts in via `AWS_SSO=1` or `GH_AUTH=1`)
```

- [ ] **Step 3: Document the env vars in Conventions**

In the `.env` auto-source bullet (`CLAUDE.md:112`), extend the trailing example list. Change "use it for `ANTHROPIC_MODEL`, `DOCKER_SOCKET`, etc." to:

```markdown
use it for `ANTHROPIC_MODEL`, `DOCKER_SOCKET`, `AWS_SSO`/`AWS_DIR` (mount `~/.aws` to reuse host AWS SSO), `GH_AUTH` (inject host `gh auth token` as `GH_TOKEN`), etc.
```

- [ ] **Step 4: Sanity-check the rendered table**

Run: `grep -n "/home/coder/.aws\|AWS_SSO\|GH_AUTH" CLAUDE.md`
Expected: matches in the volume table, the security note, and the conventions bullet (confirming all three edits landed).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document AWS_SSO/GH_AUTH opt-in passthrough toggles"
```

---

## Self-Review

**Spec coverage:**
- Change 1 (run.sh AWS + gh) → Task 1 ✓
- Change 2 (dev.sh, array-spliced) → Task 2 ✓
- Change 3 (compose best-effort: GH_TOKEN env + commented aws volume) → Task 3 ✓
- Change 4 (docs: volume table, security note, conventions, help) → Task 4 (docs) + Task 1 Step 2 / Task 2 Step 3 (help) ✓
- All 7 spec verification items covered: default-off (T1 S4), gh on (T1 S5), gh host-logged-out warning (code path in T1 S1 / T2 S1), AWS on (T1 S6), AWS no-dir warning (code path in T1 S1 / T2 S1), dev.sh parity (T2 S5), shellcheck (T1 S3, T2 S4) ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type/name consistency:** `AWS_SSO`, `AWS_DIR`, `GH_AUTH`, `GH_TOKEN`, `AWS_HOST_DIR`, `GH_TOKEN_VALUE`, `AWS_ARGS`, `GH_ARGS` used identically across run.sh and dev.sh tasks; mount target `/home/coder/.aws` consistent across launchers, compose, and docs. ✓

**Note on `aws sso login`:** A prerequisite the *user* runs on the host, not a plan step. Verification steps 1.6 and 2.5 assume it's been done; if the SSO session has expired, `aws sts get-caller-identity` will report an expired-token error rather than success — re-run `aws sso login` on the host and retry.
