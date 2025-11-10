#!/bin/bash

# ==============================================================================
# Скрипт смены DNS на Cloudflare (1.1.1.1)
# GitHub: https://github.com/твой-username/xray-server-setup
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}  Скрипт смены DNS на Cloudflare (1.1.1.1)${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ОШИБКА] Скрипт должен быть запущен от root${NC}"
    echo -e "${YELLOW}Используйте: sudo bash change-dns.sh${NC}"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[ОШИБКА] Не могу определить ОС${NC}"
    exit 1
fi

source /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    echo -e "${RED}[ОШИБКА] Скрипт работает только на Ubuntu${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Обнаружена ОС: Ubuntu $VERSION_ID${NC}"
echo ""

echo -e "${YELLOW}Текущие DNS-серверы:${NC}"
systemd-resolve --status | grep "DNS Servers" | head -5
echo ""

echo -e "${YELLOW}Создаём бэкап...${NC}"
if [ -f /etc/systemd/resolved.conf ]; then
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup
    echo -e "${GREEN}[OK] Бэкап создан${NC}"
fi
echo ""

echo -e "${YELLOW}Настраиваем Cloudflare DNS...${NC}"

cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
DNSOverTLS=no
Cache=yes
DNSStubListener=yes
EOF

echo -e "${GREEN}[OK] Конфигурация обновлена${NC}"
echo ""

echo -e "${YELLOW}Перезапускаем systemd-resolved...${NC}"
systemctl restart systemd-resolved
echo -e "${GREEN}[OK] Сервис перезапущен${NC}"
echo ""

echo -e "${YELLOW}Проверяем новые DNS-серверы:${NC}"
sleep 2
systemd-resolve --status | grep "DNS Servers" | head -5
echo ""

echo -e "${YELLOW}Тестируем DNS...${NC}"
if nslookup torproject.org 1.1.1.1 > /dev/null 2>&1; then
    echo -e "${GREEN}[OK] DNS работает!${NC}"
else
    echo -e "${RED}[ОШИБКА] Не удалось резолвить torproject.org${NC}"
fi
echo ""

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}  DNS успешно изменён на Cloudflare!${NC}"
echo -e "${BLUE}================================================================${NC}"
