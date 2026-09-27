#!/usr/bin/env bash
set -euo pipefail

PREFIX=kuzmin-01

echo "==> удаление балансировщика"
if yc load-balancer network-load-balancer get "$PREFIX-lb" >/dev/null 2>&1; then
  yc load-balancer network-load-balancer delete "$PREFIX-lb"
fi

echo "==> удаление целевой группы"
if yc load-balancer target-group get --name "$PREFIX-tg" >/dev/null 2>&1; then
  yc load-balancer target-group delete "$PREFIX-tg"
fi

echo "==> удаление машин"
yc compute instance list --format json \
  | jq -r --arg prefix "${PREFIX}-app-" \
      '.[] | select(.name | startswith($prefix)) | .name' \
  | while read -r name; do
      yc compute instance delete "$name"
    done

echo "==> удаление дополнительного диска"
if yc compute disk get "$PREFIX-data" >/dev/null 2>&1; then
  yc compute disk delete "$PREFIX-data"
fi

echo "==> удаление подсетей"
for subnet in "$PREFIX-subnet-a" "$PREFIX-subnet-b"; do
  if yc vpc subnet get "$subnet" >/dev/null 2>&1; then
    yc vpc subnet delete "$subnet"
  fi
done

echo "==> удаление сети"
if yc vpc network get "$PREFIX-net" >/dev/null 2>&1; then
  yc vpc network delete "$PREFIX-net"
fi

echo "==> стенд удалён"
