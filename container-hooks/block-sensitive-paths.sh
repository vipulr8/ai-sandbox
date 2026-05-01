#!/usr/bin/env bash
# block-sensitive-paths.sh (container version)
#
# Adapted for Linux container environment. Blocks:
#   - Credential paths: ~/.gnupg, ~/.kube, ~/.docker/config.json, ~/.netrc, ~/.npmrc, ~/.pypirc
#   - Writes to system paths: /etc, /usr/lib, /usr/bin, /sbin
#   - Bash commands: sudo
#   - Access outside the project directory

set -u

input="$(cat)"

if ! tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"block-sensitive-paths: failed to parse hook input"}}'
  exit 0
fi

[ -z "$tool_name" ] && exit 0

emit_deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# --- Extract path (file tools) or command (Bash) ---
file_path=""
bash_command=""
case "$tool_name" in
  Read|Edit|Write|Grep|Glob)
    file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')"
    ;;
  Bash)
    bash_command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    ;;
  *)
    exit 0
    ;;
esac

# Expand leading ~/
case "$file_path" in
  "~")    file_path="$HOME" ;;
  "~/"*)  file_path="$HOME/${file_path#\~/}" ;;
esac

# ---------------------------------------------------------------------------
# Policy lists (Linux container paths)
# ---------------------------------------------------------------------------

# Full deny: credential locations
DENY_CRED_PREFIXES=(
  "$HOME/.gnupg/"
  "$HOME/.kube/"
  "$HOME/.docker/config.json"
  "$HOME/.netrc"
  "$HOME/.npmrc"
  "$HOME/.pypirc"
  "$HOME/.claude/"
)

# Deny writes only: system paths (reads OK for debugging)
DENY_WRITE_PREFIXES=(
  "/etc/"
  "/usr/lib/"
  "/usr/bin/"
  "/usr/sbin/"
  "/sbin/"
  "/opt/ai-sandbox/"
)

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

if [ -n "$file_path" ]; then
  for p in "${DENY_CRED_PREFIXES[@]}"; do
    case "$file_path" in
      "$p"*) emit_deny "Blocked: access to '$p' is not allowed" ;;
    esac
  done

  if [ "$tool_name" = "Edit" ] || [ "$tool_name" = "Write" ]; then
    for p in "${DENY_WRITE_PREFIXES[@]}"; do
      case "$file_path" in
        "$p"*) emit_deny "Blocked: writes to system path '$p' are not allowed" ;;
      esac
    done
  fi
fi

if [ -n "$bash_command" ]; then
  stripped="${bash_command#"${bash_command%%[![:space:]]*}"}"
  case "$stripped" in
    "sudo"|"sudo "*)
      emit_deny "Blocked: sudo is not allowed"
      ;;
    "git push"*|"git remote add"*|"git remote set-url"*)
      emit_deny "Blocked: git push and remote modifications are not allowed in ai-sandbox"
      ;;
    "gh pr create"*|"gh pr merge"*|"gh pr comment"*|"gh issue create"*|"gh issue comment"*|"gh release create"*|"gh repo create"*|"gh repo delete"*)
      emit_deny "Blocked: publishing to GitHub is not allowed in ai-sandbox"
      ;;
  esac
fi

exit 0
