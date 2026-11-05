#!/usr/bin/env bats

load helpers

setup() {
  load_libs
  setup_work
  LT_BASE_URL="https://lantern.example.test"
  LT_VERSION="9.9.9"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  echo 0 >"$STUB/n"
  : >"$STUB/sleeps"
  : >"$STUB/urls"
  : >"$STUB/uas"
  printf '{}' >"$BATS_TEST_TMPDIR/report.json"
  prepare_auth_header "$FAKE_KEY"
  # Defined after load_libs so they replace the real lt_sleep.
  lt_sleep() { echo "$1" >>"$STUB/sleeps"; }
}

# script_response <n> <http> [body] [headers] [curl-rc]: what the n-th curl call returns.
script_response() {
  printf '%s' "$2" >"$STUB/$1.http"
  printf '%s' "${3:-}" >"$STUB/$1.body"
  printf '%b' "${4:-}" >"$STUB/$1.headers"
  printf '%s' "${5:-0}" >"$STUB/$1.rc"
}

# A fake curl: serves the scripted responses and records the URL and User-Agent it was given.
curl() {
  local n out="" hdr="" url="" prev="" a
  n=$(($(cat "$STUB/n") + 1))
  echo "$n" >"$STUB/n"
  for a in "$@"; do
    case "$prev" in
      --output) out=$a ;;
      --dump-header) hdr=$a ;;
      --header) [[ "$a" == User-Agent:* ]] && echo "$a" >>"$STUB/uas" ;;
    esac
    prev=$a
    url=$a
  done
  echo "$url" >>"$STUB/urls"
  cp "$STUB/$n.body" "$out"
  cp "$STUB/$n.headers" "$hdr"
  if [[ "$(cat "$STUB/$n.rc")" != "0" ]]; then
    echo "curl: (6) Could not resolve host: lantern.example.test" >&2
    return "$(cat "$STUB/$n.rc")"
  fi
  printf '%s' "$(cat "$STUB/$n.http")"
}

calls() { cat "$STUB/n"; }
sleeps() { tr '\n' ' ' <"$STUB/sleeps" | sed 's/ $//'; }

map() { # map <http> [body]
  printf '%s' "${2:-}" >"$BATS_TEST_TMPDIR/b.json"
  map_response "$1" "$BATS_TEST_TMPDIR/b.json"
}

@test "201 -> created" {
  map 201 '{"runId":"r1"}'
  [ "$UP_OUTCOME" = created ] && [ "$UP_KIND" = success ]
}

@test "200 with duplicate:true -> duplicate (success)" {
  map 200 '{"duplicate":true,"runId":"r1"}'
  [ "$UP_OUTCOME" = duplicate ] && [ "$UP_KIND" = success ]
}

@test "200 without duplicate:true is not trusted -> failed" {
  map 200 '<html>captive portal</html>'
  [ "$UP_OUTCOME" = failed ] && [ "$UP_KIND" = fatal ]
}

@test "409 -> stale (success, not a failure)" {
  map 409 '{"error":{"code":"stale_scan","message":"A newer scan is already recorded for this source."}}'
  [ "$UP_OUTCOME" = stale ] && [ "$UP_KIND" = success ]
}

@test "401 -> failed, with Lantern's code and message and a hint, never retried" {
  map 401 '{"error":{"code":"unauthorized","message":"Invalid or missing API key."}}'
  [ "$UP_OUTCOME" = failed ] && [ "$UP_KIND" = fatal ]
  [[ "$UP_ERROR" == "unauthorized: Invalid or missing API key."* ]]
  [[ "$UP_ERROR" == *"api-key"* ]]
}

@test "400, 413, 422 and other 4xx -> failed with the error code" {
  map 400 '{"error":{"code":"bad_request","message":"bad scannedAt"}}'
  [ "$UP_OUTCOME" = failed ] && [ "$UP_KIND" = fatal ] && [[ "$UP_ERROR" == "bad_request: bad scannedAt" ]]
  map 413 '{"error":{"code":"payload_too_large","message":"too big"}}'
  [ "$UP_KIND" = fatal ] && [[ "$UP_ERROR" == "payload_too_large: too big" ]]
  map 422 '{"error":{"code":"invalid_report","message":"not a valid SARIF document"}}'
  [ "$UP_KIND" = fatal ] && [[ "$UP_ERROR" == "invalid_report: not a valid SARIF document" ]]
  map 418 ''
  [ "$UP_OUTCOME" = failed ] && [ "$UP_KIND" = fatal ]
}

@test "403 with a plain-text body -> failed, body not echoed" {
  map 403 'Cross-site POST form submissions are forbidden'
  [ "$UP_OUTCOME" = failed ] && [ "$UP_KIND" = fatal ]
  [[ "$UP_ERROR" != *"Cross-site"* ]]
  [[ "$UP_ERROR" == "HTTP 403"* ]]
}

@test "429, 5xx and network errors are retryable" {
  for code in 429 500 502 503 504 000; do
    map "$code" ''
    [ "$UP_KIND" = retry ] || { echo "$code not retryable"; return 1; }
  done
}

@test "other statuses (redirects) fail without retry" {
  map 302 ''
  [ "$UP_OUTCOME" = failed ] && [ "$UP_KIND" = fatal ]
}

