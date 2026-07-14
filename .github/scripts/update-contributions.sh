#!/bin/bash
set -euo pipefail

README="README.md"

echo "Fetching contribution data from GitHub API..."

# Fetch contribution stats via GraphQL
GRAPHQL_RESPONSE=$(gh api graphql -f query='
query {
  user(login: "wy471x") {
    contributionsCollection {
      totalCommitContributions
      totalPullRequestContributions
      totalPullRequestReviewContributions
      totalIssueContributions
      contributionCalendar { totalContributions }
    }
    repositories(ownerAffiliations: OWNER, isFork: false) { totalCount }
    followers { totalCount }
  }
}
')

# Parse GraphQL values
TOTAL_CONTRIBUTIONS=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions')
TOTAL_COMMITS=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.contributionsCollection.totalCommitContributions')
TOTAL_PRS=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.contributionsCollection.totalPullRequestContributions')
TOTAL_ISSUES=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.contributionsCollection.totalIssueContributions')
TOTAL_REVIEWS=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.contributionsCollection.totalPullRequestReviewContributions')
ORIGINAL_REPOS=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.repositories.totalCount')
FOLLOWERS=$(echo "$GRAPHQL_RESPONSE" | jq -r '.data.user.followers.totalCount')

# Get total public repos from REST API
TOTAL_REPOS_ALL=$(gh api "users/wy471x" --jq '.public_repos')
FORKED_REPOS=$((TOTAL_REPOS_ALL - ORIGINAL_REPOS))

# Get total stars across all repos (paginated)
TOTAL_STARS=0
PAGE=1
while true; do
  PAGE_STARS=$(gh api "users/wy471x/repos?per_page=100&page=${PAGE}&type=owner" --jq '([.[] | .stargazers_count] | add)')
  if [ "$PAGE_STARS" = "null" ] || [ "$PAGE_STARS" = "0" ] && [ "$PAGE" -gt 1 ]; then
    break
  fi
  TOTAL_STARS=$((TOTAL_STARS + PAGE_STARS))
  PAGE=$((PAGE + 1))
done

echo "Contributions: $TOTAL_CONTRIBUTIONS"
echo "Commits: $TOTAL_COMMITS"
echo "PRs: $TOTAL_PRS"
echo "Issues: $TOTAL_ISSUES"
echo "Reviews: $TOTAL_REVIEWS"
echo "Original repos: $ORIGINAL_REPOS"
echo "Forked repos: $FORKED_REPOS"
echo "Total stars: $TOTAL_STARS"
echo "Followers: $FOLLOWERS"

# Update README (Linux sed syntax for GitHub Actions)
sed -i -E "s/\*\*[0-9]+\*\* total contributions/**${TOTAL_CONTRIBUTIONS}** total contributions/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* commits/**${TOTAL_COMMITS}** commits/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* pull requests/**${TOTAL_PRS}** pull requests/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* issues/**${TOTAL_ISSUES}** issues/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* PR review/**${TOTAL_REVIEWS}** PR review/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* original repos/**${ORIGINAL_REPOS}** original repos/" "$README"
sed -i -E "s/\*\*[0-9]+\+\*\* forked repos/**${FORKED_REPOS}+** forked repos/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* total stars/**${TOTAL_STARS}** total stars/" "$README"
sed -i -E "s/\*\*[0-9]+\*\* followers/**${FOLLOWERS}** followers/" "$README"

echo "README updated successfully."
