#!/bin/bash
#===============================================================================
# Unified Server Setup Script with Selective Install/Uninstall & Verbose Mode
# Installs: Tailscale, Samba, Apache+PHP, SearxNG, Calibre-Web, CrossPoint Sync, Navidrome
# Version: 3.1
# Date: 2026-09-27
# Usage Examples:
#   sudo ./unified_install.sh                    # Full installation (silent)
#   sudo ./unified_install.sh -v                 # Full installation (verbose)
#   sudo ./unified_install.sh --install-sync     # Only CrossPoint Sync
#   sudo ./unified_install.sh --uninstall-navidrome
#   sudo ./unified_install.sh -v --uninstall-all
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION SECTION - EDIT THESE VALUES
#-------------------------------------------------------------------------------

# General
TIMEZONE="Etc/UTC"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Samba/Tailscale
YOURDOMAIN="yourdomain.com"
SUBDOMAIN="yoursubdmain"   #like yoursubdomain.yourdomain.com
YOUREMAIL="youremail@domain.com"

# Library Paths
# This is where your calibre books/ebooks are/will be stored
CALIBRE_LIBRARY="/path/to/books/library"

# Music Path
MUSIC_LIBRARY="/path/to/music/library"

# Ports
SEARXNG_PORT=80
CALIBRE_PORT=8083
CROSSPOINT_PORT=8085
NAVDROME_PORT=4533

# Users
CALIBRE_USER="acw"
CALIBRE_GROUP="acw"
CROSSPOINT_USER="cps"
CROSSPOINT_GROUP="cps"

# Installation flags
VERBOSE=false
INSTALL_SHARING=false
INSTALL_WEB=false
INSTALL_SEARXNG=false
INSTALL_CALIBRE=false
INSTALL_CROSSPOINT=false
INSTALL_NAVIDROME=false

# Uninstall flags
UNINSTALL_ALL=false
UNINSTALL_SHARING=false
UNINSTALL_WEB=false
UNINSTALL_SEARXNG=false
UNINSTALL_CALIBRE=false
UNINSTALL_CROSSPOINT=false
UNINSTALL_NAVIDROME=false

#-------------------------------------------------------------------------------
# COLOURS FOR OUTPUT
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Colour

#-------------------------------------------------------------------------------
# UTILITY FUNCTIONS
#-------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_action()  { echo -e "${CYAN}[ACTION]${NC} $*"; }
log_verbose() { if [[ "${VERBOSE}" == true ]]; then echo -e "${MAGENTA}[VERBOSE]${NC} $*"; fi; }

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Please run as root (sudo $0)"
        exit 1
    fi
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    read -p "$prompt [$default]: " response
    case "${response:-$default}" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

section_header() {
    echo ""
    echo "==============================================================================="
    log_info "$1"
    echo "==============================================================================="
    echo ""
}

cmd_exec() {
    """Execute a command, showing it in verbose mode."""
    if [[ "${VERBOSE}" == true ]]; then
        echo -e "${CYAN}➜ ${NC}$*"
        "$@"
    else
        "$@"
    fi
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install/Manage self-hosted server services

OPTIONS:
  Installation Modes:
    (no args)                    Run complete installation of all services
    --install-all                Same as no args - install everything
    --reinstall                  Force reinstall of all services

  Selective Installation:
    --install-sharing            Install file sharing (Samba, Tailscale, Nemo)
    --install-web                Install web server (Apache + PHP)
    --install-searxng            Install SearxNG search engine
    --install-calibre            Install Calibre-Web NextGen (includes Calibre)
    --install-sync               Install CrossPoint Sync only
    --install-navidrome          Install Navidrome music server only

  Uninstallation Modes:
    --uninstall-all              Remove ALL services and clean system
    --uninstall-sharing          Remove Samba, Tailscale, Nemo
    --uninstall-web              Remove Apache + PHP
    --uninstall-searxng          Remove SearxNG
    --uninstall-calibre          Remove Calibre-Web (keeps library)
    --uninstall-sync             Remove CrossPoint Sync
    --uninstall-navidrome        Remove Navidrome

  Utility Commands:
    --status                     Show status of all services
    --help,-h                    Show this help message

  Verbosity:
    -v, --verbose                Show every command being executed
    -s, --silent                 Minimal output (default)

EXAMPLES:
  sudo $0                              # Full installation (minimal output)
  sudo $0 -v                           # Full installation (verbose)
  sudo $0 -v --install-sync            # Install CrossPoint Sync verbosely
  sudo $0 --uninstall-navidrome        # Remove Navidrome only
  sudo $0 --uninstall-all              # Remove everything
  sudo $0 -v --status                  # Check service status verbosely

NOTES:
  - All operations require root privileges
  - Services are independent; order matters for dependencies
  - Personal library files are preserved during uninstallation

EOF
}

