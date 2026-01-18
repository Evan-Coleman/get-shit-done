---
name: gsd:execute-phase
description: Execute all plans in a phase with wave-based parallelization
argument-hint: "<phase-number> [--gaps-only]"
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - Task
  - TodoWrite
  - AskUserQuestion
---

<objective>
Execute all plans in a phase using wave-based parallel execution.

Orchestrator stays lean: discover plans, analyze dependencies, group into waves, spawn subagents, collect results. Each subagent loads the full execute-plan context and handles its own plan.

Context budget: ~15% orchestrator, 100% fresh per subagent.
</objective>

<execution_context>
@~/.claude/get-shit-done/references/ui-brand.md
@~/.claude/get-shit-done/workflows/execute-phase.md
</execution_context>

<context>
Phase: $ARGUMENTS

**Flags:**
- `--gaps-only` — Execute only gap closure plans (plans with `gap_closure: true` in frontmatter). Use after verify-work creates fix plans.

@.planning/ROADMAP.md
@.planning/STATE.md
</context>

<process>

## 0. Session Safety Pre-flight Checks

Reference: `@~/.claude/get-shit-done/references/session-management.md`

**Check if session safety is enabled:**
```bash
SESSION_SAFETY=$(cat .planning/config.json 2>/dev/null | grep -o '"session_safety":[^,}]*' | cut -d':' -f2 | tr -d ' ')
```

**If `session_safety` is explicitly `false`:** Skip all session checks, proceed to step 0b.

**Otherwise (default ON):**

### 0a. Initialize Session File & Clean Stale Sessions

```bash
# Create file if missing
if [ ! -f .planning/ACTIVE-SESSIONS.json ]; then
  echo '{"sessions":[]}' > .planning/ACTIVE-SESSIONS.json
fi

# Clean stale sessions (>4 hours old)
NOW=$(date +%s)
FOUR_HOURS=14400
jq --argjson now "$NOW" --argjson ttl "$FOUR_HOURS" '
  .sessions = [.sessions[] | select(
    ($now - (.started | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) < $ttl
  )]
' .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
  && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
```

### 0a.1. Check for Conflicts

```bash
# PHASE is the target phase (normalized in step 1)
CONFLICTS=$(jq -r --arg phase "$PHASE" \
  '.sessions[] | select(.phase == $phase)' \
  .planning/ACTIVE-SESSIONS.json 2>/dev/null)
```

**If conflict found:**
```
╔══════════════════════════════════════════════════════════════╗
║  CHECKPOINT: Session Conflict                                ║
╚══════════════════════════════════════════════════════════════╝

Another session is working on Phase {X}:
- Session ID: {id}
- Started: {timestamp}
- Last activity: {timestamp}

──────────────────────────────────────────────────────────────
→ Select: continue / wait / claim
──────────────────────────────────────────────────────────────
```

Handle response:
- **continue** — Proceed with registration (may cause git conflicts)
- **wait** — Exit gracefully, user will try later
- **claim** — Remove old session entry, then register this one

### 0a.2. Register This Session

```bash
# Generate session ID
TIMESTAMP=$(date +%s)
SESSION_ID="${PHASE}-${TIMESTAMP}"

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

# Export for stop hook cleanup
export GSD_SESSION_ID="$SESSION_ID"
```

Display: `Session registered: ${SESSION_ID}`

### 0b. Context Resume Detection

**If conversation contains summary of prior work** (context was compacted):
```
⚠️ Context Resume Detected

This session was continued from a previous conversation.
Prior context has been compacted into a summary.

For complex plans (5+ tasks): Recommend starting fresh session.

Continue here? (y/n)
```

If user says no, provide command to restart fresh:
```
Run: /clear then /gsd:execute-phase {X}
```

### 0c. Previous Progress Check

```bash
ls .planning/phases/${PHASE}-*/*-PROGRESS.md 2>/dev/null
ls .planning/phases/${PHASE}-*/*-SUMMARY.md 2>/dev/null
```

**If PROGRESS.md exists:** Resume from last checkpoint (read PROGRESS.md for state)

**If SUMMARY.md exists (and no PROGRESS.md):**
```
Phase {X} appears complete. Re-run?
1. Yes, re-execute all plans
2. No, show me the summary
3. Only run incomplete plans
```

**If neither exists:** Fresh execution, proceed to step 1.

---

1. **Validate phase exists**
   - Find phase directory matching argument
   - Count PLAN.md files
   - Error if no plans found

