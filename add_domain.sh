#!/bin/bash

# === УНИВЕРСАЛЬНЫЙ СКРИПТ ДОБАВЛЕНИЯ САЙТА ===
# Поддерживает: Ubuntu, Debian, Fedora, RHEL, CentOS, AlmaLinux, Rocky Linux

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

# === ОПРЕДЕЛЕНИЕ СИСТЕМЫ ===
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
  else
    echo "❌ Не удалось определить ОС"
    exit 1
  fi

  case $OS in
    ubuntu|debian|linuxmint|raspbian)
      OS_FAMILY="debian"
      PKG_MANAGER="apt"
      APACHE_SERVICE="apache2"
      APACHE_USER="www-data"
      APACHE_CONF_DIR="/etc/apache2/sites-available"
      APACHE_CONF_ENABLED="/etc/apache2/sites-enabled"
      APACHE_CONF_EXT=".conf"
      LOG_DIR="/var/log/apache2"
      DIG_PACKAGE="dnsutils"
      ;;
    
    fedora|rhel|centos|rocky|almalinux)
      OS_FAMILY="redhat"
      PKG_MANAGER="dnf"
      APACHE_SERVICE="httpd"
      APACHE_USER="apache"
      APACHE_CONF_DIR="/etc/httpd/conf.d"
      APACHE_CONF_ENABLED="$APACHE_CONF_DIR" # В conf.d все файлы автоматически включены
      APACHE_CONF_EXT=".conf"
      LOG_DIR="/var/log/httpd"
      DIG_PACKAGE="bind-utils"
      ;;
    
    *)
      echo "❌ Неподдерживаемая ОС: $OS"
      exit 1
      ;;
  esac

  echo "✅ Определена система: $OS $VER (семейство: $OS_FAMILY)"
}

# === Установка пакетов ===
install_packages() {
  case $PKG_MANAGER in
    apt)
      apt update -y > /dev/null 2>&1
      apt install -y "$@" > /dev/null 2>&1
      ;;
    dnf)
      dnf install -y "$@" > /dev/null 2>&1
      ;;
  esac
}

# === Проверка наличия Apache ===
check_apache() {
  if ! systemctl is-active --quiet $APACHE_SERVICE; then
    echo "❌ Apache ($APACHE_SERVICE) не запущен!"
    exit 1
  fi
}

# === Основная логика ===
main() {
  detect_os
  check_apache

  # Создание директории сайта
  if [ ! -d "$SITE_PATH" ]; then
    echo "📁 Создаём директорию: $SITE_PATH"
    mkdir -p "$SITE_PATH"
    chown -R $APACHE_USER:$APACHE_USER "$SITE_PATH"
    chmod -R 755 "$SITE_PATH"
  fi

  # Создание заглушки index.html (если нет)
  if [ ! -f "$SITE_PATH/index.html" ]; then
    cat > "$SITE_PATH/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome to $DOMAIN</title></head>
<body>
<h1>✅ Your $DOMAIN is working!</h1>
<p>You are connected by <strong>HTTPS</strong>.</p>
<p>Server: $(hostname)</p>
<p>OS: $OS $VER</p>
</body>
</html>
EOF
    chown $APACHE_USER:$APACHE_USER "$SITE_PATH/index.html"
  fi

  # Имя конфигурации
  CONF_NAME="${DOMAIN}${APACHE_CONF_EXT}"
  HTTP_CONF="${APACHE_CONF_DIR}/${CONF_NAME}"

  # Создание HTTP-виртуального хоста
  if [ ! -f "$HTTP_CONF" ]; then
    cat > "$HTTP_CONF" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
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

    ErrorLog ${LOG_DIR}/${DOMAIN}_error.log
    CustomLog ${LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

    echo "📄 Создан HTTP-конфиг: $HTTP_CONF"

    # Для Debian/Ubuntu нужно включить сайт
    if [ "$OS_FAMILY" = "debian" ]; then
      a2ensite "$CONF_NAME" > /dev/null 2>&1
      echo "   Сайт включён (a2ensite)"
    fi
  else
    echo "⚠️  Конфиг для $DOMAIN уже существует. Используем существующий."
  fi

  # Включаем модуль rewrite если нужно
  if [ "$OS_FAMILY" = "debian" ]; then
    a2enmod rewrite > /dev/null 2>&1
  fi

  # Перезагружаем Apache
  systemctl reload $APACHE_SERVICE

  # Установка dig если нужно
  if ! command -v dig &> /dev/null; then
    echo "📦 Устанавливаем dig..."
    install_packages $DIG_PACKAGE
  fi

  # Проверка DNS
  SERVER_IP=$(hostname -I | awk '{print $1}')
  DOMAIN_IP=$(dig +short "$DOMAIN" A | head -n1)

  if [ -z "$DOMAIN_IP" ]; then
    echo "⚠️  Не удалось разрешить A-запись для $DOMAIN"
  elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    echo "⚠️  DNS $DOMAIN → $DOMAIN_IP, сервер → $SERVER_IP"
  else
    echo "✅ DNS корректен"
  fi

  # Настройка firewall
  if command -v ufw &> /dev/null; then
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    echo "🔥 UFW настроен"
  elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-service=http > /dev/null 2>&1
    firewall-cmd --permanent --add-service=https > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    echo "🔥 Firewalld настроен"
  fi

  # Запрос SSL-сертификата
  echo "🔐 Запрашиваем SSL-сертификат для: $DOMAIN"

  EMAIL="admin@$DOMAIN"

  if certbot --$APACHE_SERVICE \
             --non-interactive \
             --agree-tos \
             --email "$EMAIL" \
             --domains "$DOMAIN" \
             --redirect; then
    echo "✅ SSL-сертификат успешно выпущен"
  else
    echo "❌ Не удалось выпустить сертификат"
    echo "   Проверьте: порт 80 доступен, DNS настроен"
    exit 1
  fi

  systemctl reload $APACHE_SERVICE

  # Финальный вывод
  echo ""
  echo "✅ Настройка завершена!"
  echo "────────────────────────────────────"
  echo "Домен: $DOMAIN"
  echo "URL: https://$DOMAIN"
  echo "www.$DOMAIN → https://$DOMAIN"
  echo "Папка сайта: $SITE_PATH"
  echo "Система: $OS $VER"
  echo "────────────────────────────────────"
  echo "💡 Проверка: curl -I https://$DOMAIN"
  echo "   Логи: $LOG_DIR/${DOMAIN}_*.log"
}

# Запуск
main
