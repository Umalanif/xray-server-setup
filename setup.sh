#!/bin/bash

# ==============================================================================
# Скрипт первичной настройки Ubuntu-сервера для X-ray
# GitHub: https://github.com/Umalanif/xray-server-setup
# ==============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Логирование
LOGFILE="/var/log/server-setup.log"
exec > >(tee -a "$LOGFILE")
exec 2>&1

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}  Скрипт первичной настройки Ubuntu-сервера для X-ray${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# ==============================================================================
# Проверка 1: Запуск от root
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ОШИБКА] Скрипт должен быть запущен от root${NC}"
    echo -e "${YELLOW}Используйте: sudo bash setup.sh${NC}"
    exit 1
fi

# ==============================================================================
# Проверка 2: ОС Ubuntu
# ==============================================================================
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[ОШИБКА] Не могу определить ОС${NC}"
    exit 1
fi

source /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
    echo -e "${RED}[ОШИБКА] Скрипт работает только на Ubuntu${NC}"
    echo -e "${YELLOW}Ваша ОС: $ID $VERSION_ID${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Обнаружена ОС: Ubuntu $VERSION_ID${NC}"
echo ""

# ==============================================================================
# Шаг 1: Обновление системы
# ==============================================================================
echo -e "${YELLOW}[1/7] Обновляем систему...${NC}"
apt update -y
apt upgrade -y
echo -e "${GREEN}[OK] Система обновлена${NC}"
echo ""

# ==============================================================================
# Шаг 2: Установка базовых пакетов
# ==============================================================================
echo -e "${YELLOW}[2/7] Устанавливаем базовые пакеты (ufw, curl, wget, git, sudo, adduser)...${NC}"
apt install -y ufw curl wget git sudo adduser
echo -e "${GREEN}[OK] Пакеты установлены${NC}"
echo ""

# ==============================================================================
# Шаг 3: Настройка firewall (UFW)
# ==============================================================================
echo -e "${YELLOW}[3/7] Настраиваем firewall (UFW)...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo -e "${GREEN}[OK] Firewall настроен (порты: 22, 80, 443)${NC}"
echo ""

# ==============================================================================
# Шаг 4: Создание нового пользователя
# ==============================================================================
echo -e "${YELLOW}[4/7] Создаём нового пользователя...${NC}"
echo -e "${BLUE}Важно: Этот пользователь будет иметь sudo-права${NC}"
echo ""

# Создание группы sudo, если не существует
if ! getent group sudo > /dev/null; then
    echo -e "${YELLOW}Создаю группу sudo...${NC}"
    groupadd sudo
fi

# Настройка sudoers (только если строка отсутствует)
if ! grep -q "^%sudo" /etc/sudoers; then
    echo -e "${YELLOW}Настраиваю sudoers...${NC}"
    echo "%sudo   ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

# Чтение имени пользователя
while true; do
    read -p "Введите имя нового пользователя: " USERNAME < /dev/tty
    
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Имя не может быть пустым. Попробуйте снова.${NC}"
        continue
    fi
    
    if id "$USERNAME" &>/dev/null; then
        echo -e "${RED}Пользователь '$USERNAME' уже существует. Выберите другое имя.${NC}"
        continue
    fi
    
    break
done

# Создание пользователя
adduser --gecos "" "$USERNAME" < /dev/tty

# Добавление в группу sudo
usermod -aG sudo "$USERNAME"

# Проверка
if groups "$USERNAME" | grep -q '\bsudo\b'; then
    echo -e "${GREEN}[OK] Пользователь '$USERNAME' создан и добавлен в группу sudo${NC}"
else
    echo -e "${RED}[ОШИБКА] Пользователь '$USERNAME' НЕ добавлен в группу sudo!${NC}"
    exit 1
fi
echo ""

# ==============================================================================
# Шаг 5: Отключение root-входа по паролю
# ==============================================================================
echo -e "${YELLOW}[5/7] Отключаем вход root по паролю...${NC}"

# Проверка наличия sshd_config
if [ -f /etc/ssh/sshd_config ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    
    # Перезапуск SSH (только если служба существует)
    if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        echo -e "${GREEN}[OK] Root-вход по паролю отключён${NC}"
    else
        echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ] SSH-сервер не запущен (нормально для Docker)${NC}"
    fi
else
    echo -e "${YELLOW}[ПРОПУЩЕНО] SSH-конфигурация не найдена (нормально для Docker)${NC}"
fi
echo ""

# ==============================================================================
# Шаг 6: Настройка SSH-ключей (опционально)
# ==============================================================================
echo -e "${YELLOW}[6/7] Настройка SSH-ключей (опционально)${NC}"
read -p "Хотите настроить SSH-ключи? (y/n): " SETUP_SSH < /dev/tty

if [[ "$SETUP_SSH" =~ ^[Yy]$ ]]; then
    mkdir -p /home/$USERNAME/.ssh
    echo -e "${BLUE}Вставьте ваш публичный SSH-ключ:${NC}"
    read -r SSH_KEY < /dev/tty
    
    if [ -z "$SSH_KEY" ]; then
        echo -e "${RED}[ПРОПУЩЕНО] SSH-ключ не введён${NC}"
    else
        echo "$SSH_KEY" >> /home/$USERNAME/.ssh/authorized_keys
        chmod 700 /home/$USERNAME/.ssh
        chmod 600 /home/$USERNAME/.ssh/authorized_keys
        chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
        echo -e "${GREEN}[OK] SSH-ключ добавлен${NC}"
    fi
else
    echo -e "${BLUE}[ПРОПУЩЕНО] SSH-ключи не настроены${NC}"
fi
echo ""

# ==============================================================================
# Шаг 7: Финальное обновление
# ==============================================================================
echo -e "${YELLOW}[7/7] Финальное обновление...${NC}"
apt update -y
echo -e "${GREEN}[OK] Обновление завершено${NC}"
echo ""

# ==============================================================================
# Итоги
# ==============================================================================
echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}  Настройка сервера завершена успешно!${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""
echo -e "${RED}ВАЖНО! Перед выходом из root:${NC}"
echo -e "${YELLOW}1. Переключитесь на нового пользователя:${NC}"
echo -e "   ${GREEN}su - $USERNAME${NC}"
echo ""
echo -e "${YELLOW}2. Проверьте sudo-права:${NC}"
echo -e "   ${GREEN}sudo whoami${NC}"
echo ""
echo -e "${YELLOW}3. Установите X-ray:${NC}"
echo -e "   ${GREEN}wget -qO- https://raw.githubusercontent.com/ServerTechnologies/simple-xray-core/refs/heads/main/xray-install | sudo bash${NC}"
echo ""
echo -e "${BLUE}================================================================${NC}"
