#!/usr/bin/env bash
# Run Strix with Lantern's shared dedupe/retest instructions and assemble the push payload.
#
#   strix-run.sh prepare  --out DIR [--local FILE]
#   strix-run.sh assemble --run-dir strix_runs/NAME --previous FILE --out FILE [--redact FILE]
#   strix-run.sh run      [--out DIR] [--local FILE] [--redact FILE] -- <strix args, e.g. --target ./app>
#
# Env: LANTERN_API_KEY (ltn_...), LANTERN_URL (default https://lantern.foundryhq.co.uk),
#      LANTERN_SOURCE (default strix).
# Needs bash, curl and jq. Never `set -x`: the API key is in this process's environment.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANTERN_URL="${LANTERN_URL:-https://lantern.foundryhq.co.uk}"
LANTERN_SOURCE="${LANTERN_SOURCE:-strix}"

die() {
  printf 'strix-run: %s\n' "$*" >&2
  exit 1
}
warn() { printf 'strix-run: warning: %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

# ---------------------------------------------------------------- prepare

# Fetch what Lantern already knows about this source and build the instruction file.
cmd_prepare() {
  local out="" local_file="strix.local.md"
  while (($#)); do
    case $1 in
      --out) out=$2; shift 2 ;;
      --local) local_file=$2; shift 2 ;;
      *) die "prepare: unknown option $1" ;;
    esac
  done
  [[ -n "$out" ]] || die "prepare: --out DIR is required"
  mkdir -p "$out" || die "cannot create $out"
  [[ "$LANTERN_SOURCE" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || die "LANTERN_SOURCE is not a valid source key"

  local prev="$out/previous-findings.json"
  printf '{"issues":[]}\n' >"$prev"
  if [[ -z "${LANTERN_API_KEY:-}" ]]; then
    warn "LANTERN_API_KEY is empty: running without previous findings (no dedupe, no retests)."
  else
    case "$LANTERN_URL" in https://*) ;; *) die "LANTERN_URL must be https://" ;; esac
    local hdr body http
    hdr=$(mktemp) || die "mktemp failed"
    body=$(mktemp) || die "mktemp failed"
    chmod 600 "$hdr"
    printf 'Authorization: Bearer %s\n' "$LANTERN_API_KEY" >"$hdr"
    http=$(curl --silent --show-error --proto '=https' --connect-timeout 10 --max-time 60 \
      --header "@${hdr}" --output "$body" --write-out '%{http_code}' \
      "${LANTERN_URL%/}/api/v1/sources/${LANTERN_SOURCE}/issues?status=all&include=detail") || http=000
    rm -f "$hdr"
    case "$http" in
      200)
        if jq -e '.issues | type == "array"' "$body" >/dev/null 2>&1; then
          cp "$body" "$prev"
        else
          warn "Lantern answered 200 but not with an issue list; ignoring it."
        fi
        ;;
      404) echo "strix-run: source '${LANTERN_SOURCE}' does not exist yet (first run): no previous findings." ;;
      *) rm -f "$body"; die "could not fetch previous findings (HTTP ${http}). Not running blind: fix the key/URL, or unset LANTERN_API_KEY to run without history." ;;
    esac
    rm -f "$body"
  fi

  {
    cat "$SELF_DIR/instructions.md"
    if [[ -f "$local_file" ]]; then
      printf '\n\n# App-specific instructions\n\n'
      cat "$local_file"
    fi
  } >"$out/instructions.md"
  echo "strix-run: prepared $out ($(jq '[.issues[] | select(.status == "open")] | length' "$prev") open previous issues)"
}

# ---------------------------------------------------------------- assemble

# Best-effort secret redaction applied to every text field that leaves the machine. Extra patterns
# (jq/Oniguruma regexes, one per line, replaced by [redacted]) come from --redact FILE.
REDACT_JQ='
def redact($extra):
  if type == "string" then
    gsub("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{5,}"; "[redacted-jwt]")
    | gsub("ltn_[0-9a-f]{8}_[A-Za-z0-9_-]{43}"; "[redacted-lantern-key]")
    | gsub("(?<p>authorization:\\s*bearer\\s+)[A-Za-z0-9._~+/=-]{16,}"; "\(.p)[redacted]"; "i")
    | gsub("sb_(publishable|secret)_[A-Za-z0-9_-]{16,}"; "[redacted-supabase-key]")
    | gsub("(sk|rk)-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}"; "[redacted-key]")
    | gsub("(?<p>pass(word|wd)?[\"'"'"']?\\s*[:=]\\s*[\"'"'"'])[^\"'"'"'\\n]+"; "\(.p)[redacted]"; "i")
    | gsub("(?<p>[\"'"'"'][^\"'"'"'\\s]+@[^\"'"'"'\\s]+[\"'"'"']\\s*,\\s*[\"'"'"'])[^\"'"'"'\\n]+"; "\(.p)[redacted]")
    | reduce $extra[] as $re (.; gsub($re; "[redacted]"))
  else . end;
