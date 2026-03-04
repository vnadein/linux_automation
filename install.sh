#!/bin/bash

# === УНИВЕРСАЛЬНЫЙ СКРИПТ УСТАНОВКИ (LAMP + phpMyAdmin + Node.js 22 + Certbot) ===
# Поддерживает: Ubuntu, Debian, Fedora, RHEL, CentOS, AlmaLinux, Rocky Linux
# ВНИМАНИЕ: устанавливается официальный MySQL вместо MariaDB

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

# === ОПРЕДЕЛЕНИЕ СИСТЕМЫ ===
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    OS_LIKE=$ID_LIKE
  else
    echo "❌ Не удалось определить ОС"
    exit 1
  fi

  # Нормализация имени ОС
  case $OS in
    ubuntu|debian|linuxmint|raspbian)
      OS_FAMILY="debian"
      PKG_MANAGER="apt"
      APACHE_SERVICE="apache2"
      APACHE_USER="www-data"
      APACHE_CONF_DIR="/etc/apache2/sites-available"
      APACHE_CONF_ENABLE="a2ensite"
      APACHE_MODULES_DIR="/etc/apache2/mods-available"
      LOG_DIR="/var/log/apache2"
      PHP_PACKAGES="php libapache2-mod-php php-mysql php-curl php-gd php-mbstring php-xml php-zip php-json php-cli php-fpm php-intl php-bcmath php-opcache"
      NODE_SETUP_CMD="curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
      NODE_INSTALL_CMD="apt install -y nodejs"
      CERTBOT_PACKAGES="certbot python3-certbot-apache"
      # MySQL (официальный)
      MYSQL_SERVICE="mysql"
      MYSQL_CLIENT="mysql-client"
      MYSQL_SERVER="mysql-server"
      MYSQL_DEV="libmysqlclient-dev"
      PHPMYADMIN_PACKAGE="phpmyadmin"
      PHPMYADMIN_CONF_DIR="/etc/phpmyadmin"
      PHPMYADMIN_WEB_DIR="/usr/share/phpmyadmin"
      EXTRA_REPOS=""
      REPO_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"
      ;;
    
    fedora|rhel|centos|rocky|almalinux)
      OS_FAMILY="redhat"
      PKG_MANAGER="dnf"
      APACHE_SERVICE="httpd"
      APACHE_USER="apache"
      APACHE_CONF_DIR="/etc/httpd/conf.d"
      APACHE_CONF_ENABLE="ln -s"
      APACHE_MODULES_DIR="/etc/httpd/conf.modules.d"
      LOG_DIR="/var/log/httpd"
      PHP_PACKAGES="php php-mysqlnd php-curl php-gd php-mbstring php-xml php-zip php-json php-cli php-fpm php-intl php-bcmath php-opcache"
      NODE_SETUP_CMD="curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -"
      NODE_INSTALL_CMD="dnf install -y nodejs"
      CERTBOT_PACKAGES="certbot python3-certbot-apache"
      # MySQL (официальный)
      MYSQL_SERVICE="mysqld"
      MYSQL_CLIENT="mysql"
      MYSQL_SERVER="mysql-server"
      MYSQL_DEV="mysql-devel"
      PHPMYADMIN_PACKAGE="phpMyAdmin"
      PHPMYADMIN_CONF_DIR="/etc/phpMyAdmin"
      PHPMYADMIN_WEB_DIR="/usr/share/phpMyAdmin"
      EXTRA_REPOS="epel-release"
      REPO_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"
      ;;
    
    *)
      echo "❌ Неподдерживаемая ОС: $OS"
      exit 1
      ;;
  esac

  log "✅ Определена система: $OS $VER (семейство: $OS_FAMILY)"
  log "   Пакетный менеджер: $PKG_MANAGER"
}

# === Генерация надёжных паролей ===
generate_password() {
  tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | fold -w 24 | head -n 1
}

