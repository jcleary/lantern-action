#!/usr/bin/env bats
# strix/strix-run.sh assemble: ids, retest verdicts, redaction, and refusing incomplete runs.

load helpers

setup() {
  SCRIPT="$REPO_ROOT/strix/strix-run.sh"
  RUN="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN/vulnerabilities" "$RUN/.state"
  cat >"$RUN/run.json" <<'J'
{ "run_id": "demo_0002", "status": "completed", "start_time": "2026-11-13T17:00:00Z", "end_time": "2026-11-13T17:30:00Z" }
J
  cat >"$RUN/vulnerabilities.json" <<'J'
[
  { "id": "vuln-0001", "title": "Reworded known bug", "severity": "high", "cwe": "CWE-639", "cvss": 8.1,
    "endpoint": "/api/a", "method": "POST", "description": "d1", "remediation_steps": "fix1", "confidence": "High" },
  { "id": "vuln-0002", "title": "Brand new bug", "severity": "medium", "cwe": "CWE-79", "cvss": 5.0,
    "endpoint": "/api/b", "method": "GET", "description": "d2", "remediation_steps": "fix2", "confidence": "Medium" }
]
J
  printf '# Reworded known bug\n\nattacker = token("a@b.test", "hunter2hunter2")\nAuthorization: Bearer abcdefghijklmnopqrstuvwxyz012345\n' >"$RUN/vulnerabilities/vuln-0001.md"
  printf '# Brand new bug\n\nBody\n' >"$RUN/vulnerabilities/vuln-0002.md"
  cat >"$RUN/.state/notes.json" <<'J'
{
  "n1": { "title": "Valid tokens", "content": "SECRET-DO-NOT-FORWARD", "updated_at": "2026-11-13T17:10:00Z" },
  "n2": { "title": "LANTERN-RESULT", "updated_at": "2026-11-13T17:29:00Z",
          "content": "{\"map\":{\"vuln-0001\":\"STRIX-0003\"},\"retest\":{\"STRIX-0001\":{\"verdict\":\"resolved\",\"note\":\"now 403\"},\"STRIX-0002\":{\"verdict\":\"could_not_verify\"},\"STRIX-0003\":{\"verdict\":\"resolved\",\"note\":\"conflict\"}}}" }
}
J
  cat >"$BATS_TEST_TMPDIR/prev.json" <<'J'
{ "issues": [
  { "externalId": "STRIX-0001", "status": "open" },
  { "externalId": "STRIX-0002", "status": "open" },
  { "externalId": "STRIX-0003", "status": "open" } ] }
J
  OUT="$BATS_TEST_TMPDIR/out.json"
}

assemble() { "$SCRIPT" assemble --run-dir "$RUN" --previous "$BATS_TEST_TMPDIR/prev.json" --out "$OUT" "$@"; }

@test "reuses the mapped id, numbers new findings after the highest previous id, embeds markdown" {
  run assemble
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings | map(.externalId) | join(",")' "$OUT")" = "STRIX-0003,STRIX-0004" ]
  [ "$(jq -r '.findings[0].retest' "$OUT")" = still_present ]
  [ "$(jq -r '.findings[1].retest' "$OUT")" = new ]
  [ "$(jq -r '.findings[1].markdown' "$OUT" | head -n1)" = "# Brand new bug" ]
  [ "$(jq -r '.run.status' "$OUT")" = completed ]
}

@test "only a verified fix of a still-open, un-re-reported issue is resolved" {
  run assemble
  [ "$status" -eq 0 ]
  # STRIX-0001 resolved; STRIX-0002 could_not_verify stays open; STRIX-0003 is re-reported so its resolved verdict is ignored
  [ "$(jq -c '.resolved | map(.externalId)' "$OUT")" = '["STRIX-0001"]' ]
  [[ "$output" == *"ignored the resolved verdict for STRIX-0003"* ]]
}

@test "redacts secrets and never forwards other notes" {
  run assemble
  [ "$status" -eq 0 ]
  ! grep -q 'hunter2hunter2' "$OUT"
  ! grep -q 'abcdefghijklmnopqrstuvwxyz012345' "$OUT"
  ! grep -q 'SECRET-DO-NOT-FORWARD' "$OUT"
  grep -q '\[redacted\]' "$OUT"
}

@test "extra --redact patterns are applied" {
  printf 'Brand new\n' >"$BATS_TEST_TMPDIR/redact.txt"
  run assemble --redact "$BATS_TEST_TMPDIR/redact.txt"
  [ "$status" -eq 0 ]
  ! jq -r '.findings[].markdown' "$OUT" | grep -q 'Brand new'
}

@test "without a LANTERN-RESULT note: fresh ids, nothing resolved, a warning" {
  jq 'del(.n2)' "$RUN/.state/notes.json" >"$RUN/.state/n.json" && mv "$RUN/.state/n.json" "$RUN/.state/notes.json"
  run assemble
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings | map(.externalId) | join(",")' "$OUT")" = "STRIX-0004,STRIX-0005" ]
  [ "$(jq '.resolved | length' "$OUT")" = 0 ]
  [[ "$output" == *"no usable LANTERN-RESULT note"* ]]
}

@test "refuses a run that is not completed" {
  jq '.status = "crashed"' "$RUN/run.json" >"$RUN/r.json" && mv "$RUN/r.json" "$RUN/run.json"
  run assemble
  [ "$status" -ne 0 ]
  [[ "$output" == *"not 'completed'"* ]]
  [ ! -s "$OUT" ] || [ ! -e "$OUT" ]
}

@test "first run (no previous file) starts numbering at STRIX-0001" {
  rm "$BATS_TEST_TMPDIR/prev.json"
  jq 'del(.n2)' "$RUN/.state/notes.json" >"$RUN/.state/n.json" && mv "$RUN/.state/n.json" "$RUN/.state/notes.json"
  run "$SCRIPT" assemble --run-dir "$RUN" --out "$OUT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings | map(.externalId) | join(",")' "$OUT")" = "STRIX-0001,STRIX-0002" ]
}

@test "the output is accepted by Lantern's shape rules: unique ids, none both finding and resolved" {
  run assemble
  [ "$status" -eq 0 ]
  jq -e '(.findings | map(.externalId) | length) == (.findings | map(.externalId) | unique | length)' "$OUT"
  jq -e '[.resolved[].externalId] - [.findings[].externalId] == [.resolved[].externalId]' "$OUT"
}
