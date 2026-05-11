---
name: re-review-pr
description: Use when asked to re-review a GitHub PR that already has prior reviewer comments, to check which comments were resolved by new commits, post resolution replies, and run a scoped review on only the new diff.
---

# PR Re-Review

Follow-up PR review after an author has pushed new commits in response to prior feedback. Covers three steps: (1) classify prior reviewer comments as resolved or still-open and reply to each thread, (2) run a fresh scoped review on only the new commits' diff, and (3) present new findings to the human for approval before posting.

## Prerequisites

```bash
gh auth status          # must be authenticated
gh pr view <PR_URL>     # must succeed
```

If either fails, stop and tell the user to run `gh auth login` or verify the PR URL.

## Input

The PR URL is required and comes from the skill args (e.g., `/re-review-pr https://github.com/org/repo/pull/123`).

---

## Phase 0 — Identity & Boundaries

Get the reviewer's GitHub login:
```bash
gh api user --jq '.login'
```
Store as `REVIEWER_LOGIN`. Parse `owner`, `repo`, `pr_number` from the PR URL.

---

## Phase 1 — Load Baseline Context

If `review_context.md` exists in the workspace root, read it first — it contains pre-extracted context
(CLAUDE.md, domain invariants filtered to affected domains, repository interfaces, touched entity files,
and testspecs). Reading this one file replaces 10-15 individual file-read turns.

```
Read review_context.md
```

If `review_context.md` is absent (local run), load context manually:
1. `CLAUDE.md` — already in context
2. `docs/invariants/` — affected domains only (glob `docs/invariants/*.md`, filter to domains in the diff)
3. `docs/testspecs/` — affected domains only — **Agent 1 in Phase 5 only**

Fetch PR metadata:
```bash
gh pr view <PR_URL> --json title,body,baseRefName,headRefName,files,headRefOid
```

---

## Phase 2 — Reconstruct Prior Review State

**Step 2.1** — Fetch all prior inline comments by the reviewer:
```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  --paginate \
  --jq "[.[] | select(.user.login == \"$REVIEWER_LOGIN\")]"
```
→ If empty: **stop.** Tell the user this PR has no prior reviewer comments — use `review-pr` instead.

**Step 2.2** — Find the SHA the last review was posted against:
```
last_reviewed_sha = max(reviewer_comments, key=created_at).commit_id
```

**Step 2.3** — Compare against current head:
- `HEAD_SHA` = `headRefOid` from Phase 1
- If `last_reviewed_sha == HEAD_SHA`: **stop.** Report "no changes since last review — head is still `<HEAD_SHA[:7]>`."

> **Why SHA, not timestamps?** Force-pushes replace commits with ones that carry their original author dates. A rebased commit pushed after the review will have `author.date < last_review_ts` even though the branch genuinely changed. SHA comparison is always correct: same SHA = nothing new, different SHA = something changed.

**Step 2.4** — Determine diff boundaries:

Fetch all PR commits and filter to those not reachable from `last_reviewed_sha` (commits new since the last review), sorted ascending:
```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/commits
```
- `BASE_SHA` = parent of the oldest new commit:
  ```bash
  gh api repos/{owner}/{repo}/commits/{oldest_new_sha} --jq '.parents[0].sha'
  ```
- `HEAD_SHA` = `headRefOid` from Phase 1 (already set in Step 2.3)

**Step 2.5** — Fetch the scoped diff:
```bash
gh api repos/{owner}/{repo}/compare/{BASE_SHA}...{HEAD_SHA} \
  -H "Accept: application/vnd.github.diff"
```
Save to a temp file if >500 lines; read in chunks with `offset`/`limit`.

**Step 2.6** — Fetch PR author login (needed to identify author replies):
```bash
gh api repos/{owner}/{repo}/pulls/{pr_number} --jq '.user.login'
```
Store as `PR_AUTHOR_LOGIN`.

---

## Phase 3 — Categorize Prior Comments

For each prior reviewer comment, classify using **semantic verification** — read the actual current file and check whether the specific issue still exists.

**Step 3.0 — Identify which files actually changed (skip unnecessary reads):**

Extract the list of changed files and their changed line ranges from the scoped diff (Phase 2.5):

