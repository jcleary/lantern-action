# Build prompt: `lantern-action` v1

> Paste everything below the line into Claude Code, started in a **new, empty repository** for the action
> (suggested name `lantern-action`; it must be **public** so customers in other GitHub orgs can use it).
> Give the session read access to `jcleary/lantern` for the ingest contract.

---

## Task

Build **v1 of `lantern-action`**: a GitHub Action that customers add to their CI to push the reports
their own scanners produce to Lantern (`https://lantern.foundryhq.co.uk`). It must be small, dependency-free
and safe. It must **never break the customer's build** unless they explicitly ask it to.

Before writing code, read these files in `jcleary/lantern`: `docs/ingest.md`, `SPEC.md` §7 (ingest contract) and
§12 (CI snippet), and `src/lib/server/ingest/normalize.ts` (or wherever the normalizers live). They are the
source of truth for the API. If anything below conflicts with them, they win: tell me about the conflict and
record it in `docs/DECISIONS.md`.

Where this prompt says "verify against current docs" (composite-action syntax, `GITHUB_OUTPUT`,
`GITHUB_STEP_SUMMARY`, immutable releases), look the docs up. Don't rely on memory.

## Scope

**In scope (v1):**

- A **composite action** (`runs.using: composite`) written in **bash + curl + jq**. These are preinstalled on
  GitHub-hosted Ubuntu runners. Don't use Node, Docker or nested `uses:` steps. Put the logic in `scripts/`,
  not inline YAML.
- Auth with the existing Lantern **API key** only (`Authorization: Bearer ltn_…`), passed as an input from a
  secret.
- Upload the formats Lantern already accepts: `sarif`, `a11y` (axe-core) and `sonarqube`. Use the current
  endpoint `POST /api/v1/reports?source=…&format=…&scannedAt=…` **with no Lantern changes**.
- A job summary, step outputs, docs, tests and a release process.

