# Bake Claude plugins + OpenSpec implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake the `superpowers` Claude Code plugin and the `openspec` npm CLI into the ai-sandbox image so every project that uses the container starts with them pre-installed, with a list-file extension point (`claude-plugins.txt`) for adding more plugins later.

**Architecture:** A new `claude-plugins.txt` enumerates plugin name + git URL + sha. A build-time script `scripts/install-claude-plugins.sh` clones each plugin into `/opt/ai-sandbox/plugins/<name>/` and generates `/usr/local/bin/claude` — a 5-line wrapper that exec's the real `claude` binary with one `--plugin-dir` flag per baked plugin pre-pended. OpenSpec installs globally via `npm install -g @fission-ai/openspec` in the same Dockerfile layer.

**Tech Stack:** Bash, Docker, git, npm, shellcheck. No test suite — verification is shellcheck + empirical container smoke tests. Spec: `docs/superpowers/specs/2026-05-13-bake-claude-plugins-and-openspec-design.md`.

**Operating rules (carry through every commit):**
- Branch: `feat/bake-claude-plugins` (already created and on the spec commit).
- **No git push, no `gh pr create`** — local commits only.
- **No Claude attribution in commit messages.** No `Co-Authored-By: Claude` trailer; no "Generated with Claude" footer.
- After **any** edit to `Dockerfile`, `scripts/install-claude-plugins.sh`, or `claude-plugins.txt`, rebuild with `./run.sh --build` before behavioral testing.

---

## Task 1: Create `claude-plugins.txt`

**Files:**
- Create: `claude-plugins.txt` (repo root)

- [ ] **Step 1.1: Create the list file**

Write `claude-plugins.txt` at the repo root with this exact content:

```
# Claude Code plugins baked into the image.
# Format: <name> <git-url> [<ref-or-sha>]
# Empty lines and lines starting with # are ignored.
# Adding a line here + rebuilding the image installs the plugin
# at /opt/ai-sandbox/plugins/<name>/, loaded via --plugin-dir.
superpowers https://github.com/obra/superpowers.git f2cbfbefebbfef77321e4c9abc9e949826bea9d7
```

- [ ] **Step 1.2: Verify file contents**

```bash
cat claude-plugins.txt | grep -c '^superpowers '
```
Expected: `1` (exactly one non-comment plugin entry).

- [ ] **Step 1.3: Commit**

```bash
git add claude-plugins.txt
git status   # confirm only claude-plugins.txt staged
git commit -m "$(cat <<'EOF'
Add claude-plugins.txt with superpowers as the initial entry

Repo-root list file enumerates Claude Code plugins to bake into
the image. Mirrors the vscode-extensions.txt extension point.
Format: name url [ref]. The sha for superpowers is taken from the
official marketplace catalog (claude-plugins-official) for
reproducible builds.

The install script and Dockerfile wiring land in subsequent commits.
EOF
)"
```

Verify with `git log -1 --format='%B'` that the commit has no Claude attribution.

---

## Task 2: Create `scripts/install-claude-plugins.sh`

This is the build-time installer. It reads `claude-plugins.txt`, clones each plugin, and generates `/usr/local/bin/claude` as a wrapper that injects `--plugin-dir` flags.

**Files:**
- Create: `scripts/install-claude-plugins.sh`

- [ ] **Step 2.1: Verify the scripts directory exists**

