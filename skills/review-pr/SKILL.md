---
name: review-pr
description: Use when asked to review a GitHub PR for correctness, performance, or maintainability. Requires a PR URL as argument and gh CLI authenticated.
---

# PR Review

End-to-end PR review across three dimensions: business correctness, performance, and maintainability. Findings are posted as inline GitHub comments grouped by severity.

## Prerequisites

Before any review work, verify:

```bash
gh auth status          # must be authenticated
gh pr view <PR_URL>     # must succeed
```

If either fails, stop and tell the user to run `gh auth login` or verify the PR URL.

## Input

The PR URL is required and comes from the skill args (e.g., `/review-pr https://github.com/org/repo/pull/123`).

## Baseline Context to Load

If `review_context.md` exists in the workspace root, read it first — it contains pre-extracted context
(CLAUDE.md, domain invariants filtered to affected domains, repository interfaces, touched entity files,
and testspecs). Reading this one file replaces 10-15 individual file-read turns.

```
Read review_context.md
```

If `review_context.md` is absent (local run), load context manually:
1. `CLAUDE.md` — already in context
2. `docs/invariants/` — affected domains only (glob `docs/invariants/*.md`, filter to domains in the diff)
3. `docs/testspecs/` — affected domains only (glob `docs/testspecs/**/*.md`, skip if none) — **Agent 1 only**

Then fetch the PR:

```bash
gh pr view <PR_URL> --json title,body,baseRefName,headRefName,files
gh pr diff <PR_URL>
```

If the diff is large (>500 lines), read it in chunks using `offset`/`limit` on the saved file.

## Phase 1 — Structured Analysis (3 dimensions, single pass)

> **Why single pass?** In GitHub Actions, the `Agent` tool is unavailable — parallel sub-agents are not possible. A single structured pass with 3 labeled sections produces identical findings at ~40% of the turn cost.

**Read `docs/review-dimensions.md` now.** It is the SSOT for Section 1–3 focus areas, severity definitions, and dedup rules. Apply them exactly.

Analyse the full PR diff in one pass, completing each section fully before moving to the next.

**Context available:**
- Full PR diff (from `gh pr diff`)
- Domain invariants and CLAUDE.md rules (from `review_context.md` or loaded in Baseline Context)
- Testspecs (from `review_context.md` — used in Section 1 only)

## Phase 2 — Deduplication

Apply dedup rules from `docs/review-dimensions.md`. Then assign severity per the severity table in that file.

> **Automated mode:** When the prompt begins with `AUTOMATED MODE:`, skip Phase 2.5
> (Human Approval Gate) only — **do not skip Phase 2 (Deduplication)**. Deduplication
> must still run.
> This is used by `.github/workflows/claude-pr-review.yml`. In that context,
> `REVIEWER_LOGIN` is `claude[bot]`.

## Phase 2.5 — Human Approval Gate

After deduplication, present the findings summary to the user **before posting anything to GitHub**.

Format the summary as a table:

| Severity | File | Line | Summary |
|----------|------|------|---------|
| Critical | `path/to/file.go` | 42 | One-line description |
| ... | | | |

Then ask:

> "Found N findings (X critical, Y high, Z medium, W low). Post all as inline GitHub comments?"

**Wait for explicit approval before proceeding.**

- If approved: proceed to Phase 3 without asking again for each individual comment.
- If rejected or user asks to skip/edit: stop or adjust per their instructions.

## Phase 3 — Post to GitHub

**Step 1 — General PR comment (header only):**

The general comment contains ONLY the header line — no findings, no bullet list of issues.

```bash
gh pr comment <PR_URL> --body "$(cat <<'EOF'
## PR Review

Reviewing against: CLAUDE.md, docs/invariants/, and testspecs.
Three dimensions: business correctness · performance · maintainability.
Findings are inline below, ordered Critical → High → Medium → Low.
EOF
)"
```

**Step 2 — Batch all findings in a single API call:**

First, get the commit SHA:
```bash
gh pr view <PR_URL> --json headRefOid --jq '.headRefOid'
```

Build a JSON payload with all findings and post in **one** `gh api` call using `POST /pulls/{pr}/reviews`. This minimizes turns and keeps conversation history short.

**Always write the full payload to a temp file using a quoted heredoc (`<< 'JSONEOF'`), then post with `--input`.** Do NOT use `jq -n --argjson` with shell variables — comment bodies contain backticks, double-quoted strings, and newlines that corrupt JSON when interpolated through shell variables.

```bash
# Write the complete JSON payload to a temp file.
# Use a QUOTED heredoc marker ('JSONEOF') so the shell does not expand $ inside the body.
cat > /tmp/pr_review_payload.json << 'JSONEOF'
{
  "commit_id": "<headRefOid>",
  "event": "COMMENT",
  "body": "",
  "comments": [
    {
      "path": "<file path in diff>",
      "line": <right-side line number>,
      "body": "[SEVERITY] <finding body>"
    }
  ]
}
JSONEOF

gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews \
  --method POST \
  --input /tmp/pr_review_payload.json
```

