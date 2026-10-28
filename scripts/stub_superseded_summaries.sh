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
# ❗ Stub first, minimize only when nothing is open. Minimizing a review also hides its threads on
# the Conversation tab, so minimizing one with an unresolved finding drops that finding off the
# page. A stub leaves every thread where it was.
set -uo pipefail # no -e: every failure has to reach a warning and exit 0, not abort mid-way

if [ $# -ne 4 ]; then
  echo "usage: $0 <owner/repo> <pr> <body-marker> <label>" >&2
  exit 0
fi
REPO="$1" PR="$2" MARKER="$3" LABEL="$4"
# Keep in sync with the `superseded-summary` filters in `.claude/commands/improve-reviewer-bots.md`,
# which keep stubs out of the prose metrics. It also makes a stubbed review skip every later run.
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
# A stub links the summary that was newest when it was written, so an old one may point at a later
# stub. That's deliberate: re-pointing every stub each run would push the original text deeper into
# the edit history.
# Process substitution, not a pipe, so the loop runs in this shell rather than a subshell.
while IFS= read -r r; do
  id=$(jq -r '.id' <<<"${r}")
  if jq -n --argjson r "${r}" --arg label "${LABEL}" --arg url "${newest_url}" --arg stub "${STUB_MARKER}" \
       '{body: ("\($label) Superseded by a [newer summary](\($url)). The original is under *edited* above.\n\n"
                + (([$r.body | scan("<!--[\\s\\S]*?-->")] + [$stub]) | join("\n")) + "\n")}' \
     | gh api "repos/${REPO}/pulls/${PR}/reviews/${id}" -X PUT --input - >/dev/null; then
    echo "📝 Stubbed ${LABEL} summary ${id}, newest is ${newest_url}"
  else
    echo "::warning title=Superseded summaries::Could not stub ${LABEL} summary ${id}, so it stays expanded."
  fi
done < <(jq -c --arg stub "${STUB_MARKER}" '.[:-1][] | select(.body | contains($stub) | not) | {id, body}' <<<"${mine}")

# A superseded summary whose threads are all resolved collapses to one line: minimizing hides only
# that review's own threads, and none of them is open. Re-checked every run, because a thread can
# be unresolved later. Then the review is expanded again, or an open finding would sit hidden.
# A thread belongs to the review of its first comment; replies are other reviews and don't move it.
superseded=$(jq -c '[.[:-1][].id]' <<<"${mine}")
if [ "${superseded}" = "[]" ]; then exit 0; fi
# shellcheck disable=SC2016 # $o/$r/$n are GraphQL variables, not shell ones
if ! state=$(gh api graphql -F o="${REPO%/*}" -F r="${REPO#*/}" -F n="${PR}" -f query='
    query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $n) {
      reviews(first: 100) { pageInfo { hasNextPage } nodes { id databaseId isMinimized } }
      reviewThreads(first: 100) { pageInfo { hasNextPage }
        nodes { isResolved comments(first: 1) { nodes { pullRequestReview { databaseId } } } } } } } }'); then
  echo "::warning title=Superseded summaries::Could not read thread state on #${PR}, so no ${LABEL} summary was collapsed or expanded."
  exit 0
fi
# A page cap would hide threads, and a hidden open thread reads as "all resolved". Skip instead.
if [ "$(jq '.data.repository.pullRequest | .reviews.pageInfo.hasNextPage or .reviewThreads.pageInfo.hasNextPage' <<<"${state}")" != "false" ]; then
  echo "::notice title=Superseded summaries::#${PR} has over 100 reviews or threads, so ${LABEL} summaries are only stubbed, never collapsed."
  exit 0
fi
while read -r action node id; do
  classifier=""
  if [ "${action}" = minimize ]; then classifier=", classifier: OUTDATED"; fi
  # `\$id` stays literal for GraphQL; `${action}` picks minimizeComment or unminimizeComment.
  if gh api graphql -F id="${node}" -f query="mutation(\$id: ID!) {
       ${action}Comment(input: {subjectId: \$id${classifier}}) { clientMutationId } }" >/dev/null; then
    echo "🗜️ ${action}d ${LABEL} summary ${id}"
  else
    echo "::warning title=Superseded summaries::Could not ${action} ${LABEL} summary ${id}."
  fi
done < <(jq -r --argjson ids "${superseded}" '.data.repository.pullRequest
    | ([.reviewThreads.nodes[] | select(.isResolved | not) | .comments.nodes[0].pullRequestReview.databaseId]) as $open
    | .reviews.nodes[] | select(.databaseId as $d | $ids | index($d))
    | (.databaseId as $d | $open | index($d)) as $has_open
    | if   $has_open == null and (.isMinimized | not) then "minimize \(.id) \(.databaseId)"
      elif $has_open != null and .isMinimized        then "unminimize \(.id) \(.databaseId)"
      else empty end' <<<"${state}")

exit 0
