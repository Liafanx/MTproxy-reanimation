#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MTproxy-reanimation v1.0.0
#  Telemt inbound SYN limiter + tuning manager
#  https://github.com/Liafanx/MTproxy-reanimation
# ═══════════════════════════════════════════════════════════════
set -eo pipefail

VERSION="1.0.0"
INSTALL_DIR="/opt/mtproxy-reanimation"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
NFT_SCRIPT="/usr/local/sbin/mtpr-syn-limit.sh"
SYSTEMD_UNIT="mtpr-syn-limit.service"

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Default settings ─────────────────────────────────────────
DETECTED_MODE=""          # mtproxymax / docker / local / unknown
DETECTED_CONTAINER=""     # container name if docker
DETECTED_CONFIG_PATH=""   # path to config.toml
DETECTED_IP=""
DETECTED_PORT=""
DETECTED_NETWORK_MODE=""  # host / bridge

# User settings (saved to settings.conf)
SERVER_IP=""
SERVER_PORT=""
NFT_RATE="1/second"
NFT_BURST="1"
NFT_METER_TIMEOUT="60s"
NFT_TABLE="telemt_limit"
NFT_HOOK="input"
TUNING_TG_CONNECT="10"
TUNING_CLIENT_HANDSHAKE="15"
TUNING_CLIENT_KEEPALIVE="60"
TUNING_APPLIED="false"
NFT_SERVICE_ENABLED="false"

# Additional rules: RULE_<N>_PORT, RULE_<N>_IP, RULE_<N>_RATE, etc.
declare -A EXTRA_RULES_PORT
declare -A EXTRA_RULES_IP
declare -A EXTRA_RULES_RATE
declare -A EXTRA_RULES_BURST
EXTRA_RULES_COUNT=0

# ── Logging ───────────────────────────────────────────────────
log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} $1" >&2; }
log_error()   { echo -e "  ${RED}[✗]${NC} $1" >&2; }

# ── Root check ────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Must be run as root"
        exit 1
    fi
}

# ── Save / Load settings ─────────────────────────────────────
save_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$SETTINGS_FILE" << EOF
# MTproxy-reanimation settings — v${VERSION}
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
SERVER_IP='${SERVER_IP}'
SERVER_PORT='${SERVER_PORT}'
NFT_RATE='${NFT_RATE}'
NFT_BURST='${NFT_BURST}'
NFT_METER_TIMEOUT='${NFT_METER_TIMEOUT}'
NFT_TABLE='${NFT_TABLE}'
NFT_HOOK='${NFT_HOOK}'
TUNING_TG_CONNECT='${TUNING_TG_CONNECT}'
TUNING_CLIENT_HANDSHAKE='${TUNING_CLIENT_HANDSHAKE}'
TUNING_CLIENT_KEEPALIVE='${TUNING_CLIENT_KEEPALIVE}'
TUNING_APPLIED='${TUNING_APPLIED}'
NFT_SERVICE_ENABLED='${NFT_SERVICE_ENABLED}'
EXTRA_RULES_COUNT='${EXTRA_RULES_COUNT}'
EOF
    local i
    for i in $(seq 1 "$EXTRA_RULES_COUNT"); do
        cat >> "$SETTINGS_FILE" << EOF
EXTRA_RULES_${i}_PORT='${EXTRA_RULES_PORT[$i]:-}'
EXTRA_RULES_${i}_IP='${EXTRA_RULES_IP[$i]:-}'
EXTRA_RULES_${i}_RATE='${EXTRA_RULES_RATE[$i]:-1/second}'
EXTRA_RULES_${i}_BURST='${EXTRA_RULES_BURST[$i]:-1}'
EOF
    done
    chmod 600 "$SETTINGS_FILE"
}

load_settings() {
    [ -f "$SETTINGS_FILE" ] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            case "$key" in
                SERVER_IP|SERVER_PORT|NFT_RATE|NFT_BURST|NFT_METER_TIMEOUT|\
                NFT_TABLE|NFT_HOOK|TUNING_TG_CONNECT|TUNING_CLIENT_HANDSHAKE|\
                TUNING_CLIENT_KEEPALIVE|TUNING_APPLIED|NFT_SERVICE_ENABLED|\
                EXTRA_RULES_COUNT)
                    printf -v "$key" '%s' "$val"
                    ;;
                EXTRA_RULES_*_PORT)
                    local idx="${key#EXTRA_RULES_}"; idx="${idx%_PORT}"
                    EXTRA_RULES_PORT[$idx]="$val"
                    ;;
                EXTRA_RULES_*_IP)
                    local idx="${key#EXTRA_RULES_}"; idx="${idx%_IP}"
                    EXTRA_RULES_IP[$idx]="$val"
                    ;;
                EXTRA_RULES_*_RATE)
                    local idx="${key#EXTRA_RULES_}"; idx="${idx%_RATE}"
                    EXTRA_RULES_RATE[$idx]="$val"
                    ;;
                EXTRA_RULES_*_BURST)
                    local idx="${key#EXTRA_RULES_}"; idx="${idx%_BURST}"
                    EXTRA_RULES_BURST[$idx]="$val"
                    ;;
            esac
        fi
    done < "$SETTINGS_FILE"
    [[ "$EXTRA_RULES_COUNT" =~ ^[0-9]+$ ]] || EXTRA_RULES_COUNT=0
}

