#!/usr/bin/env bash
set -u

PREFIX="${PREFIX:-kuzmin-01}"
APP_PORT="${APP_PORT:-8003}"

RESULT=0

LB_IP=$(yc load-balancer network-load-balancer get \
  --name "$PREFIX-lb" \
  --format json | jq -r '.listeners[0].address')

APP_IP=$(yc compute instance get "$PREFIX-app" \
  --format json \
  | jq -r '.network_interfaces[0].primary_v4_address.address')

WEB1_IP=$(yc compute instance get "$PREFIX-web-1" \
  --format json \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

HTTP_CODE=$(curl -s \
  -o /dev/null \
  -w '%{http_code}' \
  --connect-timeout 3 \
  --max-time 5 \
  "http://$LB_IP" || true)

if [ "$HTTP_CODE" = "200" ]; then
  echo "балансировщик отвечает: $HTTP_CODE"
else
  echo "балансировщик не отвечает корректно: $HTTP_CODE"
  RESULT=1
fi

RESPONSES=""

for i in $(seq 1 10); do
  RESPONSE=$(curl -s \
    --connect-timeout 3 \
    --max-time 5 \
    "http://$LB_IP" || true)

  RESPONSES+="$RESPONSE"$'\n'
done

HOSTS=$(printf '%s' "$RESPONSES" \
  | grep -o "${PREFIX}-web-[0-9]*" \
  | sort -u)

HOST_COUNT=$(printf '%s\n' "$HOSTS" \
  | sed '/^$/d' \
  | wc -l)

if [ "$HOST_COUNT" -gt 1 ]; then
  echo "ответили машины: $(echo "$HOSTS" | paste -sd ', ' -)"
else
  echo "отвечает только одна машина: $(echo "$HOSTS" | paste -sd ', ' -)"
  RESULT=1
fi

APP_HTTP_CODE=$(ssh \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=5 \
  student@"$WEB1_IP" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 http://$APP_IP:$APP_PORT" \
  || true)

if [ "$APP_HTTP_CODE" = "200" ]; then
  echo "сервер приложения доступен с web-1: $APP_HTTP_CODE"
else
  echo "сервер приложения недоступен с web-1: $APP_HTTP_CODE"
  RESULT=1
fi

exit "$RESULT"
