#!/usr/bin/env python3
"""Fail if review.yml asks for more than the callers in the field actually grant.

Why this exists: on 16 Sep 2026 the `respond` job was merged asking for
`issues: write`. Callers in the field grant `issues: read`. A called workflow's
job permissions must be a SUBSET of the caller's, so GitHub refused to start the
whole workflow — build and review included — on all 23 repos that had not yet
taken the new caller. Every one of them was down until someone noticed a
developer's PRs sitting there with no checks at all.

The shared workflow goes live on every repo the moment it merges, and the 26
callers update independently. So the rule is: whatever review.yml requires must
hold for the OLDEST caller still out there, not just the newest one.

    check-caller-contract.py [review.yml] [caller-template.yml]

Checks two directions:
  1. no job in review.yml requests a permission above FIELD_GRANTS
  2. caller-template.yml does not grant less than FIELD_GRANTS, or new installs
     would break the same way from the other side

No third-party imports on purpose: a check that needs `pip install` is a check
nobody runs locally before pushing.
"""
import re
import sys

# The permission set every caller in the field is known to grant. Raise this ONLY
# after every repo in _shared/pr-reviewer-rollout/repos.txt has taken a caller
# that grants more, and say so in the PR that raises it.
FIELD_GRANTS = {
    "contents": "read",
    "pull-requests": "write",
    "issues": "read",
    "id-token": "write",
}

RANK = {"none": 0, "read": 1, "write": 2}
KEY = re.compile(r"^(\s*)([A-Za-z_][\w.-]*):\s*(.*?)\s*$")
BLOCK_SCALAR = re.compile(r"^[|>][+-]?\d*$")


def job_permissions(path):
    """{job_name: {scope: level}} for every job in a workflow file.

    A deliberately small YAML subset: nested mappings by indentation, skipping
    block scalars (review.yml's `prompt: |` is full of lines that would
    otherwise parse as keys) and list items.
    """
    jobs, stack, skip_to = {}, [], None
    for raw in open(path).read().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if skip_to is not None:
            if indent > skip_to:      # still inside the block scalar
                continue
            skip_to = None
        if raw.lstrip().startswith("- "):
            continue
        m = KEY.match(raw)
        if not m:
            continue
        indent, key, value = len(m.group(1)), m.group(2), m.group(3)
        # `issues: write   # why` must read as `write`, not as the whole rest of the
        # line — the same trailing-comment trap that let an empty APP_KEY through.
        if not value.startswith(("'", '"')):
            value = value.split("#", 1)[0].strip()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        path_keys = [k for _, k in stack] + [key]
        stack.append((indent, key))
        if BLOCK_SCALAR.match(value):
            skip_to = indent
            continue
        # jobs -> <job> -> permissions -> <scope>: <level>
        if len(path_keys) == 4 and path_keys[0] == "jobs" and path_keys[2] == "permissions" and value:
            jobs.setdefault(path_keys[1], {})[key] = value
        elif len(path_keys) == 2 and path_keys[0] == "jobs":
            jobs.setdefault(key, {})
    return jobs


def rank(level):
    return RANK.get(str(level), 0)


def main(review_path="./.github/workflows/review.yml", caller_path="./caller-template.yml"):
    problems = []

    for job, perms in job_permissions(review_path).items():
        for scope, level in perms.items():
            granted = FIELD_GRANTS.get(scope, "none")
            if rank(level) > rank(granted):
                problems.append(
                    f"{review_path}: job `{job}` asks for `{scope}: {level}` but callers grant "
                    f"`{scope}: {granted}`.\n"
                    f"    GitHub refuses to START the whole workflow on every repo still on the "
                    f"current caller — build and review too, not just this job."
                )

    for job, perms in job_permissions(caller_path).items():
        for scope, needed in FIELD_GRANTS.items():
            if rank(perms.get(scope, "none")) < rank(needed):
                problems.append(
                    f"{caller_path}: job `{job}` grants `{scope}: {perms.get(scope, 'none')}`, below "
                    f"the `{scope}: {needed}` the workflow relies on."
                )

    if problems:
        print("Caller contract broken:\n")
        for p in problems:
            print(f"  - {p}\n")
        print("Either drop the permission, or roll a new caller to every repo FIRST and")
        print("then raise FIELD_GRANTS here as a separate, deliberate change.")
        return 1

    print(f"Caller contract ok: every job in {review_path} fits within {FIELD_GRANTS}")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