# ── Detection ─────────────────────────────────────────────────

detect_telemt() {
    DETECTED_MODE="unknown"
    DETECTED_CONTAINER=""
    DETECTED_CONFIG_PATH=""
    DETECTED_IP=""
    DETECTED_PORT=""
    DETECTED_NETWORK_MODE=""

    # 1. Check MTProxyMax
    if [ -f /opt/mtproxymax/settings.conf ] && command -v mtproxymax &>/dev/null; then
        DETECTED_MODE="mtproxymax"
        DETECTED_CONFIG_PATH="/opt/mtproxymax/mtproxy/config.toml"
        # Extract port from MTProxyMax settings
        local _port
        _port=$(awk -F"'" '/^PROXY_PORT=/{print $2; exit}' /opt/mtproxymax/settings.conf 2>/dev/null)
        [ -n "$_port" ] && DETECTED_PORT="$_port"
        # Extract custom IP
        local _ip
        _ip=$(awk -F"'" '/^CUSTOM_IP=/{print $2; exit}' /opt/mtproxymax/settings.conf 2>/dev/null)
        [ -n "$_ip" ] && DETECTED_IP="$_ip"
        # Check container network mode
        if docker inspect -f '{{.HostConfig.NetworkMode}}' mtproxymax 2>/dev/null | grep -q "host"; then
            DETECTED_NETWORK_MODE="host"
        else
            DETECTED_NETWORK_MODE="bridge"
        fi
        DETECTED_CONTAINER="mtproxymax"
        return 0
    fi

    # 2. Check Docker containers with telemt
    if command -v docker &>/dev/null; then
        local cname
        for cname in $(docker ps --format '{{.Names}}' 2>/dev/null); do
            # Check if container runs telemt binary
            if docker inspect "$cname" 2>/dev/null | grep -qiE '"telemt|telemt.toml'; then
                DETECTED_MODE="docker"
                DETECTED_CONTAINER="$cname"
                # Try to find config path
                local _mount
                _mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/telemt.toml"}}{{.Source}}{{end}}{{end}}' "$cname" 2>/dev/null)
                [ -n "$_mount" ] && DETECTED_CONFIG_PATH="$_mount"
                # Check for config dir mount
                if [ -z "$DETECTED_CONFIG_PATH" ]; then
                    _mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/telemt"}}{{.Source}}{{end}}{{end}}' "$cname" 2>/dev/null)
                    [ -n "$_mount" ] && [ -f "${_mount}/config.toml" ] && DETECTED_CONFIG_PATH="${_mount}/config.toml"
                fi
                # Network mode
                local _nm
                _nm=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cname" 2>/dev/null)
                DETECTED_NETWORK_MODE="${_nm:-bridge}"
                # Extract port from config
                if [ -f "$DETECTED_CONFIG_PATH" ]; then
                    local _p
                    _p=$(awk '/^\[server\]/,/^\[/' "$DETECTED_CONFIG_PATH" 2>/dev/null | awk '/^port[[:space:]]*=/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
                    [ -n "$_p" ] && DETECTED_PORT="$_p"
                fi
                return 0
            fi
        done
    fi

    # 3. Check local telemt process
    if pgrep -x telemt &>/dev/null; then
        DETECTED_MODE="local"
        DETECTED_NETWORK_MODE="host"
        # Try to find config from process args
        local _args
        _args=$(ps -eo args 2>/dev/null | grep -m1 '[t]elemt' | grep -oE '/[^ ]+\.toml')
        if [ -n "$_args" ] && [ -f "$_args" ]; then
            DETECTED_CONFIG_PATH="$_args"
        elif [ -f "/etc/telemt.toml" ]; then
            DETECTED_CONFIG_PATH="/etc/telemt.toml"
        elif [ -f "/etc/telemt/config.toml" ]; then
            DETECTED_CONFIG_PATH="/etc/telemt/config.toml"
        fi
        if [ -f "$DETECTED_CONFIG_PATH" ]; then
            local _p
            _p=$(awk '/^\[server\]/,/^\[/' "$DETECTED_CONFIG_PATH" 2>/dev/null | awk '/^port[[:space:]]*=/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
            [ -n "$_p" ] && DETECTED_PORT="$_p"
        fi
        return 0
    fi

    # 4. Check common config paths even if no process found
    local _cf
    for _cf in /etc/telemt.toml /etc/telemt/config.toml /opt/telemt/config.toml /opt/mtproxymax/mtproxy/config.toml; do
        if [ -f "$_cf" ]; then
            DETECTED_CONFIG_PATH="$_cf"
            DETECTED_MODE="config_only"
            DETECTED_NETWORK_MODE="host"
            local _p
            _p=$(awk '/^\[server\]/,/^\[/' "$_cf" 2>/dev/null | awk '/^port[[:space:]]*=/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
            [ -n "$_p" ] && DETECTED_PORT="$_p"
            return 0
        fi
    done

    return 1
}

# Detect public IP
detect_public_ip() {
    local ip=""
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) ||
    ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) ||
    ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null) ||
    ip=""
    echo "$ip"
}