@test "server error text is sanitised: no newlines, bounded length" {
  map 422 "$(jq -cn --arg m "$(printf 'line1\n::error::boom%0.s' 1)$(head -c 900 /dev/zero | tr '\0' x)" '{error:{code:"invalid_report",message:$m}}')"
  [[ "$UP_ERROR" != *$'\n'* ]]
  [ "${#UP_ERROR}" -lt 400 ]
}

@test "Retry-After: parsed, capped at 60, ignored when it is a date" {
  printf 'HTTP/1.1 429\r\nRetry-After: 7\r\n\r\n' >"$BATS_TEST_TMPDIR/h"
  [ "$(retry_after_seconds "$BATS_TEST_TMPDIR/h")" = 7 ]
  printf 'HTTP/1.1 429\r\nretry-after:   120 \r\n\r\n' >"$BATS_TEST_TMPDIR/h"
  [ "$(retry_after_seconds "$BATS_TEST_TMPDIR/h")" = 60 ]
  printf 'HTTP/1.1 429\r\nRetry-After: 08\r\n\r\n' >"$BATS_TEST_TMPDIR/h"
  [ "$(retry_after_seconds "$BATS_TEST_TMPDIR/h")" = 8 ]
  printf 'HTTP/1.1 429\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n' >"$BATS_TEST_TMPDIR/h"
  not retry_after_seconds "$BATS_TEST_TMPDIR/h"
  printf 'HTTP/1.1 500\r\n\r\n' >"$BATS_TEST_TMPDIR/h"
  not retry_after_seconds "$BATS_TEST_TMPDIR/h"
}

@test "500, 500, 201: backs off 2s then 5s, succeeds, reuses the identical URL" {
  LT_RETRY_DELAYS="2 5 10"
  script_response 1 500 '{"error":{"code":"internal","message":"boom"}}'
  script_response 2 500 ''
  script_response 3 201 '{"runId":"r1"}'
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$UP_OUTCOME" = created ]
  [ "$(calls)" = 3 ]
  [ "$(sleeps)" = "2 5" ]
  [ "$(sort -u "$STUB/urls" | wc -l | tr -d ' ')" = 1 ]
  grep -q 'source=osv&format=sarif&scannedAt=2026-07-07T16:24:55Z' "$STUB/urls"
  grep -q 'User-Agent: lantern-action/9.9.9' "$STUB/uas"
}

@test "429 with Retry-After: waits that long instead of the backoff" {
  script_response 1 429 '' 'HTTP/1.1 429\r\nRetry-After: 7\r\n\r\n'
  script_response 2 201 '{"runId":"r1"}'
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$UP_OUTCOME" = created ]
  [ "$(sleeps)" = 7 ]
}

@test "Retry-After above 60 is capped to 60" {
  script_response 1 503 '' 'HTTP/1.1 503\r\nRetry-After: 3600\r\n\r\n'
  script_response 2 201 '{"runId":"r1"}'
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$(sleeps)" = 60 ]
}

@test "a 4xx is never retried" {
  script_response 1 422 '{"error":{"code":"invalid_report","message":"nope"}}'
  script_response 2 201 '{"runId":"r1"}'
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$UP_OUTCOME" = failed ]
  [ "$(calls)" = 1 ]
  [ -z "$(sleeps)" ]
}

@test "gives up after 3 attempts and reports failed" {
  for i in 1 2 3 4; do script_response "$i" 503 '{"error":{"code":"unavailable","message":"try later"}}'; done
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$UP_OUTCOME" = failed ]
  [ "$(calls)" = 3 ]
  [[ "$UP_ERROR" == *"gave up after 3 attempts"* ]]
}

@test "a transport error is retried and then succeeds" {
  script_response 1 000 '' '' 6
  script_response 2 201 '{"runId":"r1"}'
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$UP_OUTCOME" = created ]
  [ "$(calls)" = 2 ]
}

@test "persistent network error -> failed, with the curl reason" {
  for i in 1 2 3; do script_response "$i" 000 '' '' 6; done
  upload_report osv sarif "$BATS_TEST_TMPDIR/report.json" 2026-07-07T16:24:55Z >/dev/null
  [ "$UP_OUTCOME" = failed ]
  [[ "$UP_ERROR" == *"network error: curl: (6) Could not resolve host"* ]]
}

@test "the auth header file is private and holds the key; the key is not in curl's arguments" {
  [ "$(stat -c %a "$LT_AUTH_FILE" 2>/dev/null || stat -f %Lp "$LT_AUTH_FILE")" = 600 ]
  grep -q "Bearer $FAKE_KEY" "$LT_AUTH_FILE"
  # attempt_once passes the header as @file, never inline
  run grep -n 'Bearer' "$REPO_ROOT/scripts/lib/upload.sh"
  [[ "$output" != *'$LT_API_KEY'* ]]
}

@test "add_result keeps runId and counts from the response and drops junk" {
  printf '%s' '{"runId":"abc","opened":2,"closed":1,"reopened":0,"open":{"critical":1,"high":0,"medium":2,"low":3},"extra":"x"}' >"$BATS_TEST_TMPDIR/b.json"
  add_result osv sarif osv.sarif 201 created "" "$BATS_TEST_TMPDIR/b.json"
  [ "$(results | jq -c '.[0]')" = '{"source":"osv","format":"sarif","file":"osv.sarif","http":201,"outcome":"created","runId":"abc","opened":2,"closed":1,"reopened":0,"open":{"critical":1,"high":0,"medium":2,"low":3}}' ]
}
