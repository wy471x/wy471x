#!/bin/bash
set -euo pipefail

README="README.md"
MERGED_PR_COUNT=12

echo "Fetching contribution data from GitHub API..."

# Helper: retry on rate limit with exponential backoff
gh_graphql() {
  local max_retries=3
  local delay=30

  for i in $(seq 1 $max_retries); do
    local stderr_file
    stderr_file=$(mktemp)
    local exit_code=0

    if gh api graphql "$@" 2>"$stderr_file"; then
      rm -f "$stderr_file"
      return 0
    else
      exit_code=$?
    fi

    if grep -qi "rate limit" "$stderr_file"; then
      rm -f "$stderr_file"
      if [ "$i" -lt "$max_retries" ]; then
        echo "Rate limited. Retry $i/$max_retries in ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))
        continue
      fi
    else
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
    fi

    echo "gh api graphql failed with exit code $exit_code" >&2
    return "$exit_code"
  done
}

# Single GraphQL call: contributions + repo counts + first 100 repos with stars
echo "  → Fetching profile, contribution stats & repo stars..."
RESPONSE=$(gh_graphql -f query='
query {
  user(login: "wy471x") {
    contributionsCollection {
      totalCommitContributions
      totalPullRequestContributions
      totalPullRequestReviewContributions
      totalIssueContributions
      contributionCalendar { totalContributions }
    }
    originalRepos: repositories(first: 1, ownerAffiliations: OWNER, isFork: false) {
      totalCount
    }
    allRepos: repositories(first: 100, ownerAffiliations: OWNER) {
      totalCount
      nodes { stargazerCount }
      pageInfo { endCursor, hasNextPage }
    }
    followers { totalCount }
  }
}
')

TOTAL_CONTRIBUTIONS=$(echo "$RESPONSE" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions')
TOTAL_COMMITS=$(echo "$RESPONSE"     | jq -r '.data.user.contributionsCollection.totalCommitContributions')
TOTAL_PRS=$(echo "$RESPONSE"         | jq -r '.data.user.contributionsCollection.totalPullRequestContributions')
TOTAL_ISSUES=$(echo "$RESPONSE"      | jq -r '.data.user.contributionsCollection.totalIssueContributions')
TOTAL_REVIEWS=$(echo "$RESPONSE"     | jq -r '.data.user.contributionsCollection.totalPullRequestReviewContributions')
ORIGINAL_REPOS=$(echo "$RESPONSE"    | jq -r '.data.user.originalRepos.totalCount')
ALL_REPOS=$(echo "$RESPONSE"         | jq -r '.data.user.allRepos.totalCount')
FOLLOWERS=$(echo "$RESPONSE"         | jq -r '.data.user.followers.totalCount')

FORKED_REPOS=$((ALL_REPOS - ORIGINAL_REPOS))

# Parse stars from first page (already fetched above)
TOTAL_STARS=$(echo "$RESPONSE" | jq -r '[.data.user.allRepos.nodes[].stargazerCount] | add // 0')
HAS_NEXT=$(echo "$RESPONSE"    | jq -r '.data.user.allRepos.pageInfo.hasNextPage')
CURSOR=$(echo "$RESPONSE"      | jq -r '.data.user.allRepos.pageInfo.endCursor')

# Paginate remaining repos if needed (repos > 100)
PAGE=1
while [ "$HAS_NEXT" = "true" ]; do
  PAGE=$((PAGE + 1))
  echo "    Fetching repo stars page $PAGE..."

  REPO_RESPONSE=$(gh_graphql -f query="
  query {
    user(login: \"wy471x\") {
      repositories(first: 100, ownerAffiliations: OWNER, after: \"$CURSOR\") {
        nodes { stargazerCount }
        pageInfo { endCursor, hasNextPage }
      }
    }
  }
  ")

  PAGE_STARS=$(echo "$REPO_RESPONSE" | jq -r '[.data.user.repositories.nodes[].stargazerCount] | add // 0')
  TOTAL_STARS=$((TOTAL_STARS + PAGE_STARS))

  HAS_NEXT=$(echo "$REPO_RESPONSE" | jq -r '.data.user.repositories.pageInfo.hasNextPage')
  CURSOR=$(echo "$REPO_RESPONSE"   | jq -r '.data.user.repositories.pageInfo.endCursor')
done

echo ""
echo "  Contributions:  $TOTAL_CONTRIBUTIONS"
echo "  Commits:        $TOTAL_COMMITS"
echo "  PRs:            $TOTAL_PRS"
echo "  Issues:         $TOTAL_ISSUES"
echo "  Reviews:        $TOTAL_REVIEWS"
echo "  Original repos: $ORIGINAL_REPOS"
echo "  Forked repos:   $FORKED_REPOS"
echo "  Total stars:    $TOTAL_STARS"
echo "  Followers:      $FOLLOWERS"

# Update README (perl for GNU/BSD sed portability)
set_stat() {
  local label="$1"
  local value="$2"
  perl -i -pe "s/\\*\\*[0-9]+\\+?\\*\\* \\Q${label}\\E/**${value}** ${label}/g" "$README"
}

set_stat "total contributions" "$TOTAL_CONTRIBUTIONS"
set_stat "commits"             "$TOTAL_COMMITS"
set_stat "pull requests"       "$TOTAL_PRS"
set_stat "issues"              "$TOTAL_ISSUES"
set_stat "PR review"           "$TOTAL_REVIEWS"
set_stat "original repos"      "$ORIGINAL_REPOS"
set_stat "forked repos"        "${FORKED_REPOS}+"
set_stat "total stars"         "$TOTAL_STARS"
set_stat "followers"           "$FOLLOWERS"

echo ""
echo "  → Fetching recently merged pull requests..."

PR_RESPONSE=$(gh_graphql -f query="
query {
  search(query: \"author:wy471x is:pr is:merged sort:updated-desc\", type: ISSUE, first: $MERGED_PR_COUNT) {
    nodes {
      ... on PullRequest {
        title
        url
        mergedAt
        repository { nameWithOwner stargazerCount }
      }
    }
  }
}
") || PR_RESPONSE=""

PR_TABLE=$(mktemp)
if [ -n "$PR_RESPONSE" ] && echo "$PR_RESPONSE" | jq -e '.data.search' >/dev/null 2>&1; then
  echo "$PR_RESPONSE" | jq -r --argjson n "$MERGED_PR_COUNT" '
    [ .data.search.nodes[]? | select(.url != null and .mergedAt != null) ][0:$n]
    | group_by(.repository.nameWithOwner)
    | map({
        repo: .[0].repository.nameWithOwner,
        stars: (.[0].repository.stargazerCount // 0),
        items: (sort_by(.mergedAt) | reverse)
      })
    | sort_by(-(.items | length))
    | map(
        "**[\(.repo)](https://github.com/\(.repo))**"
        + (if .stars > 0 then " · ⭐ \(.stars)" else "" end)
        + "\n\n"
        + ([ .items[]
             | "- ["
               + (.title
                   | gsub("\\(#[0-9]+\\)\\s*$"; "")
                   | sub("\\s+$"; "")
                   | gsub("\\|"; "\\|"))
               + "](" + .url + ") · " + (.mergedAt | split("T")[0])
           ] | join("\n"))
      )
    | join("\n\n")
  ' > "$PR_TABLE" || true
  [ -s "$PR_TABLE" ] || echo "_No recently merged pull requests._" > "$PR_TABLE"
fi

if [ -s "$PR_TABLE" ]; then
  # Replace the table between the markers, keeping the markers themselves.
  awk -v start="<!-- MERGED_PRS:START -->" -v end="<!-- MERGED_PRS:END -->" -v content="$PR_TABLE" '
    index($0, start) > 0 { print; while ((getline line < content) > 0) print line; close(content); skip=1; next }
    index($0, end) > 0   { skip=0; print; next }
    skip != 1 { print }
  ' "$README" > "$README.tmp" && mv "$README.tmp" "$README"
  echo "  Merged PRs written: $(grep -c '^- ' "$PR_TABLE" || true) entries"
else
  echo "  ⚠️  Could not fetch merged PRs, leaving existing table untouched."
fi
rm -f "$PR_TABLE"

# Nudge when the hand-maintained "Now" section goes stale.
NOW_UPDATED=$(grep -oE 'NOW:UPDATED:[0-9]{4}-[0-9]{2}-[0-9]{2}' "$README" | head -1 | cut -d: -f3 || true)
if [ -n "$NOW_UPDATED" ]; then
  NOW_AGE=""
  if command -v python3 >/dev/null 2>&1; then
    NOW_AGE=$(python3 -c 'import sys, datetime; print((datetime.date.today() - datetime.date.fromisoformat(sys.argv[1])).days)' "$NOW_UPDATED" 2>/dev/null || true)
  fi
  if [ -n "$NOW_AGE" ] && [ "$NOW_AGE" -gt 30 ] 2>/dev/null; then
    echo "::warning title=Now section is stale::README 'Now' was last updated ${NOW_AGE} days ago ($NOW_UPDATED). Refresh the in-progress links and bump the NOW:UPDATED marker."
  elif [ -n "$NOW_AGE" ]; then
    echo "  Now section updated ${NOW_AGE} days ago."
  fi
fi

echo ""
echo "README updated successfully."