2. **Discover plans**
   - List all *-PLAN.md files in phase directory
   - Check which have *-SUMMARY.md (already complete)
   - If `--gaps-only`: filter to only plans with `gap_closure: true`
   - Build list of incomplete plans

3. **Group by wave**
   - Read `wave` from each plan's frontmatter
   - Group plans by wave number
   - Report wave structure to user

4. **Execute waves**
   For each wave in order:
   - Spawn `gsd-executor` for each plan in wave (parallel Task calls)
   - Wait for completion (Task blocks)
   - Verify SUMMARYs created
   - **Update session heartbeat** (if session safety enabled):
     ```bash
     jq --arg id "$GSD_SESSION_ID" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '(.sessions[] | select(.id == $id)).last_activity = $now' \
        .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
        && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
     ```
   - Proceed to next wave

5. **Aggregate results**
   - Collect summaries from all plans
   - Report phase completion status

6. **Commit any orchestrator corrections**
   Check for uncommitted changes before verification:
   ```bash
   git status --porcelain
   ```

   **If changes exist:** Orchestrator made corrections between executor completions. Commit them:
   ```bash
   git add -u && git commit -m "fix({phase}): orchestrator corrections"
   ```

   **If clean:** Continue to verification.

7. **Verify phase goal**
   - Spawn `gsd-verifier` subagent with phase directory and goal
   - Verifier checks must_haves against actual codebase (not SUMMARY claims)
   - Creates VERIFICATION.md with detailed report
   - Route by status:
     - `passed` → continue to step 8
     - `human_needed` → present items, get approval or feedback
     - `gaps_found` → present gaps, offer `/gsd:plan-phase {X} --gaps`

8. **Update roadmap and state**
   - Update ROADMAP.md, STATE.md

9. **Update requirements**
   Mark phase requirements as Complete:
   - Read ROADMAP.md, find this phase's `Requirements:` line (e.g., "AUTH-01, AUTH-02")
   - Read REQUIREMENTS.md traceability table
   - For each REQ-ID in this phase: change Status from "Pending" to "Complete"
   - Write updated REQUIREMENTS.md
   - Skip if: REQUIREMENTS.md doesn't exist, or phase has no Requirements line

10. **Commit phase completion**
    Bundle all phase metadata updates in one commit:
    - Stage: `git add .planning/ROADMAP.md .planning/STATE.md`
    - Stage REQUIREMENTS.md if updated: `git add .planning/REQUIREMENTS.md`
    - Commit: `docs({phase}): complete {phase-name} phase`

11. **Clean up session** (if session safety enabled)
    ```bash
    jq --arg id "$GSD_SESSION_ID" \
       '.sessions = [.sessions[] | select(.id != $id)]' \
       .planning/ACTIVE-SESSIONS.json > .planning/ACTIVE-SESSIONS.json.tmp \
       && mv .planning/ACTIVE-SESSIONS.json.tmp .planning/ACTIVE-SESSIONS.json
    ```

12. **Offer next steps**
    - Route to next action (see `<offer_next>`)
</process>

<offer_next>
Output this markdown directly (not as a code block). Route based on status:

| Status | Route |
|--------|-------|
| `gaps_found` | Route C (gap closure) |
| `human_needed` | Present checklist, then re-route based on approval |
| `passed` + more phases | Route A (next phase) |
| `passed` + last phase | Route B (milestone complete) |

---

**Route A: Phase verified, more phases remain**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 GSD ► PHASE {Z} COMPLETE ✓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Phase {Z}: {Name}**

{Y} plans executed
Goal verified ✓

───────────────────────────────────────────────────────────────

## ▶ Next Up

**Phase {Z+1}: {Name}** — {Goal from ROADMAP.md}

/gsd:discuss-phase {Z+1} — gather context and clarify approach

<sub>/clear first → fresh context window</sub>

───────────────────────────────────────────────────────────────

**Also available:**
- /gsd:plan-phase {Z+1} — skip discussion, plan directly
- /gsd:verify-work {Z} — manual acceptance testing before continuing

───────────────────────────────────────────────────────────────

---

**Route B: Phase verified, milestone complete**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 GSD ► MILESTONE COMPLETE 🎉
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**v1.0**

{N} phases completed
All phase goals verified ✓

───────────────────────────────────────────────────────────────

## ▶ Next Up

**Audit milestone** — verify requirements, cross-phase integration, E2E flows

/gsd:audit-milestone

