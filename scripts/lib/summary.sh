#!/usr/bin/env bash
# Job summary and step outputs. Needs common.sh and metadata.sh.

# Make untrusted text safe inside a Markdown table cell.
md_cell() {
  local s
  s=$(sanitize_text "$1" 200)
  s=${s//\\/\\\\}
  s=${s//|/\\|}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\`/\'}
  printf '%s' "$s"
}

# write_outputs <status> <results-json>   (no-op outside Actions)
write_outputs() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  local delim
  delim="lantern_$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  {
    printf 'status=%s\n' "$1"
    printf 'results<<%s\n%s\n%s\n' "$delim" "$2" "$delim"
  } >>"$GITHUB_OUTPUT"
}

# write_summary <status> <results-json> <note>   (no-op outside Actions)
# The /api/v1/reports response carries no project identifier, so the link goes to the Lantern base URL.
write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  local status=$1 results=$2 note=$3 rows
  {
    printf '## Lantern upload\n\n'
    printf '**Status:** `%s`' "$status"
    [[ -n "${LT_BASE_URL:-}" ]] && printf ' · [Open Lantern](%s)' "$LT_BASE_URL"
    printf '\n\n'
    [[ -n "$note" ]] && printf '%s\n\n' "$(md_cell "$note")"
    if [[ "$results" != "[]" ]]; then
      printf '| Source | Format | Outcome | Opened | Closed | Reopened | Open |\n'
      printf '| --- | --- | --- | ---: | ---: | ---: | --- |\n'
      rows=$(jq -r '
        .[] | [
          .source, .format,
          (.outcome + (if .error then " (" + .error + ")" else "" end)),
          (.opened // "-" | tostring), (.closed // "-" | tostring), (.reopened // "-" | tostring),
          (if .open then
             ((.open | to_entries | map(.value | numbers) | add // 0 | tostring)
              + " (" + ([.open.critical, .open.high, .open.medium, .open.low]
                        | map(. // 0 | tostring) | join("/")) + " c/h/m/l)")
           else "-" end)
        ] | @tsv' <<<"$results")
      local src fmt out opened closed reopened open
      while IFS=$'\t' read -r src fmt out opened closed reopened open; do
        [[ -z "$src" ]] && continue
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
          "$(md_cell "$src")" "$(md_cell "$fmt")" "$(md_cell "$out")" \
          "$(md_cell "$opened")" "$(md_cell "$closed")" "$(md_cell "$reopened")" "$(md_cell "$open")"
      done <<<"$rows"
      printf '\n'
    fi
    local meta
    meta=$(metadata_markdown)
    if [[ -n "$meta" ]]; then
      printf '<details><summary>Run metadata (not sent to Lantern)</summary>\n\n%s\n\n</details>\n' "$meta"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
}