show_status() {
    section_header "Service Status Report"
    
    echo ""
    printf "%-20s %-15s %-10s %-8s %s\n" "SERVICE" "UNIT ACTIVE?" "HTTP STATUS" "PORT" "LAST CHECK"
    printf "%-20s %-15s %-10s %-8s %s\n" "-------" "------------" "-----------" "----" "----------"
    
    # Apache
    if systemctl is-active --quiet apache2 2>/dev/null; then
        printf "%-20s %-15s " "apache2" "running" "checking" "80" "$(date '+%H:%M:%S')"
        if curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null | grep -q "^2"; then
            printf "HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' http://localhost/)"
        else
            printf "N/A\n"
        fi
    else
        printf "%-20s %-15s %-10s %-8s %s\n" "apache2" "stopped" "N/A" "80" "$(date '+%H:%M:%S')"
    fi
    
    # Calibre-Web
    if systemctl is-active --quiet calibre-web-nextgen 2>/dev/null; then
        printf "%-20s %-15s " "calibre-web" "running" "checking" "$CALIBRE_PORT" "$(date '+%H:%M:%S')"
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CALIBRE_PORT}/" 2>/dev/null | grep -q "^2\|^3"; then
            printf "HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${CALIBRE_PORT}/")"
        else
            printf "N/A\n"
        fi
    else
        printf "%-20s %-15s %-10s %-8s %s\n" "calibre-web" "stopped" "N/A" "$CALIBRE_PORT" "$(date '+%H:%M:%S')"
    fi
    
    # CrossPoint Sync
    if systemctl is-active --quiet crosspoint-sync 2>/dev/null; then
        printf "%-20s %-15s " "crosspoint-sync" "running" "checking" "$CROSSPOINT_PORT" "$(date '+%H:%M:%S')"
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CROSSPOINT_PORT}/" 2>/dev/null | grep -q "^2\|^3"; then
            printf "HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${CROSSPOINT_PORT}/")"
        else
            printf "N/A\n"
        fi
    else
        printf "%-20s %-15s %-10s %-8s %s\n" "crosspoint-sync" "stopped" "N/A" "$CROSSPOINT_PORT" "$(date '+%H:%M:%S')"
    fi
    
    # Navidrome
    if systemctl is-active --quiet navidrome 2>/dev/null; then
        printf "%-20s %-15s " "navidrome" "running" "checking" "$NAVDROME_PORT" "$(date '+%H:%M:%S')"
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${NAVDROME_PORT}/" 2>/dev/null | grep -q "^2\|^3"; then
            printf "HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${NAVDROME_PORT}/")"
        else
            printf "N/A\n"
        fi
    else
        printf "%-20s %-15s %-10s %-8s %s\n" "navidrome" "stopped" "N/A" "$NAVDROME_PORT" "$(date '+%H:%M:%S')"
    fi
    
    echo ""
    log_info "Run 'systemctl status <service>' for detailed service info"
}

#-------------------------------------------------------------------------------
# INSTALL FUNCTIONS
#-------------------------------------------------------------------------------

step_system_prep() {
    section_header "System Preparation"
    
    log_info "Updating package lists..."
    cmd_exec apt-get update -qq
    
    log_info "Installing base dependencies..."
    cmd_exec apt-get install -y \
        curl \
        git \
        python3 \
        python3-pip \
        python3-venv \
        sqlite3 \
        imagemagick \
        python3-dev \
        libldap2-dev \
        libsasl2-dev \
        libssl-dev \
        unzip \
        wget \
        ufw

    log_info "Enabling ufw..."
    cmd_exec ufw enable
    
    log_info "Creating Python symlink..."
    if [[ "${VERBOSE}" == true ]]; then
        echo -e "${CYAN}➜ ${NC}[ -L /usr/bin/python ] || ln -sf /usr/bin/python3 /usr/bin/python"
        [ -L /usr/bin/python ] || ln -sf /usr/bin/python3 /usr/bin/python
    else
        [ -L /usr/bin/python ] || ln -sf /usr/bin/python3 /usr/bin/python >/dev/null 2>&1
    fi
    
    log_success "System preparation complete"
}

step_file_sharing() {
    section_header "File Sharing & Remote Access"
    
    log_info "Installing Nemo file manager..."
    cmd_exec apt-get install -y nemo nemo-share

    log_info "Opening firewall port..."
    cmd_exec ufw allow 445/tcp    # Samba
    
    log_info "Installing Tailscale..."
    cmd_exec curl -fsSL https://tailscale.com/install.sh | sh
    log_info "Tailscale installed. Run 'sudo tailscale up --ssh' to activate."
    
    log_info "Installing Samba..."
    cmd_exec apt-get install -y samba
    
    log_info "Configuring Samba directory..."
    cmd_exec mkdir -p /srv/samba/shared
    cmd_exec chown nobody:nogroup /srv/samba/shared
    cmd_exec chmod 2770 /srv/samba/shared
    
    log_warn "Post-installation: Add users to Samba with 'sudo smbpasswd -a <username>'"
    
    log_success "File sharing services ready"
}