> **Why batch?** Each individual `gh api` call is a separate agent turn added to the rolling conversation history. Posting 10 findings individually = 10 turns × growing history ≈ 50K extra input tokens. One batch call = 1 turn.

> **Retrievability:** Comments posted via the batch review API are returned by `GET /pulls/{pr}/comments` — identical to individually-posted comments. The `/re-review` skill can fetch and classify them without any changes.

Use the **right-side** (new file) line number. If the finding is on a deleted line, use the nearest surviving line.

Every comment MUST have a specific line number — never omit `line` or post at the file level. For findings that span multiple lines (e.g. N+1 loops, missing batch calls, unbounded scans), anchor to the **first line of the problematic construct** — the loop opening, the function call, or the first statement of the pattern.

Comment body format:
```
[CRITICAL] <1-sentence summary>

<2-3 sentences explaining the specific risk or violation. Reference the invariant or rule by name if applicable.>

**Suggested fix:** <1-2 sentences max — what to do and why, no more>
```go
// Before (if showing a diff):
<current code, concise>

// After:
<fixed code, concise>
```
```

Rules for the suggested fix:
- 1-2 sentences of prose is allowed — just enough to orient the reader before the code
- Always follow with a fenced code block with language tag (e.g. ` ```go `)
- Show a before/after diff when the change is a direct replacement
- Show only the after when the change is purely additive
- Keep blocks concise — no more than ~15 lines total; omit unchanged surrounding code
- Use `...` to elide irrelevant lines
- The code block is the primary communication — prose is context, not explanation
- **Before writing any suggested fix that modifies a function call, read the actual function signature** from the relevant interface file to confirm argument types, argument count, and positions. A suggested fix with wrong argument types or positions will fail the build and waste an autofix run. If you cannot read the signature, omit the code block and describe the intent in prose only.

## Phase 4 — Emit Verdict

After all inline comments are posted, read current thread state, post the verdict as a final PR comment, then output it to the conversation.

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

MEDIUM and LOW threads do not block the verdict. On a fresh review, nearly all threads will be unresolved — the verdict will typically be NEEDS FIX.

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
- X CRITICAL/HIGH threads posted
- Y MEDIUM/LOW threads (do not block merge)

### Next Action
[NEEDS FIX]
- **On GitHub:** Comment `/autofix` (fixes MEDIUM+LOW by default) or `/autofix SEVERITY,...` (e.g. `/autofix CRITICAL,MEDIUM` or `/autofix ALL`) to auto-fix findings at specific severities
- **Local (Claude Code):** Run `/receiving-pr-review <PR_URL>` to work through CRITICAL/HIGH comments interactively
[NEEDS HUMAN DISCUSSION] → Share the listed comment links with your team for alignment
[SAFE TO MERGE]          → All blocking issues resolved. Ready to merge.
EOF
)"
```

**Step 2 — Output the same verdict to the conversation** (copy exactly from the posted comment).

---

## Severity Ordering

Post Critical findings first, then High, Medium, Low. Within each severity, order by file path alphabetically.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Posting comment on wrong commit SHA | Always fetch `headRefOid` fresh from `gh pr view` |
| Duplicate inline comments from different sections | Deduplicate by (file, line) in Phase 2 before posting |
| Putting all findings in the `gh pr comment` body instead of inline | Summary only goes in `gh pr comment`; findings go in the `comments` array of the batch `POST .../pulls/{pr}/reviews` call |
| Posting findings one-by-one with separate `gh api` calls | Use one batch `POST .../pulls/{pr}/reviews` call with all findings in the `comments` array — one turn regardless of finding count |
| Skipping deduplication (Phase 2) in AUTOMATED MODE | Only Phase 2.5 (Human Approval Gate) is skipped in automated mode — deduplication always runs |
| Reporting subscriber Ack/Nack behavior as a bug when it's intentional | Check test file for the subscriber to confirm intent |
| Over-flagging single-use helpers as Low when they have meaningful complexity | Only flag truly trivial pass-throughs |
| Using `--body "...\n..."` for multi-line comments | Bash never expands `\n` inside double-quoted strings — GitHub stores literal backslash-n and renders the body as one line. Always use a heredoc: `--body "$(cat <<'EOF' ... EOF)"` |
| Posting comments without waiting for approval | Always present the findings table and wait for explicit human approval before any `gh api` or `gh pr comment` call — **unless the prompt specifies AUTOMATED MODE** |
| Building JSON via `jq -n --argjson` with shell-variable comment bodies | Comment bodies contain backticks, double quotes, and newlines that break shell variable interpolation and corrupt the JSON (HTTP 400). Always write the full payload to a temp file with a quoted heredoc (`cat > /tmp/pr_review_payload.json << 'JSONEOF' ... JSONEOF`) and post with `--input /tmp/pr_review_payload.json` |
| Making a test/dry-run API call with placeholder content before posting real findings | Never call `gh api .../reviews` or `gh pr review` with placeholder data (e.g. `[MEDIUM] test`). Build the complete JSON payload in the temp file first, inspect it locally with `cat /tmp/pr_review_payload.json`, then post once. A test call creates a real GitHub comment that cannot be automatically cleaned up. |
