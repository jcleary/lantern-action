#!/usr/bin/env bash
# Git/run metadata. Lantern cannot store it yet, so v1 only shows it in the job summary; the future
# /api/v1/runs call can reuse collect_metadata unchanged. Nothing here is sent to Lantern.

collect_metadata() {
  MD_SHA="${GITHUB_SHA:-}"
  MD_REF_NAME="${GITHUB_REF_NAME:-}"
  MD_RUN_ID="${GITHUB_RUN_ID:-}"
  MD_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
  MD_RUN_URL=""
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "$MD_RUN_ID" ]]; then
    MD_RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${MD_RUN_ID}"
  fi
}

# Markdown bullet list of whatever is known.
metadata_markdown() {
  [[ -n "$MD_SHA" ]] && printf -- '- Commit: `%s`\n' "${MD_SHA:0:12}"
  [[ -n "$MD_REF_NAME" ]] && printf -- '- Ref: `%s`\n' "$(sanitize_text "$MD_REF_NAME" 100 | tr -d '`')"
  if [[ -n "$MD_RUN_URL" ]]; then
    printf -- '- Run: [%s (attempt %s)](%s)\n' "$MD_RUN_ID" "${MD_RUN_ATTEMPT:-1}" "$MD_RUN_URL"
  fi
  return 0
}
