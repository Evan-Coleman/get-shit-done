#!/bin/bash
# Stop hook - clean up current session on Claude exit

SESSIONS_FILE="$CLAUDE_PROJECT_DIR/.planning/ACTIVE-SESSIONS.json"

# Get current session ID from environment (set by execute-phase)
SESSION_ID="${GSD_SESSION_ID:-}"

# If no session ID or file, nothing to clean
if [ -z "$SESSION_ID" ] || [ ! -f "$SESSIONS_FILE" ]; then
    exit 0
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    exit 0
fi

# Remove this session from the file
jq --arg id "$SESSION_ID" \
   '.sessions = [.sessions[] | select(.id != $id)]' \
   "$SESSIONS_FILE" > "${SESSIONS_FILE}.tmp" 2>/dev/null \
   && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"

# Silent exit - no output for stop hooks
exit 0