step_web_server() {
    section_header "Web Server Setup (Apache + PHP)"
    
    log_info "Installing Apache2..."
    cmd_exec apt-get install -y apache2

    log_info "Opening firewall ports..."
    cmd_exec ufw allow 80/tcp     # HTTP
    cmd_exec ufw allow 443/tcp    # HTTPS
    
    log_info "Getting Apache version..."
    APACHE_VERSION=$(apache2 -v | grep -oP 'version \K[\d.]+')
    
    log_info "Installing PHP..."
    cmd_exec apt-get install -y php libapache2-mod-php php-cli php-common
    
    # Extract PHP major.minor version (e.g., PHP 8.3.6 → 8.3)
    PHP_VERSION=$(php -v | head -n1 | grep -oP 'PHP \K\d+\.\d+')
    log_info "Detected PHP version: ${PHP_VERSION}"
    
    log_info "Enabling Apache modules..."
    
    cmd_exec a2enmod "php${PHP_VERSION}"
    cmd_exec a2enmod ssl headers proxy proxy_http proxy_uwsgi rewrite
    
    log_info "Creating document root..."
    cmd_exec mkdir -p /var/www/http
    # Get current username (non-root user who ran sudo) and use 'users' group
    CURRENT_USER="${SUDO_USER:-root}"
    log_info "Setting ownership to ${CURRENT_USER}:users with 775 permissions"
    cmd_exec chmod -R 775 /var/www/http
    
    log_info "Configuring VirtualHost..."
    cmd_exec cat > /etc/apache2/sites-available/000-default.conf << VHOST
<VirtualHost *:80>
    ServerAdmin ${YOUREMAIL}
    ServerName ${YOURDOMAIN}
    ServerAlias ${SUBDOMAIN}.${YOURDOMAIN}
    DocumentRoot /var/www/http
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
    
    <Directory /var/www/http>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
VHOST
    
    cmd_exec a2ensite 000-default.conf
    
    log_info "Testing Apache configuration..."
    cmd_exec apache2ctl configtest
    
    log_info "Restarting Apache2..."
    cmd_exec systemctl restart apache2
    
    log_info "Apache2 Status:"
    cmd_exec systemctl status apache2 --no-pager | head -5
    
    log_success "Web server ready at http://${YOURDOMAIN}"
}

step_searxng() {
    section_header "SearxNG Privacy Search Engine"
    
    log_info "Cloning SearxNG repository..."
    if [[ "${VERBOSE}" == true ]]; then
        echo -e "${CYAN}➜ ${NC}cd /opt"
        echo -e "${CYAN}➜ ${NC}[ -d searxng ] || git clone https://github.com/searxng/searxng.git searxng"
        echo -e "${CYAN}➜ ${NC}cd searxng"
    fi
    cd /opt
    [ -d searxng ] || cmd_exec git clone https://github.com/searxng/searxng.git searxng
    cd searxng
    
    log_info "Modifying platform detection for Linux Mint compatibility..."
    cmd_exec cp utils/searxng.sh utils/searxng.sh.bak
    cmd_exec cp utils/lib.sh utils/lib.sh.bak
    cmd_exec sed -i 's/ubuntu-\* |debian-\*/ubuntu-* |debian-* |linuxmint-*/g' utils/searxng.sh
    cmd_exec sed -i 's/ubuntu-\* |debian-\*/ubuntu-* |debian-* |linuxmint-*/g' utils/lib.sh
    cmd_exec sed -i 's/ubuntu |debian/ubuntu |debian |linuxmint/g' utils/lib.sh
    
    log_info "Creating SearxNG system user..."
    cmd_exec useradd --shell /bin/bash --system --home-dir "/usr/local/searxng" \
        --comment 'Privacy-respecting metasearch engine' searxng 2>/dev/null || true
    
    log_info "Setting up directories..."
    cmd_exec mkdir -p "/usr/local/searxng"
    cmd_exec chown -R searxng:searxng "/usr/local/searxng"
    cmd_exec chown -R searxng /opt/searxng
    cmd_exec git config --global --add safe.directory /opt/searxng
    
    log_info "Installing SearxNG components..."
    cmd_exec sudo -H utils/searxng.sh install all
    cmd_exec sudo -H utils/searxng.sh install uwsgi
    cmd_exec sudo -H utils/searxng.sh install apache
    
    log_info "Enabling SearxNG site..."
    cmd_exec a2ensite searxng.conf 2>/dev/null || true
    
    log_info "Restarting Apache and uWSGI..."
    cmd_exec systemctl restart apache2
    cmd_exec systemctl restart uwsgi 2>/dev/null || true
    
    log_success "SearxNG installed at http://${YOURDOMAIN}${SEARXNG_PORT}/searxng"
}

