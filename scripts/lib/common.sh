#!/usr/bin/env bash
# Shared helpers: workflow-command logging, string utilities and the per-source results log.
# Sourced, never executed. Written to also run on bash 3.2 (macOS) so the tests work locally.

# Escape a message for a GitHub workflow command (so untrusted text cannot start a new command).
gh_escape() {
  local s=$1
  s=${s//'%'/'%25'}
  s=${s//$'\r'/'%0D'}
  s=${s//$'\n'/'%0A'}
  printf '%s' "$s"
}

log_notice() { printf '::notice::%s\n' "$(gh_escape "$1")"; }
log_warning() { printf '::warning::%s\n' "$(gh_escape "$1")"; }
log_error() { printf '::error::%s\n' "$(gh_escape "$1")"; }

# A problem that counts as a failure: ::error:: when fail-on-error is on, otherwise ::warning::.
problem() {
  if [[ "${LT_FAIL_ON_ERROR:-false}" == "true" ]]; then
    log_error "$1"
  else
    log_warning "$1"
  fi
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# One line, control characters removed, truncated. For untrusted text (server messages, curl errors).
sanitize_text() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -d '\000-\010\013\014\016-\037\177' | cut -c1-"${2:-300}"
}

# "true"/"false" (case-insensitive) with a default for anything else.
normalize_bool() {
  case "$(to_lower "$(trim "$1")")" in
    true) printf 'true' ;;
    false) printf 'false' ;;
    *) printf '%s' "$2" ;;
  esac
}

# Append one result to $LT_WORK/results.jsonl (a file, so it survives subshells).
# add_result <source> <format> <file> <http> <outcome> [error] [response-body-file]
add_result() {
  local source=$1 format=$2 file=$3 http=${4:-0} outcome=$5 error=${6:-} body=${7:-}
  local extra='{}' entry
  if [[ -n "$body" && -s "$body" ]]; then
    extra=$(jq -c '
      if type == "object" then
        {
          runId: (.runId | if type == "string" then . else null end),
          opened: (.opened | if type == "number" then . else null end),
          closed: (.closed | if type == "number" then . else null end),
          reopened: (.reopened | if type == "number" then . else null end),
          open: (.open | if type == "object" then . else null end)
        } | with_entries(select(.value != null))
      else {} end' "$body" 2>/dev/null) || extra='{}'
    [[ -n "$extra" ]] || extra='{}'
  fi
  entry=$(jq -cn \
    --arg source "$source" --arg format "$format" --arg file "$file" \
    --argjson http "$http" --arg outcome "$outcome" --arg error "$error" \
    --argjson extra "$extra" '
    {
      source: $source, format: $format, file: $file,
      http: (if $http > 0 then $http else null end),
      outcome: $outcome
    } + $extra + (if $error == "" then {} else { error: $error } end)
    | with_entries(select(.value != null))') || return 1
  printf '%s\n' "$entry" >>"$LT_WORK/results.jsonl"
}

# Print the results as a compact JSON array.
results_json() {
  if [[ -s "$LT_WORK/results.jsonl" ]]; then
    jq -cs . "$LT_WORK/results.jsonl"
  else
    printf '[]'
  fi
}