# === Установка пакетов ===
install_packages() {
  log "📦 Устанавливаем пакеты: $*"
  
  case $PKG_MANAGER in
    apt)
      apt update -y
      apt install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
  esac
}

# === Запуск сервиса ===
start_service() {
  log "▶️  Запускаем сервис: $1"
  systemctl enable --now "$1"
}

# === Перезагрузка сервиса ===
reload_service() {
  log "🔄 Перезагружаем сервис: $1"
  systemctl reload "$1" 2>/dev/null || systemctl restart "$1"
}

# === Настройка firewall ===
setup_firewall() {
  if command -v ufw &> /dev/null; then
    log "🔥 Настройка UFW..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload 2>/dev/null || true
  elif command -v firewall-cmd &> /dev/null; then
    log "🔥 Настройка firewalld..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
  else
    log "⚠️  Firewall не обнаружен или не поддерживается"
  fi
}

# === Добавление официального репозитория MySQL ===
add_mysql_repo() {
  log "📦 Добавляем официальный репозиторий MySQL..."
  
  case $OS_FAMILY in
    debian)
      # Устанавливаем необходимые пакеты
      install_packages wget gnupg2 lsb-release
      
      # Скачиваем и устанавливаем пакет конфигурации репозитория
      MYSQL_APT_CONFIG_DEB="mysql-apt-config_0.8.33-1_all.deb"
      wget -q "https://dev.mysql.com/get/${MYSQL_APT_CONFIG_DEB}" -O /tmp/${MYSQL_APT_CONFIG_DEB}
      dpkg -i /tmp/${MYSQL_APT_CONFIG_DEB} 2>&1 | tee -a "$LOG_FILE"
      rm -f /tmp/${MYSQL_APT_CONFIG_DEB}
      
      # Обновляем список пакетов
      apt update -y
      ;;
    
    redhat)
      # Определяем основной номер версии
      MAJOR_VER=$(echo $VER | cut -d. -f1)
      
      if [ "$OS" = "fedora" ]; then
        REPO_RPM="mysql80-community-release-fc${MAJOR_VER}.noarch.rpm"
      else
        # Для RHEL/CentOS/Rocky/AlmaLinux используем el+версия
        REPO_RPM="mysql80-community-release-el${MAJOR_VER}.noarch.rpm"
      fi
      
      # Устанавливаем репозиторий
      dnf install -y https://dev.mysql.com/get/${REPO_RPM}
      
      # Импортируем ключ GPG (на всякий случай)
      rpm --import ${REPO_KEY_URL} 2>/dev/null || true
      
      # Отключаем модуль MariaDB, чтобы избежать конфликтов
      dnf module disable mariadb -y 2>/dev/null || true
      
      # Обновляем кэш
      dnf makecache
      ;;
  esac
  
  log "✅ Репозиторий MySQL добавлен"
}

