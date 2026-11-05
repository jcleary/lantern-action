#!/usr/bin/env bats
# main.sh end to end against the HTTPS mock server, with a simulated GitHub environment.

load helpers

setup() {
  act_env
  cd "$BATS_TEST_TMPDIR"
  cp "$REPO_ROOT"/test/fixtures/* .
}

teardown() { stop_mock; }

sarif_pair() { printf 'osv=osv.sarif\ngitleaks=gitleaks.sarif'; }

@test "all uploads succeed -> uploaded, exit 0, one request per report" {
  start_mock all-success
  export INPUT_SARIF="$(sarif_pair)" INPUT_A11Y="a11y=a11y.json" INPUT_SONARQUBE="sonarqube=sonarqube.json"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = uploaded ]
  [ "$(out_results | jq 'length')" = 4 ]
  [ "$(out_results | jq '[.[] | select(.outcome == "created")] | length')" = 4 ]
  [ "$(hits | jq 'length')" = 4 ]
  [ "$(result_field osv .runId)" = run-1 ]
  [ "$(result_field osv '.open.high')" = 1 ]
  # formats and headers, as docs/ingest.md requires
  [ "$(hits | jq -r '[.[] | "\(.source)=\(.format)"] | sort | join(",")')" = "a11y=a11y,gitleaks=sarif,osv=sarif,sonarqube=sonarqube" ]
  [ "$(hits | jq '[.[] | select(.content_type == "application/json" and .auth_ok and (.user_agent | startswith("lantern-action/1.")))] | length')" = 4 ]
  # one scannedAt for the whole step
  [ "$(hits | jq '[.[].scannedAt] | unique | length')" = 1 ]
  [[ "$(hits | jq -r '.[0].scannedAt')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "snippets never leave CI when strip-snippets is on (the default)" {
  start_mock all-success
  export INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  body="$MOCK_DIR/bodies/$(hits | jq -r '.[0].body_file')"
  [ "$(jq '[.. | objects | select(has("contextRegion") or has("codeFlows") or ((.region? // {}) | type == "object" and has("snippet")))] | length' "$body")" = 0 ]
  [ "$(jq -r '.runs[0].results[0].ruleId' "$body")" = GHSA-0000-aaaa-0001 ]
  not grep -q '"snippet"' "$body"
  not grep -q 'contextRegion' "$body"
}

@test "strip-snippets: false uploads the file byte for byte" {
  start_mock all-success
  export INPUT_SARIF="osv=osv.sarif" INPUT_STRIP_SNIPPETS=false
  run_action
  [ "$status" -eq 0 ]
  [ "$(hits | jq -r '.[0].body_sha256')" = "$(shasum -a 256 osv.sarif | cut -d' ' -f1)" ]
}

@test "a mix of success and failure -> partial, exit 0" {
  start_mock partial
  export INPUT_SARIF="osv=osv.sarif
bad=gitleaks.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = partial ]
  [ "$(result_field osv .outcome)" = created ]
  [ "$(result_field bad .outcome)" = failed ]
  [ "$(result_field bad .http)" = 422 ]
  [[ "$(result_field bad .error)" == "invalid_report: "* ]]
  [[ "$output" == *"::warning::Lantern: 'bad' (sarif) failed (HTTP 422)"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "the same mix with fail-on-error: true -> exit 1 and ::error::" {
  start_mock partial
  export INPUT_SARIF="osv=osv.sarif
bad=gitleaks.sarif" INPUT_FAIL_ON_ERROR=true
  run_action
  [ "$status" -eq 1 ]
  [ "$(out_status)" = partial ]
  [[ "$output" == *"::error::Lantern: 'bad' (sarif) failed (HTTP 422)"* ]]
}

@test "409 -> stale, a warning not a failure, exit 0 even with fail-on-error" {
  start_mock stale
  export INPUT_SARIF="osv=osv.sarif" INPUT_FAIL_ON_ERROR=true
  run_action
  [ "$status" -eq 0 ]
  [ "$(result_field osv .outcome)" = stale ]
  [ "$(out_status)" = uploaded ]
  [[ "$output" == *"::warning::"*"is stale"* ]]
  [ "$(hit_count osv)" = 1 ]
}

@test "200 duplicate -> duplicate (success)" {
  start_mock duplicate
  export INPUT_SARIF="osv=osv.sarif" INPUT_SCANNED_AT="2026-07-07T16:24:55Z"
  run_action
  [ "$status" -eq 0 ]
  [ "$(result_field osv .outcome)" = duplicate ]
  [ "$(out_status)" = uploaded ]
  [ "$(hits | jq -r '.[0].scannedAt')" = "2026-07-07T16:24:55Z" ]
}

@test "500 then 201 -> created after a retry, with the same scannedAt on both attempts" {
  start_mock retry
  export INPUT_SARIF="flaky=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(result_field flaky .outcome)" = created ]
  [ "$(hit_count flaky)" = 2 ]
  [ "$(hits | jq '[.[].scannedAt] | unique | length')" = 1 ]
  [ "$(hits | jq '[.[] | select(.violation)] | length')" = 0 ]
  [ "$(hits | jq -r '[.[].status] | join(",")')" = "500,201" ]
}

@test "429 with Retry-After then 201 -> created" {
  start_mock retry
  export INPUT_SARIF="limited=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(result_field limited .outcome)" = created ]
  [ "$(hit_count limited)" = 2 ]
}

@test "persistent 503: three attempts, then failed (exit 0 unless fail-on-error)" {
  start_mock always-500
  export INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = failed ]
  [ "$(hit_count osv)" = 3 ]
  export INPUT_FAIL_ON_ERROR=true
  run_action
  [ "$status" -eq 1 ]
}

@test "401 is not retried and shows Lantern's message" {
  start_mock unauthorized
  export INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(hit_count osv)" = 1 ]
  [[ "$output" == *"unauthorized: Invalid or missing API key."* ]]
}

@test "empty api-key -> skipped quietly (notice, no warning), no requests" {
  start_mock all-success
  export INPUT_API_KEY="" INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = skipped ]
  [ "$(hits | jq length)" = 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "upload-on: never -> dry-run, validated, zero HTTP calls (even without a key)" {
  start_mock all-success
  export INPUT_UPLOAD_ON=never INPUT_API_KEY="" INPUT_SARIF="$(sarif_pair)
missing=nope.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = dry-run ]
  [ "$(hits | jq length)" = 0 ]
  [ "$(out_results | jq '[.[] | select(.outcome == "skipped")] | length')" = 3 ]
  [[ "$output" == *"::warning::"*"not found"* ]]
  grep -q 'dry-run' "$GITHUB_STEP_SUMMARY"
}

@test "pull_request event with the default-branch gate -> skipped, no requests" {
  start_mock all-success
  export INPUT_UPLOAD_ON=default-branch GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/7/merge
  export INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = skipped ]
  [ "$(hits | jq length)" = 0 ]
  [[ "$output" == *"::notice::"*"pull_request"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "pull_request_target is gated too" {
  start_mock all-success
  export INPUT_UPLOAD_ON=default-branch GITHUB_EVENT_NAME=pull_request_target INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$(out_status)" = skipped ]
  [ "$(hits | jq length)" = 0 ]
}

@test "default-branch gate: another branch is skipped, the default branch and a schedule upload" {
  start_mock all-success
  export INPUT_UPLOAD_ON=default-branch INPUT_SARIF="osv=osv.sarif"
  GITHUB_REF=refs/heads/feature/x run_action
  [ "$(out_status)" = skipped ]
  [ "$(hits | jq length)" = 0 ]
  : >"$GITHUB_OUTPUT"
  GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/main run_action
  [ "$(out_status)" = uploaded ]
  : >"$GITHUB_OUTPUT"
  GITHUB_REF=refs/heads/main run_action
  [ "$(out_status)" = uploaded ]
  [ "$(hits | jq length)" = 2 ]
}

@test "default-branch gate: tags and an unknown default branch are skipped" {
  start_mock all-success
  export INPUT_UPLOAD_ON=default-branch INPUT_SARIF="osv=osv.sarif"
  GITHUB_REF=refs/tags/v1 run_action
  [ "$(out_status)" = skipped ]
  : >"$GITHUB_OUTPUT"
  LANTERN_DEFAULT_BRANCH="" run_action
  [ "$(out_status)" = skipped ]
  [ "$(hits | jq length)" = 0 ]
}

@test "upload-on: always uploads from a pull_request" {
  start_mock all-success
  export GITHUB_EVENT_NAME=pull_request INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$(out_status)" = uploaded ]
}

@test "a missing file is skipped with a warning while the rest uploads" {
  start_mock all-success
  export INPUT_SARIF="osv=osv.sarif
ghost=ghost.sarif
broken=invalid.json"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = uploaded ]
  [ "$(hits | jq length)" = 1 ]
  [ "$(result_field ghost .outcome)" = skipped ]
  [ "$(result_field broken .error)" = "invalid JSON" ]
  [[ "$output" != *"::error::"* ]]
}

@test "nothing valid to upload -> skipped" {
  start_mock all-success
  export INPUT_SARIF="ghost=ghost.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = skipped ]
}

@test "http:// lantern-url is refused: failed, nothing sent" {
  start_mock all-success
  export INPUT_LANTERN_URL="http://localhost:1" INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = failed ]
  [ "$(hits | jq length)" = 0 ]
  [[ "$output" == *"lantern-url must be an https:// URL"* ]]
  INPUT_FAIL_ON_ERROR=true run_action
  [ "$status" -eq 1 ]
}

@test "an invalid scanned-at override is refused rather than silently replaced" {
  start_mock all-success
  export INPUT_SCANNED_AT="yesterday" INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$(out_status)" = failed ]
  [ "$(hits | jq length)" = 0 ]
}

@test "an unreachable server -> failed after retries, never a crash" {
  export INPUT_LANTERN_URL="https://localhost:1" INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out_status)" = failed ]
  [[ "$(result_field osv .error)" == *"network error"* ]]
}

@test "whitespace around the key (a copy-paste newline) is tolerated" {
  start_mock all-success
  export INPUT_API_KEY="$(printf '  %s\n' "$FAKE_KEY")" INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$(out_status)" = uploaded ]
  [ "$(hits | jq '[.[] | select(.auth_ok)] | length')" = 1 ]
}

@test "the API key never appears in logs, outputs or the summary (success and failure paths)" {
  for scenario in all-success partial always-500 unauthorized; do
    start_mock "$scenario"
    act_env
    export INPUT_SARIF="osv=osv.sarif
bad=gitleaks.sarif" INPUT_A11Y="a11y=a11y.json" INPUT_FAIL_ON_ERROR=true
    run_action
    printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/log-$scenario"
    # the ::add-mask:: line carries the key by design: the runner consumes it and redacts the key
    [ "$(grep -v '^::add-mask::' "$BATS_TEST_TMPDIR/log-$scenario" | grep -cF -- "$FAKE_KEY" || true)" = 0 ]
    not grep -F -- "$FAKE_KEY" "$GITHUB_OUTPUT"
    not grep -F -- "$FAKE_KEY" "$GITHUB_STEP_SUMMARY"
    not grep -rF -- "$FAKE_KEY" "$MOCK_DIR/server.log"
    not grep -F -- "$FAKE_KEY" "$MOCK_DIR/hits.jsonl"
    stop_mock
  done
  grep -q "::add-mask::$FAKE_KEY" "$BATS_TEST_TMPDIR/log-all-success"
}

@test "the key is not visible on any command line while uploading" {
  # Hold the mock's reply open by pointing at a stub 'curl' that records its arguments.
  mkdir -p bin
  cat >bin/curl <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGS_LOG"
out=""; prev=""
for a in "$@"; do [[ "$prev" == "--output" ]] && out=$a; prev=$a; done
echo '{"runId":"r"}' >"$out"
printf '201'
STUB
  chmod +x bin/curl
  export ARGS_LOG="$BATS_TEST_TMPDIR/args.log"
  export INPUT_SARIF="osv=osv.sarif"
  PATH="$PWD/bin:$PATH" run_action
  [ "$(out_status)" = uploaded ]
  not grep -F -- "$FAKE_KEY" "$ARGS_LOG"
  grep -q -- '^@.*auth.hdr$' "$ARGS_LOG"
}

@test "outputs: results is a valid one-line JSON array; the summary has the table and the link" {
  start_mock all-success
  export INPUT_SARIF="osv=osv.sarif"
  run_action
  out_results | jq -e 'type == "array" and length == 1 and (.[0] | has("source", "format", "file", "http", "outcome"))' >/dev/null
  grep -q '^| Source | Format | Outcome | Opened | Closed | Reopened | Open |' "$GITHUB_STEP_SUMMARY"
  grep -q '^| osv | sarif | created | 2 | 1 | 0 | 2 (0/1/1/0 c/h/m/l) |' "$GITHUB_STEP_SUMMARY"
  grep -q "\[Open Lantern\]($MOCK_URL)" "$GITHUB_STEP_SUMMARY"
  grep -q 'Commit: `0123456789ab`' "$GITHUB_STEP_SUMMARY"
  grep -q 'actions/runs/42' "$GITHUB_STEP_SUMMARY"
}

@test "metadata is shown but never sent to Lantern" {
  start_mock all-success
  export INPUT_SARIF="osv=osv.sarif"
  run_action
  not grep -qF 0123456789abcdef "$MOCK_DIR/hits.jsonl"
  [ "$(hits | jq -r '.[0].path')" = "/api/v1/reports" ]
}

@test "hostile server text cannot inject workflow commands or break the summary table" {
  cat >"$BATS_TEST_TMPDIR/evil.json" <<'JSON'
{"routes":{},"default":{"status":422,"body":{"error":{"code":"invalid_report","message":"x\n::error::pwned | <script>alert(1)</script>"}}}}
JSON
  MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  MOCK_URL=$("$REPO_ROOT/test/mock-server/start.sh" "$BATS_TEST_TMPDIR/evil.json" "$MOCK_DIR" "$FAKE_KEY")
  export MOCK_URL CURL_CA_BUNDLE="$MOCK_DIR/cert.pem" INPUT_LANTERN_URL="$MOCK_URL" INPUT_SARIF="osv=osv.sarif"
  run_action
  [ "$status" -eq 0 ]
  not grep -q '^::error::' <<<"$output"
  not grep -q '<script>' "$GITHUB_STEP_SUMMARY"
}
