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

Since 21 Sep 2026 the callers are thin: the draft / fork / label / bot-comment filter
moved out of every repo's caller and into review.yml's job-level `if`s. That makes those
`if`s the only thing standing between a bot's own comment and a reply to it — a loop paid
for out of one person's subscription. So three more checks:
  3. every job's gate carries its mandatory clauses, and matches tests/gates.golden
     word for word (a gate never changes by accident, and the change shows up in review)
  4. the caller template stays thin: no `if:`, `concurrency:` or `with:` — logic put
     back in the caller is logic that costs a pull request per repo to change
  5. the tags line up: REVIEWER_REF and the template's `@tag` are both known release
     tags, and the workflow's concurrency group is not the old callers' group name

    check-caller-contract.py --print-gates     regenerate tests/gates.golden (stdout)

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

# Tags release.sh keeps on one commit. v1 = callers that still carry their own filter,
# v2 = thin callers. Drop v1 here only after `fleet.sh census` shows nothing pinned to it.
RELEASE_TAGS = {"v1", "v2"}

# What each gate must contain, whatever else changes. Substrings of the normalised
# expression. `respond` has two clauses (issue comment / review comment), and the fork
# test can only be written for the second — the first is covered by respond-gate.sh,
# because an issue_comment event carries no head-repo field.
PR_GATE = [
    "github.event_name == 'pull_request'",
    "github.event.pull_request.draft == false",
    "github.event.pull_request.head.repo.full_name == github.repository",
    "!contains(github.event.pull_request.labels.*.name, 'no-review')",
]
MANDATORY = {
    "build": PR_GATE,
    "review": PR_GATE + ["!cancelled()"],
    "respond": [
        "github.event_name == 'issue_comment'",
        "github.event.issue.pull_request != null",
        "github.event.issue.state == 'open'",
        "!contains(github.event.issue.labels.*.name, 'no-review')",
        "github.event_name == 'pull_request_review_comment'",
        "github.event.pull_request.draft == false",
        "github.event.pull_request.head.repo.full_name == github.repository",
        "!contains(github.event.pull_request.labels.*.name, 'no-review')",
    ],
}
# ...and the bot filter must appear once per clause of `respond`.
BOT_FILTER = "github.event.comment.user.type != 'Bot'"
# A gate is a chain of ANDs; `respond` is two such chains joined by ONE `||`. Any other
# `||` widens it — `… || true`, or a whole extra clause — while every mandatory substring
# is still present and a regenerated golden file still matches. Counting them is what
# actually stops a widening; the golden copy only makes a change visible.
ALLOWED_ORS = {"build": 0, "review": 0, "respond": 1}
# The other direction: a clause that is NOT in the mandatory list (`!inputs.skip_build`,
# `needs.build.result != 'cancelled'`) can be deleted with no new `||` and every listed
# substring still present. Counting `&&` makes every clause load-bearing: adding or
# removing one is a deliberate edit of this number, in a file a person reviews.
ALLOWED_ANDS = {"build": 4, "review": 5, "respond": 8}
assert set(ALLOWED_ORS) == set(ALLOWED_ANDS) == set(MANDATORY)

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
        # jobs -> <job> -> permissions: write-all   (the scalar shorthand, one level up).
        # Until 21 Sep 2026 this was invisible here: the job read as asking for nothing,
        # and `write-all` — the 16 Sep outage in two words — passed every guard.
        elif len(path_keys) == 3 and path_keys[0] == "jobs" and key == "permissions":
            jobs.setdefault(path_keys[1], {})["__declared__"] = "yes"
            # `{}` included: it grants NOTHING, so the job could no longer post a verdict —
            # a red `review` check on every PR in every repo, with no comment to say why.
            if value:
                jobs[path_keys[1]]["__scalar__"] = value
        elif len(path_keys) == 2 and path_keys[0] == "jobs":
            jobs.setdefault(key, {})
    return jobs