# Read current tuning values from config.toml
read_config_value() {
    local key="$1" file="$2"
    [ -f "$file" ] || return 0
    awk -v k="$key" '$1==k && $2=="=" {gsub(/[^0-9]/,"",$3); print $3; exit}' "$file" 2>/dev/null
}

# ── Dependencies ──────────────────────────────────────────────

install_dependencies() {
    log_info "Checking dependencies..."
    local missing=()
    command -v nft &>/dev/null || missing+=("nftables")
    command -v curl &>/dev/null || missing+=("curl")

    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Installing: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing[@]}"
        elif command -v apk &>/dev/null; then
            apk add --no-cache "${missing[@]}"
        else
            log_error "Cannot install ${missing[*]} — install manually"
            return 1
        fi
    fi
    log_success "Dependencies OK"
}

# ── Telemt Tuning ─────────────────────────────────────────────

apply_tuning() {
    log_info "Applying Telemt tuning..."

    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        log_info "Mode: MTProxyMax — using mtproxymax tune commands"
        local changed=false

        # tg_connect
        local _cur
        _cur=$(mtproxymax tune get tg_connect 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_TG_CONNECT" ]; then
            echo "n" | mtproxymax tune set tg_connect "$TUNING_TG_CONNECT" &>/dev/null || true
            changed=true
            log_success "tg_connect = $TUNING_TG_CONNECT"
        else
            log_info "tg_connect already $TUNING_TG_CONNECT"
        fi

        # client_handshake
        _cur=$(mtproxymax tune get client_handshake 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
            echo "n" | mtproxymax tune set client_handshake "$TUNING_CLIENT_HANDSHAKE" &>/dev/null || true
            changed=true
            log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
        else
            log_info "client_handshake already $TUNING_CLIENT_HANDSHAKE"
        fi

        # client_keepalive
        _cur=$(mtproxymax tune get client_keepalive 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
            echo "n" | mtproxymax tune set client_keepalive "$TUNING_CLIENT_KEEPALIVE" &>/dev/null || true
            changed=true
            log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
        else
            log_info "client_keepalive already $TUNING_CLIENT_KEEPALIVE"
        fi

        if [ "$changed" = "true" ]; then
            log_info "Restarting MTProxyMax..."
            mtproxymax restart &>/dev/null || log_warn "Restart failed"
        fi
        TUNING_APPLIED="true"
        save_settings
        return 0
    fi

    # For docker / local — edit config.toml directly
    if [ -z "$DETECTED_CONFIG_PATH" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_warn "Config file not found — cannot apply tuning automatically"
        echo ""
        echo -e "  ${BOLD}Add these to your config.toml manually:${NC}"
        echo ""
        echo "  [general]"
        echo "  tg_connect = $TUNING_TG_CONNECT"
        echo ""
        echo "  [timeouts]"
        echo "  client_handshake = $TUNING_CLIENT_HANDSHAKE"
        echo "  client_keepalive = $TUNING_CLIENT_KEEPALIVE"
        echo ""
        TUNING_APPLIED="manual"
        save_settings
        return 0
    fi

    local cfg="$DETECTED_CONFIG_PATH"
    local changed=false

    # tg_connect is in [general] or [timeouts] depending on version
    local _cur
    _cur=$(read_config_value "tg_connect" "$cfg")
    if [ "$_cur" != "$TUNING_TG_CONNECT" ]; then
        if grep -qE '^tg_connect[[:space:]]*=' "$cfg"; then
            sed -i "s/^tg_connect[[:space:]]*=.*/tg_connect = $TUNING_TG_CONNECT/" "$cfg"
        else
            # Add after [general] section
            sed -i "/^\[general\]/a tg_connect = $TUNING_TG_CONNECT" "$cfg"
        fi
        changed=true
        log_success "tg_connect = $TUNING_TG_CONNECT"
    fi

    _cur=$(read_config_value "client_handshake" "$cfg")
    if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
        if grep -qE '^client_handshake[[:space:]]*=' "$cfg"; then
            sed -i "s/^client_handshake[[:space:]]*=.*/client_handshake = $TUNING_CLIENT_HANDSHAKE/" "$cfg"
        else
            sed -i "/^\[timeouts\]/a client_handshake = $TUNING_CLIENT_HANDSHAKE" "$cfg"
        fi
        changed=true
        log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
    fi

    _cur=$(read_config_value "client_keepalive" "$cfg")
    if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
        if grep -qE '^client_keepalive[[:space:]]*=' "$cfg"; then
            sed -i "s/^client_keepalive[[:space:]]*=.*/client_keepalive = $TUNING_CLIENT_KEEPALIVE/" "$cfg"
        else
            sed -i "/^\[timeouts\]/a client_keepalive = $TUNING_CLIENT_KEEPALIVE" "$cfg"
        fi
        changed=true
        log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
    fi

    if [ "$changed" = "true" ]; then
        # Restart container or process
        if [ "$DETECTED_MODE" = "docker" ] && [ -n "$DETECTED_CONTAINER" ]; then
            log_info "Restarting container $DETECTED_CONTAINER..."
            docker restart "$DETECTED_CONTAINER" &>/dev/null || log_warn "Container restart failed"
        elif [ "$DETECTED_MODE" = "local" ]; then
            log_info "Sending SIGHUP to telemt..."
            pkill -HUP telemt 2>/dev/null || log_warn "Could not signal telemt"
        fi
    fi

    TUNING_APPLIED="true"
    save_settings
}

# ── NFT Rules ─────────────────────────────────────────────────

generate_nft_script() {
    local ip="${SERVER_IP:-}"
    local port="${SERVER_PORT:-443}"
    local rate="${NFT_RATE:-1/second}"
    local burst="${NFT_BURST:-1}"
    local timeout="${NFT_METER_TIMEOUT:-60s}"
    local table="${NFT_TABLE:-telemt_limit}"
    local hook="${NFT_HOOK:-input}"

    cat > "$NFT_SCRIPT" << NFTEOF
#!/bin/sh
set -eu

TABLE="$table"
CHAIN="$hook"

nft delete table inet "\$TABLE" 2>/dev/null || true
nft add table inet "\$TABLE"
nft "add chain inet \$TABLE \$CHAIN { type filter hook $hook priority 0; policy accept; }"

# Main rule
nft "add rule inet \$TABLE \$CHAIN \\
$([ -n "$ip" ] && echo "ip daddr $ip " || echo "")tcp dport $port \\
tcp flags & (syn | ack) == syn \\
meter telemt_in_syn_main { ip saddr timeout $timeout limit rate over $rate burst $burst packets } \\
counter drop comment \\"mtpr_main_${rate}_burst_${burst}\\""

NFTEOF

    # Add extra rules
    local i
    for i in $(seq 1 "$EXTRA_RULES_COUNT"); do
        local eport="${EXTRA_RULES_PORT[$i]:-}"
        local eip="${EXTRA_RULES_IP[$i]:-}"
        local erate="${EXTRA_RULES_RATE[$i]:-1/second}"
        local eburst="${EXTRA_RULES_BURST[$i]:-1}"
        [ -z "$eport" ] && continue

        cat >> "$NFT_SCRIPT" << EXTRAEOF

# Extra rule $i — port $eport
nft "add rule inet \$TABLE \$CHAIN \\
$([ -n "$eip" ] && echo "ip daddr $eip " || echo "")tcp dport $eport \\
tcp flags & (syn | ack) == syn \\
meter telemt_in_syn_extra_${i} { ip saddr timeout $timeout limit rate over $erate burst $eburst packets } \\
counter drop comment \\"mtpr_extra_${i}_${erate}_burst_${eburst}\\""

EXTRAEOF
    done

    cat >> "$NFT_SCRIPT" << 'TAILEOF'

echo "MTproxy-reanimation: nft rules applied"
nft list chain inet "$TABLE" "$CHAIN"
TAILEOF

    chmod +x "$NFT_SCRIPT"
}

apply_nft_rules() {
    generate_nft_script
    if /bin/sh "$NFT_SCRIPT"; then
        log_success "NFT rules applied"
    else
        log_error "Failed to apply NFT rules"
        return 1
    fi
}

remove_nft_rules() {
    local table="${NFT_TABLE:-telemt_limit}"
    nft delete table inet "$table" 2>/dev/null || true
    log_success "NFT rules removed"
}

# ── Systemd Service ───────────────────────────────────────────

install_service() {
    generate_nft_script
    local table="${NFT_TABLE:-telemt_limit}"

    cat > "/etc/systemd/system/${SYSTEMD_UNIT}" << SVCEOF
[Unit]
Description=MTproxy-reanimation inbound SYN limiter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh ${NFT_SCRIPT}
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet ${table} 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SYSTEMD_UNIT" 2>/dev/null
    systemctl restart "$SYSTEMD_UNIT" 2>/dev/null
    NFT_SERVICE_ENABLED="true"
    save_settings
    log_success "Service installed and started"
}

remove_service() {
    systemctl disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SYSTEMD_UNIT}"
    systemctl daemon-reload 2>/dev/null || true
    NFT_SERVICE_ENABLED="false"
    save_settings
    log_success "Service removed"
}

# ── Presets ────────────────────────────────────────────────────

apply_preset() {
    local preset="$1"
    case "$preset" in
        hard)
            NFT_RATE="1/second"; NFT_BURST="1"
            ;;
        medium)
            NFT_RATE="1/second"; NFT_BURST="3"
            ;;
        soft)
            NFT_RATE="2/second"; NFT_BURST="5"
            ;;
        *)
            log_error "Unknown preset: $preset"
            return 1
            ;;
    esac
    save_settings
    log_success "Preset applied: $preset (rate=$NFT_RATE burst=$NFT_BURST)"
}

