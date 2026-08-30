#!/bin/bash
# SessionStart hook: injects the list of active IT Assistant work items
# (requests/projects/issues) so the assistant already knows what's in
# flight, instead of needing to be told to go check.

INDEX_FILE="./requests/_index.md"

if [ -f "$INDEX_FILE" ]; then
  CONTEXT=$(cat "$INDEX_FILE")
else
  CONTEXT="No active IT Assistant work items yet."
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
