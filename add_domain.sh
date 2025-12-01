#!/bin/bash

# Проверка аргументов
if [ "$#" -ne 2 ]; then
  echo "Использование: $0 <домен> <путь_к_сайту>"
  echo "Пример: $0 example.com /var/www/example.com"
  exit 1
fi

DOMAIN="$1"
SITE_PATH="$2"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт от имени root (или через sudo)."
  exit 1
fi

# Проверка наличия Apache и Certbot
if ! command -v apache2 &> /dev/null; then
  echo "❌ Apache не установлен. Установите: apt install apache2"
  exit 1
fi

if ! command -v certbot &> /dev/null; then
  echo "❌ Certbot не установлен. Установите: apt install certbot python3-certbot-apache"
  exit 1
fi

# Создание директории сайта
if [ ! -d "$SITE_PATH" ]; then
  echo "📁 Создаём директорию: $SITE_PATH"
  mkdir -p "$SITE_PATH"
  chown -R www-data:www-data "$SITE_PATH"
  chmod -R 755 "$SITE_PATH"
fi

# Создание заглушки index.html (если нет)
if [ ! -f "$SITE_PATH/index.html" ]; then
  cat > "$SITE_PATH/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Добро пожаловать на $DOMAIN</title></head>
<body>
<h1>✅ Сайт $DOMAIN работает!</h1>
<p>Вы подключены по <strong>HTTPS</strong>.</p>
</body>
</html>
EOF
fi

# Имя конфигурации
CONF_NAME="${DOMAIN}.conf"
HTTP_CONF="/etc/apache2/sites-available/${CONF_NAME}"

# Создание HTTP-виртуального хоста (только для основного домена)
if [ ! -f "$HTTP_CONF" ]; then
  cat > "$HTTP_CONF" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    # Перехватываем www и перенаправляем на основной домен
    ServerAlias www.$DOMAIN

    DocumentRoot $SITE_PATH

    <Directory $SITE_PATH>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Принудительное перенаправление на HTTPS (без www)
    RewriteEngine On
    RewriteCond %{HTTP_HOST} ^www\.(.*)$ [NC]
    RewriteRule ^(.*)$ https://%1%{REQUEST_URI} [R=301,L]
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://$DOMAIN%{REQUEST_URI} [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN_error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN_access.log combined
</VirtualHost>
EOF

  echo "📄 Создан HTTP-конфиг: $HTTP_CONF"
else
  echo "⚠️  Конфиг для $DOMAIN уже существует. Используем существующий."
fi

# Включаем сайт
a2ensite "$CONF_NAME" > /dev/null 2>&1
systemctl reload apache2

# Проверка DNS (для информации)
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN_IP=$(dig +short "$DOMAIN" A | head -n1)

if [ -z "$DOMAIN_IP" ]; then
  echo "⚠️  Не удалось разрешить A-запись для $DOMAIN. Это может помешать выпуску сертификата."
elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
  echo "⚠️  DNS $DOMAIN указывает на $DOMAIN_IP, но сервер — $SERVER_IP. Проверьте A-запись!"
fi

# Запрос сертификата ТОЛЬКО для основного домена (без www)
echo "🔐 Запрашиваем SSL-сертификат ТОЛЬКО для: $DOMAIN"

EMAIL="admin@$DOMAIN"

if certbot --apache \
           --non-interactive \
           --agree-tos \
           --email "$EMAIL" \
           --domains "$DOMAIN" \
           --redirect; then
  echo "✅ SSL-сертификат успешно выпущен для $DOMAIN"
else
  echo "❌ Не удалось выпустить сертификат. Проверьте:"
  echo "   - Доступность порта 80 из интернета"
  echo "   - Корректность DNS A-записи"
  exit 1
fi

# Certbot сам перезагружает Apache, но на всякий случай:
systemctl reload apache2

echo ""
echo "✅ Настройка завершена!"
echo "   Основной URL: https://$DOMAIN"
echo "   www.$DOMAIN → автоматически перенаправляется на https://$DOMAIN"
echo "   Папка сайта: $SITE_PATH"
echo ""
echo "💡 Советы:"
echo "   - Все HTTP → HTTPS (с редиректом без www)"
echo "   - Сертификат обновляется автоматически (certbot renew)"