'

cmd_assemble() {
  local run_dir="" prev="" out="" redact_file=""
  while (($#)); do
    case $1 in
      --run-dir) run_dir=$2; shift 2 ;;
      --previous) prev=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      --redact) redact_file=$2; shift 2 ;;
      *) die "assemble: unknown option $1" ;;
    esac
  done
  [[ -d "$run_dir" && -n "$out" ]] || die "assemble: --run-dir DIR and --out FILE are required"
  [[ -f "$run_dir/run.json" ]] || die "$run_dir/run.json not found: is this a Strix run directory?"
  if [[ -z "$prev" || ! -f "$prev" ]]; then
    prev=$(mktemp) || die "mktemp failed"
    printf '{"issues":[]}' >"$prev"
  fi

  local status
  status=$(jq -r '.status // "unknown"' "$run_dir/run.json")
  [[ "$status" == "completed" ]] || die "Strix run is '${status}', not 'completed'. Not assembling: a crashed or partial run must never reach Lantern."
  local vulns="$run_dir/vulnerabilities.json"
  if [[ ! -f "$vulns" ]]; then
    # A completed run with no findings writes no file: that is "nothing found", not an error.
    vulns=$(mktemp) || die "mktemp failed"
    printf '[]' >"$vulns"
  fi

  # Extra redaction patterns -> JSON array.
  local extra='[]'
  if [[ -n "$redact_file" ]]; then
    [[ -f "$redact_file" ]] || die "redact file not found: $redact_file"
    extra=$(grep -v '^[[:space:]]*\(#\|$\)' "$redact_file" | jq -R . | jq -s . ) || die "bad redact file"
  fi

  # Each vulnerability's markdown, keyed by id, as one JSON object.
  local md_json
  md_json=$(
    for f in "$run_dir"/vulnerabilities/vuln-*.md; do
      [[ -f "$f" ]] || continue
      jq -n --arg id "$(basename "$f" .md)" --rawfile md "$f" '{($id): $md}'
    done | jq -s 'add // {}'
  )

  # The LANTERN-RESULT note the agent wrote (latest wins); anything else in notes is never read.
  local note='{}'
  if [[ -f "$run_dir/.state/notes.json" ]]; then
    note=$(jq -r '[ to_entries[] | .value | select(.title == "LANTERN-RESULT") ] | sort_by(.updated_at) | last | .content // ""' \
      "$run_dir/.state/notes.json" 2>/dev/null \
      | sed -e 's/^```[a-z]*//' -e 's/^```$//' | jq -c 'if type == "object" then . else {} end' 2>/dev/null) || note='{}'
    [[ -n "$note" ]] || note='{}'
  fi
  [[ "$note" == '{}' ]] && warn "no usable LANTERN-RESULT note: new findings get fresh ids, nothing will be marked resolved."

  jq -n \
    --slurpfile vulns "$vulns" \
    --slurpfile run "$run_dir/run.json" \
    --slurpfile prev "$prev" \
    --argjson md "$md_json" \
    --argjson note "$note" \
    --argjson extra "$extra" \
    "$REDACT_JQ"'
    def num: capture("^STRIX-(?<n>[0-9]+)$").n | tonumber;
    def idfmt: "STRIX-" + (tostring | if length < 4 then ("0000" + .)[-4:] else . end);
    ($prev[0].issues // []) as $p
    | [$p[] | select(.externalId != null)] as $known
    | ($known | map(.externalId)) as $knownIds
    | ($known | map(select(.status == "open") | .externalId)) as $openIds
    | ([$known[] | .externalId | try num catch 0] | max // 0) as $max0
    | ($note.map // {}) as $map
    | ($note.retest // {}) as $retest
    # Resolve every vuln to an id: the agent-mapped previous id if valid and not already taken, else a fresh one.
    | (reduce ($vulns[0] // [])[] as $v ({used: [], next: $max0, out: []};
        ($map[$v.id] // null) as $m
        | if ($m | type) == "string" and ($m | test("^STRIX-[0-9]{4,}$")) and ($knownIds | index($m)) != null and (.used | index($m)) == null
          then .used += [$m] | .out += [{vuln: $v, id: $m}]
          else (.next + 1) as $n | .next = $n | .used += [($n | idfmt)] | .out += [{vuln: $v, id: ($n | idfmt)}]
          end)) as $r
    | ($r.out | map(.id)) as $findingIds
    | {
        run: {
          id: ($run[0].run_id // $run[0].run_name),
          status: $run[0].status,
          startedAt: $run[0].start_time,
          endedAt: $run[0].end_time
        },
        findings: [ $r.out[] | . as $o | $o.vuln as $v | {
          externalId: $o.id,
          title: ($v.title | redact($extra)),
          severity: $v.severity,
          cwe: $v.cwe,
          cvss: $v.cvss,
          endpoint: $v.endpoint,
          method: $v.method,
          description: (($v.description // "") | redact($extra)),
          remediation: (($v.remediation_steps // "") | redact($extra)),
          confidence: $v.confidence,
          retest: (if ($openIds | index($o.id)) != null then "still_present" else "new" end),
          markdown: (($md[$v.id] // null) | if . == null then null else redact($extra) end)
        } | with_entries(select(.value != null)) ],
        resolved: [
          $retest | to_entries[]
          | .key as $k
          | select(.value.verdict == "resolved"
                   and ($openIds | index($k)) != null
                   and ($findingIds | index($k)) == null)
          | { externalId: $k, note: ((.value.note // "") | tostring | .[0:300] | redact($extra)) }
        ]
      }
  ' >"$out" || die "could not assemble the payload"

  # Warn (never silently) about anything the agent claimed that we refused to act on.
  jq -r --argjson note "$note" --slurpfile pv "$prev" '
    ($pv[0].issues // [] | map(select(.status == "open") | .externalId)) as $open
    | (.findings | map(.externalId)) as $fids
    | ($note.retest // {} | to_entries[] | select(.value.verdict == "resolved") | .key) as $k
    | select(($open | index($k)) == null or ($fids | index($k)) != null)
    | "ignored the resolved verdict for \($k): not an open previous issue, or this run re-reported it"' "$out" \
    | while IFS= read -r line; do warn "$line"; done

  echo "strix-run: wrote $out: $(jq '.findings | length' "$out") findings, $(jq '.resolved | length' "$out") resolved"
}

# ---------------------------------------------------------------- run

list_runs() { find strix_runs -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort; }

cmd_run() {
  local out="lantern-strix" local_file="strix.local.md" redact=""
  while (($#)); do
    case $1 in
      --out) out=$2; shift 2 ;;
      --local) local_file=$2; shift 2 ;;
      --redact) redact=$2; shift 2 ;;
      --) shift; break ;;
      *) die "run: unknown option $1 (strix arguments go after --)" ;;
    esac
  done
  need strix
  cmd_prepare --out "$out" --local "$local_file" || exit 1

  local before
  before=$(list_runs)
  # Exit 2 just means "findings were reported" in headless mode; anything else is a real failure.
  strix -n --instruction-file "$out/instructions.md" \
    --workspace-file "$out/previous-findings.json:previous-findings.json" "$@"
  local rc=$?
  [[ $rc -eq 0 || $rc -eq 2 ]] || die "strix exited with status $rc"

  local after run_dir
  after=$(list_runs)
  run_dir=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tail -n1)
  [[ -n "$run_dir" ]] || die "could not find the new run under ./strix_runs"

  local args=(--run-dir "strix_runs/$run_dir" --previous "$out/previous-findings.json" --out "$out/lantern-result.json")
  [[ -n "$redact" ]] && args+=(--redact "$redact")
  cmd_assemble "${args[@]}" || exit 1
  cat <<EOF

Next: upload $out/lantern-result.json with the lantern-action:
  strix: |
    ${LANTERN_SOURCE}=$out/lantern-result.json
EOF
}

# ---------------------------------------------------------------- main

need jq
need curl
case "${1:-}" in
  prepare) shift; cmd_prepare "$@" ;;
  assemble) shift; cmd_assemble "$@" ;;
  run) shift; cmd_run "$@" ;;
  *) die "usage: strix-run.sh prepare|assemble|run (see the header of this file)" ;;
esac
