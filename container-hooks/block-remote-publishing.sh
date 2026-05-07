#!/usr/bin/env bash
# block-remote-publishing.sh
#
# Container PreToolUse hook. Blocks AI Bash commands that affect remote state:
#   - `git push` (any variant)
#   - `git remote add` / `git remote set-url` (could redirect a push)
#   - `gh pr create|merge|comment`, `gh issue create|comment`,
#     `gh release create`, `gh repo create|delete`
#
# Rationale: the container is otherwise an isolated sandbox — no host secrets
# are reachable, project files are intentionally visible. The one set of
# operations that escapes the sandbox is publishing to remotes (push / PR /
# release / issue). This hook keeps the AI from doing those without explicit
# user action; the user runs them themselves.
#
# All the previous file-pattern blocks (.env, *.pem, ~/.gnupg, etc.) and
# system-path write blocks were removed because they protected against
# threats that don't exist in container isolation, while creating friction
# for normal Claude Code operations (writing plans, memory, settings).
set -u

input="$(cat)"

if ! tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"block-remote-publishing: failed to parse hook input"}}'
  exit 0
fi

[ "$tool_name" = "Bash" ] || exit 0

bash_command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -z "$bash_command" ] && exit 0

emit_deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

stripped="${bash_command#"${bash_command%%[![:space:]]*}"}"
case "$stripped" in
  "git push"*|"git remote add"*|"git remote set-url"*)
    emit_deny "Blocked: git push and remote modifications are not allowed in ai-sandbox"
    ;;
  "gh pr create"*|"gh pr merge"*|"gh pr comment"*|"gh issue create"*|"gh issue comment"*|"gh release create"*|"gh repo create"*|"gh repo delete"*)
    emit_deny "Blocked: publishing to GitHub is not allowed in ai-sandbox"
    ;;
esac

exit 0
