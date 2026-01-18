---
name: gsd:audit-plan
description: Audit plan quality before execution
argument-hint: "[path-to-plan.md | phase-number]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

<objective>
Audit plan(s) for quality issues that could cause execution failures.

This is NOT just a linter - it's a comprehensive review that evaluates whether the plan will actually work when executed by gsd-executor.

**What it checks:**
1. Structural completeness (required fields, valid frontmatter)
2. Action specificity (no vague patterns)
3. Verification executability
4. Project idiom compliance (references existing patterns)
5. Dependency correctness (no circular deps, valid waves)
6. Scope reasonableness (task count, context budget)

**Output:** Report with issues grouped by severity + before/after suggestions.
</objective>

<execution_context>
@~/.claude/get-shit-done/references/ui-brand.md
</execution_context>

<context>
$ARGUMENTS — Path to PLAN.md file OR phase number

If path provided: audit that specific plan
If phase number: audit all plans in that phase
If nothing: audit most recent unexecuted plan

@.planning/STATE.md
@.planning/ROADMAP.md
</context>

<process>

## 1. Find Plan(s) to Audit

**If path provided:**
```bash
[ -f "$ARGUMENTS" ] && echo "Found: $ARGUMENTS"
```

**If phase number provided:**
```bash
PHASE=$(printf "%02d" $ARGUMENTS 2>/dev/null || echo "$ARGUMENTS")
ls .planning/phases/${PHASE}-*/*-PLAN.md 2>/dev/null
```

**If nothing provided:**
```bash
# Find most recent plan without a SUMMARY
for plan in $(ls -t .planning/phases/*/*-PLAN.md 2>/dev/null); do
  summary="${plan%-PLAN.md}-SUMMARY.md"
  [ ! -f "$summary" ] && echo "$plan" && break
done
```

Build list of plan files to audit.

## 2. Structural Checks

For each plan file:

### 2a. Frontmatter Validation

Check required frontmatter fields:
```bash
grep -E "^wave:|^depends_on:|^files_modified:|^autonomous:" "$PLAN_FILE"
```

**Required fields:**
- `wave:` — integer for parallel grouping
- `depends_on:` — list or empty
- `files_modified:` — list of file paths
- `autonomous:` — true/false

**Issues:**
- Missing field → BLOCKER
- Invalid value → WARNING

### 2b. Task Structure Validation

Each task must have:
```xml
<task name="...">
  <files>...</files>
  <action>...</action>
  <verify>...</verify>
  <done>...</done>
</task>
```

Search for incomplete tasks:
```bash
# Count tasks vs complete structures
TASK_COUNT=$(grep -c '<task name=' "$PLAN_FILE")
FILES_COUNT=$(grep -c '<files>' "$PLAN_FILE")
ACTION_COUNT=$(grep -c '<action>' "$PLAN_FILE")
VERIFY_COUNT=$(grep -c '<verify>' "$PLAN_FILE")
DONE_COUNT=$(grep -c '<done>' "$PLAN_FILE")
```

**If counts don't match:** List which tasks are incomplete → BLOCKER

### 2c. must_haves Section

```bash
grep -A20 '<must_haves>' "$PLAN_FILE"
```

