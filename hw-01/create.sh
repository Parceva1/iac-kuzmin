#!/usr/bin/env bash
set -euo pipefail

# ---- параметры варианта 01 ----
PREFIX="${PREFIX:-kuzmin-01}"
ZONE_A="${ZONE_A:-ru-central1-a}"
ZONE_B="${ZONE_B:-ru-central1-b}"
CIDR_A="${CIDR_A:-10.11.1.0/24}"
CIDR_B="${CIDR_B:-10.11.2.0/24}"
APP_PORT="${APP_PORT:-8003}"
GREETING="${GREETING:-labwork}"
WEB_COUNT="${WEB_COUNT:-2}"
ENV_NAME="${ENV_NAME:-lab}"

BOOT_SIZE="${BOOT_SIZE:-15}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-count)
      WEB_COUNT="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    *)
      echo "Неизвестный аргумент: $1"
      exit 1
      ;;
  esac
done

echo "==> параметры стенда"
echo "PREFIX=$PREFIX"
echo "WEB_COUNT=$WEB_COUNT"
echo "ENV_NAME=$ENV_NAME"
echo "ZONE_A=$ZONE_A"
echo "ZONE_B=$ZONE_B"
echo "APP_PORT=$APP_PORT"

echo "==> генерация cloud-init"

SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)

export APP_PORT GREETING SSH_KEY

envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < hw-01/cloud-init.tpl.yaml \
  > hw-01/cloud-init.yaml

grep -qxF 'hw-01/cloud-init.yaml' .gitignore \
  || echo 'hw-01/cloud-init.yaml' >> .gitignore

echo "==> сеть"

if yc vpc network get "$PREFIX-net" >/dev/null 2>&1; then
  echo "сеть $PREFIX-net уже существует, пропускаю"
else
  yc vpc network create --name "$PREFIX-net"
fi

echo "==> подсети"

if yc vpc subnet get "$PREFIX-subnet-a" >/dev/null 2>&1; then
  echo "подсеть $PREFIX-subnet-a уже существует, пропускаю"
else
  yc vpc subnet create \
    --name "$PREFIX-subnet-a" \
    --network-name "$PREFIX-net" \
    --zone "$ZONE_A" \
    --range "$CIDR_A"
fi

if yc vpc subnet get "$PREFIX-subnet-b" >/dev/null 2>&1; then
  echo "подсеть $PREFIX-subnet-b уже существует, пропускаю"
else
  yc vpc subnet create \
    --name "$PREFIX-subnet-b" \
    --network-name "$PREFIX-net" \
    --zone "$ZONE_B" \
    --range "$CIDR_B"
fi


echo "==> NAT-шлюз"

if yc vpc gateway get "$PREFIX-nat" >/dev/null 2>&1; then
  echo "NAT-шлюз $PREFIX-nat уже существует, пропускаю"
else
  yc vpc gateway create --name "$PREFIX-nat"
fi


echo "==> таблица маршрутизации"

GW_ID=$(yc vpc gateway get --name "$PREFIX-nat" --format json | jq -r '.id')

if yc vpc route-table get "$PREFIX-rt" >/dev/null 2>&1; then
  echo "таблица маршрутизации $PREFIX-rt уже существует, пропускаю"
else
  yc vpc route-table create \
    --name "$PREFIX-rt" \
    --network-name "$PREFIX-net" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID"
fi

echo "==> привязка таблицы маршрутизации"

SUBNET_A_RT=$(yc vpc subnet get "$PREFIX-subnet-a" --format json \
  | jq -r '.route_table_id // empty')

RT_ID=$(yc vpc route-table get "$PREFIX-rt" --format json | jq -r '.id')

if [ "$SUBNET_A_RT" = "$RT_ID" ]; then
  echo "таблица маршрутизации уже привязана к $PREFIX-subnet-a"
else
  yc vpc subnet update \
    --name "$PREFIX-subnet-a" \
    --route-table-name "$PREFIX-rt"
fi

echo "==> веб-серверы"

ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  VM_NAME="$PREFIX-web-$i"

  if yc compute instance get "$VM_NAME" >/dev/null 2>&1; then
    echo "машина $VM_NAME уже существует, пропускаю"
  else
    yc compute instance create \
      --name "$VM_NAME" \
      --zone "${ZONES[$idx]}" \
      --platform standard-v3 \
      --cores=2 \
      --core-fraction=20 \
      --memory=2 \
      --preemptible \
      --create-boot-disk \
        image-folder-id=standard-images,\
image-family="$IMAGE_FAMILY",\
type=network-hdd,\
size="$BOOT_SIZE" \
      --network-interface \
        subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
      --hostname "$VM_NAME" \
      --metadata-from-file user-data=hw-01/cloud-init.yaml
  fi
done

echo "==> сервер приложения"

APP_VM="$PREFIX-app"

if yc compute instance get "$APP_VM" >/dev/null 2>&1; then
  echo "машина $APP_VM уже существует, пропускаю"
else
  yc compute instance create \
    --name "$APP_VM" \
    --zone "$ZONE_A" \
    --platform standard-v3 \
    --cores=2 \
    --core-fraction=20 \
    --memory=2 \
    --preemptible \
    --create-boot-disk \
      image-folder-id=standard-images,\
image-family="$IMAGE_FAMILY",\
type=network-hdd,\
size="$BOOT_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet-a" \
    --hostname "$APP_VM" \
    --metadata-from-file user-data=hw-01/cloud-init.yaml
fi

echo "==> целевая группа"

TARGET_ARGS=()

for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  VM_NAME="$PREFIX-web-$i"

  INTERNAL_IP=$(yc compute instance get "$VM_NAME" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')

  TARGET_ARGS+=(
    --target "subnet-name=${SUBNETS[$idx]},address=$INTERNAL_IP"
  )
done

if yc load-balancer target-group get --name "$PREFIX-tg" >/dev/null 2>&1; then
  echo "целевая группа $PREFIX-tg уже существует, пропускаю"
else
  yc load-balancer target-group create \
    --name "$PREFIX-tg" \
    "${TARGET_ARGS[@]}"
fi

echo "==> балансировщик"

TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" \
  --format json | jq -r '.id')

if yc load-balancer network-load-balancer get --name "$PREFIX-lb" >/dev/null 2>&1; then
  echo "балансировщик $PREFIX-lb уже существует, пропускаю"
else
  yc load-balancer network-load-balancer create \
    --name "$PREFIX-lb" \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group \
target-group-id="$TG_ID",\
healthcheck-name=http,\
healthcheck-interval=2s,\
healthcheck-timeout=1s,\
healthcheck-unhealthythreshold=2,\
healthcheck-healthythreshold=2,\
healthcheck-http-port="$APP_PORT",\
healthcheck-http-path=/
fi

echo "==> ожидание готовности стенда"

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" \
  --format json | jq -r '.listeners[0].address')

READY=0

for attempt in $(seq 1 60); do
  HTTP_CODE=$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    --connect-timeout 2 \
    --max-time 3 \
    "http://$LB_IP" || true)

  if [ "$HTTP_CODE" = "200" ]; then
    READY=1
    break
  fi

  echo "ожидание сервиса... попытка $attempt/60"
  sleep 5
done

if [ "$READY" -ne 1 ]; then
  echo "стенд не стал готов за отведённое время"
  exit 1
fi

echo "==> стенд готов"
echo "Load Balancer: http://$LB_IP"
