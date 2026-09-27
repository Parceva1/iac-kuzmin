#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-kuzmin-01}"

echo "==> балансировщик"
if yc load-balancer network-load-balancer get --name "$PREFIX-lb" >/dev/null 2>&1; then
  yc load-balancer network-load-balancer delete --name "$PREFIX-lb"
else
  echo "$PREFIX-lb уже отсутствует"
fi

echo "==> целевая группа"
if yc load-balancer target-group get --name "$PREFIX-tg" >/dev/null 2>&1; then
  yc load-balancer target-group delete --name "$PREFIX-tg"
else
  echo "$PREFIX-tg уже отсутствует"
fi

echo "==> виртуальные машины"
yc compute instance list --format json \
  | jq -r --arg prefix "$PREFIX" \
      '.[] | select(.name | startswith($prefix)) | .name' \
  | while read -r name; do
      [ -z "$name" ] || yc compute instance delete "$name"
    done

echo "==> отвязка таблицы маршрутизации"

if yc vpc subnet get "$PREFIX-subnet-a" >/dev/null 2>&1; then
  ROUTE_TABLE_ID=$(yc vpc subnet get "$PREFIX-subnet-a" --format json \
    | jq -r '.route_table_id // empty')

  if [ -n "$ROUTE_TABLE_ID" ]; then
    yc vpc subnet update "$PREFIX-subnet-a" --disassociate-route-table
  else
    echo "таблица маршрутизации уже отвязана"
  fi
fi

echo "==> таблица маршрутизации"
if yc vpc route-table get "$PREFIX-rt" >/dev/null 2>&1; then
  yc vpc route-table delete "$PREFIX-rt"
else
  echo "$PREFIX-rt уже отсутствует"
fi

echo "==> NAT-шлюз"
if yc vpc gateway get "$PREFIX-nat" >/dev/null 2>&1; then
  yc vpc gateway delete "$PREFIX-nat"
else
  echo "$PREFIX-nat уже отсутствует"
fi

echo "==> подсети"

for subnet in "$PREFIX-subnet-a" "$PREFIX-subnet-b"; do
  if yc vpc subnet get "$subnet" >/dev/null 2>&1; then
    yc vpc subnet delete "$subnet"
  else
    echo "$subnet уже отсутствует"
  fi
done

echo "==> сеть"

if yc vpc network get "$PREFIX-net" >/dev/null 2>&1; then
  yc vpc network delete "$PREFIX-net"
else
  echo "$PREFIX-net уже отсутствует"
fi

echo "==> стенд удалён"