<sub>/clear first → fresh context window</sub>

───────────────────────────────────────────────────────────────

**Also available:**
- /gsd:verify-work — manual acceptance testing
- /gsd:complete-milestone — skip audit, archive directly

───────────────────────────────────────────────────────────────

---

**Route C: Gaps found — need additional planning**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 GSD ► PHASE {Z} GAPS FOUND ⚠
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Phase {Z}: {Name}**

Score: {N}/{M} must-haves verified
Report: .planning/phases/{phase_dir}/{phase}-VERIFICATION.md

### What's Missing

{Extract gap summaries from VERIFICATION.md}

───────────────────────────────────────────────────────────────

## ▶ Next Up

**Plan gap closure** — create additional plans to complete the phase

/gsd:plan-phase {Z} --gaps

<sub>/clear first → fresh context window</sub>

───────────────────────────────────────────────────────────────

**Also available:**
- cat .planning/phases/{phase_dir}/{phase}-VERIFICATION.md — see full report
- /gsd:verify-work {Z} — manual testing before planning

───────────────────────────────────────────────────────────────

---

After user runs /gsd:plan-phase {Z} --gaps:
1. Planner reads VERIFICATION.md gaps
2. Creates plans 04, 05, etc. to close gaps
3. User runs /gsd:execute-phase {Z} again
4. Execute-phase runs incomplete plans (04, 05...)
5. Verifier runs again → loop until passed
</offer_next>

<wave_execution>
**Parallel spawning:**

Spawn all plans in a wave with a single message containing multiple Task calls:

```
Task(prompt="Execute plan at {plan_01_path}\n\nPlan: @{plan_01_path}\nProject state: @.planning/STATE.md", subagent_type="gsd-executor")
Task(prompt="Execute plan at {plan_02_path}\n\nPlan: @{plan_02_path}\nProject state: @.planning/STATE.md", subagent_type="gsd-executor")
Task(prompt="Execute plan at {plan_03_path}\n\nPlan: @{plan_03_path}\nProject state: @.planning/STATE.md", subagent_type="gsd-executor")
```

All three run in parallel. Task tool blocks until all complete.

**No polling.** No background agents. No TaskOutput loops.
</wave_execution>

<checkpoint_handling>
Plans with `autonomous: false` have checkpoints. The execute-phase.md workflow handles the full checkpoint flow:
- Subagent pauses at checkpoint, returns structured state
- Orchestrator presents to user, collects response
- Spawns fresh continuation agent (not resume)

See `@~/.claude/get-shit-done/workflows/execute-phase.md` step `checkpoint_handling` for complete details.
</checkpoint_handling>

<deviation_rules>
During execution, handle discoveries automatically:

1. **Auto-fix bugs** - Fix immediately, document in Summary
2. **Auto-add critical** - Security/correctness gaps, add and document
3. **Auto-fix blockers** - Can't proceed without fix, do it and document
4. **Ask about architectural** - Major structural changes, stop and ask user

Only rule 4 requires user intervention.
</deviation_rules>

<commit_rules>
**Per-Task Commits:**

After each task completes:
1. Stage only files modified by that task
2. Commit with format: `{type}({phase}-{plan}): {task-name}`
3. Types: feat, fix, test, refactor, perf, chore
4. Record commit hash for SUMMARY.md

**Plan Metadata Commit:**

After all tasks in a plan complete:
1. Stage plan artifacts only: PLAN.md, SUMMARY.md
2. Commit with format: `docs({phase}-{plan}): complete [plan-name] plan`
3. NO code files (already committed per-task)

**Phase Completion Commit:**

After all plans in phase complete (step 7):
1. Stage: ROADMAP.md, STATE.md, REQUIREMENTS.md (if updated), VERIFICATION.md
2. Commit with format: `docs({phase}): complete {phase-name} phase`
3. Bundles all phase-level state updates in one commit

**NEVER use:**
- `git add .`
- `git add -A`
- `git add src/` or any broad directory

**Always stage files individually.**
</commit_rules>

<success_criteria>
- [ ] All incomplete plans in phase executed
- [ ] Each plan has SUMMARY.md
- [ ] Phase goal verified (must_haves checked against codebase)
- [ ] VERIFICATION.md created in phase directory
- [ ] STATE.md reflects phase completion
- [ ] ROADMAP.md updated
- [ ] REQUIREMENTS.md updated (phase requirements marked Complete)
- [ ] User informed of next steps
</success_criteria>
