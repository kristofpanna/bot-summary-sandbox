#!/usr/bin/env bash
# Shrink every older summary review one AI reviewer posted on a PR to a one-line stub linking to
# its newest, so the Conversation tab shows one current summary per reviewer instead of one per
# round. Run right after a reviewer posts: scripts/ai_code_review.sh (LP reviewer) and
# .github/workflows/claude-review.yml (red-panda), each passing its own body marker.
#
# Usage: scripts/stub_superseded_summaries.sh <owner/repo> <pr> <body-marker> <label>
# Needs GH_TOKEN with `pull-requests: write`.
#
# Always exits 0. This is cosmetic, so a failure must never fail the review job: it becomes a
# ::warning:: and the old summary simply stays expanded.
#
# ❗ Edit, never minimize. Minimizing a review also hides its still-open threads on the
# Conversation tab, so an unresolved finding would drop off the page. A stub leaves every thread
# where it was.
set -uo pipefail # no -e: every failure has to reach a warning and exit 0, not abort mid-way

if [ $# -ne 4 ]; then
  echo "usage: $0 <owner/repo> <pr> <body-marker> <label>" >&2
  exit 0
fi
REPO="$1" PR="$2" MARKER="$3" LABEL="$4"
STUB_MARKER='<!-- superseded-summary -->'

# `--paginate` prints one JSON array per page, so `jq -s add` merges them before anything is
# selected; filtering per page would pick a "newest" from the last page only.
if ! reviews=$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews?per_page=100" | jq -s 'add // []'); then
  echo "::warning title=Superseded summaries::Could not list the reviews on #${PR}, so older ${LABEL} summaries stay expanded."
  exit 0
fi

# ❗ Only reviews github-actions[bot] wrote: that is the identity this token posts and edits as,
# and a write-scoped token may be able to edit a human's review that happens to quote the marker.
# If a reviewer moves to another identity (a GitHub App), this matches nothing and the old
# summaries stay expanded. That fails toward noise, never toward lost text.
mine=$(jq -c --arg m "${MARKER}" '[.[] | select(.user.login == "github-actions[bot]"
          and .state != "PENDING" and ((.body // "") | contains($m)))] | sort_by(.submitted_at)' <<<"${reviews}")
newest_url=$(jq -r 'last | .html_url // empty' <<<"${mine}")
if [ -z "${newest_url}" ]; then
  echo "No ${LABEL} summary on #${PR}, so there is nothing to stub."
  exit 0
fi

# Every HTML comment in the old body is carried into the stub. The reviewer marker keeps
# `/improve-reviewer-bots` counting the run, and the LP reviewer's `ai-review-run` JSON is that
# run's only record of what it emitted. The prose stays readable in GitHub's edit history.
# Process substitution, not a pipe, so the loop runs in this shell rather than a subshell.
while IFS= read -r r; do
  id=$(jq -r '.id' <<<"${r}")
  if jq -n --argjson r "${r}" --arg label "${LABEL}" --arg url "${newest_url}" --arg stub "${STUB_MARKER}" \
       '{body: ("\($label) Superseded by the [newer summary](\($url)). The original is under *edited* above.\n\n"
                + (([$r.body | scan("<!--[\\s\\S]*?-->")] + [$stub]) | join("\n")) + "\n")}' \
     | gh api "repos/${REPO}/pulls/${PR}/reviews/${id}" -X PUT --input - >/dev/null; then
    echo "📝 Stubbed ${LABEL} summary ${id}, newest is ${newest_url}"
  else
    echo "::warning title=Superseded summaries::Could not stub ${LABEL} summary ${id}, so it stays expanded."
  fi
done < <(jq -c --arg stub "${STUB_MARKER}" '.[:-1][] | select(.body | contains($stub) | not) | {id, body}' <<<"${mine}")

exit 0