```bash
gh api repos/{owner}/{repo}/compare/{BASE_SHA}...{HEAD_SHA} \
  --jq '[.files[] | {filename: .filename, patch: .patch}]'
```

For each prior reviewer comment at `(path, line)`:
- If `path` does **not** appear in the changed files list → classify as **STILL_OPEN** immediately, no file read needed. Unchanged code means the issue was not addressed.
- If `path` appears in changed files but the changed hunks are all more than 10 lines away from `comment.line` → classify as **STILL_OPEN** immediately. A hunk far from the finding location cannot have fixed the issue.
- If `path` appears in changed files and a hunk overlaps within 10 lines of `comment.line` → proceed to Step 3.1 (read the file and verify semantically).

> This skip rule eliminates 60-80% of file reads on typical re-reviews where most prior findings were not yet addressed by the author.

**Step 3.1** — For each comment where a hunk overlaps within 10 lines, read the current file at `path` using the Read tool.

Classify as:

- **RESOLVED** — the specific issue described in the comment is no longer present in the current code at that location. The fix must address the root problem: e.g. an N+1 loop is now batched, a missing pagination field is now set, dead code is removed. A nearby change that does not fix the root problem does NOT qualify.
- **RESOLVED** (file gone) — the file was deleted or renamed in the diff.
- **STILL_OPEN** — the issue described in the comment is still present in the current file, regardless of whether nearby lines changed.

> **Do not use positional heuristics alone** — if you do read the file (hunk within 10 lines), verify semantically that the root problem is actually fixed, not just that lines changed nearby.

**Step 3.2** — Fetch all PR comments in one call and filter in-memory (do NOT call the API once per comment):
```bash
ALL_COMMENTS=$(gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  --paginate \
  --jq "[.[] | {id: .id, in_reply_to_id: .in_reply_to_id, user: .user.login, body: .body}]")
```

For each STILL_OPEN comment, filter `ALL_COMMENTS` in-memory:
```
author_replies = [c for c in ALL_COMMENTS if c.in_reply_to_id == comment_id and c.user == PR_AUTHOR_LOGIN]
```

Evaluate the author's reply (if any):
- **STILL_OPEN / unaddressed** — no author reply, or the reply does not meaningfully justify the non-fix (e.g., "will fix later" with no linked issue, or a reply that does not resolve the core concern).
- **STILL_OPEN / acknowledged** — author replied with a valid justification: deferred to a separate PR/issue, intentional design decision with a given reason, or confirmed working-as-intended with rationale. Accept the reasoning and note it.

Build a summary table before posting anything:

| Prior Comment (1-line summary) | File | Line | Classification | Reason |
|---|---|---|---|---|
| [CRITICAL] Missing audit field... | service/ad.go | 42 | RESOLVED | `created_by` field now set on line 58 |
| [HIGH] N+1 in loop... | repo/ad.go | 87 | STILL_OPEN / unaddressed | Loop still calls DB per item; no author reply |
| [MEDIUM] Missing index... | db/ad.go | 12 | STILL_OPEN / acknowledged | Author replied: "deferred to SAP-999" |

**Present this table to the human.** State:

> "Ready to post resolution replies to the threads above. Reply YES to proceed, NO to abort, or correct any misclassifications."

> **Automated mode:** When the prompt specifies `AUTOMATED MODE:`, skip this gate and
> proceed automatically with the classification as computed. Used by
> `.github/workflows/claude-pr-re-review.yml`.

**Wait for explicit YES before posting anything.**

---

## Phase 4 — Post Resolution Replies + Resolve Threads (after approval)

**Step 4.0 — Fetch thread node IDs**

GitHub's resolve-thread action requires GraphQL thread node IDs, not comment database IDs. Fetch them now and build a map of `commentDatabaseId → threadNodeId`:

```bash
gh api graphql -f query='
{
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr_number}) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              databaseId
            }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes | map({threadId: .id, isResolved: .isResolved, firstCommentId: .comments.nodes[0].databaseId})'
```

Match each reviewer comment ID to its thread node ID.

**Step 4.1 — Post all replies in one pass, then batch-resolve**

