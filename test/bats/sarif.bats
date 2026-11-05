#!/usr/bin/env bats

load helpers

setup() {
  load_libs
  OUT="$BATS_TEST_TMPDIR/stripped.json"
}

@test "strips region.snippet, contextRegion and codeFlows everywhere they occur" {
  strip_sarif "$REPO_ROOT/test/fixtures/osv.sarif" "$OUT"
  run jq '[.. | objects | select(has("contextRegion") or has("codeFlows"))] | length' "$OUT"
  [ "$output" = 0 ]
  run jq '[.. | objects | select(has("region")) | .region | select(type == "object" and has("snippet"))] | length' "$OUT"
  [ "$output" = 0 ]
}

@test "everything else is unchanged in meaning (compared with an explicit hand-written deletion)" {
  strip_sarif "$REPO_ROOT/test/fixtures/osv.sarif" "$OUT"
  expected="$BATS_TEST_TMPDIR/expected.json"
  jq 'del(
        .runs[0].results[0].locations[0].physicalLocation.region.snippet,
        .runs[0].results[0].locations[0].physicalLocation.contextRegion,
        .runs[0].results[0].relatedLocations[0].physicalLocation.region.snippet,
        .runs[0].results[0].codeFlows)' "$REPO_ROOT/test/fixtures/osv.sarif" >"$expected"
  [ "$(jq -S . "$OUT")" = "$(jq -S . "$expected")" ]
  # and what Lantern reads is still there
  run jq -r '.runs[0].results[0] | [.ruleId, .level, .message.text, .locations[0].physicalLocation.artifactLocation.uri, (.locations[0].physicalLocation.region.startLine | tostring)] | join("|")' "$OUT"
  [ "$output" = "GHSA-0000-aaaa-0001|error|Package 'example-package@1.0.0' is vulnerable to GHSA-0000-aaaa-0001.|package-lock.json|12" ]
}

@test "'snippet' outside a region, and other keys, are left alone" {
  printf '%s' '{"runs":[{"properties":{"snippet":"keep me"},"results":[{"message":{"text":"snippet codeFlows contextRegion"},"locations":[{"physicalLocation":{"region":{"startLine":1,"snippet":{"text":"drop"}}}}]}]}]}' >"$BATS_TEST_TMPDIR/in.json"
  strip_sarif "$BATS_TEST_TMPDIR/in.json" "$OUT"
  [ "$(jq -cS . "$OUT")" = '{"runs":[{"properties":{"snippet":"keep me"},"results":[{"locations":[{"physicalLocation":{"region":{"startLine":1}}}],"message":{"text":"snippet codeFlows contextRegion"}}]}]}' ]
}

@test "a SARIF file with none of those fields is unchanged in meaning" {
  strip_sarif "$REPO_ROOT/test/fixtures/a11y.json" "$OUT"
  [ "$(jq -S . "$OUT")" = "$(jq -S . "$REPO_ROOT/test/fixtures/a11y.json")" ]
}

@test "the stripped output is valid JSON and a single line" {
  strip_sarif "$REPO_ROOT/test/fixtures/gitleaks.sarif" "$OUT"
  jq empty "$OUT"
  [ "$(wc -l <"$OUT" | tr -d ' ')" = 1 ]
}