**Out of scope (don't build or stub):**

- OIDC auth
- New Lantern endpoints (`/runs`, `/metrics`, `/deployments`, `/runs/preview`)
- SBOM/JUnit/coverage ingest
- PR comments or deltas
- gzip uploads
- Running scanners inside the action
- Marketplace listing

These are planned for later. Mention them in the README's "Roadmap" section only.

## Inputs (`action.yml`)

| Input | Default | Behaviour |
|---|---|---|
| `api-key` | *(required in practice)* | Lantern API key. If empty, warn and skip with `status=skipped`. Don't fail. |
| `lantern-url` | `https://lantern.foundryhq.co.uk` | Base URL. Allow staging. Must be `https://`. |
| `sarif` | `""` | Multi-line list. Each line is `source-key=path/to/file.sarif`. |
| `a11y` | `""` | Same `source-key=path` format, uploaded with `format=a11y`. |
| `sonarqube` | `""` | Same `source-key=path` format, uploaded with `format=sonarqube`. |
| `upload-on` | `default-branch` | `default-branch` uploads only on push or schedule runs of the repo's default branch (`${{ github.event.repository.default_branch }}`). `always` uploads on any run. `never` is a dry run: validate and summarise, no HTTP calls. |
| `scanned-at` | `""` | ISO-8601 UTC override. If empty, use the current UTC time **computed once** when the step starts (see Idempotency). |
| `max-payload-mb` | `10` | A file larger than this is skipped with a warning, not uploaded. |
| `strip-snippets` | `true` | For SARIF only, remove `region.snippet`, `contextRegion` and `codeFlows` before upload, so source code doesn't leave the customer's CI. **First verify in Lantern's normalizer and fingerprint code that none of these fields are used.** If any are, stop and report. |
| `fail-on-error` | `false` | If `true`, exit non-zero when any upload fails. Otherwise always exit 0. |

Validation rules:

- Source keys must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Lower-case them first.
- Paths are exact paths, not globs. A missing file gives a warning and that entry is skipped.
- Duplicate source keys are a config error. The duplicate entry is skipped with a warning.
- Invalid JSON is caught locally with `jq empty` and gives a warning plus a skip.

## Outputs

- `status`: `uploaded` (at least one upload succeeded and none failed), `partial`, `failed`, `skipped`, or `dry-run`.
- `results`: a compact JSON array with one object per source:
  `{ source, format, file, http, outcome, runId?, opened?, closed?, reopened?, open?, error? }`.
  `outcome` is one of `created`, `duplicate`, `stale`, `skipped` or `failed`.

Write both via `$GITHUB_OUTPUT`, using the multi-line-safe delimiter form.

## Behaviour

**Never break CI.**

- Use `set -uo pipefail` but **not** `-e`. Handle every error explicitly.
- The final exit code is 0 unless `fail-on-error: true` and at least one upload failed.
- Surface problems as `::warning::`, or as `::error::` only when `fail-on-error` is on.

**Responses.** Map them as `docs/ingest.md` defines:

| Response | Outcome |
|---|---|
| `201` | `created` |
| `200` with `duplicate: true` | `duplicate` (success) |
| `409` | `stale`: warning, not a failure. It means a newer scan already exists. |
| `401`, `400`, `422`, `413` or any other 4xx | `failed`. Show Lantern's `error.code` and `error.message`. Never print the request body or the key. |
| `5xx`, `429` or a network error | Retry, then `failed`. |

**Retries and timeouts.**

- Up to 3 attempts, for network errors, 5xx and 429 only. Never retry other 4xx.
- Honour `Retry-After` (cap 60s). Otherwise back off 2s, then 5s, then 10s.
- Set `--connect-timeout 10` and `--max-time 60` per attempt.
- Write the retry loop yourself rather than relying on `--retry-all-errors`, so 4xx are never retried.

**Idempotency.**

- Compute `scannedAt` once per step and reuse it for every attempt. Lantern then treats a retried request as
  a `200 duplicate`.
- Don't default `scannedAt` to the commit timestamp. Weekly scheduled rescans of an unchanged commit would
  look like duplicates, and newly disclosed CVEs would never register.
- Re-running the workflow produces a new `scannedAt`. That is intended.

**Headers.**

- Send `Content-Type: application/json`. It is required, or SvelteKit's CSRF guard answers 403.
- Send `User-Agent: lantern-action/<version>`.
- Send the API key without exposing it on the command line. For example, pass it with
  `curl --header @<file>` from a `mktemp` file that is `chmod 600` and deleted in a `trap`, or a similar
  approach.
- Never use `set -x`. Call `::add-mask::` on the key defensively.

**Branch gating.**

- With `upload-on: default-branch`, skip on `pull_request*` events and on any ref other than
  `refs/heads/<default branch>`. The outcome is `status=skipped` with a notice explaining why.
- Fork PRs have no secrets, so they hit the empty-`api-key` path. That path must stay quiet: a notice, not a
  warning.

**Job summary.** Append a Markdown table to `$GITHUB_STEP_SUMMARY`: source, format, outcome, opened, closed,
reopened and open totals. Include one line with a link to the project in Lantern, if the response gives you
enough to build one. If it doesn't, link the Lantern base URL.

**Metadata.** Lantern can't store git metadata yet. Still collect `GITHUB_SHA`, `GITHUB_REF_NAME`,
`GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT` and `GITHUB_SERVER_URL/REPOSITORY/actions/runs/RUN_ID` in one place
(`scripts/lib/metadata.sh`) and show them in the job summary. The future `/api/v1/runs` call can then reuse
them without a refactor. Don't send them to Lantern in v1.

## Repository layout

```
action.yml
scripts/
  main.sh            # entrypoint: parse inputs → validate → gate → upload each → outputs/summary → exit
  lib/inputs.sh      # parsing + validation of source=path lists
  lib/upload.sh      # curl + retry + response mapping
  lib/sarif.sh       # strip-snippets jq filter
  lib/metadata.sh
  lib/summary.sh
test/
  bats/*.bats        # unit tests (bats-core) for parsing, validation, response mapping, SARIF stripping
  mock-server/       # tiny Python stdlib HTTP server returning scripted responses (201/200dup/409/401/422/500→201/429+Retry-After)
  fixtures/          # small scrubbed SARIF, axe and SonarQube samples (no real secrets, emails or JWTs)
.github/workflows/
  ci.yml             # shellcheck, actionlint, bats, then the action itself against the mock server (uses: ./)
  staging-smoke.yml  # workflow_dispatch only: uploads a fixture to lantern-staging using secret LANTERN_STAGING_API_KEY
  release.yml        # optional helper; see Release
README.md
CHANGELOG.md
LICENSE              # MIT
docs/DECISIONS.md
```

Pin every third-party action in this repo's own workflows by full commit SHA, with a version comment.

## Tests (must pass in CI)

1. `shellcheck` is clean and `actionlint` is clean.
2. The bats unit tests cover:
   - source-key validation and lower-casing
   - malformed lines
   - duplicate keys
   - missing files and the size cap
   - each HTTP status → outcome mapping
   - `Retry-After` handling
   - the SARIF strip filter, which removes the three fields and leaves everything else byte-identical in meaning
3. Integration runs of `uses: ./` against the mock server cover:
   - all-success → `uploaded`, exit 0
   - a mix of success and failure → `partial`, exit 0
   - the same mix with `fail-on-error: true` → exit 1
   - `409` → `stale`, exit 0
   - `500` then `201` → `created` after a retry, with the same `scannedAt` on both attempts (the mock asserts this)
   - an empty `api-key` → `skipped`, exit 0
   - `upload-on: never` → no HTTP calls (the mock asserts zero hits)
   - a `pull_request` event with the `default-branch` gate → `skipped`
4. The key never appears in logs. A test greps the captured step log for the fake key and fails if found.

## Docs

`README.md` must contain:

- what the action does
- a quick start with the customer's own scanners producing files
- the full inputs and outputs tables
- an outcomes table
- a "Never breaks your build" section
- a privacy section on what leaves CI and what `strip-snippets` removes
- troubleshooting for 401, 403 without a `Content-Type`, 409 and 422
- a roadmap

Show **SHA-pinned usage** as the recommended form: `uses: <owner>/lantern-action@<full-sha> # v1.0.0`. Mention
that Dependabot or Renovate can keep it updated.

Include this example customer workflow, adapted to whatever you build:

```yaml
name: lantern
on:
  push: { branches: [main] }
  schedule: [{ cron: "0 5 * * 1" }]   # weekly rescan picks up newly disclosed CVEs
permissions: { contents: read }
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha> # vX
        with: { persist-credentials: false }
      - name: Dependencies (OSV-Scanner)
        run: osv-scanner scan source -r --format sarif --output osv.sarif . || true
      - name: Secrets (Gitleaks CLI, redacted)
        run: gitleaks git --redact --report-format sarif --report-path gitleaks.sarif || true
      - name: Send to Lantern
        if: always()
        continue-on-error: true
        uses: <owner>/lantern-action@<sha> # v1.0.0
        with:
          api-key: ${{ secrets.LANTERN_API_KEY }}
          sarif: |
            osv=osv.sarif
            gitleaks=gitleaks.sarif
```

Recommend the Gitleaks **CLI** over `gitleaks-action`, which needs a licence key for organisation-owned repos.

## Release

Verify the release mechanics against current GitHub docs, then document them in the README's "Maintainers"
section:

- Enable **immutable releases** on the repo.
- Publish `v1.0.0` as a GitHub Release.
- Move a floating `v1` tag for convenience, but recommend SHA pinning in all docs.
- Add `CHANGELOG.md` with Keep a Changelog style entries.

Don't publish the release yourself. Prepare everything and leave the publish step to me.

## Follow-up in `jcleary/lantern`

Open a small PR in the Lantern repo:

- Add a "Using the GitHub Action" section to `docs/ingest.md` that links to the action and shows the
  SHA-pinned example.
- Keep the curl docs for non-GitHub CI.
- Make no code changes. Follow that repo's `CLAUDE.md` working agreements.

## Acceptance checklist (run it, then stop)

- [ ] `action.yml` is a composite action with no nested `uses:` and no Node or Docker.
- [ ] CI is green: shellcheck, actionlint, bats and every integration scenario above.
- [ ] `staging-smoke.yml` run manually against `lantern-staging` gives `created`, then `duplicate` on a re-run with the same `scanned-at`, and the run appears in Lantern's admin "Recent runs".
- [ ] The key never appears in any log (tested).
- [ ] The `strip-snippets` safety check against Lantern's normalizer/fingerprint is done and recorded in `docs/DECISIONS.md`.
- [ ] README, CHANGELOG, LICENSE and DECISIONS are written; the release is prepared but not published.
- [ ] The docs PR is open in `jcleary/lantern`.

When the checklist passes:

1. Summarise what you built, any deviations, and what I should look at.
2. Stop.
