#!/bin/bash
# PreToolUse hook: flags destructive/irreversible commands for confirmation
# instead of letting the agent run them silently. Edit the pattern list
# below to match the operations you care most about.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

if [ "$TOOL_NAME" = "runTerminalCommand" ] || [ "$TOOL_NAME" = "terminal" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

  if echo "$COMMAND" | grep -qEi '(rm[[:space:]]+-rf[[:space:]]+/|dd[[:space:]]+if=.*of=/dev/|mkfs\.|DROP[[:space:]]+TABLE|DELETE[[:space:]]+FROM[[:space:]]+\w+[[:space:]]*;|iptables[[:space:]]+-F|shutdown[[:space:]]+-h|reboot\b|:\(\)\{.*\};:)'; then
    echo '{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"This command looks destructive or hard to reverse. Confirm before running it."}}'
    exit 0
  fi
fi

echo '{"continue":true}'
