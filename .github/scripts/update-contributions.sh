#!/bin/bash
set -euo pipefail

README="README.md"

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

# Update README
sed -i -E "s/\*\*[0-9]+\*\* total contributions/**${TOTAL_CONTRIBUTIONS}** total contributions/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* commits/**${TOTAL_COMMITS}** commits/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* pull requests/**${TOTAL_PRS}** pull requests/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* issues/**${TOTAL_ISSUES}** issues/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* PR review/**${TOTAL_REVIEWS}** PR review/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* original repos/**${ORIGINAL_REPOS}** original repos/" "$README"
sed -i -E "s/\*\*[0-9]+\+\*\* forked repos/**${FORKED_REPOS}+** forked repos/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* total stars/**${TOTAL_STARS}** total stars/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* followers/**${FOLLOWERS}** followers/" "$README"

echo ""
echo "README updated successfully."
