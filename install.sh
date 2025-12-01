#!/bin/bash

# === КОНФИГУРАЦИЯ ===
YOUR_DOMAIN=""  # ← Укажите ваш домен (например: example.com), если хотите автоматический SSL

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (или через sudo)."
  exit 1
fi

LOG_FILE="/root/install.log"
> "$LOG_FILE"  # Очистка или создание лог-файла

log() {
  echo "$1" | tee -a "$LOG_FILE"
}

log "🚀 Начало установки LAMP + phpMyAdmin + Node.js 22 + Certbot на Ubuntu 24.04"
log "Время начала: $(date)"

# === Генерация надёжных паролей ===
generate_password() {
  tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | fold -w 24 | head -n 1
}

MYSQL_ROOT_PASSWORD=$(generate_password)
PHPMYADMIN_PASSWORD=$(generate_password)

log "Сгенерирован пароль MySQL root: $MYSQL_ROOT_PASSWORD"
log "Сгенерирован пароль phpMyAdmin DB user: $PHPMYADMIN_PASSWORD"

# === Обновление системы ===
apt update -y
apt upgrade -y

# === Установка Apache ===
log "📦 Устанавливаем Apache..."
apt install -y apache2

a2enmod ssl rewrite headers
systemctl restart apache2

# === Установка MySQL ===
log "📦 Настраиваем и устанавливаем MySQL..."

apt install -y debconf-utils

debconf-set-selections <<< "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD"

apt install -y mysql-server
systemctl enable --now mysql

# === Установка PHP ===
log "📦 Устанавливаем PHP и расширения..."
apt install -y php libapache2-mod-php php-mysql php-curl php-gd php-mbstring php-xml php-zip php-json php-cli

systemctl restart apache2

# === Установка phpMyAdmin ===
log "📦 Устанавливаем phpMyAdmin..."

debconf-set-selections <<< "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2"
debconf-set-selections <<< "phpmyadmin phpmyadmin/dbconfig-install boolean true"
debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/admin-user string root"
debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/admin-pass password $MYSQL_ROOT_PASSWORD"
debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/app-pass password $PHPMYADMIN_PASSWORD"
debconf-set-selections <<< "phpmyadmin phpmyadmin/app-password-confirm password $PHPMYADMIN_PASSWORD"

apt install -y phpmyadmin
a2enconf phpmyadmin
systemctl reload apache2

# === Установка Node.js 22.x ===
log "📦 Устанавливаем Node.js 22.x и npm..."

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -  
apt install -y nodejs

NODE_VERSION=$(node --version 2>/dev/null || echo "не установлен")
NPM_VERSION=$(npm --version 2>/dev/null || echo "не установлен")
log "Node.js версия: $NODE_VERSION"
log "npm версия: $NPM_VERSION"

# === Установка Certbot ===
log "📦 Устанавливаем Certbot и Apache-плагин..."
apt install -y certbot python3-certbot-apache

# === Выпуск SSL-сертификата (если указан домен) ===
SERVER_IP=$(hostname -I | awk '{print $1}')
log "IP-адрес сервера: $SERVER_IP"

if [ -n "$YOUR_DOMAIN" ]; then
  log "🔐 Попытка выпуска SSL-сертификата для домена: $YOUR_DOMAIN"

  DOMAIN_IP=$(dig +short "$YOUR_DOMAIN" A | head -n1)
  if [ -z "$DOMAIN_IP" ]; then
    log "⚠️  Не удалось разрешить A-запись для $YOUR_DOMAIN. Пропускаем выпуск сертификата."
  elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    log "⚠️  DNS $YOUR_DOMAIN указывает на $DOMAIN_IP, но сервер имеет IP $SERVER_IP. Пропускаем выпуск."
  else
    log "✅ DNS корректен. Запускаем Certbot..."

    # Используем email admin@domain (можно заменить на реальный при необходимости)
    EMAIL="admin@$YOUR_DOMAIN"

    if certbot --apache -n \
               --agree-tos \
               --email "$EMAIL" \
               --domains "$YOUR_DOMAIN" \
               --redirect 2>>"$LOG_FILE"; then
      log "✅ SSL-сертификат успешно выпущен для $YOUR_DOMAIN"
      log "HTTPS доступен по адресу: https://$YOUR_DOMAIN"
    else
      log "❌ Не удалось выпустить сертификат. Проверьте сетевые настройки и DNS."
    fi
  fi
else
  log "ℹ️  Домен не указан. Certbot установлен, выпуск сертификата пропущен."
  log "   Для ручной настройки выполните: sudo certbot --apache"
fi

# === Базовая безопасность MySQL ===
log "🔒 Применяем базовую безопасность MySQL..."
mysql --user="root" --password="$MYSQL_ROOT_PASSWORD" <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS phpmyadmin;
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'localhost' IDENTIFIED BY '$PHPMYADMIN_PASSWORD';
FLUSH PRIVILEGES;
EOF

# === Тестовый PHP-файл ===
echo "<?php phpinfo(); ?>" > /var/www/html/info.php

# === Финальная сводка ===
log ""
log "✅ УСТАНОВКА ЗАВЕРШЕНА"
log "────────────────────────────────────"
log "IP сервера: $SERVER_IP"
if [ -n "$YOUR_DOMAIN" ]; then
  log "Домен: $YOUR_DOMAIN"
fi
log "MySQL root password: $MYSQL_ROOT_PASSWORD"
log "phpMyAdmin DB user password: $PHPMYADMIN_PASSWORD"
log "phpMyAdmin URL: http://$SERVER_IP/phpmyadmin"
log "Тест PHP: http://$SERVER_IP/info.php"
if [ -n "$YOUR_DOMAIN" ] && grep -q "SSL-сертификат успешно выпущен" "$LOG_FILE"; then
  log "HTTPS: https://$YOUR_DOMAIN"
fi
log "────────────────────────────────────"
log "⚠️  ВАЖНО:"
log "   - УДАЛИТЕ /var/www/html/info.php после проверки!"
log "   - Не передавайте /root/install.log третьим лицам — он содержит пароли!"
log "   - Рассмотрите возможность настройки UFW: sudo ufw allow 'Apache Full'"
log "   - Certbot обновляет сертификаты автоматически (раз в 12 часов)."

# Защита лог-файла
chmod 600 "$LOG_FILE"
chown root:root "$LOG_FILE"

echo ""
echo "✅ Установка завершена. Все данные сохранены в: $LOG_FILE"
echo "   (доступ только для root)"
