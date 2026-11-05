#!/usr/bin/env bash
# lantern-action entrypoint: inputs -> validate -> gate -> upload each -> outputs/summary -> exit.
#
# Deliberately `set -uo pipefail` WITHOUT -e: every error is handled explicitly because this script
# must never break the customer's build unless fail-on-error is true. Never add `set -x`: the API key
# is in this process's environment.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/inputs.sh
source "$SCRIPT_DIR/lib/inputs.sh"
# shellcheck source=lib/sarif.sh
source "$SCRIPT_DIR/lib/sarif.sh"
# shellcheck source=lib/metadata.sh
source "$SCRIPT_DIR/lib/metadata.sh"
# shellcheck source=lib/upload.sh
source "$SCRIPT_DIR/lib/upload.sh"
# shellcheck source=lib/summary.sh
source "$SCRIPT_DIR/lib/summary.sh"

cleanup() {
  [[ -n "${LT_WORK:-}" && -d "$LT_WORK" ]] && rm -rf "$LT_WORK"
}

# finish <status> [note]: write outputs + summary, then exit (0 unless fail-on-error and a failure).
finish() {
  local status=$1 note=${2:-} results
  results=$(results_json)
  write_outputs "$status" "$results"
  write_summary "$status" "$results" "$note"
  echo "Lantern: status=${status}"
  if [[ "$LT_FAIL_ON_ERROR" == "true" && ("$status" == "failed" || "$status" == "partial") ]]; then
    exit 1
  fi
  exit 0
}

# Decide from the event whether this run may upload. Prints a reason and returns 1 to skip.
branch_gate() {
  local event=${GITHUB_EVENT_NAME:-} ref=${GITHUB_REF:-} default=${LANTERN_DEFAULT_BRANCH:-}
  case "$event" in
    pull_request*)
      printf 'upload-on is default-branch and this is a %s event.' "$event"
      return 1
      ;;
  esac
  if [[ -z "$default" ]]; then
    printf "upload-on is default-branch but the repository's default branch is unknown for this event; set upload-on: always to upload anyway."
    return 1
  fi
  if [[ "$ref" != "refs/heads/${default}" ]]; then
    printf "upload-on is default-branch and %s is not the default branch (%s)." "${ref:-<no ref>}" "$default"
    return 1
  fi
  return 0
}

