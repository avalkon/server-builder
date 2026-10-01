#!/bin/bash
#===============================================================================
# Unified Server Setup Script with Selective Install/Uninstall & Verbose Mode
# Installs: Tailscale, Samba, Apache+PHP, SearxNG, Calibre-Web, CrossPoint Sync, Navidrome
# Version: 3.1
# Date: 2026-09-27
# Usage Examples:
#    sudo ./server-install.sh                    # Show help
#    sudo ./server-install.sh -v                 # Show help
#    sudo ./server-install.sh --install-all      # Full installation
#    sudo ./server-install.sh -v --install-all   # Full installation (verbose)
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION SECTION - EDIT THESE VALUES
#-------------------------------------------------------------------------------

# General
TIMEZONE="Etc/UTC"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(dpkg --print-architecture)"

# Web Addresses
YOURDOMAIN="yourdomain.com" #for local use, tailscale funnel, and Cloudflare Tunnels, this can be "localhost"
SUBDOMAIN=""   #like yoursubdomain.yourdomain.com(Only used if apache will not be serving at www.)
SITENAME="yoursitename"    #This determines apache's .conf and ensite. can be practically anything you want, EXCEPT "000-default"
YOUREMAIL="youremail@domain.com" #for apache config, not actually necessary, and certainly not sent anywhere.

# Library Paths
# This is where your calibre books/ebooks are/will be stored
CALIBRE_LIBRARY="/path/to/books/library"
# This is where auto ingest looks for books. Reccomend using the default.
INGEST_DIR="/srv/calibre-ingest"

# Music Path
MUSIC_LIBRARY="/path/to/music/library"

# Ports
APACHE_PORT=80
APACHE_SEC_PORT=443
CALIBRE_PORT=8083
CROSSPOINT_PORT=8085
NAVIDROME_PORT=4533
SSH_PORT=22

# Users
CALIBRE_USER="acw"
CALIBRE_GROUP="acw"
CROSSPOINT_USER="cps"
CROSSPOINT_GROUP="cps"

# Installation flags
INSTALL_MODE=false
VERBOSE=false
INSTALL_SHARING=false
INSTALL_WEB=false
INSTALL_SEARXNG=false
INSTALL_CALIBRE=false
INSTALL_CROSSPOINT=false
INSTALL_NAVIDROME=false

# Uninstall flags
UNINSTALL_MODE=false
REINSTALL_MODE=false
UNINSTALL_ALL=false
UNINSTALL_SHARING=false
UNINSTALL_WEB=false
UNINSTALL_SEARXNG=false
UNINSTALL_CALIBRE=false
UNINSTALL_CROSSPOINT=false
UNINSTALL_NAVIDROME=false

# Track installed services for health check
SERVICES_CHECKED=()
FAILED_SERVICES=()

OPERATION_MODE=""

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

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    CURRENT_USER="${SUDO_USER}"
else
    CURRENT_USER=""
fi

if (( BASH_VERSINFO[0] < 4 )); then
    echo "This script requires Bash 4 or newer." >&2
    exit 1
fi

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    read -p "$prompt [$default]: " response
    case "${response:-$default}" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

select_all_services() {
    INSTALL_SHARING=true
    INSTALL_WEB=true
    INSTALL_SEARXNG=true
    INSTALL_CALIBRE=true
    INSTALL_CROSSPOINT=true
    INSTALL_NAVIDROME=true
}

prompt_value() {
    local prompt="$1"
    local current="$2"
    local placeholder="${3:-}"
    local result
    while true; do
        read -r -p "${prompt} [${current}]: " result
        result="${result:-$current}"
        # Don't allow an unchanged placeholder
        if [[ -n "$placeholder" && "$result" == "$placeholder" ]]; then
            log_error "Please enter a value for ${prompt}."
            continue
        fi
        if [[ -z "$result" ]]; then
            log_error "${prompt} cannot be empty."
            continue
        fi
        printf '%s' "$result"
        return 0
    done
}

prompt_optional_value() {
    local prompt="$1"
    local current="$2"
    local result
    if [[ -n "$current" ]]; then
        read -r -p "${prompt} [${current}]: " result
        printf '%s' "${result:-$current}"
    else
        read -r -p "${prompt} [optional]: " result
        printf '%s' "$result"
    fi
}

