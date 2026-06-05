# AWS SSO + gh auth passthrough — design

**Date:** 2026-06-05
**Status:** Approved, pending implementation plan

## Goal

Let a user reuse their **host** AWS SSO session and **host** GitHub CLI login
inside the sandbox, with zero per-container login, while keeping the repo's
default "no host secrets are reachable" posture intact for anyone who hasn't
opted in.

Both binaries already exist in the image — `gh` (Dockerfile L55–63) and AWS CLI
v2 (L80–89) — so this is **launcher plumbing only**. No Dockerfile changes, no
new binaries, no entrypoint logic required.

After this change, with the two toggles set once in the git-ignored `.env`:

| Invocation | Result |
|------------|--------|
| `./run.sh ~/proj --claude` (toggles unset) | Unchanged — no AWS mount, no token injection (default isolation preserved) |
| `AWS_SSO=1` in `.env`, host has `~/.aws/` | `~/.aws/` mounted into container; `aws` reuses host SSO token cache |
| `GH_AUTH=1` in `.env`, host logged into `gh` | Host `gh auth token` injected as `GH_TOKEN`; container `gh` is logged in |

## Background: how each auth flow actually works

- **gh** — The launcher runs on the host *before* the container starts, so it
  can reach the host's gh login. `gh auth token` resolves the token from
  wherever the host stored it (macOS Keychain **or** `~/.config/gh/hosts.yml`),
  so it works regardless of storage backend. `gh` inside the container honors
  the `GH_TOKEN` env var with no further config. The user's host login is never
  touched, and `gh auth login` is never run inside a container.
- **AWS SSO** — File-based. The user runs `aws sso login` on the host (host
  browser opens), which populates `~/.aws/sso/cache/`. Mounting `~/.aws/` lets
  the container's `aws` reuse that cached SSO token to derive short-lived role
  credentials (which it caches under `~/.aws/cli/cache/`).

## Non-goals

- **In-container `aws sso login` / device-code flow.** Rejected in
  brainstorming — host login + shared cache is the chosen flow.
- **Mounting `~/.config/gh/`.** Rejected in favor of `GH_TOKEN` env injection:
  works regardless of Keychain-vs-file storage, needs no mount, leaves nothing
  to clean up, and keeps the token out of the `docker run` argv.
- **Always-on (no toggle).** Rejected. Silently piping a GitHub token and
  mounting `~/.aws/` into every build of this image would void the documented
  isolation guarantee for other users. Opt-in via `.env` gives this user
  zero-friction reuse while keeping the repo safe-by-default.
- **Full `docker-compose.yml` parity.** Compose can't run `gh auth token`
  dynamically. Best-effort only (see Change 3); compose is a documented
  secondary path.
- **Writing in-container gh/aws config changes back to the host gh store.**
  gh config/aliases are not synced; only auth is reused.

## Architecture

Four narrow changes. Toggles mirror the existing `DOCKER_SOCKET=1` convention
(off by default, read from the auto-sourced `.env`).

### Change 1: `run.sh` — AWS mount + GH_TOKEN injection

After the existing Docker-socket block (around L182–190), add two guarded
blocks appended to `DOCKER_ARGS`:

**AWS** (only when `AWS_SSO=1` *and* the host dir exists):
```bash
# Optional AWS SSO config/cache passthrough (host login, shared cache).
if [ "${AWS_SSO:-0}" = "1" ]; then
    AWS_HOST_DIR="${AWS_DIR:-$HOME/.aws}"
    if [ -d "$AWS_HOST_DIR" ]; then
        AWS_HOST_DIR="$(cd "$AWS_HOST_DIR" && pwd)"
        DOCKER_ARGS+=(-v "$AWS_HOST_DIR:/home/coder/.aws")
    else
        echo "Warning: AWS_SSO=1 but $AWS_HOST_DIR not found, skipping AWS mount."
    fi
fi
```
- Read-write mount (default): the container must write derived role credentials
  to `~/.aws/cli/cache/`. Sharing these with the host is harmless.
- Optional `AWS_DIR` override lets a user point at a non-default location;
  defaults to `$HOME/.aws`.