# ── Drop counter ──────────────────────────────────────────────

show_drop_counter() {
    local table="${NFT_TABLE:-telemt_limit}"
    local hook="${NFT_HOOK:-input}"

    if ! nft list table inet "$table" &>/dev/null; then
        log_warn "No active NFT rules found"
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}Drop counters (Ctrl+C to stop):${NC}"
    echo ""
    watch -n 2 "nft list chain inet $table $hook 2>/dev/null | grep -E 'counter|comment'"
}

# ── Full uninstall ────────────────────────────────────────────

full_uninstall() {
    echo ""
    echo -e "  ${RED}${BOLD}UNINSTALL MTproxy-reanimation${NC}"
    echo ""
    echo -e "  This will remove:"
    echo -e "  ${DIM}- NFT rules${NC}"
    echo -e "  ${DIM}- Systemd service${NC}"
    echo -e "  ${DIM}- All config and scripts${NC}"
    echo -e "  ${DIM}- /usr/local/bin/mtpr symlink${NC}"
    echo ""
    echo -e "  ${YELLOW}Telemt tuning values will NOT be reverted.${NC}"
    echo ""
    echo -en "  ${BOLD}Type 'yes' to confirm:${NC} "
    local confirm
    read -r confirm
    [ "$confirm" != "yes" ] && { log_info "Cancelled"; return; }

    remove_nft_rules 2>/dev/null || true
    remove_service 2>/dev/null || true
    rm -f "$NFT_SCRIPT"
    rm -f /usr/local/bin/mtpr
    rm -rf "$INSTALL_DIR"

    echo ""
    log_success "MTproxy-reanimation fully uninstalled"

    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        echo ""
        echo -e "  ${DIM}To revert Telemt tuning in MTProxyMax:${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear tg_connect${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear client_handshake${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear client_keepalive${NC}"
        echo -e "  ${CYAN}mtproxymax restart${NC}"
    fi
    echo ""
    exit 0
}

