#!/usr/bin/env bats

load helpers

setup() {
  load_libs
  setup_work
  cd "$BATS_TEST_TMPDIR"
  cp "$REPO_ROOT"/test/fixtures/*.s* "$REPO_ROOT"/test/fixtures/*.json . 2>/dev/null || true
}

entries() { cat "$LT_WORK/entries.tsv"; }

@test "valid entries are accepted and the key is lower-cased" {
  parse_source_list sarif "OSV=osv.sarif
Gitleaks = gitleaks.sarif" >/dev/null
  [ "$(entries)" = "$(printf 'sarif\tosv\tosv.sarif\nsarif\tgitleaks\tgitleaks.sarif')" ]
  [ "$(results)" = "[]" ]
}

@test "blank lines, comments and CRLF endings are ignored or tolerated" {
  parse_source_list sarif "$(printf '# a comment\n\nosv=osv.sarif\r\n')" >/dev/null
  [ "$(entries)" = "$(printf 'sarif\tosv\tosv.sarif')" ]
}

@test "a path may itself contain '='" {
  cp osv.sarif "we=ird.sarif"
  parse_source_list sarif "osv=we=ird.sarif" >/dev/null
  [ "$(entries)" = "$(printf 'sarif\tosv\twe=ird.sarif')" ]
}

@test "source keys: accepts the allowed alphabet and 64 chars" {
  valid_source_key a
  valid_source_key zap-privsec
  valid_source_key a_b-c9
  valid_source_key "$(printf 'a%.0s' $(seq 1 64))"
}

@test "source keys: rejects bad characters, leading punctuation and 65 chars" {
  not valid_source_key "-lead"
  not valid_source_key "_lead"
  not valid_source_key "has space"
  not valid_source_key "dot.ted"
  not valid_source_key "UPPER"
  not valid_source_key ""
  not valid_source_key "$(printf 'a%.0s' $(seq 1 65))"
}

@test "an invalid key is warned about, skipped and recorded" {
  run parse_source_list sarif "bad key=osv.sarif"
  [[ "$output" == *"::warning::"*"must match"* ]]
  parse_source_list sarif "bad key=osv.sarif" >/dev/null
  [ -z "$(entries)" ]
  [ "$(results | jq -r '.[0].outcome')" = "skipped" ]
}

@test "malformed lines warn and are skipped" {
  run parse_source_list sarif "justapath.sarif
=osv.sarif
osv="
  [ "$(grep -c '::warning::' <<<"$output")" = "3" ]
  [[ "$output" == *"expected 'source-key=path'"* ]]
  [[ "$output" == *"both a source key and a path are required"* ]]
  parse_source_list sarif "justapath.sarif" >/dev/null
  [ -z "$(entries)" ]
}

@test "duplicate keys: the second entry is skipped with a warning, across formats" {
  run parse_source_list sarif "osv=osv.sarif
OSV=gitleaks.sarif"
  [[ "$output" == *"Duplicate source key 'osv'"* ]]
  : >"$LT_WORK/seen"; : >"$LT_WORK/entries.tsv"
  parse_source_list sarif "osv=osv.sarif" >/dev/null
  parse_source_list a11y "osv=a11y.json" >/dev/null
  [ "$(entries)" = "$(printf 'sarif\tosv\tosv.sarif')" ]
  [ "$(results | jq -r '.[0].error')" = "duplicate source key" ]
}

@test "a missing file warns and is skipped" {
  run parse_source_list sarif "osv=nope.sarif"
  [[ "$output" == *"::warning::"*"not found"* ]]
  parse_source_list sarif "osv=nope.sarif" >/dev/null
  [ -z "$(entries)" ]
  [ "$(results | jq -r '.[0].error')" = "file not found" ]
}

@test "a directory is not a report file" {
  mkdir adir
  run parse_source_list sarif "osv=adir"
  [[ "$output" == *"not found"* ]]
}

@test "files over max-payload-mb are skipped; files under are accepted" {
  LT_MAX_MB=1
  head -c 1200000 /dev/zero | tr '\0' ' ' >big.json
  run parse_source_list sarif "big=big.json"
  [[ "$output" == *"over the 1 MB limit"* ]]
  parse_source_list sarif "big=big.json" >/dev/null
  [ -z "$(entries)" ]
  : >"$LT_WORK/seen"
  head -c 900000 /dev/zero | tr '\0' ' ' >ok.json
  parse_source_list sarif "ok=ok.json" >/dev/null
  [ "$(entries)" = "$(printf 'sarif\tok\tok.json')" ]
}

@test "invalid JSON is caught locally and skipped" {
  run parse_source_list sarif "osv=invalid.json"
  [[ "$output" == *"not valid JSON"* ]]
  parse_source_list sarif "osv=invalid.json" >/dev/null
  [ -z "$(entries)" ]
  [ "$(results | jq -r '.[0].error')" = "invalid JSON" ]
}

@test "base URL: https only, trailing slashes trimmed, empty means the default" {
  [ "$(normalize_base_url "https://lantern-staging.foundryhq.co.uk/")" = "https://lantern-staging.foundryhq.co.uk" ]
  [ "$(normalize_base_url "  https://example.com:8443/lantern  ")" = "https://example.com:8443/lantern" ]
  [ "$(normalize_base_url "")" = "https://lantern.foundryhq.co.uk" ]
  not normalize_base_url "http://lantern.example.com"
  not normalize_base_url "ftp://lantern.example.com"
  not normalize_base_url "https://user:pw@example.com"
  not normalize_base_url "https://example.com/?x=1"
  not normalize_base_url "https://exa mple.com"
  not normalize_base_url "lantern.example.com"
}

@test "scanned-at must be a UTC instant ending in Z" {
  valid_scanned_at "2026-07-07T16:24:55Z"
  valid_scanned_at "2026-07-07T16:24:55.123Z"
  not valid_scanned_at "2026-07-07T16:24:55+01:00"
  not valid_scanned_at "2026-07-07 16:24:55Z"
  not valid_scanned_at "yesterday"
}

@test "max-payload-mb falls back to 10 with a warning when not a positive integer" {
  [ "$(normalize_max_mb 25 2>/dev/null)" = "25" ]
  [ "$(normalize_max_mb 0 2>/dev/null)" = "10" ]
  [ "$(normalize_max_mb abc 2>/dev/null)" = "10" ]
  [ "$(normalize_max_mb -3 2>/dev/null)" = "10" ]
}

@test "booleans: case-insensitive, anything else takes the default" {
  [ "$(normalize_bool TRUE false)" = "true" ]
  [ "$(normalize_bool " false " true)" = "false" ]
  [ "$(normalize_bool yes false)" = "false" ]
  [ "$(normalize_bool "" true)" = "true" ]
}

@test "workflow-command escaping stops untrusted text starting a new command" {
  run log_warning "$(printf 'line1\n::error::injected')"
  [ "$output" = "::warning::line1%0A::error::injected" ]
}
