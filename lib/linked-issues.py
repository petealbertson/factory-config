#!/usr/bin/env python3
"""Fetch issues linked to a PR via GitHub GraphQL or PR-body references.

Outputs a markdown list suitable for inclusion in a review/implement prompt.
"""
import json
import re
import subprocess
import sys


def gh_api(*args):
    return subprocess.run(["gh", "api", *args], capture_output=True, text=True)


def graphql_linked(repo, pr):
    owner, name = repo.split("/", 1)
    q = (
        f'{{ repository(owner:"{owner}", name:"{name}") '
        f'{{ pullRequest(number:{pr}) '
        f'{{ closingIssuesReferences(first:5) '
        f'{{ nodes {{ number title body }} }} }} }} }}'
    )
    r = gh_api("graphql", "-f", f"query={q}")
    if r.returncode != 0:
        return []
    try:
        nodes = (
            json.loads(r.stdout)
            .get("data", {})
            .get("repository", {})
            .get("pullRequest", {})
            .get("closingIssuesReferences", {})
            .get("nodes", [])
        )
        return sorted({n["number"]: n for n in nodes}.values(), key=lambda n: n["number"])
    except Exception:
        return []


def body_referenced(repo, pr):
    r = gh_api(f"repos/{repo}/pulls/{pr}", "--jq", ".body")
    if r.returncode != 0:
        return []
    body = r.stdout or ""
    numbers = {
        int(m.group(1))
        for m in re.finditer(r"(?:close|fix|resolve|see|related\s+to)\s*#(\d+)", body, re.IGNORECASE)
    }
    issues = []
    for num in sorted(numbers):
        r = gh_api(f"repos/{repo}/issues/{num}", "--jq", "{number,title,body}")
        if r.returncode == 0:
            try:
                issues.append(json.loads(r.stdout))
            except Exception:
                pass
    return issues


def main():
    if len(sys.argv) != 3:
        print("usage: linked-issues.py owner/repo PR", file=sys.stderr)
        sys.exit(1)
    repo, pr = sys.argv[1], sys.argv[2]
    linked = graphql_linked(repo, pr) or body_referenced(repo, pr)
    if not linked:
        return
    print("## Linked issues")
    for i in linked:
        body = i.get("body") or ""
        first = body.split("\n")[0] if body.strip() else ""
        print(f"- #{i['number']} {i.get('title', '')}: {first}")


if __name__ == "__main__":
    main()