**If missing or empty:** → WARNING (verification won't know what to check)

## 3. Action Specificity Checks

Scan for vague patterns that cause executor confusion:

**Vague action patterns (WARNING):**
```bash
grep -iE "set up|handle|proper|appropriate|as needed|accordingly|similar to|like the other|best practices" "$PLAN_FILE"
```

| Vague Pattern | Problem | Suggest |
|---------------|---------|---------|
| "Set up the infrastructure" | What infrastructure? | Specify exact files/components |
| "Handle edge cases" | Which cases? | List specific cases |
| "Add proper error handling" | What errors? How handled? | Name errors and handlers |
| "Use best practices" | Which practices? | Reference specific pattern/file |
| "Similar to the other X" | Which X? | Reference exact file path |

**For each vague pattern found:**
- Extract context (surrounding lines)
- Suggest specific replacement from codebase

## 4. Verification Executability

For each `<verify>` block:

**Check if command is executable:**
```bash
# Extract verify commands
grep -A5 '<verify>' "$PLAN_FILE" | grep -E "^\s*(npm|yarn|pnpm|bun|python|pytest|cargo|go|swift|xcodebuild|git|ls|cat|grep)"
```

**Issues:**
- No executable command → WARNING ("Tests pass" is not executable)
- Command references non-existent file → WARNING
- Command has syntax errors → WARNING

**Verify patterns that need fixing:**
| Bad | Good |
|-----|------|
| "Tests pass" | `npm test -- --grep "feature"` |
| "It works correctly" | `curl localhost:3000/api/health` |
| "Build succeeds" | `npm run build 2>&1 | tail -5` |

## 5. Project Idiom Checks

**Only if codebase docs exist** (`.planning/codebase/` directory):

### 5a. Pattern References

For tasks creating new code, check if they reference existing patterns:

```bash
# Find "Create" or "Add" actions
grep -B2 -A10 '<action>' "$PLAN_FILE" | grep -iE "create|add|implement|build"
```

**For each creation task:**
- Does action mention existing file to follow? ("like src/services/UserService.ts")
- Does action specify conventions? ("use @Observable", "follow Theme colors")

**If no pattern reference:** → INFO
Suggest: "Reference existing pattern: [find similar file]"

### 5b. Technology Choices

Check for explicit technology decisions:

```bash
grep -iE "use|install|add|import" "$PLAN_FILE" | grep -v "node_modules"
```

**If ambiguous:** (e.g., "add authentication" without specifying library) → WARNING

## 6. Dependency Checks

### 6a. Circular Dependencies

```bash
# Extract depends_on from each plan
for plan in $PLANS; do
  name=$(basename "$plan" -PLAN.md)
  deps=$(grep "depends_on:" "$plan" | sed 's/depends_on://')
  echo "$name: $deps"
done
```

Build dependency graph and check for cycles → BLOCKER if found

### 6b. Wave Assignment

```bash
# Verify wave assignments match dependencies
for plan in $PLANS; do
  wave=$(grep "wave:" "$plan" | awk '{print $2}')
  deps=$(grep "depends_on:" "$plan")
  # Check that deps have lower wave numbers
done
```

**If dependency has higher wave:** → BLOCKER (will execute out of order)

### 6c. File Conflicts

```bash
# Check for same file modified by parallel tasks
grep -h "files_modified:" $PLANS | sort | uniq -d
```

**If same file in multiple parallel plans:** → WARNING (potential conflicts)

## 7. Scope Checks

### 7a. Task Count

```bash
TASK_COUNT=$(grep -c '<task name=' "$PLAN_FILE")
```

| Count | Status |
|-------|--------|
| 1-3 | OK |
| 4 | WARNING ("Consider splitting") |
| 5+ | BLOCKER ("Too many tasks - split into multiple plans") |

### 7b. Context Budget

Estimate context usage based on:
- Number of files in `<files>` sections
- Size of referenced context files
- Complexity of actions

**If estimated > 50% context:** → WARNING ("May run out of context")

## 8. Present Findings

Output report in this format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 GSD ► PLAN AUDIT REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Plans audited:** {N}

## Summary

| Category | Issues | Status |
|----------|--------|--------|
| Structural | {n} | ✓/⚠/✗ |
| Specificity | {n} | ✓/⚠/✗ |
| Verification | {n} | ✓/⚠/✗ |
| Dependencies | {n} | ✓/⚠/✗ |
| Scope | {n} | ✓/⚠/✗ |

**Overall:** {READY | NEEDS FIXES | BLOCKED}

---

## Issues Found

### ✗ BLOCKER: {issue title}

**Location:** {plan file}:{line number}
**Problem:** {what's wrong}

**Current:**
```xml
{current content}
```

**Suggested fix:**
```xml
{improved content}
```

**Why:** {explanation}

---

### ⚠ WARNING: {issue title}

**Location:** {plan file}:{line number}
**Problem:** {what's wrong}
**Suggestion:** {how to fix}

---

### ℹ INFO: {issue title}

**Suggestion:** {optional improvement}

---

## Context Recommendations

Consider adding these files to plan context:
- `@src/services/ExampleService.ts` — Similar service pattern
- `@src/tests/example.test.ts` — Test pattern to follow

---

## Next Steps

{If BLOCKED:}
Fix blockers before execution. Run audit again after fixes.

{If NEEDS FIXES:}
Warnings won't prevent execution but may cause issues.
- Fix warnings, OR
- Proceed with `/gsd:execute-phase` (warnings documented)

{If READY:}
Plan is ready for execution.
/gsd:execute-phase {phase}
```

</process>

<offer_next>
Based on audit result:

**If READY:**
```
Plan audit passed. Ready for execution.

/gsd:execute-phase {phase}
```

**If NEEDS FIXES:**
```
Plan has warnings. Options:

1. Fix warnings first (recommended)
2. Execute anyway — /gsd:execute-phase {phase}
3. Re-audit after fixes — /gsd:audit-plan {path}
```

**If BLOCKED:**
```
Plan has blockers that will cause execution failures.

Fix blockers first, then re-run:
/gsd:audit-plan {path}
```
</offer_next>

<success_criteria>
- [ ] Plan(s) found based on arguments
- [ ] All structural checks completed
- [ ] Vague patterns identified with suggestions
- [ ] Verification commands validated
- [ ] Dependencies checked for cycles
- [ ] Scope assessed for reasonableness
- [ ] Report presented with severity levels
- [ ] Specific before/after suggestions provided
- [ ] Next steps clear based on audit result
</success_criteria>