# ── TUI ───────────────────────────────────────────────────────

show_header() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}Telemt inbound SYN limiter + tuning${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""

    # Current status
    local nft_status="${RED}inactive${NC}"
    if nft list table inet "${NFT_TABLE:-telemt_limit}" &>/dev/null; then
        nft_status="${GREEN}active${NC}"
    fi

    local svc_status="${DIM}not installed${NC}"
    if systemctl is-enabled "$SYSTEMD_UNIT" &>/dev/null; then
        if systemctl is-active "$SYSTEMD_UNIT" &>/dev/null; then
            svc_status="${GREEN}enabled + running${NC}"
        else
            svc_status="${YELLOW}enabled + stopped${NC}"
        fi
    fi

    echo -e "  ${BOLD}Detection:${NC}     ${DETECTED_MODE}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    echo -e "  ${BOLD}Network:${NC}       ${DETECTED_NETWORK_MODE:-unknown} → hook ${NFT_HOOK}"
    echo -e "  ${BOLD}Config:${NC}        ${DETECTED_CONFIG_PATH:-${DIM}not found${NC}}"
    echo -e "  ${BOLD}NFT rules:${NC}     ${nft_status}"
    echo -e "  ${BOLD}Service:${NC}       ${svc_status}"
    echo ""
    echo -e "  ${BOLD}IP:${NC}            ${SERVER_IP:-${DIM}any${NC}}"
    echo -e "  ${BOLD}Port:${NC}          ${SERVER_PORT:-${DIM}not set${NC}}"
    echo -e "  ${BOLD}Rate:${NC}          ${NFT_RATE}"
    echo -e "  ${BOLD}Burst:${NC}         ${NFT_BURST}"
    echo -e "  ${BOLD}Meter timeout:${NC} ${NFT_METER_TIMEOUT}"
    echo ""
    echo -e "  ${BOLD}Tuning:${NC}        tg_connect=${TUNING_TG_CONNECT}  handshake=${TUNING_CLIENT_HANDSHAKE}  keepalive=${TUNING_CLIENT_KEEPALIVE}  (${TUNING_APPLIED})"

    if [ "$EXTRA_RULES_COUNT" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}Extra rules:${NC}"
        local i
        for i in $(seq 1 "$EXTRA_RULES_COUNT"); do
            echo -e "    ${DIM}[$i]${NC} port=${EXTRA_RULES_PORT[$i]:-?} ip=${EXTRA_RULES_IP[$i]:-any} rate=${EXTRA_RULES_RATE[$i]:-?} burst=${EXTRA_RULES_BURST[$i]:-?}"
        done
    fi

    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
}

show_main_menu() {
    while true; do
        show_header

        echo -e "  ${CYAN}[1]${NC}  Apply NFT rules"
        echo -e "  ${CYAN}[2]${NC}  Apply Telemt tuning"
        echo -e "  ${CYAN}[3]${NC}  Settings"
        echo -e "  ${CYAN}[4]${NC}  Rate presets (hard / medium / soft)"
        echo -e "  ${CYAN}[5]${NC}  Watch drop counter"
        echo -e "  ${CYAN}[6]${NC}  Service management"
        echo -e "  ${CYAN}[7]${NC}  Extra rules (add port)"
        echo -e "  ${CYAN}[8]${NC}  Re-detect Telemt"
        echo ""
        echo -e "  ${RED}[u]${NC}  Uninstall"
        echo -e "  ${CYAN}[0]${NC}  Exit"
        echo ""
        echo -en "  Choice: "
        local choice
        read -r choice

        case "$choice" in
            1)
                if [ -z "$SERVER_PORT" ]; then
                    log_error "Port not set — configure in Settings first"
                    read -rsn1; continue
                fi
                apply_nft_rules || true
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            2)
                apply_tuning || true
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            3) show_settings_menu ;;
            4) show_preset_menu ;;
            5)
                show_drop_counter || true
                ;;
            6) show_service_menu ;;
            7) show_extra_rules_menu ;;
            8)
                detect_telemt || true
                # Auto-fill from detection if not set
                [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
                if [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ]; then
                    SERVER_IP="$DETECTED_IP"
                fi
                # Determine hook from network mode
                if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
                    NFT_HOOK="forward"
                else
                    NFT_HOOK="input"
                fi
                save_settings
                log_success "Re-detected: mode=$DETECTED_MODE port=$DETECTED_PORT"
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            u|U) full_uninstall ;;
            0|q|Q) exit 0 ;;
        esac
    done
}