step_calibre() {
    section_header "Calibre-Web NextGen Installation"
    
    INSTALL_DIR="/opt/calibre-web-nextgen"
    CONFIG_DIR="${INSTALL_DIR}/config"
    
    log_info "Verifying library path configuration..."
    
    log_info "Creating library path: $CALIBRE_LIBRARY"
    cmd_exec mkdir -p "$CALIBRE_LIBRARY"
    cmd_exec chmod 755 "$CALIBRE_LIBRARY"
    
    log_info "Installing Calibre (required by Calibre-Web NextGen)..."
    cmd_exec apt-get install -y calibre
    
    log_info "Installing Calibre-Web dependencies..."
    cmd_exec apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        git \
        sqlite3 \
        curl \
        zip \
        imagemagick

    log_info "Opening firewall port..."
    cmd_exec ufw allow 8083/tcp   # Calibre-Web
    
    log_info "Creating installation directory..."
    cmd_exec mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    log_info "Cloning repository..."
    if [[ -d .git ]]; then
        log_info "Repository already exists, skipping clone."
    else
        cmd_exec git clone https://github.com/new-usemame/Calibre-Web-NextGen.git .
    fi
    
    log_info "Creating service user '$CALIBRE_USER'..."
    id "$CALIBRE_USER" &>/dev/null && log_info "User exists, skipping creation." || \
        cmd_exec useradd -r -s /bin/false -d "$INSTALL_DIR" "$CALIBRE_USER"
    CURRENT_USER="${SUDO_USER:-root}"
    cmd_exec usermod -a -G "$CALIBRE_GROUP" "$CURRENT_USER" 2>/dev/null || true
    
    log_info "Setting up Python virtual environment..."
    python3 -m venv venv
    source venv/bin/activate
    python -m pip install --upgrade pip setuptools wheel
    ./venv/bin/python3 -m pip install -e .
    deactivate
    
    log_info "Creating config directory..."
    cmd_exec mkdir -p "$CONFIG_DIR"
    cmd_exec chmod 775 "$CONFIG_DIR"
    
    log_info "Creating systemd service..."
    cmd_exec cat > /etc/systemd/system/calibre-web-nextgen.service << SERVICE
[Unit]
Description=Calibre-Web NextGen
After=network.target

[Service]
Type=simple
User=${CALIBRE_USER}
Group=${CALIBRE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${INSTALL_DIR}/venv/bin"
Environment="TZ=${TIMEZONE}"
ExecStart=${INSTALL_DIR}/venv/bin/python cps.py -p ${CONFIG_DIR}/app.db
Restart=always
RestartSec=10
UMask=022

[Install]
WantedBy=multi-user.target
SERVICE
    
    log_info "Setting permissions..."
    cmd_exec chown -R "${CALIBRE_USER}:${CALIBRE_GROUP}" "$INSTALL_DIR"
    cmd_exec chmod -R 775 "$INSTALL_DIR"
    cmd_exec setfacl -R -m u:${CALIBRE_USER}:rwx "$CALIBRE_LIBRARY" 2>/dev/null || \
        log_warn "ACL command failed, manually run: sudo setfacl -R -m u:${CALIBRE_USER}:rwx '${CALIBRE_LIBRARY}'"
    
    log_info "Initializing Calibre database with README.md..."
    if [ -f "$SCRIPT_DIR/README.md" ]; then
        log_info "Adding README.md to Calibre library..."
        cmd_exec calibredb add "$SCRIPT_DIR/README.md" --with-library "$CALIBRE_LIBRARY"
        log_success "README.md added to library successfully"
    else
        log_warn "README.md not found at $SCRIPT_DIR/README.md - skipping initialization"
        log_info "You can manually add books later with: calibredb add <ebook> --with-library $CALIBRE_LIBRARY"
    fi
    
    log_info "Initializing database..."
    cmd_exec systemctl daemon-reload
    cmd_exec systemctl start calibre-web-nextgen || true
    log_info "Waiting for database initialization..."
    sleep 10
    cmd_exec systemctl stop calibre-web-nextgen 2>/dev/null || true
    
    if [ -f "${CONFIG_DIR}/app.db" ]; then
        log_info "Setting library path in database..."
        cmd_exec sqlite3 "${CONFIG_DIR}/app.db" << SQLEOF
UPDATE settings SET config_calibre_dir = '${CALIBRE_LIBRARY}' WHERE id = 1;
.quit
SQLEOF
    fi
    
    log_info "Enabling and starting service..."
    cmd_exec systemctl enable calibre-web-nextgen
    cmd_exec systemctl start calibre-web-nextgen
    
    systemctl is-active --quiet calibre-web-nextgen && \
        log_success "Calibre-Web running at http://localhost:${CALIBRE_PORT}" || \
        log_warn "Calibre-Web service failed to start. Check logs."
    
    log_info "Default credentials: admin / admin123"
    log_info "Remember to change the password after first login!"
    log_info "Library path: $CALIBRE_LIBRARY"
}

step_crosspoint() {
    section_header "CrossPoint Sync Server"
    
    APP_DIR="/opt/crosspoint-sync"
    
    log_info "Installing Node.js 22..."
    cmd_exec curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    cmd_exec apt-get install -y nodejs
    log_info "Node version: $(node --version)"

    log_info "Opening firewall port..."
    cmd_exec ufw allow 8085/tcp   # CrossPoint
    
    log_info "Creating application directory..."
    cmd_exec mkdir -p "$APP_DIR"
    cd "$APP_DIR"
    
    log_info "Creating service user..."
    id "$CROSSPOINT_USER" &>/dev/null && log_info "User exists, skipping creation." || \
        cmd_exec useradd -r -s /bin/false -d "$APP_DIR" "$CROSSPOINT_USER"
    cmd_exec chown -R "$CROSSPOINT_USER:$CROSSPOINT_GROUP" "$APP_DIR"
    
    log_info "Cloning repository..."
    if [[ -d .git ]]; then
        log_info "Repository already exists, skipping clone."
    else
        cmd_exec git clone https://github.com/crosspoint-reader/crosspoint-sync.git .
    fi
    
    log_info "Installing npm dependencies..."
    cmd_exec npm install
    cmd_exec npm audit fix || true
    cmd_exec npm run build
    
    log_info "Generating encryption token..."
    TOKEN_KEY=$(openssl rand -hex 32)
    cmd_exec echo "$TOKEN_KEY" > "$APP_DIR/token.key"
    cmd_exec chown "$CROSSPOINT_USER:$CROSSPOINT_GROUP" "$APP_DIR/token.key"
    cmd_exec chmod 600 "$APP_DIR/token.key"
    
    log_info "Creating environment file..."
    cmd_exec cat > "$APP_DIR/env" << ENVFILE
PORT=${CROSSPOINT_PORT}
DATABASE_PATH=$APP_DIR/crosspoint.db
REGISTRATION_DISABLED=false
AUTH_RATE_LIMIT_PER_MINUTE=30
TOKEN_ENC_KEY=${TOKEN_KEY}
TRUST_PROXY=true
CORS_ORIGINS=
LOG_LEVEL=info
ENVFILE
    cmd_exec chmod 600 "$APP_DIR/env"
    
    log_info "Creating systemd service..."
    cmd_exec cat > /etc/systemd/system/crosspoint-sync.service << SERVICE
[Unit]
Description=CrossPoint Sync Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$CROSSPOINT_USER
Group=$CROSSPOINT_GROUP
WorkingDirectory=$APP_DIR
EnvironmentFile=-$APP_DIR/env
ExecStart=/usr/bin/node dist/index.js
NoNewPrivileges=yes
PrivateTmp=yes
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE
    
    log_info "Starting service..."
    cmd_exec systemctl daemon-reload
    cmd_exec systemctl enable crosspoint-sync
    cmd_exec systemctl start crosspoint-sync
    sleep 2
    
    systemctl is-active --quiet crosspoint-sync && \
        log_success "CrossPoint Sync running at http://localhost:${CROSSPOINT_PORT}" || \
        log_warn "CrossPoint Sync service failed. Check logs."
}

step_navidrome() {
    section_header "Navidrome Music Server"
    
    NAVIDROME_VERSION="0.63.2"
    DEB_URL="https://github.com/navidrome/navidrome/releases/download/v${NAVIDROME_VERSION}/navidrome_${NAVIDROME_VERSION}_linux_amd64.deb"
    
    log_info "Downloading Navidrome..."
    cmd_exec mkdir -p ~/Downloads
    cd ~/Downloads
    cmd_exec wget -q "$DEB_URL"

    log_info "Opening firewall port..."
    cmd_exec ufw allow 4533/tcp   # Navidrome
    
    log_info "Installing Navidrome..."
    cmd_exec apt-get install -y ./navidrome_${NAVIDROME_VERSION}_linux_amd64.deb
    
    log_info "Creating music library directory..."
    cmd_exec mkdir -p "$MUSIC_LIBRARY"
    cmd_exec chmod 755 "$MUSIC_LIBRARY"
    
    log_info "Configuring Navidrome..."
    cmd_exec mkdir -p /etc/navidrome
    cmd_exec cat > /etc/navidrome/navidrome.toml << CONFIG
MusicFolder = "${MUSIC_LIBRARY}"
Port = ${NAVDROME_PORT}
DataDir = "/var/lib/navidrome"
LogLevel = "info"
CONFIG
    
    log_info "Enabling and starting service..."
    cmd_exec systemctl enable navidrome
    cmd_exec systemctl start navidrome
    
    systemctl is-active --quiet navidrome && \
        log_success "Navidrome running at http://localhost:${NAVDROME_PORT}" || \
        log_warn "Navidrome service failed. Check logs."
}

#-------------------------------------------------------------------------------
# UNINSTALL FUNCTIONS
#-------------------------------------------------------------------------------

uninstall_searxng() {
    section_header "Removing SearxNG"
    
    log_action "Stopping SearxNG-related services..."
    cmd_exec systemctl stop uwsgi 2>/dev/null || true
    cmd_exec systemctl stop apache2 2>/dev/null || true
    
    log_action "Disabling SearxNG Apache site..."
    cmd_exec a2dissite searxng.conf 2>/dev/null || true
    
    log_action "Removing SearxNG directories..."
    cmd_exec rm -rf /opt/searxng
    cmd_exec rm -rf /usr/local/searxng
    
    log_action "Removing SearxNG user..."
    cmd_exec deluser --remove-home searxng 2>/dev/null || true
    
    log_action "Cleaning uWSGI configurations..."
    cmd_exec rm -rf /etc/uwsgi/apps-enabled/searxng* 2>/dev/null || true
    cmd_exec rm -rf /etc/uwsgi/apps-available/searxng* 2>/dev/null || true
    
    cmd_exec systemctl restart apache2 2>/dev/null || true
    log_success "SearxNG removed successfully"
}

uninstall_calibre() {
    section_header "Removing Calibre-Web NextGen"
    
    INSTALL_DIR="/opt/calibre-web-nextgen"
    CONFIG_DIR="${INSTALL_DIR}/config"
    
    log_action "Stopping Calibre-Web service..."
    cmd_exec systemctl stop calibre-web-nextgen 2>/dev/null || true
    cmd_exec systemctl disable calibre-web-nextgen 2>/dev/null || true
    
    log_action "Removing systemd service..."
    cmd_exec rm -f /etc/systemd/system/calibre-web-nextgen.service
    cmd_exec systemctl daemon-reload
    
    log_action "Removing installation directory..."
    cmd_exec rm -rf "$INSTALL_DIR"
    
    log_action "Removing Calibre-Web user..."
    cmd_exec deluser --remove-home "$CALIBRE_USER" 2>/dev/null || true
    
    log_action "Cleaning up library ACLs..."
    cmd_exec setfacl -R -b "$CALIBRE_LIBRARY" 2>/dev/null || true
    
    log_success "Calibre-Web removed successfully"
    log_warn "Note: Your calibre library at $CALIBRE_LIBRARY is preserved"
    log_warn "Note: Calibre package (apt) is preserved - uninstall manually if desired"
}

uninstall_crosspoint() {
    section_header "Removing CrossPoint Sync"
    
    APP_DIR="/opt/crosspoint-sync"
    
    log_action "Stopping CrossPoint Sync service..."
    cmd_exec systemctl stop crosspoint-sync 2>/dev/null || true
    cmd_exec systemctl disable crosspoint-sync 2>/dev/null || true
    
    log_action "Removing systemd service..."
    cmd_exec rm -f /etc/systemd/system/crosspoint-sync.service
    cmd_exec systemctl daemon-reload
    
    log_action "Removing application directory..."
    cmd_exec rm -rf "$APP_DIR"
    
    log_action "Removing CrossPoint user..."
    cmd_exec deluser --remove-home "$CROSSPOINT_USER" 2>/dev/null || true
    
    log_action "Cleaning Node.js packages..."
    cmd_exec npm cache clean -f 2>/dev/null || true
    
    log_success "CrossPoint Sync removed successfully"
}

uninstall_navidrome() {
    section_header "Removing Navidrome"
    
    log_action "Stopping Navidrome service..."
    cmd_exec systemctl stop navidrome 2>/dev/null || true
    cmd_exec systemctl disable navidrome 2>/dev/null || true
    
    log_action "Removing Navidrome package..."
    cmd_exec apt-get remove -y navidrome
    
    log_action "Removing configuration..."
    cmd_exec rm -rf /etc/navidrome
    cmd_exec rm -rf /var/lib/navidrome
    
    log_action "Cleaning up Debian package..."
    cmd_exec dpkg -r navidrome 2>/dev/null || true
    
    log_success "Navidrome removed successfully"
    log_warn "Note: Your music library at $MUSIC_LIBRARY is preserved"
}

uninstall_web() {
    section_header "Removing Web Server (Apache + PHP)"
    
    log_action "Stopping Apache2..."
    cmd_exec systemctl stop apache2 2>/dev/null || true
    cmd_exec systemctl disable apache2 2>/dev/null || true
    
    log_action "Removing Apache2 and PHP packages..."
    cmd_exec apt-get remove --purge -y apache2 apache2-utils apache2-bin \
        php php-cli php-common libapache2-mod-php
    
    log_action "Removing Apache configuration..."
    cmd_exec rm -rf /etc/apache2
    cmd_exec rm -rf /var/www/html
    cmd_exec rm -rf /var/www/http
    
    log_action "Cleaning systemd..."
    cmd_exec systemctl daemon-reload
    
    log_success "Web server removed successfully"
    log_warn "Warning: This removes ALL web hosting capability including SearxNG"
}

uninstall_sharing() {
    section_header "Removing File Sharing Services"
    
    log_action "Stopping Samba..."
    cmd_exec systemctl stop smbd nmbd 2>/dev/null || true
    cmd_exec systemctl disable smbd nmbd 2>/dev/null || true
    
    log_action "Removing Samba..."
    cmd_exec apt-get remove --purge -y samba nemo nemo-share
    
    log_action "Removing Tailscale..."
    cmd_exec apt-get remove -y tailscale
    cmd_exec systemctl disable tailscaled 2>/dev/null || true
    cmd_exec systemctl stop tailscaled 2>/dev/null || true
    
    log_action "Cleaning Samba directories..."
    cmd_exec rm -rf /srv/samba
    
    log_action "Cleaning systemd..."
    cmd_exec systemctl daemon-reload
    
    log_success "File sharing services removed successfully"
}

uninstall_all() {
    section_header "FULL SYSTEM CLEANUP"
    
    log_warn "This will remove ALL services and configurations!"
    log_warn "Your personal library files will be preserved where configured"
    
    if ! confirm "Are you absolutely sure? This cannot be undone!"; then
        log_info "Uninstall cancelled"
        return 1
    fi
    
    log_action "Stopping all services..."
    cmd_exec systemctl stop calibre-web-nextgen crosspoint-sync navidrome uwsgi apache2 2>/dev/null || true
    
    log_action "Running individual uninstallers..."
    uninstall_navidrome
    uninstall_crosspoint
    uninstall_calibre
    uninstall_searxng
    uninstall_web
    uninstall_sharing
    
    log_action "Removing remaining users..."
    cmd_exec deluser --remove-home acw 2>/dev/null || true
    cmd_exec deluser --remove-home cps 2>/dev/null || true
    cmd_exec deluser --remove-home searxng 2>/dev/null || true
    
    log_action "Cleaning systemd..."
    cmd_exec systemctl daemon-reload
    
    log_action "Clearing apt cache..."
    cmd_exec apt-get autoremove -y
    cmd_exec apt-get autoclean
    
    log_success "============================================"
    log_success "SYSTEM COMPLETELY CLEANED!"
    log_success "============================================"
}

#-------------------------------------------------------------------------------
# MAIN EXECUTION WITH ARGUMENT PARSING
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --status)
                show_status
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--silent)
                VERBOSE=false
                shift
                ;;
            --install-all|--install-sharing|--install-web|--install-searxng|--install-calibre|--install-sync|--install-navidrome)
                INSTALL_MODE=true
                # Set specific flags
                case "$1" in
                    --install-all)
                        INSTALL_SHARING=true
                        INSTALL_WEB=true
                        INSTALL_SEARXNG=true
                        INSTALL_CALIBRE=true
                        INSTALL_CROSSPOINT=true
                        INSTALL_NAVIDROME=true
                        ;;
                    --install-sharing)
                        INSTALL_SHARING=true
                        ;;
                    --install-web)
                        INSTALL_WEB=true
                        ;;
                    --install-searxng)
                        INSTALL_SEARXNG=true
                        ;;
                    --install-calibre)
                        INSTALL_CALIBRE=true
                        ;;
                    --install-sync)
                        INSTALL_CROSSPOINT=true
                        ;;
                    --install-navidrome)
                        INSTALL_NAVIDROME=true
                        ;;
                esac
                shift
                ;;
            --reinstall)
                REINSTALL_MODE=true
                shift
                ;;
            --uninstall-all|--uninstall-sharing|--uninstall-web|--uninstall-searxng|--uninstall-calibre|--uninstall-sync|--uninstall-navidrome)
                UNINSTALL_MODE=true
                # Set specific flags
                case "$1" in
                    --uninstall-all)
                        UNINSTALL_ALL=true
                        ;;
                    --uninstall-sharing)
                        UNINSTALL_SHARING=true
                        ;;
                    --uninstall-web)
                        UNINSTALL_WEB=true
                        ;;
                    --uninstall-searxng)
                        UNINSTALL_SEARXNG=true
                        ;;
                    --uninstall-calibre)
                        UNINSTALL_CALIBRE=true
                        ;;
                    --uninstall-sync)
                        UNINSTALL_CROSSPOINT=true
                        ;;
                    --uninstall-navidrome)
                        UNINSTALL_NAVIDROME=true
                        ;;
                esac
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

