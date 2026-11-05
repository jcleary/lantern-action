#!/usr/bin/env bash
# SARIF snippet stripping. Lantern's normalizer and fingerprint never read these fields
# (see docs/DECISIONS.md), so removing them cannot change which issues open or close.

# Removes, wherever they occur: any "contextRegion", any "codeFlows", and "snippet" inside any "region".
# Everything else is left exactly as it was.
SARIF_STRIP_FILTER='
  walk(
    if type == "object" then
      del(.contextRegion, .codeFlows)
      | if (.region | type) == "object" then .region |= del(.snippet) else . end
    else . end
  )'

# strip_sarif <input> <output>
strip_sarif() {
  jq -c "$SARIF_STRIP_FILTER" "$1" >"$2"
}