show_settings_menu() {
    while true; do
        show_header
        echo -e "  ${BOLD}Settings${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} Server IP      [${SERVER_IP:-any}]"
        echo -e "  ${DIM}[2]${NC} Server Port    [${SERVER_PORT:-not set}]"
        echo -e "  ${DIM}[3]${NC} Rate           [${NFT_RATE}]"
        echo -e "  ${DIM}[4]${NC} Burst          [${NFT_BURST}]"
        echo -e "  ${DIM}[5]${NC} Meter timeout  [${NFT_METER_TIMEOUT}]"
        echo -e "  ${DIM}[6]${NC} tg_connect     [${TUNING_TG_CONNECT}]"
        echo -e "  ${DIM}[7]${NC} client_handshake [${TUNING_CLIENT_HANDSHAKE}]"
        echo -e "  ${DIM}[8]${NC} client_keepalive [${TUNING_CLIENT_KEEPALIVE}]"
        echo -e "  ${DIM}[9]${NC} Auto-detect IP from internet"
        echo -e "  ${DIM}[c]${NC} Clear IP (apply to all addresses)"
        echo -e "  ${DIM}[0]${NC} Back"
        echo ""
        echo -en "  Choice: "
        local choice
        read -r choice

        case "$choice" in
            1)
                echo -en "  New IP [${SERVER_IP:-empty}]: "
                local v; read -r v
                [ -n "$v" ] && SERVER_IP="$v"
                save_settings
                ;;
            2)
                echo -en "  New port [${SERVER_PORT:-}]: "
                local v; read -r v
                if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ]; then
                    SERVER_PORT="$v"
                    save_settings
                elif [ -n "$v" ]; then
                    log_error "Invalid port"
                fi
                ;;
            3)
                echo -en "  New rate (e.g. 1/second, 2/second): "
                local v; read -r v
                [ -n "$v" ] && NFT_RATE="$v" && save_settings
                ;;
            4)
                echo -en "  New burst: "
                local v; read -r v
                [[ "$v" =~ ^[0-9]+$ ]] && NFT_BURST="$v" && save_settings
                ;;
            5)
                echo -en "  New meter timeout (e.g. 30s, 60s, 120s): "
                local v; read -r v
                [ -n "$v" ] && NFT_METER_TIMEOUT="$v" && save_settings
                ;;
            6)
                echo -en "  tg_connect [${TUNING_TG_CONNECT}]: "
                local v; read -r v
                [[ "$v" =~ ^[0-9]+$ ]] && TUNING_TG_CONNECT="$v" && save_settings
                ;;
            7)
                echo -en "  client_handshake [${TUNING_CLIENT_HANDSHAKE}]: "
                local v; read -r v
                [[ "$v" =~ ^[0-9]+$ ]] && TUNING_CLIENT_HANDSHAKE="$v" && save_settings
                ;;
            8)
                echo -en "  client_keepalive [${TUNING_CLIENT_KEEPALIVE}]: "
                local v; read -r v
                [[ "$v" =~ ^[0-9]+$ ]] && TUNING_CLIENT_KEEPALIVE="$v" && save_settings
                ;;
            9)
                log_info "Detecting public IP..."
                local ip
                ip=$(detect_public_ip)
                if [ -n "$ip" ]; then
                    SERVER_IP="$ip"
                    save_settings
                    log_success "IP detected: $ip"
                else
                    log_error "Could not detect public IP"
                fi
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            c|C)
                SERVER_IP=""
                save_settings
                log_success "IP cleared — rules will apply to all addresses"
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            0|"") return ;;
        esac
    done
}

show_preset_menu() {
    show_header
    echo -e "  ${BOLD}Rate Presets${NC}"
    echo ""
    echo -e "  ${RED}[1]${NC} Hard    — 1/second burst 1   ${DIM}(most restrictive)${NC}"
    echo -e "  ${YELLOW}[2]${NC} Medium  — 1/second burst 3   ${DIM}(balanced)${NC}"
    echo -e "  ${GREEN}[3]${NC} Soft    — 2/second burst 5   ${DIM}(most permissive)${NC}"
    echo -e "  ${DIM}[4]${NC} Custom"
    echo -e "  ${DIM}[0]${NC} Back"
    echo ""
    echo -en "  Choice: "
    local choice
    read -r choice

    case "$choice" in
        1) apply_preset hard ;;
        2) apply_preset medium ;;
        3) apply_preset soft ;;
        4)
            echo -en "  Rate (e.g. 1/second): "
            local r; read -r r
            echo -en "  Burst: "
            local b; read -r b
            [ -n "$r" ] && NFT_RATE="$r"
            [[ "$b" =~ ^[0-9]+$ ]] && NFT_BURST="$b"
            save_settings
            log_success "Custom rate=$NFT_RATE burst=$NFT_BURST"
            ;;
        0|"") return ;;
    esac

    # Ask to apply immediately
    echo ""
    echo -en "  Apply NFT rules now? [Y/n]: "
    local yn; read -r yn
    if [[ ! "$yn" =~ ^[nN] ]]; then
        apply_nft_rules || true
        # Rebuild service if enabled
        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
    fi
    echo ""; read -rsn1 -p "  Press any key..."
}

