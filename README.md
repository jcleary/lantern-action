# lantern-action

A GitHub Action that pushes the reports your own scanners produce to [Lantern](https://lantern.foundryhq.co.uk),
the application-quality dashboard that tracks what is open, what closed and what came back.

- **Small and dependency-free:** a composite action written in bash, `curl` and `jq` (all preinstalled on
  GitHub-hosted Ubuntu and macOS runners). No Node, no Docker, no nested actions.
- **Never breaks your build** unless you explicitly ask it to ([details](#never-breaks-your-build)).
- **Safe by default:** the API key never touches a command line or a log, and source code snippets are
  stripped from SARIF before upload ([details](#privacy)).
- Uploads the formats Lantern accepts today: **SARIF** (OSV-Scanner, Gitleaks, ZAP, Semgrep, Trivy…),
  **axe-core** accessibility reports (`a11y`) and **SonarQube** issue-search responses.

The action does not run scanners. Run them in your workflow, write their reports to files, and point the action at the files.

## 1. Create an API key in Lantern

An API key belongs to **one Lantern project** and is what tells Lantern where the reports go. Creating one needs
a Lantern **super user** (the `/admin` area); ask yours if that isn't you.

1. Sign in to Lantern and open **Admin** in the sidebar.
2. **Organisations →** pick the client's organisation (create it with **Create an organisation** if it is new).
3. Open the **project** for the repository you are wiring up (create it with **Create a project** if needed).
4. Open **API keys → Create key**. Give it a label such as `github-ci`, and optionally an expiry date.
5. **Copy the full key now.** It starts with `ltn_` and is shown **once**; Lantern only stores a hash.

Good practice: one key per project (so one leak or revocation affects one repository), and label keys so you can
tell them apart. Sources (`osv`, `gitleaks`, …) don't need setting up: the first push for a new source key creates it.

### Add the key to GitHub as a secret

In the **client's repository**: **Settings → Secrets and variables → Actions → New repository secret**, name
`LANTERN_API_KEY`, value the `ltn_…` key.

Or from a terminal:

```sh
gh secret set LANTERN_API_KEY --repo <owner>/<repo>      # paste the key when prompted
```

For several repositories that report to the same Lantern project, an organisation-level secret works too.
Never put the key in a workflow file, a `.env` file or the repository itself.

### Rotating or revoking

Create a second key, put it in the secret, run the workflow once and check the new key's **Last used** moves,
then revoke the old key. A leaked key: revoke it first. A revoked, expired or unknown key all produce the same `401`.

## 2. Add the action to your pipeline

Run your scanners so they write report files, then add one "Send to Lantern" step at the end. This example scans
dependencies with OSV-Scanner and secrets with the Gitleaks **CLI**, and sends both on every push to `main`
and on a weekly schedule (the weekly rescan picks up newly disclosed CVEs in unchanged code):

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
      - uses: actions/checkout@<full-sha> # vX
        with: { persist-credentials: false, fetch-depth: 0 }   # gitleaks scans history
      - name: Dependencies (OSV-Scanner)
        run: osv-scanner scan source -r --format sarif --output osv.sarif . || true
      - name: Secrets (Gitleaks CLI, redacted)
        run: gitleaks git --redact --report-format sarif --report-path gitleaks.sarif || true
      - name: Send to Lantern
        if: always()
        continue-on-error: true
        uses: jcleary/lantern-action@<full-sha> # v1.0.0
        with:
          api-key: ${{ secrets.LANTERN_API_KEY }}
          sarif: |
            osv=osv.sarif
            gitleaks=gitleaks.sarif
```

Notes:

- **Pin by full commit SHA** (`uses: jcleary/lantern-action@<full-sha> # v1.0.0`), as above. A tag can be
  moved; a SHA cannot. Dependabot and Renovate understand the `# v1.0.0` comment and will open update PRs.
  Find the SHA on the [releases page](https://github.com/jcleary/lantern-action/releases). (`@v1` works but trusts a movable tag.)
- Install the scanners however you like (OSV-Scanner and Gitleaks both ship binaries and Docker images). Use the
  Gitleaks **CLI** rather than `gitleaks-action`, which needs a licence key for organisation-owned repositories.
- `|| true` stops a scanner that exits non-zero on findings from failing the job before the upload runs; `if: always()` makes sure
  the upload step still runs. `continue-on-error: true` is belt and braces; the action itself never fails the job by default.
- Each `source-key=path` line is one **source** in Lantern. Keep keys stable: Lantern works out what opened and
  closed by comparing a source's latest report with the one before it.

### Other formats

```yaml
        with:
          api-key: ${{ secrets.LANTERN_API_KEY }}
          sarif: |
            zap=zap-report.sarif.json
          a11y: |
            a11y=axe-results.json            # axe-core: an array of page scans
          sonarqube: |
            sonarqube=sonar-issues.json      # response of /api/issues/search, open issues
```

### Behaviour you should know about

- By default (`upload-on: default-branch`) the action uploads only on non-pull-request runs of the repository's
  default branch. Pull requests and feature branches are skipped with a notice. Use `upload-on: always` to override
  and `upload-on: never` for a dry run that validates and summarises without sending anything.
- On **pull requests from forks** there are no secrets, so `api-key` is empty. The action then skips quietly with a notice, not a warning.
- Paths are exact paths relative to the workspace, not globs.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `api-key` | *(none)* | Lantern API key (`ltn_…`) from a secret. If empty the action warns quietly and skips (`status=skipped`). |
| `lantern-url` | `https://lantern.foundryhq.co.uk` | Base URL. Must be `https://`. Use it for staging. |
| `sarif` | `""` | Multi-line list, one `source-key=path/to/file.sarif` per line. |
| `a11y` | `""` | Same format, uploaded as `format=a11y` (axe-core). |
| `sonarqube` | `""` | Same format, uploaded as `format=sonarqube`. |
| `upload-on` | `default-branch` | `default-branch`: upload only on non-PR runs of the default branch. `always`: any run. `never`: dry run, no HTTP calls. |
| `scanned-at` | `""` | UTC time the scan finished, `2026-07-07T16:24:55Z` (must end in `Z`). Empty means the current time, computed once when the step starts. |
| `max-payload-mb` | `10` | A file larger than this is skipped with a warning. Match Lantern's `max_ingest_bytes` (default 10 MB). |
| `strip-snippets` | `true` | SARIF only: remove `region.snippet`, `contextRegion` and `codeFlows` before upload. |
| `fail-on-error` | `false` | If `true`, exit non-zero when any upload fails. Otherwise the step always exits 0. |

Source keys are lower-cased and must match `^[a-z0-9][a-z0-9_-]{0,63}$`. A key may be used only once across
`sarif`, `a11y` and `sonarqube`; a duplicate entry is skipped with a warning.

## Outputs

| Output | Description |
| --- | --- |
| `status` | `uploaded` (at least one upload succeeded, none failed), `partial` (some failed), `failed`, `skipped` (gated, no key, or nothing valid to send) or `dry-run`. |
| `results` | Compact JSON array, one object per source: `{ source, format, file, http, outcome, runId?, opened?, closed?, reopened?, open?, error? }`. `open` is Lantern's open-by-severity object. |

Example use:

```yaml
      - id: lantern
        uses: jcleary/lantern-action@<full-sha> # v1.0.0
        with: { api-key: "${{ secrets.LANTERN_API_KEY }}", sarif: "osv=osv.sarif" }
      - run: echo '${{ steps.lantern.outputs.status }}'
```

Every run also writes a **job summary**: a table of source, format, outcome and opened/closed/reopened/open
counts, a link to Lantern, and the commit/run metadata.

## Outcomes

| `outcome` | Meaning | Counts as failure? |
| --- | --- | --- |
| `created` | Lantern processed the report (`201`). | No |
| `duplicate` | This source and `scanned-at` were already processed (`200`, `duplicate: true`), typically a retry that had actually landed. Nothing changed. | No |
| `stale` | `409`: a newer scan for this source already exists. Warning only. | No |
| `skipped` | Not sent: missing file, invalid JSON, oversized file, bad or duplicate source key, or a dry run. | No |
| `failed` | Rejected (`400`, `401`, `403`, `413`, `422`, other 4xx), or still failing after retries (`5xx`, `429`, network). Lantern's `error.code` and `message` are shown. | **Yes** |

## Never breaks your build

- The step exits 0 whatever happens, unless you set `fail-on-error: true` **and** an upload actually failed.
  Missing files, bad config entries, a `409`, an unreachable server, even a wrong key are warnings.
- Problems appear as `::warning::` annotations (or `::error::` only when `fail-on-error` is on).
- Network errors, `5xx` and `429` are retried up to 3 attempts in total (waits of 2s then 5s, or Lantern's
  `Retry-After`, capped at 60s). A `4xx` is never retried. Each attempt has a 10s connect and 60s total timeout.
- A retried request re-sends the identical `scannedAt`, so one that succeeded the first time comes back as a harmless `200 duplicate`.
- `scanned-at` is **not** defaulted to the commit time: a weekly rescan of an unchanged commit must count as a
  new scan, or newly disclosed CVEs would never register. Re-running a workflow therefore produces a new scan time, as intended.

## Privacy

What leaves your CI: **only** the report files you list, over HTTPS, to the `lantern-url` you configure, with your API key in an
`Authorization` header. Nothing else is read or sent. The git/run metadata (commit, ref, run URL) is shown in the job summary
only and is **not** sent to Lantern in v1.

`strip-snippets: true` (the default) removes three things from SARIF before upload, wherever they occur:

- `region.snippet` (the source lines a finding points at),
- `contextRegion` (the surrounding lines),
- `codeFlows` (data-flow traces, which embed more snippets).

Lantern never reads these fields (checked against its normalizer and fingerprint code, see [docs/DECISIONS.md](docs/DECISIONS.md)), so
stripping doesn't change what opens or closes. Everything else, including `message.text`, file paths and line numbers, is sent
as your scanner wrote it. If a scanner puts secrets or code in finding messages or in `artifacts[].contents`, redact at the scanner
(for example `gitleaks --redact`). axe-core and SonarQube reports are sent unmodified.

The API key is passed to `curl` through a private temporary file, not on the command line, is masked in logs, and the
action never runs `set -x`. The action sends no data anywhere but your `lantern-url`.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `failed (HTTP 401)` | The key is missing, mistyped, revoked, expired, or its organisation is disabled (Lantern deliberately doesn't say which). Check the secret's name, create a fresh key in Admin → project → API keys, and update the secret. Secrets with a trailing newline are tolerated. |
| `HTTP 403 (response was not a Lantern error)` | A plain-text `403` is SvelteKit's CSRF guard refusing a request whose `Content-Type` is missing or a form type. The action always sends `application/json`, so if you see it, something between you and Lantern (a proxy or firewall) is altering or blocking the request. If you replace the action with your own `curl`, add `-H "Content-Type: application/json"`. |
| `stale` / `409` | A scan with a later `scanned-at` is already recorded for this source (for example a rerun of an older workflow, or a manual `scanned-at` in the past). Not an outage and not a failure; the newer data is already in Lantern. |
| `failed … invalid_report` / `422` | The JSON doesn't match the format, usually a file under the wrong input (a SARIF file listed under `a11y`) or a scanner that failed and wrote an error document. Check which input you used. |
| `payload_too_large` / `413` | Over Lantern's size limit or 20 000 issues. Lower the scanner's scope, or ask for the limit to be raised. |
| `skipped`, "upload-on is default-branch…" | Expected on pull requests and feature branches. Set `upload-on: always` to override. |
| `skipped`, "api-key is empty" | The secret isn't set, or this is a fork PR. Check the secret exists in *this* repository (or is shared with it). |
| `lantern-url must be an https:// URL` | Use the full base URL, for example `https://lantern-staging.foundryhq.co.uk`. Plain `http://` is refused. |

## Roadmap

Planned for later releases, none of it in v1: OIDC authentication (no stored secret), new Lantern endpoints
(`/runs`, `/metrics`, `/deployments`, `/runs/preview`), SBOM, JUnit and coverage ingest, PR comments with deltas,
gzip uploads, running scanners inside the action, and a Marketplace listing.

## Maintainers

Run the checks locally (needs `bash`, `jq`, `curl`, `python3`, `openssl`, `shellcheck`, `actionlint`, `bats`):

```sh
shellcheck scripts/main.sh scripts/lib/*.sh test/mock-server/start.sh
actionlint
bats test/bats          # unit tests + main.sh against an HTTPS mock of Lantern
```

CI (`ci.yml`) runs the same, then the action itself (`uses: ./`) against mock servers. `staging-smoke.yml` is a
manual workflow that uploads a fixture to `lantern-staging` (secret `LANTERN_STAGING_API_KEY`) and checks `created`
then `duplicate`.

### Releasing

1. **Once:** in the repository go to **Settings → Releases → Enable release immutability**. It only affects releases
   published afterwards, so do it **before** publishing `v1.0.0`. A published release's tag can then never be moved or
   deleted.
2. Update `VERSION` and move the `[Unreleased]` entries in `CHANGELOG.md` under a new `## [x.y.z] - date` heading. Merge to `main` with CI green.
3. Run the **release** workflow (`mode: draft-release`, `version: x.y.z`). It checks `VERSION` and the changelog, then creates a
   **draft** release. Review it and press **Publish release** yourself.
4. Run **release** again with `mode: move-major-tag` to move the floating `v1` tag to the new release. `v1` must be a plain git
   tag with **no GitHub release**: a tag that belongs to an immutable release can't move. The workflow refuses otherwise.
5. Post the new commit SHA to customers; the docs recommend SHA pinning, not `@v1`.

See [docs/DECISIONS.md](docs/DECISIONS.md) for the reasoning behind these choices and anything that deviates from the build brief.

## Licence

[MIT](LICENSE)