# === ОСНОВНАЯ УСТАНОВКА ===
main() {
  log "🚀 Начало универсальной установки LAMP + phpMyAdmin + Node.js 22 + Certbot (с официальным MySQL)"
  log "Время начала: $(date)"

  # Определяем систему
  detect_os

  # Генерируем пароли
  MYSQL_ROOT_PASSWORD=$(generate_password)
  PHPMYADMIN_PASSWORD=$(generate_password)

  log "Сгенерирован пароль MySQL root: $MYSQL_ROOT_PASSWORD"
  log "Сгенерирован пароль phpMyAdmin DB user: $PHPMYADMIN_PASSWORD"

  # Устанавливаем дополнительные репозитории (для RedHat семейства)
  if [ "$OS_FAMILY" = "redhat" ] && [ -n "$EXTRA_REPOS" ]; then
    log "📦 Устанавливаем дополнительные репозитории..."
    install_packages $EXTRA_REPOS
  fi

  # Для Fedora добавляем REMI репозиторий для PHP (опционально, для более новых версий PHP)
  if [ "$OS" = "fedora" ]; then
    install_packages https://rpms.remirepo.net/fedora/remi-release-${VER}.rpm
    dnf config-manager --set-enabled remi
    dnf module reset php -y
    dnf module install php:remi-8.3 -y
  fi

  # Добавляем официальный репозиторий MySQL (для всех систем)
  add_mysql_repo

  # === Установка Apache ===
  log "📦 Устанавливаем Apache ($APACHE_SERVICE)..."
  install_packages $APACHE_SERVICE ${APACHE_SERVICE}-tools 2>/dev/null || install_packages $APACHE_SERVICE

  # Включаем SSL модуль
  if [ "$OS_FAMILY" = "debian" ]; then
    a2enmod ssl rewrite headers
  elif [ "$OS_FAMILY" = "redhat" ]; then
    install_packages mod_ssl
  fi

  start_service $APACHE_SERVICE

  # === Установка MySQL (Oracle) ===
  log "📦 Устанавливаем MySQL сервер и клиент..."
  install_packages $MYSQL_SERVER $MYSQL_CLIENT $MYSQL_DEV
  start_service $MYSQL_SERVICE

  # Небольшая задержка для полного старта MySQL
  sleep 5

  # Настройка пароля root (метод ALTER USER работает в MySQL 8)
  # После установки root обычно не имеет пароля (или доступ через socket)
  mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF

  # === Установка PHP ===
  log "📦 Устанавливаем PHP и расширения..."
  install_packages $PHP_PACKAGES
  reload_service $APACHE_SERVICE

  # === Установка phpMyAdmin ===
  log "📦 Устанавливаем phpMyAdmin..."
  
  if [ "$OS_FAMILY" = "debian" ]; then
    # Debian/Ubuntu способ с предварительной настройкой
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect $APACHE_SERVICE" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-user string root" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-pass password $MYSQL_ROOT_PASSWORD" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/app-pass password $PHPMYADMIN_PASSWORD" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/app-password-confirm password $PHPMYADMIN_PASSWORD" | debconf-set-selections
    
    install_packages $PHPMYADMIN_PACKAGE
    a2enconf phpmyadmin 2>/dev/null || true
    
  elif [ "$OS_FAMILY" = "redhat" ]; then
    # RedHat/Fedora способ
    install_packages $PHPMYADMIN_PACKAGE
    
    # Создаем симлинк если нужно
    if [ ! -L "/var/www/html/phpmyadmin" ] && [ -d "$PHPMYADMIN_WEB_DIR" ]; then
      ln -sf "$PHPMYADMIN_WEB_DIR" /var/www/html/phpmyadmin
    fi
    
    # Создаем конфиг Apache для phpMyAdmin
    cat > /etc/httpd/conf.d/phpMyAdmin.conf << EOF
Alias /phpmyadmin $PHPMYADMIN_WEB_DIR

<Directory $PHPMYADMIN_WEB_DIR/>
    Options None
    AllowOverride None
    Require all granted
</Directory>
EOF
  fi

  # Создаем базу данных и пользователя для phpMyAdmin
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS phpmyadmin;
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'localhost' IDENTIFIED BY '$PHPMYADMIN_PASSWORD';
FLUSH PRIVILEGES;
EOF

  # Импортируем таблицы конфигурации (если есть)
  if [ -f "$PHPMYADMIN_WEB_DIR/sql/create_tables.sql" ]; then
    mysql -u phpmyadmin -p"$PHPMYADMIN_PASSWORD" phpmyadmin < "$PHPMYADMIN_WEB_DIR/sql/create_tables.sql" 2>/dev/null || true
  fi

  reload_service $APACHE_SERVICE

  # === Установка Node.js 22.x ===
  log "📦 Устанавливаем Node.js 22.x и npm..."
  
  # Устанавливаем curl если нет
  if ! command -v curl &> /dev/null; then
    install_packages curl
  fi

  eval "$NODE_SETUP_CMD"
  eval "$NODE_INSTALL_CMD"

  NODE_VERSION=$(node --version 2>/dev/null || echo "не установлен")
  NPM_VERSION=$(npm --version 2>/dev/null || echo "не установлен")
  log "Node.js версия: $NODE_VERSION"
  log "npm версия: $NPM_VERSION"

  # === Установка Certbot ===
  log "📦 Устанавливаем Certbot и Apache-плагин..."
  install_packages $CERTBOT_PACKAGES

  # === Настройка firewall ===
  setup_firewall

  # === Выпуск SSL-сертификата (если указан домен) ===
  SERVER_IP=$(hostname -I | awk '{print $1}')
  log "IP-адрес сервера: $SERVER_IP"

  # Установка dig если нужно
  if ! command -v dig &> /dev/null; then
    if [ "$OS_FAMILY" = "debian" ]; then
      install_packages dnsutils
    else
      install_packages bind-utils
    fi
  fi

  if [ -n "$YOUR_DOMAIN" ]; then
    log "🔐 Попытка выпуска SSL-сертификата для домена: $YOUR_DOMAIN"

    DOMAIN_IP=$(dig +short "$YOUR_DOMAIN" A | head -n1)
    if [ -z "$DOMAIN_IP" ]; then
      log "⚠️  Не удалось разрешить A-запись для $YOUR_DOMAIN. Пропускаем выпуск сертификата."
    elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
      log "⚠️  DNS $YOUR_DOMAIN указывает на $DOMAIN_IP, но сервер имеет IP $SERVER_IP. Пропускаем выпуск."
    else
      log "✅ DNS корректен. Запускаем Certbot..."

      EMAIL="admin@$YOUR_DOMAIN"

      if certbot --$APACHE_SERVICE -n \
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
  fi

  # === Базовая безопасность ===
  log "🔒 Применяем базовые настройки безопасности..."
  
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

  # === Тестовый PHP-файл ===
  echo "<?php phpinfo(); ?>" > /var/www/html/info.php
  chown -R $APACHE_USER:$APACHE_USER /var/www/html/
  chmod 755 /var/www/html

  # === Финальная сводка ===
  log ""
  log "✅ УСТАНОВКА ЗАВЕРШЕНА"
  log "────────────────────────────────────"
  log "Система: $OS $VER"
  log "IP сервера: $SERVER_IP"
  if [ -n "$YOUR_DOMAIN" ]; then
    log "Домен: $YOUR_DOMAIN"
  fi
  log "База данных: MySQL (Oracle)"
  log "Пароль root: $MYSQL_ROOT_PASSWORD"
  log "Пароль phpMyAdmin DB user: $PHPMYADMIN_PASSWORD"
  log "phpMyAdmin URL: http://$SERVER_IP/phpmyadmin"
  log "Тест PHP: http://$SERVER_IP/info.php"
  if [ -n "$YOUR_DOMAIN" ] && grep -q "SSL-сертификат успешно выпущен" "$LOG_FILE"; then
    log "HTTPS: https://$YOUR_DOMAIN"
  fi
  log "────────────────────────────────────"
  log "⚠️  ВАЖНО:"
  log "   - УДАЛИТЕ /var/www/html/info.php после проверки!"
  log "   - Не передавайте /root/install.log третьим лицам — он содержит пароли!"
  log "   - Сертификаты обновляются автоматически"
  log ""
  log "📊 Статус сервисов:"
  systemctl status $APACHE_SERVICE --no-pager -l | head -n 3 | tee -a "$LOG_FILE"
  systemctl status $MYSQL_SERVICE --no-pager -l | head -n 3 | tee -a "$LOG_FILE"

  # Защита лог-файла
  chmod 600 "$LOG_FILE"
  chown root:root "$LOG_FILE"

  echo ""
  echo "✅ Установка завершена. Все данные сохранены в: $LOG_FILE"
}

# Запуск основной функции
main
