#!/usr/bin/env bash
# shellcheck disable=SC2034  # UP_* are this library's result variables, read by the caller
# One report -> one POST, with a hand-written retry loop and the response -> outcome mapping.
# Needs common.sh. Results are returned in globals (UP_*) so callers can read them without a subshell.

LT_MAX_ATTEMPTS=3
# Wait before attempt 2, attempt 3 (the third value is only reached if the attempt count is raised).
# Overridable in tests only.
LT_RETRY_DELAYS="${LANTERN_RETRY_DELAYS:-2 5 10}"
LT_RETRY_AFTER_CAP=60

lt_sleep() { sleep "$1"; }

# Prints the Retry-After value in whole seconds (capped), or returns 1 if absent / not a number
# (an HTTP-date is ignored and the normal backoff is used).
retry_after_seconds() {
  local v
  v=$(grep -i '^retry-after:' "$1" 2>/dev/null | tail -n1 | cut -d: -f2- | tr -d '[:space:]')
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || return 1
  v=$((10#$v))
  ((v > LT_RETRY_AFTER_CAP)) && v=$LT_RETRY_AFTER_CAP
  printf '%s' "$v"
}

# Lantern's error.code + error.message, sanitised; or a generic description for non-JSON bodies.
api_error_text() {
  local http=$1 body=$2 code msg
  if [[ -s "$body" ]]; then
    code=$(jq -r 'if (.error | type) == "object" then (.error.code // "") | tostring else "" end' "$body" 2>/dev/null)
    msg=$(jq -r 'if (.error | type) == "object" then (.error.message // "") | tostring else "" end' "$body" 2>/dev/null)
    if [[ -n "$code$msg" ]]; then
      code=$(sanitize_text "$code" 60)
      msg=$(sanitize_text "$msg" 300)
      if [[ -n "$code" && -n "$msg" ]]; then
        printf '%s: %s' "$code" "$msg"
      else
        printf '%s' "${code}${msg}"
      fi
      return 0
    fi
  fi
  printf 'HTTP %s (response was not a Lantern error)' "$http"
}

# map_response <http-code> <body-file>
# Sets UP_KIND (success | fatal | retry), UP_OUTCOME and UP_ERROR.
map_response() {
  local http=$1 body=$2
  UP_ERROR=""
  case "$http" in
    201)
      UP_KIND=success UP_OUTCOME=created
      ;;
    200)
      if jq -e '.duplicate == true' "$body" >/dev/null 2>&1; then
        UP_KIND=success UP_OUTCOME=duplicate
      else
        UP_KIND=fatal UP_OUTCOME=failed
        UP_ERROR="HTTP 200 without the expected Lantern response (is lantern-url correct?)"
      fi
      ;;
    409)
      UP_KIND=success UP_OUTCOME=stale
      UP_ERROR="a newer scan is already recorded for this source"
      ;;
    429 | 5[0-9][0-9] | 000)
      UP_KIND=retry UP_OUTCOME=failed
      if [[ "$http" == "000" ]]; then
        UP_ERROR="network error"
      else
        UP_ERROR=$(api_error_text "$http" "$body")
      fi
      ;;
    401)
      UP_KIND=fatal UP_OUTCOME=failed
      UP_ERROR="$(api_error_text "$http" "$body") (check the api-key secret: is it correct, unrevoked and unexpired?)"
      ;;
    403)
      UP_KIND=fatal UP_OUTCOME=failed
      UP_ERROR="$(api_error_text "$http" "$body") (request refused before reaching Lantern; check for a proxy or firewall)"
      ;;
    4[0-9][0-9])
      UP_KIND=fatal UP_OUTCOME=failed
      UP_ERROR=$(api_error_text "$http" "$body")
      ;;
    *)
      UP_KIND=fatal UP_OUTCOME=failed
      UP_ERROR="unexpected HTTP ${http}"
      ;;
  esac
}

# Writes the Authorization header to a private file so the key is never on a command line.
# prepare_auth_header <key>   (sets LT_AUTH_FILE)
prepare_auth_header() {
  LT_AUTH_FILE="$LT_WORK/auth.hdr"
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "$1" >"$LT_AUTH_FILE"
  )
  chmod 600 "$LT_AUTH_FILE"
}

# One HTTP attempt. Sets UP_HTTP (000 on a transport error), UP_CURL_ERR.
# Response body -> $LT_WORK/body, headers -> $LT_WORK/headers.
attempt_once() {
  local url=$1 file=$2 rc
  : >"$LT_WORK/body"
  : >"$LT_WORK/headers"
  UP_HTTP=$(curl --silent --show-error \
    --proto '=https' \
    --connect-timeout 10 --max-time 60 \
    --output "$LT_WORK/body" --dump-header "$LT_WORK/headers" \
    --write-out '%{http_code}' \
    --request POST \
    --header "@${LT_AUTH_FILE}" \
    --header 'Content-Type: application/json' \
    --header "User-Agent: lantern-action/${LT_VERSION:-dev}" \
    --data-binary "@${file}" \
    "$url" </dev/null 2>"$LT_WORK/curl.err") && rc=0 || rc=$?
  if ((rc != 0)); then
    UP_HTTP=000
    UP_CURL_ERR=$(sanitize_text "$(head -n1 "$LT_WORK/curl.err" 2>/dev/null)" 200)
  else
    UP_CURL_ERR=""
  fi
  [[ "$UP_HTTP" =~ ^[0-9]{3}$ ]] || UP_HTTP=000
}

# upload_report <source> <format> <file> <scanned-at>
# The URL (and so scannedAt) is built once and reused by every attempt, which makes a retry that
# actually succeeded the first time come back as 200 duplicate.
# Sets UP_HTTP, UP_OUTCOME, UP_ERROR; the final response body is left in $LT_WORK/body.
upload_report() {
  local source=$1 format=$2 file=$3 scanned_at=$4
  local url="${LT_BASE_URL}/api/v1/reports?source=${source}&format=${format}&scannedAt=${scanned_at}"
  local attempt=1 wait delays
  read -r -a delays <<<"$LT_RETRY_DELAYS"

  while :; do
    attempt_once "$url" "$file"
    map_response "$UP_HTTP" "$LT_WORK/body"
    if [[ "$UP_KIND" != "retry" ]]; then
      break
    fi
    if [[ -n "$UP_CURL_ERR" ]]; then
      UP_ERROR="network error: ${UP_CURL_ERR}"
    fi
    if ((attempt >= LT_MAX_ATTEMPTS)); then
      UP_ERROR="${UP_ERROR} (gave up after ${attempt} attempts)"
      break
    fi
    wait=$(retry_after_seconds "$LT_WORK/headers") || wait=${delays[$((attempt - 1))]:-10}
    echo "Lantern: '${source}' attempt ${attempt}/${LT_MAX_ATTEMPTS} failed (${UP_ERROR}); retrying in ${wait}s."
    lt_sleep "$wait"
    attempt=$((attempt + 1))
  done
}