def job_gates(path):
    """{job_name: normalised `if` expression} for every job in a workflow file.

    Handles `if: <expr>` and folded/literal block scalars (`if: >-`). Normalised means
    the `${{ }}` wrapper is dropped and all whitespace runs collapse to one space, so
    re-wrapping a gate is not a change and editing it is.
    """
    gates, job, in_jobs, collecting, buf = {}, None, False, False, []

    def flush():
        if job is not None and buf:
            expr = " ".join(" ".join(buf).split())
            expr = re.sub(r"^\$\{\{\s*|\s*\}\}$", "", expr)
            gates[job] = " ".join(expr.split())

    for raw in open(path).read().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if collecting:
            if indent > 4:
                buf.append(raw.strip())
                continue
            collecting = False
            flush()
            buf = []
        if indent == 0:
            in_jobs = raw.startswith("jobs:")
            continue
        if not in_jobs:
            continue
        m = re.match(r"^  ([A-Za-z_][\w-]*):\s*$", raw)
        if m:
            job = m.group(1)
            continue
        m = re.match(r"^    if:\s*(.*?)\s*$", raw)
        if m and job is not None:
            if BLOCK_SCALAR.match(m.group(1)):
                collecting, buf = True, []
            else:
                buf = [m.group(1)]
                flush()
                buf = []
    if collecting:
        flush()
    return gates


def read_golden(path):
    golden = {}
    try:
        for line in open(path).read().splitlines():
            if line.strip() and not line.startswith("#") and "\t" in line:
                job, expr = line.split("\t", 1)
                golden[job.strip()] = expr.strip()
    except FileNotFoundError:
        pass
    return golden


def uncommented(path):
    return [l for l in open(path).read().splitlines() if l.strip() and not l.lstrip().startswith("#")]


def rank(level):
    return RANK.get(str(level), 0)