prompt_path() {
    local prompt="$1"
    local current="$2"
    local placeholder="${3:-}"
    local result
    while true; do
        read -r -p "${prompt} [${current}]: " result
        result="${result:-$current}"
        # Don't allow an unchanged placeholder
        if [[ -n "$placeholder" && "$result" == "$placeholder" ]]; then
            log_error "Please enter a real path for ${prompt}."
            continue
        fi
        # Require absolute Linux paths
        if [[ "$result" != /* ]]; then
            log_error "Path must be absolute and begin with /"
            continue
        fi
        # Remove trailing slash except for /
        if [[ "$result" != "/" ]]; then
            result="${result%/}"
        fi
        printf '%s' "$result"
        return 0
    done
}

normalize_path() {
    local path="$1"
    # Expand leading ~ for the invoking user
    if [[ "$path" == "~/"* && -n "${CURRENT_USER:-}" ]]; then
        local user_home
        user_home="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
        path="${user_home}/${path#~/}"
    fi
    # Require absolute paths
    if [[ "$path" != /* ]]; then
        log_error "Path must be absolute: $path"
        return 1
    fi
    printf '%s\n' "${path%/}"
}

show_selected_config() {
    local needs_web=false
    if [[ "$INSTALL_WEB" == true || "$INSTALL_SEARXNG" == true ]]; then
        needs_web=true
    fi
    echo ""
    echo "Selected Configuration"
    echo "============================================================"

    if [[ "$needs_web" == true ]]; then
        printf "  %-22s %s\n" "Domain:" "$YOURDOMAIN"
        if [[ -n "$SUBDOMAIN" ]]; then
            printf "  %-22s %s\n" "Subdomain:" "$SUBDOMAIN"
        else
            printf "  %-22s %s\n" "Subdomain:" "(none)"
        fi
        printf "  %-22s %s\n" "Site name:" "$SITENAME"
    fi
    if [[ "$INSTALL_CALIBRE" == true ]]; then
        printf "  %-22s %s\n" "Calibre library:" "$CALIBRE_LIBRARY"
    fi
    if [[ "$INSTALL_NAVIDROME" == true ]]; then
        printf "  %-22s %s\n" "Music library:" "$MUSIC_LIBRARY"
    fi
    echo "============================================================"
    echo ""
}

prompt_config() {
    local needs_web=false
    section_header "Installation Configuration"
    #
    # Determine which configuration groups are required.
    #
    if [[ "$INSTALL_WEB" == true || "$INSTALL_SEARXNG" == true ]]; then
        needs_web=true
    fi
    #
    # Web configuration
    #
    if [[ "$needs_web" == true ]]; then
        echo "Web configuration"
        echo "-----------------"
        YOURDOMAIN="$(
            prompt_value \
                "Domain" \
                "$YOURDOMAIN" \
                "yourdomain.com"
        )"
        SUBDOMAIN="$(
            prompt_optional_value \
                "Subdomain" \
                "$SUBDOMAIN"
        )"
        SITENAME="$(
            prompt_value \
                "Site name" \
                "$SITENAME" \
                "yoursitename"
        )"
        echo ""
    fi
    #
    # Calibre configuration
    #
    if [[ "$INSTALL_CALIBRE" == true ]]; then
        echo "Calibre-Web configuration"
        echo "-------------------------"
        CALIBRE_LIBRARY="$(
            prompt_path \
                "Calibre library path" \
                "$CALIBRE_LIBRARY" \
                "/path/to/books/library"
        )"
        echo ""
    fi
    #
    # Navidrome configuration
    #
    if [[ "$INSTALL_NAVIDROME" == true ]]; then
        echo "Navidrome configuration"
        echo "-----------------------"
        MUSIC_LIBRARY="$(
            prompt_path \
                "Music library path" \
                "$MUSIC_LIBRARY" \
                "/path/to/music/library"
        )"
        echo ""
    fi
    show_selected_config
    if ! confirm "Continue with this configuration?" "y"; then
        log_warn "Installation cancelled."
        exit 0
    fi
}

validate_config() {
    local errors=0
    local needs_web=false
    if [[ "$INSTALL_WEB" == true || "$INSTALL_SEARXNG" == true ]]; then
        needs_web=true
    fi
    #
    # Web validation
    #
    if [[ "$needs_web" == true ]]; then
        if [[ -z "$YOURDOMAIN" || "$YOURDOMAIN" == "yourdomain.com" ]]; then
            log_error "A valid domain must be configured."
            errors=$((errors + 1))
        fi

        if [[ -z "$SITENAME" || "$SITENAME" == "yoursitename" ]]; then
            log_error "A site name must be configured."
            errors=$((errors + 1))
        fi
    fi
    #
    # Calibre validation
    #
    if [[ "$INSTALL_CALIBRE" == true ]]; then
        if [[ -z "$CALIBRE_LIBRARY" ||
              "$CALIBRE_LIBRARY" == "/path/to/books/library" ]]; then
            log_error "A Calibre library path must be configured."
            errors=$((errors + 1))
        elif [[ "$CALIBRE_LIBRARY" != /* ]]; then
            log_error "CALIBRE_LIBRARY must be an absolute path."
            errors=$((errors + 1))
        fi
    fi
    #
    # Navidrome validation
    #
    if [[ "$INSTALL_NAVIDROME" == true ]]; then
        if [[ -z "$MUSIC_LIBRARY" ||
              "$MUSIC_LIBRARY" == "/path/to/music/library" ]]; then
            log_error "A music library path must be configured."
            errors=$((errors + 1))
        elif [[ "$MUSIC_LIBRARY" != /* ]]; then
            log_error "MUSIC_LIBRARY must be an absolute path."
            errors=$((errors + 1))
        fi
    fi
    if (( errors > 0 )); then
        log_error "Configuration validation failed with ${errors} error(s)."
        return 1
    fi
    log_success "Configuration validated."
}

section_header() {
    echo ""
    echo "==============================================================================="
    log_info "$1"
    echo "==============================================================================="
    echo ""
}

cmd_exec() {
    if [[ "${VERBOSE}" == true ]]; then
        printf '%b➜%b ' "$CYAN" "$NC"
        printf '%q ' "$@"
        printf '\n'
    fi
    "$@"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install/Manage self-hosted server services

OPTIONS:
  Installation Modes:
    (no args)                    Show this help message
    --install-all                Run complete installation of all services
    --reinstall                  Reinstall/repair all managed services without deleting libraries

  Selective Installation:
    --install-sharing            Install file sharing (Samba, Tailscale, Nemo)
    --install-web                Install web server (Apache + PHP)
    --install-searxng            Install SearxNG search engine
    --install-calibre            Install Calibre-Web NextGen (includes Calibre)
    --install-sync               Install CrossPoint Sync only
    --install-navidrome          Install Navidrome music server only

  Uninstallation Modes:
    --uninstall-all              Remove all managed services and packages
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
  sudo $0                              # Show help
  sudo $0 -v                           # Show help
  sudo $0 --install-all                # Full installation
  sudo $0 -v --install-all             # Full installation (verbose)
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

status_http_service() {
    local display_name="$1"
    local unit="$2"
    local url="$3"
    local port="$4"
    local http_status

    if ! systemctl cat "$unit" >/dev/null 2>&1; then
        printf "%-20s %-15s %-10s %-8s %s\n" \
            "$display_name" "not-installed" "N/A" "$port" "$(date '+%H:%M:%S')"
        return
    fi

    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        http_status=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
            "$url" 2>/dev/null || printf '000')

        printf "%-20s %-15s %-10s %-8s %s\n" \
            "$display_name" "running" "HTTP ${http_status}" "$port" "$(date '+%H:%M:%S')"
    else
        printf "%-20s %-15s %-10s %-8s %s\n" \
            "$display_name" "stopped" "N/A" "$port" "$(date '+%H:%M:%S')"
    fi
}

show_status() {
    section_header "Service Status Report"

    echo ""
    printf "%-20s %-15s %-10s %-8s %s\n" \
        "SERVICE" "UNIT ACTIVE?" "HTTP STATUS" "PORT" "LAST CHECK"
    printf "%-20s %-15s %-10s %-8s %s\n" \
        "-------" "------------" "-----------" "----" "----------"

    status_http_service \
        "apache2" \
        "apache2" \
        "http://localhost:${APACHE_PORT}/" \
        "${APACHE_PORT}"

    status_http_service \
        "calibre-web" \
        "calibre-web-nextgen" \
        "http://localhost:${CALIBRE_PORT}/" \
        "${CALIBRE_PORT}"

    status_http_service \
        "crosspoint-sync" \
        "crosspoint-sync" \
        "http://localhost:${CROSSPOINT_PORT}/" \
        "${CROSSPOINT_PORT}"

    status_http_service \
        "navidrome" \
        "navidrome" \
        "http://localhost:${NAVIDROME_PORT}/" \
        "${NAVIDROME_PORT}"
    
    # Samba
    if command -v smbd >/dev/null 2>&1; then
        if systemctl is-active --quiet smbd 2>/dev/null; then
            if testparm -s >/dev/null 2>&1; then
                printf "%-20s %-15s %-10s %-8s %s\n" \
                    "samba" "running" "config-ok" "445" "$(date '+%H:%M:%S')"
            else
                printf "%-20s %-15s %-10s %-8s %s\n" \
                    "samba" "running" "config-error" "445" "$(date '+%H:%M:%S')"
            fi
        else
            printf "%-20s %-15s %-10s %-8s %s\n" \
                "samba" "stopped" "N/A" "445" "$(date '+%H:%M:%S')"
        fi
    else
        printf "%-20s %-15s %-10s %-8s %s\n" \
            "samba" "not-installed" "N/A" "445" "$(date '+%H:%M:%S')"
    fi

    # SearxNG (runs under uWSGI)
    SEARXNG_HTTP_STATUS=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
        "http://localhost:${APACHE_PORT}/searxng/" \
        2>/dev/null || printf '000')
    if service uwsgi status searxng 2>/dev/null | grep -q "active"; then
        printf "%-20s %-15s %-10s %-8s %s\n" \
            "searxng" "running" "HTTP ${SEARXNG_HTTP_STATUS}" \
            "${APACHE_PORT}" "$(date '+%H:%M:%S')"
    else
        printf "%-20s %-15s %-10s %-8s %s\n" \
            "searxng" "stopped" "N/A" \
            "${APACHE_PORT}" "$(date '+%H:%M:%S')"
    fi
    
    # Tailscale
    if command -v tailscale >/dev/null 2>&1; then
        TAIL_STATUS=$(tailscale status 2>/dev/null | head -1 | cut -c1-34 || printf "")
        printf "%-20s %-35s %s\n" \
            "tailscale" "$TAIL_STATUS" "$(date '+%H:%M:%S')"
    else
        printf "%-20s %-34s %s\n" \
            "tailscale" "not-installed" "$(date '+%H:%M:%S')"
    fi

    
    echo ""
    log_info "Run 'systemctl status <service>' for detailed service information."
}

add_service_check() {
    local SERVICE_NAME="$1"
    SERVICES_CHECKED+=("$SERVICE_NAME")
}

verify_service_status() {

    local SERVICE_NAME="$1"
    local DISPLAY_NAME="$2"
    
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        add_service_check "${SERVICE_NAME}"
        return 0
    else
        FAILED_SERVICES+=("${SERVICE_NAME}|${DISPLAY_NAME}")
        return 1
    fi
}

verify_searxng_status() {
    log_info "Checking SearxNG service status..."
    
    # SearxNG runs under uWSGI, not direct systemd
    if service uwsgi status searxng 2>/dev/null | grep -q "active"; then
        log_success "✓ SearxNG is running (via uWSGI)"
        add_service_check "searxng"
        return 0
    else
        FAILED_SERVICES+=("searxng|SearxNG")
        return 1
    fi
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
        openssl \
        ufw \
        acl

    log_info "Allowing SSH before enabling UFW..."
    cmd_exec ufw allow "${SSH_PORT}/tcp"

    log_info "Enabling ufw..."
    cmd_exec ufw --force enable
    
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
    
    if command -v tailscale >/dev/null 2>&1; then
        log_info "Tailscale already installed."
    else
        log_info "Installing Tailscale..."
        cmd_exec curl -fsSL https://tailscale.com/install.sh | sh
    fi
    log_info "Tailscale installed. Run 'sudo tailscale up --ssh' to activate."
    
    log_info "Installing Samba..."
    cmd_exec apt-get install -y samba
    
    log_info "Configuring Samba directory..."
    cmd_exec mkdir -p /srv/samba/shared
    if ! getent group users >/dev/null; then
        cmd_exec groupadd users
    fi
    if [[ -n "${CURRENT_USER}" ]]; then
        cmd_exec chown "${CURRENT_USER}":users /srv/samba/shared
        cmd_exec chmod 2770 /srv/samba/shared
    else
        cmd_exec chown root:users /srv/samba/shared
        cmd_exec chmod 2770 /srv/samba/shared
    fi

    log_info "Checking for existing [shared] section in smb.conf..."
    
    # Check if [shared] already exists
    if grep -qiE '^[[:space:]]*\[shared\][[:space:]]*$' /etc/samba/smb.conf 2>/dev/null; then
        log_warn "[shared] already exists in smb.conf"
    else
        # Backup existing config if it exists
        if [ -f /etc/samba/smb.conf ]; then
            log_info "Backing up existing smb.conf..."
            cmd_exec cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d%H%M%S)
        fi
        
        log_info "Adding [shared] section to smb.conf..."
    
    cat >> /etc/samba/smb.conf << SMBCONF
[shared]
    path = /srv/samba/shared
    browseable = yes
    read only = no
    guest ok = no
    valid users = @users
    force group = users
    create mask = 0660
    directory mask = 2770
SMBCONF
    fi

    if [[ -n "${CURRENT_USER}" ]]; then
        cmd_exec usermod -aG users "${CURRENT_USER}"
    else
        log_warn "No non-root invoking user detected; skipping users group assignment."
    fi
    
    log_info "Testing Samba configuration..."
    cmd_exec testparm -s
    
    log_info "Restarting Samba service..."
    cmd_exec systemctl restart smbd

    verify_service_status "smbd" "Samba (smbd)" || true
        # nmbd is optional - only warn if it's failed (not if just stopped)
    if ! systemctl is-active --quiet nmbd 2>/dev/null; then
        log_info "ℹ NetBIOS discovery (nmbd) not running - optional for LAN sharing"
    else
        log_info "✓ NetBIOS discovery (nmbd) enabled"
    fi
    
    log_warn "Post-installation: Add users to Samba with 'sudo smbpasswd -a <username>'"
    log_info "Access: smb://$(hostname)/shared or \\\\$(hostname)\\shared" 
}

step_web_server() {
    section_header "Web Server Setup (Apache + PHP)"
    
    log_info "Installing Apache2..."
    cmd_exec apt-get install -y apache2

    log_info "Opening firewall ports..."
    cmd_exec ufw allow "${APACHE_PORT}/tcp"     # HTTP
    cmd_exec ufw allow "${APACHE_SEC_PORT}/tcp"    # HTTPS
    
    log_info "Installing PHP..."
    cmd_exec apt-get install -y php libapache2-mod-php php-cli php-common

    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')

    if [[ -f "/etc/apache2/mods-available/php${PHP_VERSION}.load" ]]; then
        log_info "Enabling Apache PHP module: php${PHP_VERSION}"
        if ! cmd_exec a2enmod "php${PHP_VERSION}"; then
            log_warn "Could not enable Apache PHP module php${PHP_VERSION}; continuing."
            log_warn "PHP CLI remains installed. Apache PHP integration can be fixed manually later."
        fi
    else
        log_warn "Apache PHP module php${PHP_VERSION} was not found."
        log_warn "PHP CLI is installed, but Apache PHP integration may require manual configuration."
        log_warn "If PHP pages do not work, inspect:"
        log_warn "  ls /etc/apache2/mods-available/php*.load"
        log_warn "  apache2ctl -M | grep php"
    fi

    cmd_exec a2enmod ssl headers proxy proxy_http rewrite
    
    log_info "Creating document root..."
    cmd_exec mkdir -p /var/www/http

    if [[ -n "${CURRENT_USER}" ]]; then
        cmd_exec chown ${CURRENT_USER}:users /var/www/http
        cmd_exec chmod -R 775 /var/www/http
    else
        log_warn "No non-root invoking user detected; skipping users group assignment."
    fi
    
    log_info "Configuring VirtualHost..."

    local server_alias=""
    if [[ -n "$SUBDOMAIN" ]]; then
        server_alias="    ServerAlias ${SUBDOMAIN}.${YOURDOMAIN}"
    fi
    
    cat > /etc/apache2/sites-available/${SITENAME}.conf << VHOST
<VirtualHost *:${APACHE_PORT}>
    ServerAdmin ${YOUREMAIL}
    ServerName ${YOURDOMAIN}
${server_alias}
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
    
    cmd_exec a2ensite ${SITENAME}.conf
    cmd_exec a2dissite 000-default.conf
    
    log_info "Testing Apache configuration..."
    cmd_exec apache2ctl configtest
    
    log_info "Restarting Apache2..."
    cmd_exec systemctl restart apache2
    
    log_info "Apache2 Status:"
    cmd_exec systemctl status apache2 --no-pager | head -5

    verify_service_status "apache2" "Apache" || true
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
        [[ -f utils/searxng.sh.bak ]] || cmd_exec cp utils/searxng.sh utils/searxng.sh.bak
        [[ -f utils/lib.sh.bak ]] || cmd_exec cp utils/lib.sh utils/lib.sh.bak


    [[ -f utils/searxng.sh.bak ]] || \
        cmd_exec cp utils/searxng.sh utils/searxng.sh.bak

    [[ -f utils/lib.sh.bak ]] || \
        cmd_exec cp utils/lib.sh utils/lib.sh.bak

    #
    # searxng.sh
    #
    if grep -Fq 'linuxmint-*' utils/searxng.sh; then
        log_info "Linux Mint platform entry already present in utils/searxng.sh."
    elif grep -Fq 'ubuntu-* | debian-*' utils/searxng.sh; then
        cmd_exec sed -i \
            's/ubuntu-\* | debian-\*/ubuntu-* | debian-* | linuxmint-*/g' \
            utils/searxng.sh
    else
        log_error "Could not locate expected platform detection in utils/searxng.sh."
        grep -nE 'ubuntu|debian|DIST|OS' utils/searxng.sh || true
        return 1
    fi

    #
    # lib.sh: distro-version case
    #
    if grep -Fq 'linuxmint-*' utils/lib.sh; then
    log_info "Linux Mint version entry already present in utils/lib.sh."
    elif grep -Fq 'ubuntu-* | debian-*' utils/lib.sh; then
        cmd_exec sed -i \
            's/ubuntu-\* | debian-\*/ubuntu-* | debian-* | linuxmint-*/g' \
            utils/lib.sh
    else
        log_warn "Could not locate ubuntu/debian version pattern in utils/lib.sh."
    fi

    #
    # lib.sh: distro-name case
    #
    if grep -Eq 'ubuntu[[:space:]]*\|[[:space:]]*debian[[:space:]]*\|[[:space:]]*linuxmint' \
            utils/lib.sh; then
        log_info "Linux Mint distro entry already present in utils/lib.sh."
    elif grep -Eq 'ubuntu[[:space:]]*\|[[:space:]]*debian' utils/lib.sh; then
        cmd_exec sed -Ei \
            's/ubuntu[[:space:]]*\|[[:space:]]*debian/ubuntu | debian | linuxmint/g' \
            utils/lib.sh
    else
        log_warn "Could not locate ubuntu/debian distro pattern in utils/lib.sh."
    fi

    #
    # Verify the patch actually happened.
    #
    if ! grep -q 'linuxmint' utils/searxng.sh; then
        log_error "Linux Mint patch failed for utils/searxng.sh."
        return 1
    fi

    if ! grep -q 'linuxmint' utils/lib.sh; then
        log_error "Linux Mint patch failed for utils/lib.sh."
        return 1
    fi

log_success "Linux Mint platform compatibility applied."
    log_info "Creating SearxNG system user..."
    cmd_exec useradd --shell /bin/bash --system --home-dir "/usr/local/searxng" \
        --comment 'Privacy-respecting metasearch engine' searxng 2>/dev/null || true
    
    log_info "Setting up directories..."
    cmd_exec mkdir -p "/usr/local/searxng"
    cmd_exec chown -R searxng:searxng "/usr/local/searxng"
    cmd_exec chown -R searxng /opt/searxng
    cmd_exec chmod 777 -r "/usr/local/searxng"
    cmd_exec git config --global --add safe.directory /opt/searxng
    
    log_info "Installing SearxNG components..."
    cmd_exec utils/searxng.sh install all
    cmd_exec chmod 777 -r "/usr/local/searxng"
    cmd_exec utils/searxng.sh install uwsgi
    cmd_exec chmod 777 -r "/usr/local/searxng"
    cmd_exec utils/searxng.sh install apache
    cmd_exec chmod 755 -r "/usr/local/searxng"
    cmd_exec a2enmod proxy_uwsgi
    
    log_info "Enabling SearxNG site..."
    cmd_exec a2ensite searxng.conf 2>/dev/null || true
    
    log_info "Restarting Apache and uWSGI..."
    cmd_exec systemctl restart apache2
    cmd_exec systemctl restart uwsgi
    
    verify_searxng_status || true
}

step_calibre() {
    section_header "Calibre-Web NextGen Installation"
    
    INSTALL_DIR="/opt/calibre-web-nextgen"
    CONFIG_DIR="${INSTALL_DIR}/config"
    
    log_info "Verifying library path configuration..."
    
    log_info "Creating library path: $CALIBRE_LIBRARY"
    cmd_exec mkdir -p "$CALIBRE_LIBRARY"
    cmd_exec chmod 775 "$CALIBRE_LIBRARY"
    

    
    log_info "Installing Calibre-Web dependencies..."
    cmd_exec apt-get install -y \
        python3-dev \
        sqlite3 \
        zip \
        xz-utils \
        xdg-utils \
        ca-certificates \
        libegl1 \
        libopengl0

    log_info "Installing Calibre (required by Calibre-Web NextGen)..."
    # Remove distro Calibre if it was installed previously
    if dpkg-query -W -f='${Status}' calibre 2>/dev/null | grep -q "install ok installed"; then
        sudo apt-get remove -y calibre
    fi

    # Install/upgrade current official Calibre binary release
    wget -nv -O /tmp/calibre-linux-installer.sh \
        https://download.calibre-ebook.com/linux-installer.sh

    sh /tmp/calibre-linux-installer.sh install_dir=/opt

    rm -f /tmp/calibre-linux-installer.sh

    log_info "Opening firewall port..."
    cmd_exec ufw allow "${CALIBRE_PORT}/tcp"   # Calibre-Web
    
    log_info "Creating installation directory..."
    cmd_exec mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    log_info "Cloning repository..."
    if [[ -d .git ]]; then
        log_info "Repository already exists, skipping clone."
    else
        cmd_exec git clone https://github.com/avalkon/Calibre-Web-NextGen--no-docker.git .
    fi
    
    log_info "Creating service user '$CALIBRE_USER'..."
    if ! getent group "$CALIBRE_GROUP" >/dev/null; then
        cmd_exec groupadd --system "$CALIBRE_GROUP"
    fi

    if ! id "$CALIBRE_USER" &>/dev/null; then
        cmd_exec useradd \
            --system \
            --gid "$CALIBRE_GROUP" \
            --shell /usr/sbin/nologin \
            --home-dir "$INSTALL_DIR" \
            "$CALIBRE_USER"
    fi

    if [[ -n "${CURRENT_USER}" ]]; then
        cmd_exec usermod -a -G "$CALIBRE_GROUP" "$CURRENT_USER" 2>/dev/null || true
    else
        log_warn "No non-root invoking user detected; skipping users group assignment."
    fi
    
    log_info "Setting up Python virtual environment..."
    python3 -m venv venv
    "$INSTALL_DIR/venv/bin/python3" -m pip install --upgrade pip setuptools wheel
    "$INSTALL_DIR/venv/bin/python3" -m pip install -e .
    
    log_info "Creating config and ingest directories..."
    cmd_exec mkdir -p "$CONFIG_DIR"
    cmd_exec chmod 775 "$CONFIG_DIR"
    cmd_exec mkdir -p "$INGEST_DIR"
    cmd_exec mkdir -p "${INGEST_DIR}/processed"
    cmd_exec mkdir -p "${INGEST_DIR}/failed"
    cmd_exec mkdir -p "${INGEST_DIR}/config"
    cmd_exec chmod 775 -R "$INGEST_DIR"

    cat > ${INSTALL_DIR}/dirs.json << EOF
{
    "ingest_folder": "${INGEST_DIR}",
    "calibre_library_dir": "${CALIBRE_LIBRARY}",
    "tmp_conversion_dir": "${INGEST_DIR}/config/.cwa_conversion_tmp",
    "processed_folder": "${INGEST_DIR}/processed",
    "failed_folder": "${INGEST_DIR}/failed",
    "retry_queue_file": "${INGEST_DIR}/config/retry_queue.json",
    "max_retry_attempts": 3,
    "retry_interval_seconds": 300,
    "checkpoint_file": "${INSTALL_DIR}/.meta_checkpoint",
    "status_file": "${CONFIG_DIR}/cwa_ingest_status",
    "meta_status_file": "${CONFIG_DIR}/cwa_meta_status"
}
EOF
    
    log_info "Creating systemd services..."
    cat > /etc/systemd/system/calibre-web-nextgen.service << SERVICE
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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    cat > /etc/systemd/system/calibre-web-ingest.service << SERVICE
[Unit]
Description=Calibre-Web NextGen Ingest Service
After=calibre-web-nextgen.service
Requires=calibre-web-nextgen.service

[Service]
Type=simple
User=${CALIBRE_USER}
Group=${CALIBRE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${INSTALL_DIR}/venv/bin:${INSTALL_DIR}:/usr/local/bin:/usr/bin:/bin"

ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/cps/auto-ingest.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    cat > /etc/systemd/system/calibre-web-meta.service << SERVICE
[Unit]
Description=Calibre-Web NextGen Metadata Change Detector
After=calibre-web-nextgen.service
Requires=calibre-web-nextgen.service

[Service]
Type=simple
User=${CALIBRE_USER}
Group=${CALIBRE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${INSTALL_DIR}/venv/bin:${INSTALL_DIR}:/usr/local/bin:/usr/bin:/bin"
Environment="CWA_APP_DB_PATH=${INSTALL_DIR}/config/app.db"
Environment="CWA_METADATA_CHANGE_LOGS_DIR=${INSTALL_DIR}/config/metadata_change_logs"
Environment="CWA_METADATA_TEMP_DIR=${INSTALL_DIR}/config/metadata_temp"
ExecStart=/bin/bash ${INSTALL_DIR}/scripts/metadata-detector.sh
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    log_info "Setting permissions..."
    cmd_exec chown -R "${CALIBRE_USER}:${CALIBRE_GROUP}" "$INSTALL_DIR"
    cmd_exec chmod -R u=rwX,g=rX,o=rX "$INSTALL_DIR"
    cmd_exec chmod 775 "$CONFIG_DIR"
    cmd_exec setfacl -R -m u:${CALIBRE_USER}:rwX "$CALIBRE_LIBRARY" 2>/dev/null || \
    log_warn "ACL command failed, manually run: sudo setfacl -R -m u:${CALIBRE_USER}:rwX '${CALIBRE_LIBRARY}'"
    
    log_info "Initializing Calibre database with README.md..."

    cat > "$SCRIPT_DIR/book.txt" << EOF
This is totally a book I'd read!
EOF

    cmd_exec calibredb add "$SCRIPT_DIR/book.txt" --with-library "$CALIBRE_LIBRARY"
    
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
    cmd_exec systemctl enable calibre-web-ingest
    cmd_exec systemctl enable calibre-web-meta
    cmd_exec systemctl start calibre-web-nextgen
    cmd_exec systemctl start calibre-web-ingest
    cmd_exec systemctl start calibre-web-meta
    
    verify_service_status "calibre-web-nextgen" "Calibre-Web NextGen" || true
    verify_service_status "calibre-web-ingest" "Calibre-Web Ingest" || true
    verify_service_status "calibre-web-meta" "Calibre-Web Meta" || true
    
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
    cmd_exec ufw allow "${CROSSPOINT_PORT}/tcp"   # CrossPoint
    
    log_info "Creating application directory..."
    cmd_exec mkdir -p "$APP_DIR"
    cd "$APP_DIR"

    log_info "Cloning repository..."
    if [[ -d .git ]]; then
        log_info "Repository already exists, skipping clone."
    else
        cmd_exec git clone https://github.com/crosspoint-reader/crosspoint-sync.git .
    fi
    
    log_info "Creating service user..."
    if ! getent group "$CROSSPOINT_GROUP" >/dev/null; then
        cmd_exec groupadd --system "$CROSSPOINT_GROUP"
    fi

    if ! id "$CROSSPOINT_USER" &>/dev/null; then
        cmd_exec useradd \
            --system \
            --gid "$CROSSPOINT_GROUP" \
            --shell /usr/sbin/nologin \
            --home-dir "$APP_DIR" \
            "$CROSSPOINT_USER"
    fi
    
    cmd_exec chown -R "$CROSSPOINT_USER:$CROSSPOINT_GROUP" "$APP_DIR"
    
    log_info "Installing npm dependencies..."
    cmd_exec npm install
    cmd_exec npm run build
    
    log_info "Generating encryption token..."
    if [[ -f "$APP_DIR/token.key" ]]; then
        log_info "Existing encryption token found; preserving it."
        TOKEN_KEY="$(<"$APP_DIR/token.key")"
    else
        log_info "Generating new encryption token..."
        TOKEN_KEY="$(openssl rand -hex 32)"
        printf '%s\n' "$TOKEN_KEY" > "$APP_DIR/token.key"

        cmd_exec chown "$CROSSPOINT_USER:$CROSSPOINT_GROUP" "$APP_DIR/token.key"
        cmd_exec chmod 600 "$APP_DIR/token.key"
    fi

    log_info "Creating environment file..."
    if [[ ! -f "$APP_DIR/env" ]]; then
            # Proxy configuration prompt
        log_info "Change TRUST_PROXY to true if using proxy, such as CF Tunnel"
        echo ""
        if confirm "Is CrossPoint-sync running behind a reverse proxy? (e.g., Cloudflare Tunnel, nginx)" "n"; then
            TRUST_PROXY_VALUE="true"
        else
            TRUST_PROXY_VALUE="false"
            log_info "Will set TRUST_PROXY=false (direct access mode)"
        fi
            log_info "Creating CrossPoint environment file..."

        cat > "$APP_DIR/env" << ENVFILE
PORT=${CROSSPOINT_PORT}
DATABASE_PATH=$APP_DIR/crosspoint.db
REGISTRATION_DISABLED=false
AUTH_RATE_LIMIT_PER_MINUTE=30
TOKEN_ENC_KEY=${TOKEN_KEY}
TRUST_PROXY=${TRUST_PROXY_VALUE}
CORS_ORIGINS=
LOG_LEVEL=info
ENVFILE

        cmd_exec chmod 600 "$APP_DIR/env"
    else
        log_info "Existing CrossPoint environment file found; preserving it."
    fi

    log_info "Env file created. To change TRUST_PROXY:"
    log_info "  Edit: $APP_DIR/env"
    log_info "  Then: sudo systemctl restart crosspoint-sync"
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/crosspoint-sync.service << SERVICE
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
    
    verify_service_status "crosspoint-sync" "CrossPoint Sync" || true
}

step_navidrome() {
    section_header "Navidrome Music Server"
    
    NAVIDROME_VERSION="0.63.2"
    DEB_URL="https://github.com/navidrome/navidrome/releases/download/v${NAVIDROME_VERSION}/navidrome_${NAVIDROME_VERSION}_linux_${ARCH}.deb"
    
    log_info "Downloading Navidrome..."
    cmd_exec mkdir -p /tmp/navidrome
    cd /tmp/navidrome
    cmd_exec wget -q "$DEB_URL"

    log_info "Opening firewall port..."
    cmd_exec ufw allow "${NAVIDROME_PORT}/tcp"   # Navidrome
    
    log_info "Installing Navidrome..."
    cmd_exec apt-get install -y ./navidrome_${NAVIDROME_VERSION}_linux_${ARCH}.deb
    cmd_exec rm -f "./navidrome_${NAVIDROME_VERSION}_linux_${ARCH}.deb"
    
    log_info "Creating music library directory..."
    cmd_exec mkdir -p "$MUSIC_LIBRARY"
    cmd_exec chmod 755 "$MUSIC_LIBRARY"
    
    log_info "Configuring Navidrome..."
    cmd_exec mkdir -p /etc/navidrome
    if [[ -f /etc/navidrome/navidrome.toml ]]; then
        log_info "Existing Navidrome configuration found; preserving it."
    else
        cat > /etc/navidrome/navidrome.toml << CONFIG
MusicFolder = "${MUSIC_LIBRARY}"
Port = ${NAVIDROME_PORT}
DataDir = "/var/lib/navidrome"
LogLevel = "info"
CONFIG
    fi
    
    log_info "Enabling and starting service..."
    cmd_exec systemctl enable navidrome
    cmd_exec systemctl start navidrome
    
    verify_service_status "navidrome" "Navidrome" || true
}

#-------------------------------------------------------------------------------
# UNINSTALL FUNCTIONS
#-------------------------------------------------------------------------------

apt_remove_if_installed() {
    local packages=()

    for package in "$@"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
            | grep -q "install ok installed"; then
            packages+=("$package")
        fi
    done

    if [[ ${#packages[@]} -gt 0 ]]; then
        cmd_exec apt-get remove --purge -y "${packages[@]}"
    fi
}

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
    
    log_action "Stopping Calibre-Web services..."
    cmd_exec systemctl stop calibre-web-ingest 2>/dev/null || true
    cmd_exec systemctl stop calibre-web-meta 2>/dev/null || true
    cmd_exec systemctl stop calibre-web-nextgen 2>/dev/null || true
    cmd_exec systemctl disable calibre-web-ingest 2>/dev/null || true
    cmd_exec systemctl disable calibre-web-meta 2>/dev/null || true
    cmd_exec systemctl disable calibre-web-nextgen 2>/dev/null || true
    
    log_action "Removing systemd services..."
    cmd_exec rm -f /etc/systemd/system/calibre-web-ingest.service
    cmd_exec rm -f /etc/systemd/system/calibre-web-meta.service
    cmd_exec rm -f /etc/systemd/system/calibre-web-nextgen.service
    cmd_exec systemctl daemon-reload
    
    log_action "Removing installation directory..."
    cmd_exec rm -rf "$INSTALL_DIR"
    
    log_action "Removing Calibre-Web user..."
    cmd_exec deluser --remove-home "$CALIBRE_USER" 2>/dev/null || true
    
    log_action "Cleaning up library ACLs..."
    cmd_exec setfacl -R -b "$CALIBRE_LIBRARY" 2>/dev/null || true

    cmd_exec ufw delete allow ${CALIBRE_PORT}/tcp
    
    log_success "Calibre-Web removed successfully"
    log_warn "Note: Your calibre library at $CALIBRE_LIBRARY is preserved"
    log_warn "Note: Your ingest folder is preserved at $INGEST_DIR"
    log_warn "Note: Calibre package is preserved - uninstall manually if desired"
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

    cmd_exec ufw delete allow ${CROSSPOINT_PORT}/tcp
    
    log_success "CrossPoint Sync removed successfully"
}

uninstall_navidrome() {
    section_header "Removing Navidrome"
    
    log_action "Stopping Navidrome service..."
    cmd_exec systemctl stop navidrome 2>/dev/null || true
    cmd_exec systemctl disable navidrome 2>/dev/null || true
    
    log_action "Removing Navidrome package..."
    apt_remove_if_installed navidrome
    
    log_action "Removing configuration..."
    cmd_exec rm -rf /etc/navidrome

    cmd_exec ufw delete allow ${NAVIDROME_PORT}/tcp
    
    log_success "Navidrome removed successfully"
    log_warn "Navidrome music library preserved: $MUSIC_LIBRARY"
    log_warn "Navidrome application data preserved: /var/lib/navidrome"
    log_warn "To completely remove Navidrome data:"
    log_warn "  rm -rf /var/lib/navidrome"
}

uninstall_web() {
    section_header "Removing Web Server (Apache + PHP)"
    
    log_action "Stopping Apache2..."
    cmd_exec systemctl stop apache2 2>/dev/null || true
    cmd_exec systemctl disable apache2 2>/dev/null || true
    
    log_action "Removing Apache2 and PHP packages..."
    apt_remove_if_installed apache2 apache2-utils apache2-bin \
        php php-cli php-common libapache2-mod-php
    
    log_action "Removing Apache configuration..."
    cmd_exec rm -rf /etc/apache2/sites-available/$SITENAME.conf
    
    log_action "Cleaning systemd..."
    cmd_exec systemctl daemon-reload

    cmd_exec ufw delete allow ${APACHE_PORT}/tcp
    cmd_exec ufw delete allow ${APACHE_SEC_PORT}/tcp
    
    log_success "Web server removed successfully"
    log_warn "Warning: This removes ALL web hosting capability including SearxNG"
}

uninstall_sharing() {
    section_header "Removing File Sharing Services"
    
    log_action "Stopping Samba..."
    cmd_exec systemctl stop smbd nmbd 2>/dev/null || true
    cmd_exec systemctl disable smbd nmbd 2>/dev/null || true
    
    log_action "Removing Samba..."
    apt_remove_if_installed samba nemo nemo-share
    cmd_exec ufw delete allow 445/tcp 2>/dev/null || true
    
    log_action "Removing Tailscale..."
    apt_remove_if_installed tailscale
    cmd_exec systemctl disable tailscaled 2>/dev/null || true
    cmd_exec systemctl stop tailscaled 2>/dev/null || true
    
    log_action "Cleaning systemd..."
    cmd_exec systemctl daemon-reload
    
    log_success "File sharing services removed successfully"
    log_warn "Existing Samba configuration backups were preserved."
    log_warn "Samba data preserved at /srv/samba/shared"
}

uninstall_all() {
    section_header "FULL SYSTEM CLEANUP"
    
    log_warn "The following will be removed:"
    log_warn "  - Apache/PHP"
    log_warn "  - Samba/Tailscale"
    log_warn "  - SearxNG"
    log_warn "  - Calibre-Web application"
    log_warn "  - CrossPoint Sync application"
    log_warn "  - Navidrome application"
    log_warn "  - Managed system users/configuration"
    log_warn ""
    log_warn "The following will be preserved:"
    log_warn "  - $CALIBRE_LIBRARY"
    log_warn "  - $MUSIC_LIBRARY"
    log_warn "  - /srv/samba/shared"
    
    if ! confirm "Are you absolutely sure? This cannot be undone!"; then
        log_info "Uninstall cancelled"
        return 1
    fi
    
    log_action "Stopping all services..."
    cmd_exec systemctl stop calibre-web-nextgen calibre-web-ingest calibre-web-meta crosspoint-sync navidrome uwsgi apache2 2>/dev/null || true
    
    log_action "Running individual uninstallers..."
    uninstall_navidrome
    uninstall_crosspoint
    uninstall_calibre
    uninstall_searxng
    uninstall_web
    uninstall_sharing
        
    log_action "Cleaning systemd..."
    cmd_exec systemctl daemon-reload
    
    log_action "Clearing apt cache..."
    log_action "Skipping automatic package cleanup."
    log_info "No apt autoremove will be performed because dependencies may be used by other software."
    
    log_success "============================================"
    log_success "UNINSTALL COMPLETE!"
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
                if [[ -n "$OPERATION_MODE" && "$OPERATION_MODE" != "install" ]]; then
                    log_error "Cannot combine install and uninstall options."
                    exit 1
                fi

                OPERATION_MODE="install"
                INSTALL_MODE=true
                # Set specific flags
                case "$1" in
                    --install-all)
                        select_all_services
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
                if [[ -n "$OPERATION_MODE" ]]; then
                    log_error "Cannot combine --reinstall with install or uninstall options."
                    exit 1
                fi
                OPERATION_MODE="reinstall"
                REINSTALL_MODE=true
                shift
                ;;
            --uninstall-all|--uninstall-sharing|--uninstall-web|--uninstall-searxng|--uninstall-calibre|--uninstall-sync|--uninstall-navidrome)
                if [[ -n "$OPERATION_MODE" && "$OPERATION_MODE" != "uninstall" ]]; then
                    log_error "Cannot combine install and uninstall options."
                    exit 1
                fi
                OPERATION_MODE="uninstall"
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

reinstall_all() {
    SERVICES_CHECKED=()
    FAILED_SERVICES=()

    section_header "FULL REINSTALL / REPAIR"

    log_warn "Reinstall mode will repair/reconfigure all services managed by this script."
    log_warn "It will NOT run the uninstall functions."
    log_warn "It will NOT remove system packages."
    log_warn "Library data and application data will be preserved."
    log_warn "Existing application configuration will be preserved where supported."

    if ! confirm "Continue with full reinstall?" "n"; then
        log_info "Reinstall cancelled"
        return 1
    fi

    log_action "Stopping managed services..."

    cmd_exec systemctl stop \
        calibre-web-nextgen \
        crosspoint-sync \
        navidrome \
        apache2 \
        uwsgi \
        smbd \
        2>/dev/null || true

    # Reinstall/repair in the same dependency order as a full installation.
    INSTALL_SHARING=true
    INSTALL_WEB=true
    INSTALL_SEARXNG=true
    INSTALL_CALIBRE=true
    INSTALL_CROSSPOINT=true
    INSTALL_NAVIDROME=true

    step_system_prep
    step_file_sharing
    step_web_server
    step_searxng
    step_calibre
    step_crosspoint
    step_navidrome

    log_info "=== Reinstall Health Report ==="

    if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
        log_warn "⚠ ${#FAILED_SERVICES[@]} service check(s) failed:"
        for entry in "${FAILED_SERVICES[@]}"; do
            IFS='|' read -r svc display <<< "$entry"
            log_error "   ✗ ${display} (${svc})"
            echo "     journalctl -u ${svc} -n 50 --no-pager"
        done
        return 1
    fi

    log_success "✓ Reinstall completed successfully."
}

execute_install() {
    SERVICES_CHECKED=()
    FAILED_SERVICES=()
    log_info "Execution Mode: INSTALL"
    
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

        # Aggregate service health report
    # Show results for only checked services
    log_info "=== Service Health Report ==="
    if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
        log_warn "⚠ ${#FAILED_SERVICES[@]} service check(s) failed:"
        for entry in "${FAILED_SERVICES[@]}"; do
            IFS='|' read -r svc display <<< "$entry"
            log_error "   ✗ ${display} (${svc})"
            echo "     journalctl -u ${svc} -n 50 --no-pager"
        done
        log_warn "Installation completed with service errors."
        echo ""
        installation_summary
        return 1
    fi
    log_success "✓ ${#SERVICES_CHECKED[@]} checked services are running"
    echo ""

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
    #
    # An explicit operation is required.
    #
    if [[ -z "${OPERATION_MODE:-}" ]]; then
        usage
        exit 0
    fi
    case "$OPERATION_MODE" in
        install)
            prompt_config
            validate_config
            execute_install
            ;;
        reinstall)
            select_all_services
            prompt_config
            validate_config
            log_warn "Reinstall mode will attempt to repair all services."

            if ! confirm "Continue with full reinstall?" "n"; then
                log_info "Reinstall cancelled."
                exit 0
            fi
            reinstall_all
            ;;
        uninstall)
            execute_uninstall
            ;;
        *)
            log_error "Invalid operation mode: $OPERATION_MODE"
            usage
            exit 1
            ;;
    esac
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
│ Navidrome           │ http://$(hostname):${NAVIDROME_PORT}/│
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
  --install-sharing
  --install-web
  --install-searxng
  --install-calibre
  --install-sync
  --install-navidrome
  
  ─ Uninstall Any Service ─
  sudo $0 --uninstall-[service-name]
  --uninstall-sharing
  --uninstall-web
  --uninstall-searxng
  --uninstall-calibre
  --uninstall-sync
  --uninstall-navidrome
  
  ─ Full Cleanup ─
  sudo $0 --uninstall-all

Configuration Notes:

  • Library path: $CALIBRE_LIBRARY
  • Calibre installed: Yes (apt install calibre)
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
