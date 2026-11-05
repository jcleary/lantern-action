#!/usr/bin/env bash
# Parsing and validation of the "source-key=path" lists and the scalar inputs.
# Needs common.sh. Valid entries are appended to $LT_WORK/entries.tsv as "format<TAB>source<TAB>path".

DEFAULT_LANTERN_URL="https://lantern.foundryhq.co.uk"

valid_source_key() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]
}

valid_scanned_at() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$ ]]
}

# Prints the normalised base URL (no trailing slash) or returns 1 if it is not an https:// URL.
normalize_base_url() {
  local url
  url=$(trim "$1")
  [[ -n "$url" ]] || url=$DEFAULT_LANTERN_URL
  while [[ "$url" == */ ]]; do url=${url%/}; done
  if [[ "$url" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    printf '%s' "$url"
  else
    return 1
  fi
}

# Positive integer, else the default (with a warning).
normalize_max_mb() {
  local v
  v=$(trim "$1")
  if [[ "$v" =~ ^[0-9]{1,6}$ ]] && ((10#$v > 0)); then
    printf '%s' "$((10#$v))"
  else
    log_warning "max-payload-mb must be a positive whole number; using 10." >&2
    printf '10'
  fi
}

file_size_bytes() {
  wc -c <"$1" | tr -d '[:space:]'
}

# parse_source_list <format> <multi-line text>
# Validates each "source-key=path" line. Valid entries go to entries.tsv; every skipped entry is
# warned about and recorded as a "skipped" result. Skipping is never a failure.
parse_source_list() {
  local format=$1 text=$2 line key path n=0 size limit
  limit=$((LT_MAX_MB * 1024 * 1024))
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    line=$(trim "$line")
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    if [[ "$line" != *=* ]]; then
      log_warning "${format} input, line ${n}: expected 'source-key=path'; skipping."
      continue
    fi
    key=$(to_lower "$(trim "${line%%=*}")")
    path=$(trim "${line#*=}")
    if [[ -z "$key" || -z "$path" ]]; then
      log_warning "${format} input, line ${n}: both a source key and a path are required; skipping."
      continue
    fi
    if ! valid_source_key "$key"; then
      log_warning "${format} input, line ${n}: source key '$(sanitize_text "$key" 80)' must match ^[a-z0-9][a-z0-9_-]{0,63}\$; skipping."
      add_result "$(sanitize_text "$key" 80)" "$format" "$path" 0 skipped "invalid source key"
      continue
    fi
    if [[ -f "$LT_WORK/seen" ]] && grep -Fxq -- "$key" "$LT_WORK/seen"; then
      log_warning "Duplicate source key '${key}' (${format} input, line ${n}); skipping this entry. Source keys must be unique across sarif, a11y and sonarqube."
      add_result "$key" "$format" "$path" 0 skipped "duplicate source key"
      continue
    fi
    printf '%s\n' "$key" >>"$LT_WORK/seen"

    if [[ ! -f "$path" ]]; then
      log_warning "Report file for '${key}' not found: ${path}; skipping."
      add_result "$key" "$format" "$path" 0 skipped "file not found"
      continue
    fi
    size=$(file_size_bytes "$path")
    if ((size > limit)); then
      log_warning "Report file for '${key}' is $((size / 1024 / 1024)) MB, over the ${LT_MAX_MB} MB limit (max-payload-mb); skipping."
      add_result "$key" "$format" "$path" 0 skipped "file larger than ${LT_MAX_MB} MB"
      continue
    fi
    if ! jq empty "$path" >/dev/null 2>&1; then
      log_warning "Report file for '${key}' (${path}) is not valid JSON; skipping."
      add_result "$key" "$format" "$path" 0 skipped "invalid JSON"
      continue
    fi
    printf '%s\t%s\t%s\n' "$format" "$key" "$path" >>"$LT_WORK/entries.tsv"
  done <<<"$text"
}
