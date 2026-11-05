# Decisions and deviations

Source of truth for the API: `docs/ingest.md` and `SPEC.md` §7 and §12 in `jcleary/lantern`.

## 1. `strip-snippets` safety check (required before shipping)

**Result: safe. None of `region.snippet`, `contextRegion` or `codeFlows` is read by Lantern.**

Checked in `jcleary/lantern` at `src/lib/server/ingest/`:

- `normalize.ts` `normalizeSarif` reads only: `runs[]`, `tool.driver.rules[].{id,name,shortDescription.text,fullDescription.text,properties.*,defaultConfiguration.level}`,
  `result.{ruleId,level,message.text,properties.*}`, `result.locations[0].physicalLocation.artifactLocation.uri` and
  `...physicalLocation.region.startLine`. `region` is read only for `startLine`.
- `fingerprint.ts` hashes `projectId | sourceKey | rule | location | line | description`. `description` is
  `message.text` (or the rule's `fullDescription.text`), never a snippet.
- `grep -rn "snippet\|contextRegion\|codeFlows" src/lib/server/ingest/` returns nothing.

So stripping cannot change identity, severity or lifecycle. If Lantern ever starts using any of these fields,
`strip-snippets` must be revisited (a future Lantern change should keep this file in sync).

What is **not** stripped, deliberately (the prompt names three fields): `result.message.text` (Lantern shows it
and fingerprints it), `artifacts[].contents` and `fixes[]` if a scanner embeds them. Those are the scanner's
choice; see the README privacy section.

## 2. Conflict between SPEC and `docs/ingest.md`: Content-Type

`SPEC.md` §7.1 says `Content-Type: application/json` is "not enforced". `docs/ingest.md` says it is required,
because SvelteKit's CSRF guard answers a plain-text `403` to form or missing content types. The prompt says
`ingest.md` wins on conflicts; the action always sends the header. **Lantern's SPEC §7.1 should be corrected.**

## 3. Interpretations

- **`status` and `stale`.** `uploaded` = no failures and at least one `created`, `duplicate` or `stale`.
  A `409` means Lantern already holds a newer scan, so it is neither a failure nor a reason to say `partial`.
  If nothing was attempted (all entries skipped, or no entries) the status is `skipped`.
- **Skipped entries are not failures.** A missing file, bad key, duplicate key, oversized file or invalid
  JSON is a warning and a `skipped` result. `fail-on-error` only reacts to failed uploads, an invalid
  `lantern-url`/`scanned-at`, or a snippet-strip failure.
- **Config errors fail closed.** A non-`https://` `lantern-url` or a malformed `scanned-at` gives
  `status=failed` and uploads nothing (`scanned-at` is not silently replaced by "now", which would break the
  idempotency the user asked for). Exit code is still 0 unless `fail-on-error`.
- **Retries.** "Up to 3 attempts" means two waits. The default delays are `2 5 10` as specified, but the third
  value is only used if the attempt count is raised. `Retry-After` in seconds replaces the backoff (cap 60s); an
  HTTP-date value is ignored.
- **Gate.** `default-branch` skips `pull_request*` events and any ref other than `refs/heads/<default>`. It
  therefore also allows `workflow_dispatch` and `workflow_run` on the default branch. An unknown default
  branch skips (with a notice suggesting `upload-on: always`).
- **Order of checks.** `never` is evaluated first (so a dry run needs no key), then the branch gate, then the
  empty-key skip (a quiet notice, so fork PRs are not noisy), then URL and `scanned-at`.
- **Job-summary link.** The `/api/v1/reports` response carries no project identifier, so the link goes to the
  Lantern base URL.
- **`scannedAt`** is the time the upload step started, not the time the scanner finished (the action does not
  run the scanner). Pass `scanned-at` if you know better.
- **Size check** is on the file on disk, before snippet stripping.
- **Only TLS.** `curl --proto '=https'` and no redirect following. Tests therefore use an HTTPS mock with a
  throw-away certificate, trusted through `CURL_CA_BUNDLE`; there is no "allow http" switch in production code.
- **`LANTERN_RETRY_DELAYS`** is an undocumented environment variable used only by tests to shorten waits.

## 4. Layout deviations

- Added `scripts/lib/common.sh` (logging, escaping, the results log) alongside the libraries in the prompt.
- Added `VERSION` (read for the `User-Agent`), `.shellcheckrc`, and `test/mock-server/start.sh`.
- Test scenarios live in `test/mock-server/scenarios/*.json`.
- Results are kept in a file (`results.jsonl`) rather than a shell variable, so they survive subshells.
- Scripts avoid Bash 4 features (associative arrays, `mapfile`, `${var,,}`) so the tests also run on macOS.

## 5. Releases and the floating `v1` tag

With **immutable releases** on, the tag of a published release can never be moved or deleted, so a `v1` tag
that belongs to a GitHub release cannot float. GitHub's own guidance for actions
([docs](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/using-immutable-releases-and-tags-to-manage-your-actions-releases))
is to make `v1` a plain git tag with **no release**, moved by force push. `release.yml` does exactly that
(`mode: move-major-tag`) and refuses if `v1` has a release. Immutability only applies to releases published
after it is switched on, so enable it **before** publishing `v1.0.0`. All documentation recommends SHA pinning.

Not verified against the docs: that a draft release does not create its tag until published. Check this on the
first release (the helper creates a draft, never a published release).

## 6. Not done in this session

- `staging-smoke.yml` has not been run (needs the repo on GitHub and a `LANTERN_STAGING_API_KEY` secret).
- `ci.yml` has not run on GitHub; the same scenarios were run locally through bats against the HTTPS mock, and
  `actionlint`/`shellcheck` are clean. Only the `uses: ./` wiring is untested until the first push.
- Nothing is committed or pushed in this repo; the release is not published.
