#!/bin/bash
# Block Claude from accessing credential/secret files (container version)

FILE_PATH=$(jq -r '.tool_input.file_path // .tool_input.command // ""' < /dev/stdin)

BLOCKED_PATTERNS=(
  ".env"
  ".env.*"
  "*.pem"
  "*.key"
  "credentials.json"
  "secrets/"
  ".aws/"
  ".ssh/"
  "*.tfvars"
  ".terraform.d/"
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  case "$FILE_PATH" in
    *"$pattern"*)
      jq -n '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": "Blocked: access to credential/secret files is not allowed"
        }
      }'
      exit 0
      ;;
  esac
done

exit 0