> **Why batch?** Posting replies one-by-one adds N turns to the rolling conversation history. Collect all reply bodies first, then execute them together.

**Batch all reply comments in a single script execution:**

Compose all reply bodies upfront (one per thread), then post them in a single bash execution:

```bash
# Post all replies in one script — one gh api call per thread, but all in one turn
{
  # RESOLVED threads
  gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
    --method POST \
    --field body="Resolved in the latest commits — thanks for addressing this." \
    --field in_reply_to=<comment_id_1>

  # STILL_OPEN / acknowledged threads
  gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
    --method POST \
    --field body="Acknowledged — <brief restatement of the author's justification>. Will track under that linked item." \
    --field in_reply_to=<comment_id_2>

  # STILL_OPEN / unaddressed threads
  gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
    --method POST \
    --field body="[SEVERITY] Still unresolved — <1-sentence reason why new commits don't address this>.

<1-2 sentences: the problem, the invariant/rule violated, why current code is still wrong.>

**Suggested fix:**
\`\`\`go
// Before:
<current code, concise>

// After:
<fixed code, concise>
\`\`\`" \
    --field in_reply_to=<comment_id_3>
}
```

**Batch-resolve all RESOLVED threads in one GraphQL call:**

```bash
# One mutation per resolved thread, all in one gh api call
gh api graphql -f query='mutation {
  t1: resolveReviewThread(input: {threadId: "<threadNodeId_1>"}) { thread { isResolved } }
  t2: resolveReviewThread(input: {threadId: "<threadNodeId_2>"}) { thread { isResolved } }
}'
```

Rules for STILL_OPEN reply suggested fixes:
- Always include a fenced code block with language tag (e.g. ` ```go `)
- Show before/after when the change is a direct replacement; show only after for purely additive changes
- Keep blocks under ~15 lines total; use `...` to elide irrelevant lines
- Code block is the primary communication — keep prose brief
- **Before writing any suggested fix that modifies a function call, read the actual function signature** from the relevant interface file to confirm argument types, argument count, and positions. A fix with wrong argument types will fail an autofix build. If you cannot read the signature, omit the code block and describe the intent in prose only.

Verify each `resolveReviewThread` response returns `"isResolved": true` before moving to Phase 5.

---

## Phase 5 — Fresh Review on New Diff Only

> **Why single pass?** In GitHub Actions, the `Agent` tool is unavailable — parallel sub-agents are not possible. A single structured pass with 3 labeled sections produces identical findings at ~40% of the turn cost.

**Read `docs/review-dimensions.md` now.** It is the SSOT for Section 1–3 focus areas, severity definitions, and dedup rules. Apply them exactly.

Analyse the scoped diff (`BASE_SHA...HEAD_SHA`) in one pass, completing each section fully before moving to the next.

**Scope constraint:** Review ONLY the diff between `{BASE_SHA}` and `{HEAD_SHA}`. Do not report issues in unchanged code. Do not re-raise issues already in prior reviewer comments unless new commits introduce a regression.

**Context available:**
- Scoped diff from Phase 2.5
- Domain invariants and CLAUDE.md rules (from `review_context.md` or loaded in Phase 1)
- Prior reviewer comments list (to avoid duplicates)
- Testspecs (from `review_context.md` — Section 1 only)

---

## Phase 6 — Deduplication

Apply dedup rules from `docs/review-dimensions.md`, then:
- **Explicitly discard** any finding that duplicates a `STILL_OPEN` prior comment — it was already posted
- Assign severity per the severity table in `docs/review-dimensions.md`

---

## Phase 7 — Human Approval Gate for New Findings

Present findings as a table:

| Severity | File | Line | Summary |
|---|---|---|---|
| Critical | service/ad.go | 91 | Missing `deleted_by` on bulk delete |
| High | repo/campaign.go | 44 | N+1 DB call in new pagination loop |

State: "Found N new findings (X critical, Y high, Z medium, W low). Post all as inline GitHub comments?"

**Wait for explicit approval.** If NO: stop. If YES: proceed to Phase 8.

> **Automated mode:** When the prompt specifies `AUTOMATED MODE:`, skip this gate and
> post all new findings immediately. Used by `.github/workflows/claude-pr-re-review.yml`.

---

## Phase 8 — Post Approved New Findings

**Step 8.1** — Re-fetch `headRefOid` immediately before posting:
```bash
gh pr view <PR_URL> --json headRefOid --jq '.headRefOid'
```
If it differs from `HEAD_SHA` in Phase 2.4, warn the user (PR was force-pushed) and ask to confirm before continuing.

**Step 8.2** — General PR comment (header only — no findings in the body):
```bash
gh pr comment <PR_URL> --body "$(cat <<'EOF'
## Re-Review (new commits since last review)

Reviewing commits from `{BASE_SHA_SHORT}` to `{HEAD_SHA_SHORT}`.
Three dimensions: business correctness · performance · maintainability.
Prior comment threads have been replied to above. New findings are inline below, ordered Critical → High → Medium → Low.
EOF
)"
```

**Step 8.3** — Batch all new findings in a single API call. Sort Critical → High → Medium → Low; alphabetically by file within each severity.

**Always write the full payload to a temp file using a quoted heredoc (`<< 'JSONEOF'`), then post with `--input`.** Do NOT use `jq -n --argjson` with shell variables — comment bodies contain backticks, double-quoted strings, and newlines that corrupt JSON when interpolated through shell variables.

```bash
cat > /tmp/pr_rereview_payload.json << 'JSONEOF'
{
  "commit_id": "<HEAD_SHA>",
  "event": "COMMENT",
  "body": "",
  "comments": [
    {"path": "<file>", "line": <line>, "body": "[SEVERITY] <finding>"},
    ...
  ]
}
JSONEOF

gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews \
  --method POST \
  --input /tmp/pr_rereview_payload.json
```

> **Why batch?** Each individual `gh api` call is a separate turn adding to rolling history. One batch call = 1 turn regardless of finding count.

### Comment Body Format

```
[HIGH] <1-sentence summary>

<2-3 sentences: specific risk or violation. Reference the invariant or rule by name.>

**Suggested fix:**
```go
// Before:
<current code, concise>

// After:
<fixed code, concise>
```
```

Rules for the suggested fix:
- Always include a fenced code block with language tag (e.g. ` ```go `)
- Show before/after when the change is a direct replacement; show only after for purely additive changes
- Keep blocks under ~15 lines total; use `...` to elide irrelevant lines
- Code block is the primary communication — keep prose brief
- **Before writing any suggested fix that modifies a function call, read the actual function signature** from the relevant interface file to confirm argument types, argument count, and positions. A fix with wrong argument types will fail an autofix build. If you cannot read the signature, omit the code block and describe the intent in prose only.

Use the **right-side** (new file) line number. For deleted lines, use the nearest surviving line.

Every comment MUST have a specific line number — never omit `line` or post at the file level. For findings that span multiple lines (e.g. N+1 loops, missing batch calls, unbounded scans), anchor to the **first line of the problematic construct** — the loop opening, the function call, or the first statement of the pattern.

---

## Phase 9 — Emit Verdict

After all new findings are posted, read the full accumulated thread state, post the verdict as a final PR comment, then output it to the conversation.

```bash
gh api graphql -f query='
{
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr_number}) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 3) {
            nodes {
              databaseId
              body
              path
              originalLine
              url
              author { login }
            }
          }
        }
      }
    }
  }
}'
```

Classify each thread started by `$REVIEWER_LOGIN` with severity CRITICAL or HIGH:

| Thread state | Verdict contribution |
|---|---|
| `isResolved: true` | ✅ Safe |
| Unresolved, no author reply | ❌ NEEDS FIX |
| Unresolved, author replied with valid deferral (linked issue/PR number or sound technical reason) | ✅ Safe (deferred) |
| Unresolved, author replied disputing — no resolution reached | ⚠️ NEEDS HUMAN DISCUSSION |

MEDIUM and LOW threads do not block the verdict.

Determine overall verdict:
- **NEEDS FIX** — any CRITICAL/HIGH thread is unresolved and unaddressed (takes precedence)
- **NEEDS HUMAN DISCUSSION** — any CRITICAL/HIGH thread is disputed, none are unaddressed
- **SAFE TO MERGE** — all CRITICAL/HIGH threads are resolved or validly deferred