```bash
ls scripts/
```
Expected: directory exists and contains at least `install-vscode-extensions.sh` (the precedent we're modeling on). If `scripts/` does not exist, `mkdir scripts` before continuing.

- [ ] **Step 2.2: Write the installer script**

Create `scripts/install-claude-plugins.sh` with this exact content:

```bash
#!/usr/bin/env bash
# install-claude-plugins.sh
#
# Build-time installer for Claude Code plugins listed in
# claude-plugins.txt. For each non-comment line, clones the plugin
# repo into /opt/ai-sandbox/plugins/<name>/ and pins to <ref> if
# provided. After all plugins are installed, generates
# /usr/local/bin/claude as a wrapper that exec's the real claude
# binary with --plugin-dir flags for each baked plugin.
#
# Usage: install-claude-plugins.sh <path-to-claude-plugins.txt>
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <claude-plugins.txt>" >&2
    exit 2
fi

LIST="$1"
PLUGINS_DIR="/opt/ai-sandbox/plugins"
WRAPPER="/usr/local/bin/claude"

# Resolve the real claude binary BEFORE we shadow it with the wrapper.
REAL_CLAUDE="$(command -v claude || true)"
if [ -z "$REAL_CLAUDE" ]; then
    echo "ERROR: 'claude' binary not found on PATH at install time." >&2
    echo "       This script must run AFTER the Claude CLI install layer." >&2
    exit 1
fi
# Resolve symlinks so the wrapper has an absolute, stable path.
REAL_CLAUDE="$(readlink -f "$REAL_CLAUDE")"

mkdir -p "$PLUGINS_DIR"

PLUGIN_NAMES=()
while IFS=' ' read -r name url ref || [ -n "${name:-}" ]; do
    # Skip blank lines and comments.
    case "$name" in
        ''|'#'*) continue ;;
    esac
    if [ -z "${url:-}" ]; then
        echo "ERROR: malformed line in $LIST: '$name' (missing url column)" >&2
        exit 1
    fi
    dest="$PLUGINS_DIR/$name"
    echo "==> Installing $name from $url${ref:+ @ $ref}"
    rm -rf "$dest"
    git clone --depth 1 "$url" "$dest"
    if [ -n "${ref:-}" ]; then
        git -C "$dest" fetch --depth 1 origin "$ref"
        git -C "$dest" checkout "$ref"
    fi
    git -C "$dest" rev-parse HEAD > "$dest/.installed-sha"
    # Sanity-check: a Claude plugin has either a manifest at
    # .claude-plugin/plugin.json or one of the standard component
    # directories. Reject repos that have neither.
    if [ ! -f "$dest/.claude-plugin/plugin.json" ] \
       && [ ! -d "$dest/skills" ] \
       && [ ! -d "$dest/commands" ] \
       && [ ! -d "$dest/agents" ] \
       && [ ! -d "$dest/hooks" ]; then
        echo "ERROR: $name (cloned from $url) does not look like a Claude plugin." >&2
        echo "       Expected .claude-plugin/plugin.json or skills/commands/agents/hooks dir." >&2
        exit 1
    fi
    PLUGIN_NAMES+=("$name")
done < "$LIST"

# Generate /usr/local/bin/claude wrapper. Use printf to avoid
# escaping subtleties with heredocs and embedded $ signs.
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# Generated by install-claude-plugins.sh. Do not edit; rebuild the image.'
    printf 'exec %s' "$REAL_CLAUDE"
    for name in "${PLUGIN_NAMES[@]+"${PLUGIN_NAMES[@]}"}"; do
        printf ' \\\n    --plugin-dir %s/%s' "$PLUGINS_DIR" "$name"
    done
    printf ' \\\n    "$@"\n'
} > "$WRAPPER"
chmod +x "$WRAPPER"

echo "==> Installed ${#PLUGIN_NAMES[@]} plugin(s); generated wrapper:"
sed 's/^/    /' "$WRAPPER"
```

- [ ] **Step 2.3: Make it executable**

```bash
chmod +x scripts/install-claude-plugins.sh
```

- [ ] **Step 2.4: Shellcheck**

```bash
shellcheck scripts/install-claude-plugins.sh
```
Expected: clean (no warnings or errors).

If shellcheck flags `SC2068` (double-quote array expansion) or similar on the `${PLUGIN_NAMES[@]+...}` line, the `[@]+` form is the bash-safe way to expand a possibly-empty array under `set -u` and must stay.

- [ ] **Step 2.5: Commit**

```bash
git add scripts/install-claude-plugins.sh
git status   # confirm only the new script staged (and it should have execute bit)
git commit -m "$(cat <<'EOF'
Add scripts/install-claude-plugins.sh — build-time plugin installer

Reads claude-plugins.txt, git-clones each plugin into
/opt/ai-sandbox/plugins/<name>/ pinned to the given sha, and
generates /usr/local/bin/claude as a wrapper that exec's the real
claude binary with --plugin-dir flags for each baked plugin.

Not yet wired into the Dockerfile — that's the next commit.
EOF
)"
```

Verify with `git log -1 --format='%B'` that the commit has no Claude attribution.

---

## Task 3: Wire into Dockerfile — Layer 7.5

This is the behavior commit: after it lands, fresh image builds bake the plugin and install OpenSpec.

**Files:**
- Modify: `Dockerfile` (insert new layer after Layer 7, before "Container hooks and managed settings")

- [ ] **Step 3.1: Identify the insertion point**

In `Dockerfile`, find the line:

```dockerfile
# ── Container hooks and managed settings ─────────────────────────
```

This is currently around line 124. The new layer goes IMMEDIATELY ABOVE this line (i.e., between Layer 7's `npm cache clean --force` and the "Container hooks and managed settings" block).

- [ ] **Step 3.2: Insert Layer 7.5**

Add these lines immediately before `# ── Container hooks and managed settings ──`:

```dockerfile
# ── Layer 7.5: Claude plugins + OpenSpec ─────────────────────────
# OpenSpec is a standalone CLI; the user runs `openspec init` per
# project themselves. Plugin install script reads claude-plugins.txt,
# clones each plugin, and generates /usr/local/bin/claude wrapper.
RUN npm install -g @fission-ai/openspec@latest \
    && npm cache clean --force
COPY claude-plugins.txt /tmp/claude-plugins.txt
COPY scripts/install-claude-plugins.sh /tmp/install-claude-plugins.sh
RUN chmod +x /tmp/install-claude-plugins.sh \
    && /tmp/install-claude-plugins.sh /tmp/claude-plugins.txt \
    && rm /tmp/install-claude-plugins.sh /tmp/claude-plugins.txt

```

(Blank line at end of block matches existing Dockerfile style.)

- [ ] **Step 3.3: Rebuild**

```bash
./run.sh --build 2>&1 | tail -25
```
Expected: success, and the tail of build output should include `==> Installing superpowers from https://github.com/obra/superpowers.git @ f2cbfbef...` followed by the generated wrapper printed out.

If the build fails with a clone error, check network. If it fails with the "not a Claude plugin" error, the upstream sha may have moved — verify the sha in `claude-plugins.txt` against the current marketplace catalog.

- [ ] **Step 3.4: Verify OpenSpec is installed**

```bash
docker run --rm ai-sandbox:latest openspec --version 2>&1 | tail -5
```
Expected: a version string (something like `0.x.y`); no errors.

- [ ] **Step 3.5: Verify the plugin is baked at the right path**

```bash
docker run --rm ai-sandbox:latest ls -la /opt/ai-sandbox/plugins/superpowers/.installed-sha
docker run --rm ai-sandbox:latest cat /opt/ai-sandbox/plugins/superpowers/.installed-sha
```
Expected: file exists; content is `f2cbfbefebbfef77321e4c9abc9e949826bea9d7` (40-char sha). If the sha doesn't match, the checkout step didn't pin correctly — investigate.

```bash
docker run --rm ai-sandbox:latest test -d /opt/ai-sandbox/plugins/superpowers/skills && echo "skills dir present"
```
Expected: "skills dir present".

- [ ] **Step 3.6: Verify the wrapper shadows the real binary**

```bash
docker run --rm ai-sandbox:latest which claude
docker run --rm ai-sandbox:latest cat /usr/local/bin/claude
```
Expected: `which` prints `/usr/local/bin/claude`. The file contents should look like:

```sh
#!/bin/sh
# Generated by install-claude-plugins.sh. Do not edit; rebuild the image.
exec /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js \
    --plugin-dir /opt/ai-sandbox/plugins/superpowers \
    "$@"
```

(The exact path of the real `claude` binary may differ depending on Node's global-install location; what matters is that it's an absolute path to a real file.)

- [ ] **Step 3.7: Verify the wrapper exec's the real claude correctly**

```bash
docker run --rm ai-sandbox:latest claude --version
```
Expected: prints the Claude CLI version, no errors. (This proves the wrapper's `exec` to the real binary works end-to-end.)

- [ ] **Step 3.8: Verify the wrapper itself is shellcheck-clean**

```bash
docker run --rm ai-sandbox:latest shellcheck /usr/local/bin/claude
```
Expected: clean (empty output). If shellcheck isn't in the image PATH, skip with a note — the generated script is 5 lines and visually verifiable from Step 3.6.

- [ ] **Step 3.9: Commit**

```bash
git add Dockerfile
git status   # confirm only Dockerfile staged
git commit -m "$(cat <<'EOF'
Dockerfile: bake superpowers plugin + install OpenSpec globally

New Layer 7.5 runs the plugin installer script and `npm install -g
@fission-ai/openspec`. The installer clones each plugin from
claude-plugins.txt into /opt/ai-sandbox/plugins/<name>/ and
generates /usr/local/bin/claude as a thin wrapper that exec's the
real claude binary with --plugin-dir flags pre-pended.

User-installed plugins via `/plugin install foo` continue to land
in ~/.claude/plugins/ and load via Claude's default scan, coexisting
with the baked set.
EOF
)"
```

Verify the commit has no Claude attribution.

---

## Task 4: Update `README.md`

**Files:**
- Modify: `README.md` (add a sentence to the feature list near the top; brief mention in the customization section)

- [ ] **Step 4.1: Read the current feature list**

```bash
grep -n "^- " README.md | head -20
```
Locate the bulleted feature list near the top of the README (typically right after the title/intro). Note the line range for the next edit.

- [ ] **Step 4.2: Add a bullet for baked plugins/CLI**

Find the existing feature bullet that mentions VS Code extensions or Claude CLI in `README.md`'s top-level feature list. Immediately after it, add a new bullet:

```markdown
- **Baked-in dev tooling** — the `superpowers` Claude Code plugin (brainstorming, plan-writing, TDD, debugging skills) and the `openspec` CLI come pre-installed. Plugin list lives in `claude-plugins.txt` at the repo root; add a line and rebuild to bake more.
```

(If you cannot locate a feature-list section, add the bullet under the existing description text, before the "Quickstart" or "Usage" heading.)

- [ ] **Step 4.3: Mention the customization point under "Customizing the image"**

In `README.md`, find the `## Customizing the image` section. After the existing "Build arguments" subsection, add a new subsection:

```markdown
### Baked Claude plugins

Plugins listed in `claude-plugins.txt` (repo root) are git-cloned at build time into `/opt/ai-sandbox/plugins/<name>/` and loaded automatically by every `claude` invocation via `--plugin-dir`. To add a plugin, append a line to that file in the format `<name> <git-url> [<ref-or-sha>]` and rebuild. Pinning to a sha gives reproducible builds; omit the third column to track `main`.

User-installed plugins via `/plugin install foo` are unaffected — they continue to write to `~/.claude/plugins/` (the per-project state dir on host) and coexist with the baked set.
```

- [ ] **Step 4.4: Verify the additions render**

```bash
grep -n "Baked-in dev tooling\|### Baked Claude plugins" README.md
```
Expected: two matches, in the order the file is laid out.

- [ ] **Step 4.5: Commit**

```bash
git add README.md
git status   # confirm only README.md staged
git commit -m "$(cat <<'EOF'
README: document baked superpowers + openspec and the plugin list

Surfaces the new pre-installed tools in the feature list and adds
a `Baked Claude plugins` subsection under `Customizing the image`
that documents the claude-plugins.txt extension point.
EOF
)"
```

Verify no Claude attribution.

---

## Task 5: Update `CLAUDE.md`

`CLAUDE.md` is the project's load-bearing doc for future-Claude-working-on-this-repo. It needs to know how the wrapper, plugins dir, and claude-plugins.txt fit together.

**Files:**
- Modify: `CLAUDE.md` (add a new subsection under "Architecture")

- [ ] **Step 5.1: Identify the insertion point**

In `CLAUDE.md`, find the `### Managed settings (the security-critical bit)` section heading (around line 53 after the previous branch's edits). The new subsection goes IMMEDIATELY BEFORE this heading — between the "Image tagging" section and "Managed settings", inserting a new `### Baked Claude plugins` subsection.

- [ ] **Step 5.2: Add the new subsection**

Insert this block immediately before `### Managed settings (the security-critical bit)`:

```markdown
### Baked Claude plugins

`claude-plugins.txt` (repo root) enumerates Claude Code plugins to bake into the image. Format: `<name> <git-url> [<ref-or-sha>]`, one per line; empty lines and `#`-comments are ignored. At build time, `scripts/install-claude-plugins.sh` (invoked by Dockerfile Layer 7.5) clones each plugin into `/opt/ai-sandbox/plugins/<name>/` and pins to the optional sha for reproducibility.

The installer also generates `/usr/local/bin/claude` — a 5-line wrapper that exec's the real Claude CLI with one `--plugin-dir /opt/ai-sandbox/plugins/<name>` flag pre-pended per baked plugin. Because `/usr/local/bin` precedes `/usr/bin` and Node global-install paths on Debian, the wrapper transparently shadows the npm-installed `claude` for interactive shells, the VS Code extension, and any other caller.

User-installed plugins via the `/plugin install foo` slash command continue to write to `~/.claude/plugins/` (the per-project bind-mount with auto-persist defaults) and are loaded by Claude's default scan. The baked set and the per-project set coexist; baked plugins always load, user-installed ones persist per-project.

To add a baked plugin: append a line to `claude-plugins.txt` and rebuild. The installer reads the file at build time only — no runtime re-scan. To remove or change a sha, same flow: edit the file, rebuild.

`OpenSpec` is a separate concern. It's an npm CLI (`@fission-ai/openspec`) installed globally in the same Dockerfile layer. It is NOT a Claude plugin — it provides its own slash commands once a user runs `openspec init` inside a project (which writes files into the project tree). Don't conflate it with the plugin baking machinery.
```

- [ ] **Step 5.3: Verify the insertion**

```bash
grep -n "^### " CLAUDE.md
```
Expected: the `### Baked Claude plugins` heading appears between `### Image tagging` and `### Managed settings (the security-critical bit)`.

- [ ] **Step 5.4: Commit**

```bash
git add CLAUDE.md
git status   # confirm only CLAUDE.md staged
git commit -m "$(cat <<'EOF'
CLAUDE.md: document the baked-plugin wrapper architecture

New 'Baked Claude plugins' subsection under Architecture explains
the claude-plugins.txt -> install script -> /usr/local/bin/claude
wrapper chain, the precedence of the wrapper over the npm-installed
binary, and the coexistence of baked plugins with user-installed
ones in ~/.claude/plugins/. Notes that OpenSpec is a separate npm
CLI, not a Claude plugin.
EOF
)"
```

Verify no Claude attribution.

---

## Task 6: Final sanity sweep

Run the spec's full Testing matrix against the merged result, surface the interactive gates.

**Files:** none modified in this task.

- [ ] **Step 6.1: Shellcheck all shell sources**

```bash
shellcheck run.sh dev.sh entrypoint.sh container-hooks/*.sh scripts/install-claude-plugins.sh
```
Expected: clean across the board (pre-existing SC1091 info notes about `.env` sourcing in `run.sh`/`dev.sh` are OK — they were present on `main` before this branch).

- [ ] **Step 6.2: Clean rebuild from scratch**

```bash
docker image rm ai-sandbox:latest 2>/dev/null || true
./run.sh --build 2>&1 | tail -10
```
Expected: "Built ai-sandbox:latest successfully."

- [ ] **Step 6.3: Walk through spec testing items 1-6 (non-interactive)**

In sequence, run:

```bash
# Item 1: shellcheck (already done in 6.1)
# Item 2: rebuild (already done in 6.2)

# Item 3: plugin presence
docker run --rm ai-sandbox:latest ls /opt/ai-sandbox/plugins/superpowers/.claude-plugin/plugin.json
docker run --rm ai-sandbox:latest cat /opt/ai-sandbox/plugins/superpowers/.installed-sha

# Item 4: OpenSpec installed
docker run --rm ai-sandbox:latest openspec --version

# Item 5: wrapper shadows real binary
docker run --rm ai-sandbox:latest which claude
docker run --rm ai-sandbox:latest head -10 /usr/local/bin/claude

# Item 6: real claude still launches
docker run --rm ai-sandbox:latest claude --version
```

Each should produce the expected output documented in the spec. Any failure: bisect against the per-task commits.

- [ ] **Step 6.4: Branch summary**

```bash
git log --oneline main..HEAD
git diff main --stat
```
Expected: 5 commits (Tasks 1, 2, 3, 4, 5) plus the pre-existing spec commit on the branch = 6 total. Stat should show:
- `claude-plugins.txt` (new)
- `scripts/install-claude-plugins.sh` (new)
- `Dockerfile` (+6 lines)
- `README.md` (~+10 lines)
- `CLAUDE.md` (~+8 lines)
- `docs/superpowers/specs/2026-05-13-bake-claude-plugins-and-openspec-design.md` (the existing spec commit from brainstorming)

- [ ] **Step 6.5: Surface interactive gates for the user**

The remaining spec testing items (7 and 8) require an interactive Claude session inside the container, which a subagent cannot drive. Hand off to the user with this exact wording in the final report:

> Two interactive gates remain. Please run:
>
> **Gate A — Spec item 7 (baked plugin actually loads):**
> ```
> ./run.sh ~/some-project
> # Inside the container:
> claude
> # At the Claude prompt try a superpowers slash command:
> /superpowers:brainstorming
> ```
> Expected: the brainstorming skill activates (Claude responds following the skill's instructions). If it errors out with "unknown skill" or similar, the `--plugin-dir` injection didn't work.
>
> **Gate B — Spec item 8 (coexistence with user-installed):**
> Still inside that container, at the Claude prompt: `/plugin install github@claude-plugins-official` (or any other small marketplace plugin). After install completes, run `/plugin list` and confirm BOTH the baked `superpowers` plugin AND the newly-installed one are present. Exit, restart with the same project path, run `/plugin list` again — the user-installed one should still be there (persisted via the auto-persist bind-mount), and `superpowers` should still be there (re-injected by the wrapper every launch).

- [ ] **Step 6.6: Hand off**

Branch is ready for the user to review and merge. Per the operating rules, do NOT run `git push` or `gh pr create` — report completion and stop.

---

## Risk register

| Risk | Mitigation | Where addressed |
|------|------------|-----------------|
| Real `claude` binary path resolves differently across Node setups | `command -v claude` + `readlink -f` at build time bakes the absolute resolved path into the wrapper | Step 2.2 |
| Plugin source repo lacks a `.claude-plugin/plugin.json` | Sanity check accepts any of `.claude-plugin/plugin.json`, `skills/`, `commands/`, `agents/`, `hooks/`; fails build with clear message otherwise | Step 2.2 |
| `--plugin-dir` flag changes behavior in a future Claude CLI version | The flag is publicly documented and the install script bakes a known-good Claude version (pinned via `CLAUDE_VERSION` build arg). If a Claude upgrade breaks it, downgrade temporarily and re-pin. | Spec risks section |
| User passes `--plugin-dir` themselves at runtime, conflicting with the wrapper | `--plugin-dir` is documented as stackable; the wrapper's flags appear BEFORE `"$@"`, so user flags append additively. No conflict. | Architecture |
| OpenSpec's npm install adds network dependency to build | Pre-existing for every other npm/apt/cargo install in Dockerfile. No new failure mode. | Spec risks |
| Build cache invalidation: editing `claude-plugins.txt` invalidates Layer 7.5 | Intentional — that layer SHOULD rebuild when the plugin list changes. Slow apt/Go/Rust layers above stay cached. | Architecture |
