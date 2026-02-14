#!/bin/bash
set -euo pipefail

# PostToolUse hook: after a Bash call, check if a git commit just landed
# that touched structural files without updating Architecture.md.

# Read hook input (tool info via stdin)
input=$(cat 2>/dev/null || true)

# Extract the command from the JSON tool input — only act on actual git commit commands
command=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || true)

if ! echo "$command" | grep -qE 'git commit'; then
  exit 0
fi

# Check the last commit for structural changes
structural=$(git diff --name-only HEAD~1..HEAD 2>/dev/null | grep -cE '\.swift$|^Package\.swift$' || true)
arch=$(git diff --name-only HEAD~1..HEAD 2>/dev/null | grep -c 'Architecture\.md' || true)

if [ "$structural" -gt 0 ] && [ "$arch" -eq 0 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Structural Swift files were modified in this commit but Architecture.md was not updated. If these changes affect the documented architecture (new components, changed protocols, modified state machine, new files), update Architecture.md to reflect them."}}'
fi

exit 0