show_service_menu() {
    show_header
    echo -e "  ${BOLD}Service Management${NC}"
    echo ""

    local status="${DIM}not installed${NC}"
    if systemctl is-enabled "$SYSTEMD_UNIT" &>/dev/null; then
        if systemctl is-active "$SYSTEMD_UNIT" &>/dev/null; then
            status="${GREEN}enabled + running${NC}"
        else
            status="${YELLOW}enabled + stopped${NC}"
        fi
    fi
    echo -e "  Status: ${status}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Install & enable service"
    echo -e "  ${DIM}[2]${NC} Remove service"
    echo -e "  ${DIM}[3]${NC} Restart service"
    echo -e "  ${DIM}[4]${NC} Stop service (keep rules)"
    echo -e "  ${DIM}[5]${NC} View service logs"
    echo -e "  ${DIM}[0]${NC} Back"
    echo ""
    echo -en "  Choice: "
    local choice
    read -r choice

    case "$choice" in
        1)
            if [ -z "$SERVER_PORT" ]; then
                log_error "Port not set — configure in Settings first"
            else
                install_service
            fi
            ;;
        2) remove_service ;;
        3) systemctl restart "$SYSTEMD_UNIT" 2>/dev/null && log_success "Service restarted" || log_error "Restart failed" ;;
        4) systemctl stop "$SYSTEMD_UNIT" 2>/dev/null && log_success "Service stopped" || log_error "Stop failed" ;;
        5)
            echo ""
            journalctl -u "$SYSTEMD_UNIT" -n 20 --no-pager 2>/dev/null || log_warn "No logs"
            ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Press any key..."
}

show_extra_rules_menu() {
    while true; do
        show_header
        echo -e "  ${BOLD}Extra Rules${NC}"
        echo ""

        if [ "$EXTRA_RULES_COUNT" -eq 0 ]; then
            echo -e "  ${DIM}No extra rules configured${NC}"
        else
            local i
            for i in $(seq 1 "$EXTRA_RULES_COUNT"); do
                echo -e "  ${DIM}[$i]${NC} port=${EXTRA_RULES_PORT[$i]:-?}  ip=${EXTRA_RULES_IP[$i]:-any}  rate=${EXTRA_RULES_RATE[$i]:-?}  burst=${EXTRA_RULES_BURST[$i]:-?}"
            done
        fi

        echo ""
        echo -e "  ${DIM}[a]${NC} Add extra rule"
        echo -e "  ${DIM}[d]${NC} Delete extra rule"
        echo -e "  ${DIM}[0]${NC} Back"
        echo ""
        echo -en "  Choice: "
        local choice
        read -r choice

        case "$choice" in
            a|A)
                echo -en "  Port: "
                local p; read -r p
                if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                    log_error "Invalid port"; echo ""; read -rsn1 -p "  Press any key..."; continue
                fi
                echo -en "  IP (empty = any): "
                local ip; read -r ip
                echo -en "  Rate [1/second]: "
                local r; read -r r; [ -z "$r" ] && r="1/second"
                echo -en "  Burst [1]: "
                local b; read -r b; [ -z "$b" ] && b="1"

                EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT + 1))
                local idx=$EXTRA_RULES_COUNT
                EXTRA_RULES_PORT[$idx]="$p"
                EXTRA_RULES_IP[$idx]="$ip"
                EXTRA_RULES_RATE[$idx]="$r"
                EXTRA_RULES_BURST[$idx]="$b"
                save_settings
                log_success "Extra rule $idx added"

                echo -en "  Apply rules now? [Y/n]: "
                local yn; read -r yn
                if [[ ! "$yn" =~ ^[nN] ]]; then
                    apply_nft_rules || true
                    [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
                fi
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            d|D)
                [ "$EXTRA_RULES_COUNT" -eq 0 ] && { log_info "No rules to delete"; echo ""; read -rsn1 -p "  Press any key..."; continue; }
                echo -en "  Rule number to delete: "
                local idx; read -r idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$EXTRA_RULES_COUNT" ]; then
                    # Shift rules down
                    local i
                    for i in $(seq "$idx" $((EXTRA_RULES_COUNT - 1))); do
                        local next=$((i + 1))
                        EXTRA_RULES_PORT[$i]="${EXTRA_RULES_PORT[$next]:-}"
                        EXTRA_RULES_IP[$i]="${EXTRA_RULES_IP[$next]:-}"
                        EXTRA_RULES_RATE[$i]="${EXTRA_RULES_RATE[$next]:-}"
                        EXTRA_RULES_BURST[$i]="${EXTRA_RULES_BURST[$next]:-}"
                    done
                    unset "EXTRA_RULES_PORT[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_IP[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_RATE[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_BURST[$EXTRA_RULES_COUNT]"
                    EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT - 1))
                    save_settings
                    log_success "Rule deleted"

                    echo -en "  Re-apply rules now? [Y/n]: "
                    local yn; read -r yn
                    if [[ ! "$yn" =~ ^[nN] ]]; then
                        apply_nft_rules || true
                        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
                    fi
                else
                    log_error "Invalid rule number"
                fi
                echo ""; read -rsn1 -p "  Press any key..."
                ;;
            0|"") return ;;
        esac
    done
}