main() {
  umask 077
  LT_WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lantern-action.XXXXXX") || {
    log_warning "Could not create a temporary directory; skipping the Lantern upload."
    exit 0
  }
  trap cleanup EXIT
  : >"$LT_WORK/entries.tsv"
  LT_VERSION=$(tr -d '[:space:]' <"$ACTION_ROOT/VERSION" 2>/dev/null || echo dev)

  # The key first, so it is masked before anything else can print.
  LT_API_KEY=$(trim "${INPUT_API_KEY:-}")
  [[ -n "$LT_API_KEY" ]] && echo "::add-mask::${LT_API_KEY}"

  LT_FAIL_ON_ERROR=$(normalize_bool "${INPUT_FAIL_ON_ERROR:-false}" false)
  LT_STRIP=$(normalize_bool "${INPUT_STRIP_SNIPPETS:-true}" true)
  LT_MAX_MB=$(normalize_max_mb "${INPUT_MAX_PAYLOAD_MB:-10}")
  collect_metadata

  local upload_on
  upload_on=$(to_lower "$(trim "${INPUT_UPLOAD_ON:-default-branch}")")
  case "$upload_on" in
    default-branch | always | never) ;;
    *)
      log_warning "upload-on must be default-branch, always or never; using default-branch."
      upload_on="default-branch"
      ;;
  esac

  LT_BASE_URL=""
  local reason

  if [[ "$upload_on" == "never" ]]; then
    parse_source_list sarif "${INPUT_SARIF:-}"
    parse_source_list a11y "${INPUT_A11Y:-}"
    parse_source_list sonarqube "${INPUT_SONARQUBE:-}"
    local format source path
    while IFS=$'\t' read -r format source path; do
      [[ -z "$source" ]] && continue
      add_result "$source" "$format" "$path" 0 skipped
      echo "Lantern: '${source}' (${format}) validated; dry run, not uploaded."
    done <"$LT_WORK/entries.tsv"
    finish dry-run "upload-on is never: reports were validated but nothing was sent."
  fi

  if [[ "$upload_on" == "default-branch" ]]; then
    if ! reason=$(branch_gate); then
      log_notice "Lantern upload skipped. ${reason}"
      finish skipped "$reason"
    fi
  fi

  if [[ -z "$LT_API_KEY" ]]; then
    # Quiet on purpose: fork pull requests have no secrets, so this is expected.
    log_notice "Lantern upload skipped: api-key is empty (expected on fork pull requests)."
    finish skipped "api-key is empty."
  fi
  if [[ "$LT_API_KEY" =~ [[:space:][:cntrl:]] ]]; then
    log_warning "Lantern upload skipped: api-key contains whitespace. Check the secret was copied whole."
    finish skipped "api-key is malformed."
  fi

  if ! LT_BASE_URL=$(normalize_base_url "${INPUT_LANTERN_URL:-}"); then
    LT_BASE_URL=""
    problem "lantern-url must be an https:// URL such as ${DEFAULT_LANTERN_URL}; nothing was uploaded."
    finish failed "lantern-url is not a valid https:// URL."
  fi

  local scanned_at
  scanned_at=$(trim "${INPUT_SCANNED_AT:-}")
  if [[ -z "$scanned_at" ]]; then
    scanned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) # once; every attempt and every source reuses it
  elif ! valid_scanned_at "$scanned_at"; then
    problem "scanned-at must be an ISO-8601 UTC time ending in Z, like 2026-07-07T16:24:55Z; nothing was uploaded."
    finish failed "scanned-at is not a valid UTC timestamp."
  fi

  parse_source_list sarif "${INPUT_SARIF:-}"
  parse_source_list a11y "${INPUT_A11Y:-}"
  parse_source_list sonarqube "${INPUT_SONARQUBE:-}"

  if [[ ! -s "$LT_WORK/entries.tsv" ]]; then
    log_notice "Lantern: no valid reports to upload."
    finish skipped "No valid reports to upload."
  fi

  prepare_auth_header "$LT_API_KEY"

  local payload
  while IFS=$'\t' read -r format source path; do
    [[ -z "$source" ]] && continue
    payload=$path
    if [[ "$format" == "sarif" && "$LT_STRIP" == "true" ]]; then
      payload="$LT_WORK/payload.json"
      if ! strip_sarif "$path" "$payload"; then
        problem "Lantern: could not strip snippets from '${source}'; not uploading it."
        add_result "$source" "$format" "$path" 0 failed "could not strip snippets"
        continue
      fi
    fi

    upload_report "$source" "$format" "$payload" "$scanned_at"
    add_result "$source" "$format" "$path" "$UP_HTTP" "$UP_OUTCOME" "$UP_ERROR" "$LT_WORK/body"
    case "$UP_OUTCOME" in
      created | duplicate) echo "Lantern: '${source}' (${format}) -> ${UP_OUTCOME}" ;;
      stale) log_warning "Lantern: '${source}' (${format}) is stale: ${UP_ERROR}." ;;
      *) problem "Lantern: '${source}' (${format}) failed (HTTP ${UP_HTTP}): ${UP_ERROR}" ;;
    esac
  done <"$LT_WORK/entries.tsv"

  local results failed ok status
  results=$(results_json)
  failed=$(jq '[.[] | select(.outcome == "failed")] | length' <<<"$results")
  ok=$(jq '[.[] | select(.outcome == "created" or .outcome == "duplicate" or .outcome == "stale")] | length' <<<"$results")
  if ((failed > 0 && ok > 0)); then
    status=partial
  elif ((failed > 0)); then
    status=failed
  elif ((ok > 0)); then
    status=uploaded
  else
    status=skipped
  fi
  finish "$status"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
