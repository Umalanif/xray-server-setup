#!/bin/bash

# Путь к конфигу
CONFIG_FILE="/usr/local/etc/xray/config.json"

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Запустите скрипт с правами суперпользователя (sudo)"
  exit 1
fi

# Проверяем jq
if ! command -v jq &> /dev/null; then
    apt-get update -qq && apt-get install -y jq
fi

echo "==================================================="
echo "➕ Мастер добавления gRPC маршрута"
echo "==================================================="

# 1. Проверяем, жив ли конфиг
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Конфиг не найден: $CONFIG_FILE"
    exit 1
fi

# Проверяем, не добавлен ли уже gRPC
if grep -q "grpc" "$CONFIG_FILE"; then
    echo "⚠️ gRPC уже настроен в конфиге!"
    exit 0
fi

# Вытаскиваем данные из текущего конфига
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' $CONFIG_FILE)

if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Не удалось найти ключи Reality в конфиге."
    exit 1
fi

SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG_FILE)

# === ИСПРАВЛЕНИЕ: Получаем Public Key для твоей версии Xray ===
PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" | awk '/Password:/ {print $2}')
# ==============================================================

IP=$(curl -s icanhazip.com)

# 2. Спрашиваем порт
echo "Какой порт использовать для gRPC? (Рекомендуем: 2053, 8443)"
read -p "Введите порт [по умолчанию 2053]: " PORT
PORT=${PORT:-2053}

# 3. Формируем JSON для нового inbound
NEW_INBOUND=$(jq -n \
                  --arg port "$PORT" \
                  --arg uuid "$UUID" \
                  --arg pk "$PRIVATE_KEY" \
                  --arg sid "$SHORT_ID" \
                  --arg sni "$SNI" \
                  '{
  "listen": "0.0.0.0",
  "port": ($port | tonumber),
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": $uuid,
        "flow": "" 
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "grpc",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "www.google.com:443",
      "xver": 0,
      "serverNames": [$sni],
      "privateKey": $pk,
      "shortIds": [$sid],
      "fingerprint": "chrome"
    },
    "grpcSettings": {
      "serviceName": "grpc"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}')

# 4. Вставляем в конфиг
echo "⚙️ Обновляем конфигурацию X-ray..."
cp $CONFIG_FILE "$CONFIG_FILE.bak_grpc"

tmp=$(mktemp)
jq --argjson new "$NEW_INBOUND" '.inbounds += [$new]' $CONFIG_FILE > "$tmp" && mv "$tmp" $CONFIG_FILE

# === ВАЖНО: ВОССТАНАВЛИВАЕМ ПРАВА ===
chmod 644 $CONFIG_FILE
# ====================================

# 5. Firewall
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        ufw allow "$PORT"/tcp > /dev/null
        ufw allow "$PORT"/udp > /dev/null
    fi
fi

# 6. Перезагрузка
echo "🔄 Перезагружаем сервис..."
systemctl restart xray

if systemctl is-active --quiet xray; then
    echo ""
    echo "✅ Успешно! gRPC канал активен."
    echo "---------------------------------------------------"
    echo "🔗 Ваша ссылка для подключения (gRPC):"
    echo ""
    # Используем найденный PUBLIC_KEY
    LINK="vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=grpc&serviceName=grpc&sni=$SNI&sid=$SHORT_ID#${SNI}-gRPC"
    echo "$LINK"
    echo ""
    echo "---------------------------------------------------"
else
    echo "⚠️ Ошибка запуска! Восстанавливаем бэкап..."
    mv "$CONFIG_FILE.bak_grpc" $CONFIG_FILE
    chmod 644 $CONFIG_FILE
    systemctl restart xray
    echo "Бэкап восстановлен."
fi