execute_install() {
    log_info "Execution Mode: INSTALL"
    
    if [[ -z "${INSTALL_MODE+x}" && -z "${REINSTALL_MODE+x}" ]]; then
        # No specific flags, run full install
        INSTALL_SHARING=true
        INSTALL_WEB=true
        INSTALL_SEARXNG=true
        INSTALL_CALIBRE=true
        INSTALL_CROSSPOINT=true
        INSTALL_NAVIDROME=true
    fi
    
    step_system_prep
    
    if [[ "${INSTALL_SHARING}" == true ]]; then
        step_file_sharing
    fi
    
    if [[ "${INSTALL_WEB}" == true ]]; then
        step_web_server
    fi
    
    if [[ "${INSTALL_SEARXNG}" == true ]]; then
        step_searxng
    fi
    
    if [[ "${INSTALL_CALIBRE}" == true ]]; then
        step_calibre
    fi
    
    if [[ "${INSTALL_CROSSPOINT}" == true ]]; then
        step_crosspoint
    fi
    
    if [[ "${INSTALL_NAVIDROME}" == true ]]; then
        step_navidrome
    fi
    
    installation_summary
}

execute_uninstall() {
    log_info "Execution Mode: UNINSTALL"
    
    if [[ "${UNINSTALL_ALL}" == true ]]; then
        uninstall_all
        return
    fi
    
    if [[ "${UNINSTALL_SHARING}" == true ]]; then
        uninstall_sharing
    fi
    
    if [[ "${UNINSTALL_WEB}" == true ]]; then
        uninstall_web
    fi
    
    if [[ "${UNINSTALL_SEARXNG}" == true ]]; then
        uninstall_searxng
    fi
    
    if [[ "${UNINSTALL_CALIBRE}" == true ]]; then
        uninstall_calibre
    fi
    
    if [[ "${UNINSTALL_CROSSPOINT}" == true ]]; then
        uninstall_crosspoint
    fi
    
    if [[ "${UNINSTALL_NAVIDROME}" == true ]]; then
        uninstall_navidrome
    fi
    
    log_success "Selected services removed. Run 'sudo $0 --status' to verify."
}

