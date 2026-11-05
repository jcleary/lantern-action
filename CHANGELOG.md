# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-05

### Added

- Composite action (bash, curl, jq; no Node, Docker or nested `uses:`) that uploads SARIF, axe-core
  (`a11y`) and SonarQube reports to Lantern's `POST /api/v1/reports`.
- Inputs: `api-key`, `lantern-url`, `sarif`, `a11y`, `sonarqube`, `upload-on`, `scanned-at`,
  `max-payload-mb`, `strip-snippets`, `fail-on-error`. Outputs: `status`, `results`.
- Never breaks the build: exits 0 unless `fail-on-error: true` and an upload failed.
- Up to 3 attempts for network errors, 5xx and 429 (honours `Retry-After`, capped at 60s); `scannedAt`
  is computed once so a retry is a safe `200 duplicate`.
- `strip-snippets` removes `region.snippet`, `contextRegion` and `codeFlows` from SARIF before upload.
- `upload-on: default-branch` gate (skips pull requests and other branches), `always`, and `never` (dry run).
- Job summary table, step outputs, and run metadata shown (not sent) in the summary.
- Tests: shellcheck, actionlint, bats unit tests, and integration runs against an HTTPS mock server.

[Unreleased]: https://github.com/jcleary/lantern-action/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jcleary/lantern-action/releases/tag/v1.0.0