**Step 1 — Post verdict as final PR comment.** Always use a heredoc — never `--body "...\n..."` (bash does not expand `\n` in double-quoted strings; GitHub would receive literal backslash-n and render the body as one unformatted line):

```bash
gh pr comment <PR_URL> --body "$(cat <<'EOF'
## PR Verdict: [NEEDS FIX | NEEDS HUMAN DISCUSSION | SAFE TO MERGE]

### Must Fix Before Merge
- [CRITICAL] <1-line summary> — `path/to/file.go:42` — <GitHub comment URL>
- [HIGH] <1-line summary> — `path/to/file.go:87` — <GitHub comment URL>
(omit section if empty)

### Needs Human Discussion
- [CRITICAL] <1-line summary> — `path/to/file.go:91` — <GitHub comment URL>
  Author's position: "<summary of dispute>"
(omit section if empty)

### Progress
- X CRITICAL/HIGH threads resolved ✓ (across all review rounds)
- Y MEDIUM/LOW threads (do not block merge)
- Z threads still open

### Next Action
[NEEDS FIX]
- **On GitHub:** Comment `/autofix` (fixes MEDIUM+LOW by default) or `/autofix SEVERITY,...` (e.g. `/autofix CRITICAL,MEDIUM` or `/autofix ALL`) to auto-fix findings
- **Local (Claude Code):** Run `/receiving-pr-review <PR_URL>` to work through CRITICAL/HIGH comments interactively
[NEEDS HUMAN DISCUSSION] → Share the listed comment links with your team for alignment before proceeding
[SAFE TO MERGE]          → All blocking issues resolved. Ready to merge.
EOF
)"
```

**Step 2 — Output the same verdict to the conversation** (copy exactly from the posted comment).

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Classifying a comment as resolved when only an unrelated hunk in the same file changed | Require the changed hunk overlaps within 10 lines of the comment line (Step 3.0) — file presence alone is not enough |
| Re-posting findings already raised as `STILL_OPEN` prior comments | Phase 6 explicitly discards these |
| Posting resolution replies before the human approves the classification table | Phase 3 approval gate is mandatory — no posting without explicit YES |
| Posting replies or new findings one-by-one with separate `gh api` calls | Batch all replies in one script execution (Phase 4); batch all new findings with one `POST .../pulls/{pr}/reviews` call (Phase 8) — avoids N extra turns of conversation history |
| Using stale `HEAD_SHA` if the PR was force-pushed between phases | Re-fetch `headRefOid` at the top of Phase 8 and compare before posting |
| Skipping Phase 5 because all prior comments are resolved | Always run — new commits may introduce new issues independent of prior findings |
| Putting new findings in the general PR comment body | General comment is header only; all findings go in the `comments` array of the single batch `POST .../pulls/{pr}/reviews` call in Step 8.3 |
| Posting a generic "still applies" reply for STILL_OPEN / unaddressed threads | Always include the specific reason the new commits don't fix it and a suggested code block fix |
| Accepting an author reply of "will fix later" as acknowledged without a linked issue | Only classify as STILL_OPEN / acknowledged when the author provides a concrete deferral target (issue/PR number) or a sound technical justification |
| Using `--body "...\n..."` for multi-line comments | Bash never expands `\n` inside double-quoted strings — GitHub stores literal backslash-n and renders the body as one line. Always use a heredoc: `--body "$(cat <<'EOF' ... EOF)"` |
| Building JSON via `jq -n --argjson` with shell-variable comment bodies | Comment bodies contain backticks, double quotes, and newlines that break shell variable interpolation and corrupt the JSON (HTTP 400). Always write the full payload to a temp file with a quoted heredoc (`cat > /tmp/pr_rereview_payload.json << 'JSONEOF' ... JSONEOF`) and post with `--input /tmp/pr_rereview_payload.json` |
| Making a test/dry-run API call with placeholder content before posting real findings | Never call `gh api .../reviews` with placeholder data (e.g. `[MEDIUM] test`). Build the complete JSON payload in the temp file first, inspect it locally with `cat /tmp/pr_rereview_payload.json`, then post once. A test call creates a real GitHub comment that cannot be automatically cleaned up. |