main() {
    check_root
    parse_args "$@"
    
    # Determine operation mode
    if [[ -n "${UNINSTALL_MODE+x}" ]]; then
        execute_uninstall
    elif [[ -n "${INSTALL_MODE+x}" || -n "${REINSTALL_MODE+x}" || $# -eq 0 ]]; then
        execute_install
    else
        usage
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# INSTALLATION SUMMARY (for install mode)
#-------------------------------------------------------------------------------
installation_summary() {
    section_header "Installation Summary"
    
    echo ""
    cat << EOF
===============================================================================
                        INSTALLATION COMPLETE!
===============================================================================

Services Available:

┌─────────────────────┬──────────────────────────────────────┐
│ Service             │ URL                                │
├─────────────────────┼──────────────────────────────────────┤
│ Apache Web Server   │ http://$(hostname)/                │
│ SearxNG             │ http://$(hostname)/searxng          │
│ Calibre-Web         │ http://$(hostname):${CALIBRE_PORT}/ │
│ CrossPoint Sync     │ http://$(hostname):${CROSSPOINT_PORT}/ │
│ Navidrome           │ http://$(hostname):${NAVDROME_PORT}/│
└─────────────────────┴──────────────────────────────────────┘

Quick Reference Commands:

  ─ Service Management ─
  systemctl status apache2
  systemctl status calibre-web-nextgen
  systemctl status crosspoint-sync
  systemctl status navidrome
  
  ─ View Logs ─
  journalctl -u calibre-web-nextgen -f
  journalctl -u crosspoint-sync -f
  journalctl -u navidrome -f
  
  ─ Reinstall Any Service ─
  sudo $0 --install-[service-name]
  
  ─ Uninstall Any Service ─
  sudo $0 --uninstall-[service-name]
  
  ─ Full Cleanup ─
  sudo $0 --uninstall-all

Configuration Notes:

  • Library path: $CALIBRE_LIBRARY
  • Calibre installed: Yes (apt install calibre)
  • Calibre-Web initialized with README.md: Yes
  • Music path: $MUSIC_LIBRARY

Post-Installation Tasks:

  1. Configure Samba users: sudo smbpasswd -a <username>
  2. Activate Tailscale:    sudo tailscale up --ssh
  3. Change admin passwords on first login
  4. Configure your domain DNS to point to this server

===============================================================================
EOF
    echo ""
    log_success "Script completed successfully!"
}

# Execute
main "$@"
