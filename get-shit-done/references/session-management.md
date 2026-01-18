# Session Management

Prevents concurrent GSD execution on the same phase across multiple Claude sessions.

## Session File

Location: `.planning/ACTIVE-SESSIONS.json`

```json
{
  "sessions": [
    {
      "id": "03-1737123456",
      "phase": "03",
      "started": "2026-01-17T10:30:00Z",
      "last_activity": "2026-01-17T10:45:00Z",
      "status": "executing"
    }
  ]
}
```

## Session ID Format

`{phase}-{unix_timestamp}`

Examples:
- `03-1737123456` — Phase 3, started at timestamp
- `02.1-1737123456` — Inserted phase 2.1

## Session Lifecycle

### 1. Registration (Start of execute-phase)

```bash
# Generate session ID
PHASE="03"
TIMESTAMP=$(date +%s)
SESSION_ID="${PHASE}-${TIMESTAMP}"

# Create file if missing
if [ ! -f .planning/ACTIVE-SESSIONS.json ]; then
  echo '{"sessions":[]}' > .planning/ACTIVE-SESSIONS.json
fi

# Add session entry
jq --arg id "$SESSION_ID" \
   --arg phase "$PHASE" \
   --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.sessions += [{
     "id": $id,
     "phase": $phase,
     "started": $started,
     "last_activity": $started,
     "status": "executing"
   }]' .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
   && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
```

### 2. Conflict Detection

Before registration, check for existing sessions on same phase:

```bash
CONFLICTS=$(jq -r --arg phase "$PHASE" \
  '.sessions[] | select(.phase == $phase) | .id' \
  .planning/ACTIVE-SESSIONS.json 2>/dev/null)
```

If conflicts found, present to user with options.

### 3. Conflict Resolution

User chooses one of:
1. **Continue anyway** — Register this session, may cause git conflicts
2. **Wait** — Exit without execution, check back later
3. **Claim phase** — Remove old session, register this one (use if old session is stale)

### 4. Heartbeat (Between waves)

Update `last_activity` after each wave completes:

```bash
jq --arg id "$SESSION_ID" \
   --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '(.sessions[] | select(.id == $id)).last_activity = $now' \
   .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
   && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
```

### 5. Cleanup (Completion or exit)

Remove session entry when execution completes:

```bash
jq --arg id "$SESSION_ID" \
   '.sessions = [.sessions[] | select(.id != $id)]' \
   .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
   && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
```

## Stale Session Detection

Sessions older than 4 hours are considered stale:

```bash
NOW=$(date +%s)
FOUR_HOURS=14400

jq --argjson now "$NOW" --argjson ttl "$FOUR_HOURS" '
  .sessions = [.sessions[] | select(
    ($now - (.started | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) < $ttl
  )]
' .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
  && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
```

Run this at session start to auto-clean stale entries.

## Environment Variable

After registration, export the session ID for cleanup hooks:

```bash
export GSD_SESSION_ID="$SESSION_ID"
```

The stop hook uses this to clean up on session exit.

## Hook Integration

### Session Start (hooks/session-start.sh)

Optional hook that runs on Claude session start:
- Creates ACTIVE-SESSIONS.json if missing
- Cleans stale sessions
- Shows warning if active sessions exist

### Session Stop (hooks/session-stop.sh)

Runs on Claude session exit:
- Reads `GSD_SESSION_ID` from environment
- Removes session entry from ACTIVE-SESSIONS.json
- Silent operation (no output)

## Disabling Session Safety

Add to `.planning/config.json`:

```json
{
  "session_safety": false
}
```

When disabled, skip all session checks and registration.
