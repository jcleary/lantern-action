# Shared bats helpers.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FAKE_KEY="ltn_testkey_AbCdEf0123456789-sEcReT-DoNotLeak0123456789abcdef"

load_libs() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/common.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/inputs.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/sarif.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/metadata.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/upload.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/summary.sh"
}

# A scratch $LT_WORK for unit tests that call library functions directly.
setup_work() {
  LT_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$LT_WORK"
  : >"$LT_WORK/entries.tsv"
  LT_MAX_MB=10
  LT_FAIL_ON_ERROR=false
  export LT_WORK LT_MAX_MB LT_FAIL_ON_ERROR
}

# Results as a compact JSON array.
results() { results_json; }

# --- integration helpers ----------------------------------------------------

# start_mock <scenario-name>: HTTPS mock on a free port; trusts its cert via CURL_CA_BUNDLE.
start_mock() {
  MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  MOCK_URL=$("$REPO_ROOT/test/mock-server/start.sh" "$REPO_ROOT/test/mock-server/scenarios/$1.json" "$MOCK_DIR" "$FAKE_KEY")
  export MOCK_DIR MOCK_URL
  export CURL_CA_BUNDLE="$MOCK_DIR/cert.pem" INPUT_LANTERN_URL="$MOCK_URL"
}

stop_mock() {
  if [[ -n "${MOCK_DIR:-}" && -f "$MOCK_DIR/pid" ]]; then
    kill "$(cat "$MOCK_DIR/pid")" 2>/dev/null || true
  fi
}

# A push to the default branch with a key and the mock URL; tests override what they need.
act_env() {
  export GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
  export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/widgets
  export LANTERN_DEFAULT_BRANCH=main
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/github_summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  export INPUT_API_KEY="$FAKE_KEY"
  export INPUT_LANTERN_URL="${MOCK_URL:-https://lantern.invalid}"
  export INPUT_UPLOAD_ON=always
  export INPUT_SARIF="" INPUT_A11Y="" INPUT_SONARQUBE="" INPUT_SCANNED_AT=""
  export INPUT_MAX_PAYLOAD_MB=10 INPUT_STRIP_SNIPPETS=true INPUT_FAIL_ON_ERROR=false
  export LANTERN_RETRY_DELAYS="1 1 1"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
}

run_action() { run bash "$REPO_ROOT/scripts/main.sh"; }

out_status() { grep '^status=' "$GITHUB_OUTPUT" | head -n1 | cut -d= -f2-; }
out_results() { awk '/^results<</ { getline; print; exit }' "$GITHUB_OUTPUT"; }
# result_field <source> <jq-expression on the entry>
result_field() { out_results | jq -r --arg s "$1" ".[] | select(.source == \$s) | $2"; }
hits() { jq -cs . "$MOCK_DIR/hits.jsonl"; }
hit_count() { jq -s --arg s "$1" '[.[] | select(.source == $s)] | length' "$MOCK_DIR/hits.jsonl"; }

# `! cmd` never fails a bats test (negation is exempt from errexit); `not cmd` does.
not() { if "$@"; then return 1; fi; }
