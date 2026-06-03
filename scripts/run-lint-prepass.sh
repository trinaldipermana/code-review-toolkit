#!/usr/bin/env bash
# run-lint-prepass.sh
#
# Runs golangci-lint scoped to the PR diff (--new-from-rev=origin/main).
# On lint findings: posts a PR comment, sets GITHUB_OUTPUT comment_posted=true,
#   and exits non-zero — blocking the Claude review.
# On infrastructure error (install failure, etc.): exits non-zero WITHOUT
#   setting comment_posted, so the action.yml catch step posts a generic error.
# On success: appends a clean summary to review_context.md and exits 0.
#
# Usage:
#   run-lint-prepass.sh <PR_NUMBER> <REPO>
#
# Environment:
#   GH_TOKEN        — required for posting PR comments
#   GITHUB_OUTPUT   — set by GitHub Actions; used to signal comment_posted

set -euo pipefail

PR_NUMBER="${1:?Usage: run-lint-prepass.sh <PR_NUMBER> <REPO>}"
REPO="${2:?Usage: run-lint-prepass.sh <PR_NUMBER> <REPO>}"

LINTERS="errcheck,staticcheck,gosec,ineffassign,gocyclo"

# ── Skip if not a Go project ─────────────────────────────────────────────────
if [ ! -f "go.mod" ]; then
  echo "==> No go.mod found — skipping linter pre-pass"
  {
    echo ""
    echo "## Prior static analysis findings (golangci-lint)"
    echo ""
    echo "_Skipped — not a Go project._"
    echo ""
    echo "---"
    echo ""
  } >> review_context.md
  exit 0
fi

# ── Fetch origin/main so --new-from-rev has a valid baseline ─────────────────
echo "==> Fetching origin/main for diff baseline..."
git fetch origin main --depth=1 2>/dev/null || true

# ── Install golangci-lint if not present ─────────────────────────────────────
if ! command -v golangci-lint &>/dev/null; then
  echo "==> Installing golangci-lint v2.11.4..."
  curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
    | sh -s -- -b /usr/local/bin v2.11.4
fi

# ── Run lint ─────────────────────────────────────────────────────────────────
echo "==> Running golangci-lint (linters: ${LINTERS})..."
set +e
LINT_OUTPUT=$(golangci-lint run \
  --new-from-rev=origin/main \
  --enable-only "${LINTERS}" \
  2>&1 | head -100)
LINT_EXIT=$?
set -e

# ── Findings: post comment, signal comment_posted, block ─────────────────────
if [ "$LINT_EXIT" -ne 0 ] && [ -n "$LINT_OUTPUT" ]; then
  echo "==> Lint failures found (exit ${LINT_EXIT}). Posting PR comment and blocking review."

  BODY_FILE=$(mktemp)

  cat > "$BODY_FILE" <<'BODY'
## ❌ AI Review Blocked — Fix Lint Failures First

`golangci-lint` found issues in your changes. Fix them and push again to trigger the AI review.

BODY

  printf '```\n%s\n```\n' "$LINT_OUTPUT" >> "$BODY_FILE"

  cat >> "$BODY_FILE" <<BODY

**Linters checked:** \`errcheck\` · \`staticcheck\` · \`gosec\` · \`ineffassign\` · \`gocyclo\`

Run locally to reproduce:
\`\`\`bash
golangci-lint run --new-from-rev=origin/main --enable-only ${LINTERS}
\`\`\`
BODY

  gh pr comment "$PR_NUMBER" \
    --repo "$REPO" \
    --body "$(cat "$BODY_FILE")"

  rm -f "$BODY_FILE"

  # Signal to action.yml that this script already posted a comment.
  # The catch step checks this output to avoid a duplicate comment.
  echo "comment_posted=true" >> "${GITHUB_OUTPUT:-/dev/null}"

  exit 1
fi

# ── Clean pass: append summary to review_context.md ─────────────────────────
echo "==> Lint pre-pass clean. Appending to review_context.md."
{
  echo ""
  echo "## Prior static analysis findings (golangci-lint)"
  echo ""
  echo "_No issues found by \`golangci-lint\` (linters: \`${LINTERS}\`). Do not re-flag these categories as new findings._"
  echo ""
  echo "---"
  echo ""
} >> review_context.md
