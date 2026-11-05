#!/usr/bin/env bash
# Start the mock Lantern server in the background.
#   start.sh <scenario.json> <work-dir> [expect-key]
# Writes <work-dir>/{cert.pem,key.pem,port,hits.jsonl,pid,bodies/} and prints the base URL.
# Callers must trust the cert: export CURL_CA_BUNDLE=<work-dir>/cert.pem (curl honours it).
# Set MOCK_CERT_FROM=<another work-dir> to reuse that directory's certificate.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scenario=$1
work=$2
expect_key=${3:-}

mkdir -p "$work"

if [[ ! -f "$work/cert.pem" && -n "${MOCK_CERT_FROM:-}" ]]; then
  # Several mocks can share one certificate (so one CURL_CA_BUNDLE trusts them all).
  cp "$MOCK_CERT_FROM/cert.pem" "$MOCK_CERT_FROM/key.pem" "$work/"
fi

if [[ ! -f "$work/cert.pem" ]]; then
  # A config file rather than -addext, so this works with both OpenSSL and LibreSSL.
  cat >"$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = san
prompt = no
[dn]
CN = localhost
[san]
subjectAltName = DNS:localhost,IP:127.0.0.1
basicConstraints = CA:TRUE
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/openssl.cnf" >/dev/null 2>&1
fi

rm -f "$work/port" "$work/hits.jsonl"
rm -rf "$work/bodies"

python3 -I "$here/server.py" \
  --cert "$work/cert.pem" --key "$work/key.pem" \
  --scenario "$scenario" --log "$work/hits.jsonl" \
  --port-file "$work/port" --bodies-dir "$work/bodies" \
  --expect-key "$expect_key" >"$work/server.log" 2>&1 &
echo $! >"$work/pid"

for _ in $(seq 1 50); do
  [[ -s "$work/port" ]] && break
  sleep 0.1
done
if [[ ! -s "$work/port" ]]; then
  echo "mock server did not start:" >&2
  cat "$work/server.log" >&2
  exit 1
fi
echo "https://localhost:$(cat "$work/port")"
