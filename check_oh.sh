#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <IP> [port]"
    exit 2
fi

TARGET_IP="$1"
PORT="${2:-8080}"

# Validate IP address — each octet must be 0-255
validate_ip() {
    local ip="$1"
    local IFS='.'
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

if ! validate_ip "$TARGET_IP"; then
    echo "ERROR: Invalid IP address: $TARGET_IP"
    exit 2
fi

# Validate port (integer 1-65535)
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "ERROR: Invalid port: $PORT"
    exit 2
fi

URL="http://${TARGET_IP}:${PORT}/"

echo "Checking $URL ..."
if curl -s --max-time 3 "$URL" >/dev/null; then
    echo "OK: OpenHAB at $TARGET_IP is reachable."
else
    echo "ERROR: No connection to $TARGET_IP."
    exit 1
fi
echo "$URL available, checking challenge"

ITEM="challenge"

# send command
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST --header "Content-Type: text/plain" \
    --data "challenge" "http://$TARGET_IP:${PORT}/rest/items/$ITEM")
if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: Failed to send command (HTTP $HTTP_CODE)"
    exit 1
fi
# wait a moment
sleep 5

# check state
for i in {1..6}; do
    STATE=$(curl -s "http://$TARGET_IP:${PORT}/rest/items/$ITEM/state")
    if [[ "$STATE" == "pass" ]]; then
        echo "OK after $((i*10))s"
        exit 0
    fi
	sleep 10
    echo "Try $i: state=$STATE"
done

echo "ERROR: Health check timed out — item never reached state 'pass'."
exit 1
