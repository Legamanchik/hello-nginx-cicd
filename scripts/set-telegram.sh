#!/usr/bin/env bash
set -Eeuo pipefail

HOST="${1:?usage: $0 <k8s-node-ip> [ssh-key]}"
KEY="${2:-$HOME/.ssh/hello-nginx-deploy}"

read -rsp "Telegram bot token: " TOKEN
echo
[[ -n "$TOKEN" ]] || { echo "Token is empty" >&2; exit 1; }

CHAT_ID="$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates" \
  | jq -r '[.result[] | (.message // .channel_post).chat.id] | last // empty' || true)"
if [[ -n "$CHAT_ID" ]]; then
  echo "Found chat ID from the latest message to the bot: ${CHAT_ID}"
else
  read -rp "Chat ID (send a message to the bot first, or type it): " CHAT_ID
fi
[[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || { echo "Chat ID must be a number" >&2; exit 1; }

printf '%s\n%s\n' "$TOKEN" "$CHAT_ID" | ssh -i "$KEY" "ec2-user@${HOST}" \
  'read -r token; read -r chat; kubectl -n monitoring create secret generic alertmanager-telegram --from-literal=bot-token="$token" --from-literal=chat-id="$chat" --dry-run=client -o yaml | kubectl apply -f -'

curl -fsS -o /dev/null "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=✅ hello-nginx: alerts are connected to this chat"
echo "Done. A test message was sent; Alertmanager picks up the new Secret within ~1 minute."
