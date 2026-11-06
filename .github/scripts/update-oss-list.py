#!/usr/bin/env python3
"""Refresh the "Open Source" list in README.md.

Participation is defined as: opened an issue, merged a pull request, or
reviewed a pull request in the repository.

Categories and exclusions live in .github/oss.json. Repositories that are not
listed there are still reported, under the fallback category, and announced in
the workflow log so they can be filed properly.

Requires the `gh` CLI (GH_TOKEN is picked up from the environment).

    GH_TOKEN=... python3 .github/scripts/update-oss-list.py [--check]
"""

import json
import os
import subprocess
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
README = os.path.join(ROOT, "README.md")
CONFIG = os.path.join(ROOT, ".github", "oss.json")
START = "<!-- OSS:START -->"
END = "<!-- OSS:END -->"

QUERIES = {
    "issue": "author:{user}+is:issue",
    "pr": "author:{user}+is:pr+is:merged",
    "review": "reviewed-by:{user}+is:pr",
}


def gh_api(path):
    proc = subprocess.run(
        ["gh", "api", path, "--paginate", "--jq", ".items[] | .repository_url"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"gh api failed for {path}\n{proc.stderr.strip()}")
    return [
        line.strip().replace("https://api.github.com/repos/", "")
        for line in proc.stdout.splitlines()
        if line.strip()
    ]


def collect(user):
    totals = Counter()
    for kind, template in QUERIES.items():
        repos = gh_api(f"search/issues?q={template.format(user=user)}&per_page=100")
        print(f"  {kind:7} {len(repos):3} hits across {len(set(repos))} repos")
        totals.update(repos)
    return totals


def build_section(totals, config):
    user = config["user"]
    excluded = set(config.get("exclude", []))
    fallback = config.get("fallback_category", "Others")

    candidates = {
        repo: n
        for repo, n in totals.items()
        if n > 0 and repo not in excluded and not repo.startswith(f"{user}/")
    }

    buckets = []
    filed = set()
    for category in config.get("categories", []):
        repos = [r for r in category["repos"] if r in candidates]
        filed.update(category["repos"])
        if repos:
            buckets.append((category["name"], repos))

    leftovers = [r for r in candidates if r not in filed]
    if leftovers:
        for index, (name, repos) in enumerate(buckets):
            if name == fallback:
                buckets[index] = (name, repos + leftovers)
                break
        else:
            buckets.append((fallback, leftovers))
        print(
            "::notice title=Uncategorized repositories::"
            + ", ".join(sorted(leftovers))
            + " — add them to .github/oss.json"
        )

    lines = []
    for name, repos in buckets:
        lines.append(f"**{name}**")
        for repo in sorted(repos, key=lambda r: (-candidates[r], r.lower())):
            lines.append(f"- [{repo}](https://github.com/{repo})")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main():
    check_only = "--check" in sys.argv
    with open(CONFIG, encoding="utf-8") as fh:
        config = json.load(fh)

    print(f"Scanning participation for {config['user']}...")
    section = build_section(collect(config["user"]), config)

    with open(README, encoding="utf-8") as fh:
        readme = fh.read()

    if START not in readme or END not in readme:
        raise SystemExit(f"README.md is missing the {START} / {END} markers")

    head, rest = readme.split(START, 1)
    _, tail = rest.split(END, 1)
    updated = f"{head}{START}\n{section}{END}{tail}"

    if updated == readme:
        print("README already up to date.")
        return

    if check_only:
        raise SystemExit("README is out of date (run without --check to rewrite).")

    with open(README, "w", encoding="utf-8") as fh:
        fh.write(updated)
    print("README.md updated.")


if __name__ == "__main__":
    main()
