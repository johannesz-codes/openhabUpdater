#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/.env"
[[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a

log() { printf '%s %s\n' "$(date +'%F %T')" "$*" >&2; }

send_telegram() {
  local text="${1:-}"
  if [[ -n "${bot_token:-}" && -n "${chat_id:-}" && -n "$text" ]]; then
    curl -sS -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
      --data "chat_id=${chat_id}" --data-urlencode "text=${text}" >/dev/null || true
  fi
}
