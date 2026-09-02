#!/bin/bash
# SessionStart hook: injects the list scripts
# so the assistant already knows what's in flight, instead of re-creating them from scratch.

INDEX_FILE="./requests/_scripts.md"

if [ -f "$INDEX_FILE" ]; then
  CONTEXT=$(cat "$INDEX_FILE")
else
  CONTEXT="No active IT Assistant scripts yet."
fi

ESCAPED=$(printf '%s' "$CONTEXT" | jq -Rs .)

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ESCAPED
  }
}
EOF