def main(review_path="./.github/workflows/review.yml", caller_path="./caller-template.yml",
         golden_path="./tests/gates.golden"):
    problems = []

    for job, perms in job_permissions(review_path).items():
        if "__scalar__" in perms:
            problems.append(
                f"{review_path}: job `{job}` says `permissions: {perms['__scalar__']}`. Spell the scopes "
                f"out, one per line: a blanket grant asks for more than callers give (GitHub then refuses "
                f"to START the whole workflow on every repo), and an empty one leaves the job unable to post."
            )
        if "__declared__" not in perms:
            problems.append(
                f"{review_path}: job `{job}` has no `permissions:` block, so this check cannot see "
                f"what it uses. Declare them, even when they match the caller's."
            )
        for scope, level in perms.items():
            if scope.startswith("__"):
                continue
            granted = FIELD_GRANTS.get(scope, "none")
            if rank(level) > rank(granted):
                problems.append(
                    f"{review_path}: job `{job}` asks for `{scope}: {level}` but callers grant "
                    f"`{scope}: {granted}`.\n"
                    f"    GitHub refuses to START the whole workflow on every repo still on the "
                    f"current caller — build and review too, not just this job."
                )

    for job, perms in job_permissions(caller_path).items():
        if "__scalar__" in perms:
            problems.append(f"{caller_path}: job `{job}` uses `permissions: {perms['__scalar__']}`; spell the scopes out.")
        for scope, needed in FIELD_GRANTS.items():
            if rank(perms.get(scope, "none")) < rank(needed):
                problems.append(
                    f"{caller_path}: job `{job}` grants `{scope}: {perms.get(scope, 'none')}`, below "
                    f"the `{scope}: {needed}` the workflow relies on."
                )

    # A workflow-level `permissions:` in review.yml is outside what job_permissions() reads.
    # Whether GitHub checks it against the caller's grant is not something to find out on
    # the fleet: grant per job only.
    top = re.search(r"^permissions:[ \t]*(.*)$", open(review_path).read(), re.M)
    if top:
        problems.append(
            f"{review_path}: workflow-level `permissions:` ({top.group(1) or 'a block'}). Grant per job "
            f"only — this check reads job blocks, and a called workflow must stay within its caller's grant."
        )

    # 3. the gates
    gates = job_gates(review_path)
    golden = read_golden(golden_path)
    for job, clauses in MANDATORY.items():
        expr = gates.get(job)
        if expr is None:
            problems.append(
                f"{review_path}: job `{job}` has no `if:`. Thin callers do not filter anything, "
                f"so an ungated job runs on drafts, forks and the bot's own comments."
            )
            continue
        for clause in clauses:
            if clause not in expr:
                problems.append(f"{review_path}: job `{job}` gate lost its clause `{clause}`.")
        if expr.count("||") != ALLOWED_ORS[job]:
            problems.append(
                f"{review_path}: job `{job}` gate has {expr.count('||')} `||`, expected exactly "
                f"{ALLOWED_ORS[job]}. An extra `||` WIDENS the gate: `… || true` or an added clause "
                f"lets through what the ANDs were keeping out (for `respond`: the bot's own comments)."
            )
        if expr.count("&&") != ALLOWED_ANDS[job]:
            problems.append(
                f"{review_path}: job `{job}` gate has {expr.count('&&')} `&&`, expected exactly "
                f"{ALLOWED_ANDS[job]}. A clause was added or dropped. If that is intended, change "
                f"ALLOWED_ANDS in this script in the same PR, so the change is reviewed as one."
            )
        if job == "respond" and expr.count(BOT_FILTER) < 2:
            problems.append(
                f"{review_path}: job `respond` must carry `{BOT_FILTER}` in BOTH clauses; without "
                f"it the bot answers its own comments in a loop."
            )
    for job in sorted(set(gates) | set(golden)):
        if gates.get(job) != golden.get(job):
            problems.append(
                f"gate for job `{job}` differs from {golden_path}.\n"
                f"    workflow: {gates.get(job)}\n"
                f"    golden:   {golden.get(job)}\n"
                f"    If the change is intended: check-caller-contract.py --print-gates > {golden_path}"
            )

    # 4. the template stays thin
    for line in uncommented(caller_path):
        m = re.match(r"^\s*(if|concurrency|with):", line)
        if m:
            problems.append(
                f"{caller_path}: `{m.group(1)}:` is back in the caller. Run/skip logic, concurrency and "
                f"per-repo options live in review.yml, or every change to them costs a PR per repo."
            )

    # 5. the tags line up
    review_lines = uncommented(review_path)
    refs = [m.group(1) for l in review_lines for m in [re.match(r"^\s*REVIEWER_REF:\s*(\S+)", l)] if m]
    if len(refs) != 1 or refs[0] not in RELEASE_TAGS:
        problems.append(f"{review_path}: REVIEWER_REF must be exactly one of {sorted(RELEASE_TAGS)}, found {refs}.")
    pins = [m.group(1) for l in uncommented(caller_path)
            for m in [re.match(r"^\s*uses:\s*\S+/review\.yml@(\S+)", l)] if m]
    if len(pins) != 1 or pins[0] not in RELEASE_TAGS:
        problems.append(f"{caller_path}: `uses:` must pin one of {sorted(RELEASE_TAGS)}, found {pins}.")
    text = open(review_path).read()
    m = re.search(r"^concurrency:\n(?:\s*#.*\n)*\s*group:\s*>-\n\s*(\S+)", text, re.M)
    if not m:
        problems.append(f"{review_path}: no workflow-level `concurrency:` group found.")
    elif not m.group(1).startswith("prr-"):
        problems.append(
            f"{review_path}: concurrency group `{m.group(1)}` must start `prr-`. Older callers use "
            f"`pr-review-…`, and a caller and a called workflow sharing a group cancel each other."
        )

    if problems:
        print("Caller contract broken:\n")
        for p in problems:
            print(f"  - {p}\n")
        print("Either drop the permission, or roll a new caller to every repo FIRST and")
        print("then raise FIELD_GRANTS here as a separate, deliberate change.")
        return 1

    print(f"Caller contract ok: every job in {review_path} fits within {FIELD_GRANTS};")
    print(f"  gates match {golden_path}, the template is thin, tags are {sorted(RELEASE_TAGS)}.")
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--print-gates"]:
        print("# job<TAB>normalised gate. Regenerate: scripts/check-caller-contract.py --print-gates")
        for job, expr in job_gates(sys.argv[2] if len(sys.argv) > 2 else "./.github/workflows/review.yml").items():
            print(f"{job}\t{expr}")
        sys.exit(0)
    sys.exit(main(*sys.argv[1:4]))
