#!/bin/sh
set -eu

BASE="http://<wallbox-ip>"
PW_FILE="/config/.wallbox_service_password"
USER_ROLE="technician"
PHASE="${1:-state}"

TOKEN=$(curl -i -s --max-time 8 -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "user=$USER_ROLE" \
  --data-urlencode "pass=$(cat "$PW_FILE")" \
  "$BASE/api/v2/jwt/login" \
  | awk 'BEGIN{IGNORECASE=1} /^authorization:/{sub(/^[^:]+:[[:space:]]*/,""); sub(/\r$/,""); print; exit}')

if [ -z "$TOKEN" ]; then
  echo "wallbox login failed" >&2
  exit 2
fi

get_state() {
  curl -fsS --max-time 8 \
    -H "Authorization: $TOKEN" \
    "$BASE/api/v2/system/relais-switch/state"
}

case "$PHASE" in
  state)
    curl -fsS --max-time 8 \
      -H "Authorization: $TOKEN" \
      "$BASE/api/v2/system/relais-switch/state"
    ;;
  onePhase|threePhase)
    current=$(get_state | /usr/local/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("value","unknown"))')
    if [ "$current" = "$PHASE" ]; then
      echo "{\"value\":\"$current\"}"
      exit 0
    fi

    tmp=/tmp/wallbox_phase_response.$$
    code=$(curl -s --max-time 12 -o "$tmp" -w '%{http_code}' -X PUT \
      -H "Authorization: $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"value\":\"$PHASE\"}" \
      "$BASE/api/v2/system/relais-switch/state" || true)

    # Elli may return 422 while the relay transition is already in progress.
    # Poll the state endpoint and treat that as authoritative.
    i=0
    while [ $i -lt 12 ]; do
      sleep 5
      current=$(get_state | /usr/local/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("value","unknown"))' || echo unknown)
      if [ "$current" = "$PHASE" ]; then
        echo "{\"value\":\"$current\"}"
        rm -f "$tmp"
        exit 0
      fi
      i=$((i+1))
    done

    echo "phase switch to $PHASE not completed; http=$code; current=$current; body=$(cat "$tmp" 2>/dev/null)" >&2
    rm -f "$tmp"
    exit 22
    ;;
  *)
    echo "usage: $0 state|onePhase|threePhase" >&2
    exit 64
    ;;
esac
