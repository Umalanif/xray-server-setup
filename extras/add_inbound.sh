#!/bin/bash

# Путь к конфигу
CONFIG_FILE="/usr/local/etc/xray/config.json"

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Запустите скрипт с правами суперпользователя (sudo)"
  echo "Пример: sudo bash <(curl ...)"
  exit 1
fi

# Проверяем jq
if ! command -v jq &> /dev/null; then
    echo "📦 Устанавливаем jq для работы с JSON..."
    apt-get update -qq && apt-get install -y jq
fi

echo "==================================================="
echo "➕ Мастер добавления gRPC маршрута"
echo "==================================================="
echo "Этот скрипт добавит резервный канал (gRPC) на ваш сервер."
echo "Используйте его, если основной протокол блокируется оператором."
echo ""

# 1. Проверяем, жив ли конфиг и берем ключи
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Конфиг не найден: $CONFIG_FILE"
    exit 1
fi

PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' $CONFIG_FILE)
# Если ключ пустой, значит что-то не так со структурой
if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Не удалось найти ключи Reality в конфиге. Проверьте настройки."
    exit 1
fi

SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG_FILE)
PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" | awk '{print $3}')
IP=$(curl -s ifconfig.me)

# 2. Спрашиваем порт
echo "Какой порт использовать для gRPC? (Рекомендуем: 2053, 8443, 4444)"
read -p "Введите порт [по умолчанию 2053]: " PORT
PORT=${PORT:-2053}

# 3. Формируем JSON для нового inbound (gRPC)
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
      "dest": "1.1.1.1:443",
      "xver": 0,
      "serverNames": [$sni],
      "privateKey": $pk,
      "shortIds": [$sid]
    },
    "grpcSettings": {
      "serviceName": "grpc"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}')

# 4. Вставляем в конфиг
echo "⚙️ Обновляем конфигурацию X-ray..."
cp $CONFIG_FILE "$CONFIG_FILE.bak_grpc"

tmp=$(mktemp)
jq --argjson new "$NEW_INBOUND" '.inbounds += [$new]' $CONFIG_FILE > "$tmp" && mv "$tmp" $CONFIG_FILE

# 5. ОТКРЫВАЕМ ПОРТ В FIREWALL (Важно!)
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo "🔓 Открываем порт $PORT в UFW..."
        ufw allow "$PORT"/tcp > /dev/null
        ufw allow "$PORT"/udp > /dev/null
        echo "Порт открыт."
    fi
fi

# 6. Перезагрузка и результат
echo "🔄 Перезагружаем сервис..."
systemctl restart xray

if systemctl is-active --quiet xray; then
    echo ""
    echo "✅ Успешно! gRPC канал активен."
    echo "---------------------------------------------------"
    echo "🔗 Ваша ссылка для подключения (gRPC):"
    echo ""
    LINK="vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PUBLIC_KEY&headerType=none&fp=chrome&type=grpc&serviceName=grpc&sni=$SNI&sid=$SHORT_ID#${SNI}-gRPC"
    echo "$LINK"
    echo ""
    echo "---------------------------------------------------"
    echo "👉 Скопируйте и вставьте в клиент как 'Запасной сервер'"
else
    echo "⚠️ Ошибка запуска! Восстанавливаем бэкап..."
    mv "$CONFIG_FILE.bak_grpc" $CONFIG_FILE
    systemctl restart xray
    echo "Бэкап восстановлен. Попробуйте другой порт."
fi
