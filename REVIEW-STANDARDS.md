# Review standards

These are the rules the automated reviewer applies to every pull request. They are
written for a reader who wants to know why a PR was sent back, and for the reviewer
itself. Change them by pull request to this repository; every repo picks up the
change on its next review.

## What "safe to merge" means

A PR is safe to merge when **it does not degrade the site and does not break anything
that works today**, judged on its **impact radius**: everything that depends on what
changed, not just the lines in the diff.

Concretely, before an approval the reviewer has:

1. **Built it.** Dependencies installed, the project compiled, the application booted,
   migrations applied on a fresh database, and every existing test passed. Where a repo
   has no tests the approval says so; "safe" then means "it builds and every consumer of
   the change was read and judged".
2. **Traced the impact radius.** Every consumer of every changed symbol, component,
   route, field, migration, config key and dependency was found and read. The approval
   names them.
3. **Checked cross-repo effects.** An API change names its consumer repos, and the PR
   either links the consumer PR or states that none is needed.
4. **Applied the house rules below**, security first.

An approval is a safety statement written so the author can merge on it. The author
merges; the reviewer never does.

## Severity

- **Important** — it breaks, degrades, leaks, loses data, or violates a hard rule
  below. Blocks approval. Every Important finding says what breaks and how to fix it.
- **Nit** — worth fixing, never blocking. At most five per review.

Formatting and style are never findings. A linter's job is not the reviewer's.

## Hard rules (always Important)

### Security
- SQL built from strings or interpolated input. Use bindings or the query builder.
- Mass assignment without a fillable/guarded list, or with request input passed whole.
- Output of user, CMS or API content without escaping (unescaped template output,
  `v-html` on non-hardcoded content).
- A route, controller action, API endpoint or page that lacks the authentication or
  ownership check its neighbours have.
- CSRF protection removed or bypassed on a state-changing route.
- A secret, token, private key, password or `.env` file added to the repository, in
  any form, including "example" files with real values.
- Uploads accepted without type and size validation, or stored under a user-chosen path.
- Redirects or fetches to a user-supplied URL without an allow-list.
- Debug output, stack traces or verbose errors enabled in a production path.

### Data
- A migration that drops, renames, narrows or retypes a column, or adds a NOT NULL
  column without a default, unless the PR shows how existing rows are handled.
- A seeder or command that deletes or truncates data as a side effect of a normal run.

### Frameworks
- **Laravel 11 is not accepted for new work.** Its default email validation has an
  unpatched CRLF injection; the fix exists only in 12.60+ and 13.10+. A PR that pins
  `laravel/framework` to `^11` in a new project, or downgrades to it, is Important. An
  existing 11.x project that is not upgrading in this PR gets a Nit naming the upgrade.
- A dependency bumped across a major version with no reason given in the PR.

### Build
- Install, build, boot, migrate or tests failing in the build job for a reason in the
  code **this PR changes**. A failure caused by the CI environment itself (missing env
  var or service, runtime the runner lacks) is a Nit that says exactly that. A failure
  that already exists on the base branch and is unrelated to the PR's files is repo
  debt: a Nit that names it, never a block.

## Conventions (Nits unless stated)

### Nuxt / Vue
- Content hard-coded in a component or page that the site's CMS is meant to supply.
- `useAsyncData` / `useFetch` used with options that break SSR or caching (a key that
  changes every render, `server: false` on content the page needs for SEO, fetching in
  `onMounted` what should be fetched on the server).
- A visible string added without its i18n key in a project that uses i18n.
- A shared component's props or emits changed without every caller updated — this one
  is **Important** (it is an impact-radius break).

### Laravel
- Business logic in a controller that the project keeps in services or actions.
- N+1 queries introduced in a list endpoint (missing eager load).
- A new endpoint without validation of its input.
- A queue job or listener that is not idempotent when the project retries jobs.

### Design floors (every site we ship)
- Text rendered smaller than **16px on desktop or 14px on mobile** — any label,
  caption, nav link or button.
- The font **IBM Plex Mono** introduced. Any other monospace is fine.
- A page container narrower than **1640px** where the layout is full-width.
A repo may waive a design floor in its `.github/REVIEW-NOTES.md` (see below).

### Dependencies
- A lockfile out of sync with its manifest, or missing.
- A new dependency that duplicates something already in the project.

## Standing waivers — never flag these
- A CMS password minimum of **12 characters with a breach check** is the standard. Do
  not ask for a longer minimum.
- Formatting, import order, quote style, trailing commas, whitespace.
- Missing tests in a repository that has no test suite at all. Say "no tests" in the
  summary; do not ask the author to start one in this PR.

## Repo-specific notes: `.github/REVIEW-NOTES.md`

A repository may keep a short `REVIEW-NOTES.md` under `.github/`. The reviewer reads it
after this file. Use it for:

- Waivers of a convention or design floor, with the date and who agreed it.
- Context the diff cannot show: which folders are generated, which service is the
  consumer of this API, which branch deploys where.
- Repo-specific rules ("every new endpoint needs a feature test here").

It cannot relax a security rule, a data rule, or the build and impact checks.

## Large pull requests

Over roughly 2,000 changed lines the reviewer reads the riskiest files first, lists the
files it did not read, adds a Nit asking for the PR to be split, and never approves
what it did not read.

## Re-reviews

Every push to the PR re-runs the review. The reviewer checks its own earlier Important
items first, raises no new Nits on unchanged lines, and approves once the list is empty
and the build is green.