# ── First run wizard ──────────────────────────────────────────

first_run_wizard() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}First-time setup wizard${NC}"
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""

    # Step 1: Detect
    log_info "Detecting Telemt installation..."
    if detect_telemt; then
        log_success "Found: ${DETECTED_MODE}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
        [ -n "$DETECTED_CONFIG_PATH" ] && log_info "Config: ${DETECTED_CONFIG_PATH}"
        [ -n "$DETECTED_PORT" ] && log_info "Port: ${DETECTED_PORT}"
        [ -n "$DETECTED_NETWORK_MODE" ] && log_info "Network: ${DETECTED_NETWORK_MODE}"
    else
        log_warn "Telemt not detected automatically"
    fi

    # Determine hook
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        NFT_HOOK="forward"
    else
        NFT_HOOK="input"
    fi

    # Step 2: Dependencies
    echo ""
    install_dependencies || exit 1

    # Step 3: Port
    echo ""
    SERVER_PORT="${DETECTED_PORT:-443}"
    echo -en "  ${BOLD}Proxy port [${SERVER_PORT}]:${NC} "
    local v; read -r v
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] && SERVER_PORT="$v"

    # Step 4: IP
    echo ""
    if [ -n "$DETECTED_IP" ]; then
        SERVER_IP="$DETECTED_IP"
        log_info "IP from config: $SERVER_IP"
    else
        log_info "Detecting public IP..."
        SERVER_IP=$(detect_public_ip)
        [ -n "$SERVER_IP" ] && log_success "Detected: $SERVER_IP" || log_warn "Could not detect IP"
    fi
    echo -en "  ${BOLD}Server IP [${SERVER_IP:-leave empty for any}]:${NC} "
    read -r v
    [ -n "$v" ] && SERVER_IP="$v"

    # Step 5: Preset
    echo ""
    echo -e "  ${BOLD}Rate preset:${NC}"
    echo -e "    ${RED}[1]${NC} Hard    — 1/sec burst 1  ${DIM}(recommended)${NC}"
    echo -e "    ${YELLOW}[2]${NC} Medium  — 1/sec burst 3"
    echo -e "    ${GREEN}[3]${NC} Soft    — 2/sec burst 5"
    echo ""
    echo -en "  Choice [1]: "
    local preset; read -r preset
    case "$preset" in
        2) apply_preset medium ;;
        3) apply_preset soft ;;
        *) apply_preset hard ;;
    esac

    # Save
    save_settings

    # Step 6: Apply tuning
    echo ""
    echo -en "  ${BOLD}Apply Telemt tuning? [Y/n]:${NC} "
    local yn; read -r yn
    if [[ ! "$yn" =~ ^[nN] ]]; then
        apply_tuning || true
    fi

    # Step 7: Apply NFT
    echo ""
    echo -en "  ${BOLD}Apply NFT rules now? [Y/n]:${NC} "
    read -r yn
    if [[ ! "$yn" =~ ^[nN] ]]; then
        apply_nft_rules || true
    fi

    # Step 8: Install service
    echo ""
    echo -en "  ${BOLD}Install as systemd service (auto-start on boot)? [Y/n]:${NC} "
    read -r yn
    if [[ ! "$yn" =~ ^[nN] ]]; then
        install_service || true
    fi

    echo ""
    log_success "Setup complete!"
    echo ""
    echo -e "  ${DIM}Run ${CYAN}mtpr${DIM} anytime to manage${NC}"
    echo ""
    read -rsn1 -p "  Press any key to open menu..."
}

# ── Main entry ────────────────────────────────────────────────

main() {
    check_root

    mkdir -p "$INSTALL_DIR"

    # Copy self to install dir if running from elsewhere
    local self="${BASH_SOURCE[0]}"
    if [ -f "$self" ] && [ "$(realpath "$self" 2>/dev/null)" != "$(realpath "${INSTALL_DIR}/mtpr.sh" 2>/dev/null)" ]; then
        cp "$self" "${INSTALL_DIR}/mtpr.sh"
        chmod +x "${INSTALL_DIR}/mtpr.sh"
    fi

    # Create symlink
    ln -sf "${INSTALL_DIR}/mtpr.sh" /usr/local/bin/mtpr 2>/dev/null || true

    # Load settings
    load_settings

    # Detect telemt
    detect_telemt || true

    # Auto-fill from detection
    [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
    [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ] && SERVER_IP="$DETECTED_IP"
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        NFT_HOOK="forward"
    else
        NFT_HOOK="input"
    fi

    # First run?
    if [ ! -f "$SETTINGS_FILE" ]; then
        first_run_wizard
    fi

    # Show menu
    show_main_menu
}

main "$@"