**gh** (only when `GH_AUTH=1`, `gh` exists on host, and a token comes back):
```bash
# Optional GitHub CLI auth passthrough — reuse the host's gh login.
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
- `-e GH_TOKEN` (no `=value`) makes `docker run` read the value from the
  launcher's environment, keeping the token out of the visible argv /
  `docker inspect`.

### Change 2: `dev.sh` — same two blocks

`dev.sh` builds its run args inline on the `docker run -d ...` call (L217–228)
rather than in a `DOCKER_ARGS` array. Mirror the pattern it already uses for the
Docker socket (`DOCKER_SOCK_ARGS=()`):
- Add an `AWS_ARGS=()` array populated by the same `AWS_SSO`/`AWS_DIR` guard.
- For gh, `export GH_TOKEN` and add a `GH_ARGS=()` containing `-e GH_TOKEN`.
- Splice both into the `docker run -d` invocation using the same
  `"${ARR[@]+"${ARR[@]}"}"` empty-safe expansion already used for
  `DOCKER_SOCK_ARGS` and `CLAUDE_DIR_ARGS`.

### Change 3: `docker-compose.yml` — best-effort parity

Compose can't shell out to `gh auth token`. Provide passthrough of an
already-exported value and a documented opt-in mount:
- Add `- GH_TOKEN=${GH_TOKEN:-}` to the `environment:` list (user exports it, or
  runs `export GH_TOKEN=$(gh auth token)` before `docker compose run`).
- Add a commented `~/.aws` volume next to the existing commented docker-socket
  volume, with a one-line note that it's the compose equivalent of `AWS_SSO=1`:
  ```yaml
  # Optional: AWS SSO config/cache (host login, shared cache). Uncomment to enable.
  # - ${AWS_DIR:-${HOME}/.aws}:/home/coder/.aws
  ```

### Change 4: Documentation

- **CLAUDE.md — Volume mounts table:** add a `/home/coder/.aws` row
  (source: `AWS_SSO=1` env, notes: optional, host login + shared cache).
- **CLAUDE.md — security note:** the "host secrets aren't reachable (not
  mounted)" sentence in the hooks section becomes conditionally false once a
  user opts in. Soften to note the two opt-in escape hatches (`AWS_SSO=1`,
  `GH_AUTH=1`) and that they are off by default.
- **CLAUDE.md — Conventions / env vars:** document `AWS_SSO`, `AWS_DIR`,
  `GH_AUTH`, and `GH_TOKEN` alongside the existing `DOCKER_SOCKET` mention.
- **`run.sh` / `dev.sh` `--help`:** add `AWS_SSO`, `GH_AUTH` to the
  "Environment variables" section of each help block.

## Testing / verification

No automated suite exists; verification is manual after `./run.sh --build`
(binaries unchanged, so a rebuild is optional — launcher edits take effect
immediately, but shellcheck must pass).

1. **shellcheck:** `shellcheck run.sh dev.sh` passes (the new array-splice and
   `export`+`-e VAR` patterns are shellcheck-clean).
2. **Default off:** with no toggles, `./run.sh ~/proj` shows no `~/.aws` mount
   and no `GH_TOKEN` (confirm via `docker inspect` / `env | grep GH_TOKEN`
   empty). Isolation unchanged.
3. **gh on:** `gh auth login` on host, set `GH_AUTH=1`, launch, run
   `gh auth status` inside the container → reports logged in. Confirm the token
   does **not** appear in `docker inspect <container>` config args.
4. **gh on, host logged out:** `GH_AUTH=1` but `gh auth token` empty → warning
   printed, container still starts.
5. **AWS on:** `aws sso login` on host, set `AWS_SSO=1`, launch, run
   `aws sts get-caller-identity` inside the container → returns the SSO
   identity without an in-container browser.
6. **AWS on, no host dir:** `AWS_SSO=1` with `~/.aws` absent → warning printed,
   container still starts.
7. **dev.sh parity:** repeat 3 and 5 via `./dev.sh` and confirm the VS Code
   terminal session sees the same auth.
