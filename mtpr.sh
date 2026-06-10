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

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Настройки по умолчанию ────────────────────────────────────
DETECTED_MODE=""
DETECTED_CONTAINER=""
DETECTED_CONFIG_PATH=""
DETECTED_IP=""
DETECTED_PORT=""
DETECTED_NETWORK_MODE=""

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

declare -A EXTRA_RULES_PORT
declare -A EXTRA_RULES_IP
declare -A EXTRA_RULES_RATE
declare -A EXTRA_RULES_BURST
EXTRA_RULES_COUNT=0

# ── Логирование ───────────────────────────────────────────────
log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} $1" >&2; }
log_error()   { echo -e "  ${RED}[✗]${NC} $1" >&2; }

# ── Проверка root ─────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Требуются права root"
        exit 1
    fi
}

# ── Вспомогательная функция для чтения ввода ──────────────────
# Решает проблему с конфликтом переменных при read
_read_input() {
    local _prompt="$1" _default="$2" _result
    echo -en "$_prompt"
    read -r _result
    if [ -z "$_result" ]; then
        echo "$_default"
    else
        echo "$_result"
    fi
}

# ── Сохранение / Загрузка настроек ────────────────────────────
save_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$SETTINGS_FILE" << EOF
# MTproxy-reanimation — настройки v${VERSION}
# Создано: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
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
    local _i
    for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
        cat >> "$SETTINGS_FILE" << EOF
EXTRA_RULES_${_i}_PORT='${EXTRA_RULES_PORT[$_i]:-}'
EXTRA_RULES_${_i}_IP='${EXTRA_RULES_IP[$_i]:-}'
EXTRA_RULES_${_i}_RATE='${EXTRA_RULES_RATE[$_i]:-1/second}'
EXTRA_RULES_${_i}_BURST='${EXTRA_RULES_BURST[$_i]:-1}'
EOF
    done
    chmod 600 "$SETTINGS_FILE"
}

load_settings() {
    [ -f "$SETTINGS_FILE" ] || return 0
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$_line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]]; then
            local _key="${BASH_REMATCH[1]}" _val="${BASH_REMATCH[2]}"
            case "$_key" in
                SERVER_IP|SERVER_PORT|NFT_RATE|NFT_BURST|NFT_METER_TIMEOUT|\
                NFT_TABLE|NFT_HOOK|TUNING_TG_CONNECT|TUNING_CLIENT_HANDSHAKE|\
                TUNING_CLIENT_KEEPALIVE|TUNING_APPLIED|NFT_SERVICE_ENABLED|\
                EXTRA_RULES_COUNT)
                    printf -v "$_key" '%s' "$_val"
                    ;;
                EXTRA_RULES_*_PORT)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_PORT}"
                    EXTRA_RULES_PORT[$_idx]="$_val"
                    ;;
                EXTRA_RULES_*_IP)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_IP}"
                    EXTRA_RULES_IP[$_idx]="$_val"
                    ;;
                EXTRA_RULES_*_RATE)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_RATE}"
                    EXTRA_RULES_RATE[$_idx]="$_val"
                    ;;
                EXTRA_RULES_*_BURST)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_BURST}"
                    EXTRA_RULES_BURST[$_idx]="$_val"
                    ;;
            esac
        fi
    done < "$SETTINGS_FILE"
    [[ "$EXTRA_RULES_COUNT" =~ ^[0-9]+$ ]] || EXTRA_RULES_COUNT=0
}

# ── Обнаружение Telemt ────────────────────────────────────────

detect_telemt() {
    DETECTED_MODE="unknown"
    DETECTED_CONTAINER=""
    DETECTED_CONFIG_PATH=""
    DETECTED_IP=""
    DETECTED_PORT=""
    DETECTED_NETWORK_MODE=""

    # 1. MTProxyMax
    if [ -f /opt/mtproxymax/settings.conf ] && command -v mtproxymax &>/dev/null; then
        DETECTED_MODE="mtproxymax"
        DETECTED_CONFIG_PATH="/opt/mtproxymax/mtproxy/config.toml"
        local _port
        _port=$(awk -F"'" '/^PROXY_PORT=/{print $2; exit}' /opt/mtproxymax/settings.conf 2>/dev/null)
        [ -n "$_port" ] && DETECTED_PORT="$_port"
        local _ip
        _ip=$(awk -F"'" '/^CUSTOM_IP=/{print $2; exit}' /opt/mtproxymax/settings.conf 2>/dev/null)
        [ -n "$_ip" ] && DETECTED_IP="$_ip"
        if docker inspect -f '{{.HostConfig.NetworkMode}}' mtproxymax 2>/dev/null | grep -q "host"; then
            DETECTED_NETWORK_MODE="host"
        else
            DETECTED_NETWORK_MODE="bridge"
        fi
        DETECTED_CONTAINER="mtproxymax"
        return 0
    fi

    # 2. Docker-контейнер с telemt
    if command -v docker &>/dev/null; then
        local _cname
        for _cname in $(docker ps --format '{{.Names}}' 2>/dev/null); do
            if docker inspect "$_cname" 2>/dev/null | grep -qiE '"telemt|telemt.toml'; then
                DETECTED_MODE="docker"
                DETECTED_CONTAINER="$_cname"
                local _mount
                _mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/telemt.toml"}}{{.Source}}{{end}}{{end}}' "$_cname" 2>/dev/null)
                [ -n "$_mount" ] && DETECTED_CONFIG_PATH="$_mount"
                if [ -z "$DETECTED_CONFIG_PATH" ]; then
                    _mount=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/telemt"}}{{.Source}}{{end}}{{end}}' "$_cname" 2>/dev/null)
                    [ -n "$_mount" ] && [ -f "${_mount}/config.toml" ] && DETECTED_CONFIG_PATH="${_mount}/config.toml"
                fi
                local _nm
                _nm=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$_cname" 2>/dev/null)
                DETECTED_NETWORK_MODE="${_nm:-bridge}"
                if [ -f "$DETECTED_CONFIG_PATH" ]; then
                    local _p
                    _p=$(awk '/^\[server\]/,/^\[/' "$DETECTED_CONFIG_PATH" 2>/dev/null | awk '/^port[[:space:]]*=/{gsub(/[^0-9]/,"",$NF); print $NF; exit}')
                    [ -n "$_p" ] && DETECTED_PORT="$_p"
                fi
                return 0
            fi
        done
    fi

    # 3. Локальный процесс telemt
    if pgrep -x telemt &>/dev/null; then
        DETECTED_MODE="local"
        DETECTED_NETWORK_MODE="host"
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

    # 4. Поиск конфигов
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

detect_public_ip() {
    local _ip=""
    _ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null) ||
    _ip=""
    echo "$_ip"
}

read_config_value() {
    local _key="$1" _file="$2"
    [ -f "$_file" ] || return 0
    awk -v k="$_key" '$1==k && $2=="=" {gsub(/[^0-9]/,"",$3); print $3; exit}' "$_file" 2>/dev/null
}

# ── Зависимости ──────────────────────────────────────────────

install_dependencies() {
    log_info "Проверка зависимостей..."
    local _missing=()
    command -v nft &>/dev/null || _missing+=("nftables")
    command -v curl &>/dev/null || _missing+=("curl")

    if [ ${#_missing[@]} -gt 0 ]; then
        log_info "Установка: ${_missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${_missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${_missing[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${_missing[@]}"
        elif command -v apk &>/dev/null; then
            apk add --no-cache "${_missing[@]}"
        else
            log_error "Не удалось установить ${_missing[*]} — установите вручную"
            return 1
        fi
    fi
    log_success "Зависимости в порядке"
}

# ── Тюнинг Telemt ─────────────────────────────────────────────

apply_tuning() {
    log_info "Применение тюнинга Telemt..."

    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        log_info "Режим: MTProxyMax — используем команды mtproxymax tune"
        local _changed=false

        local _cur
        _cur=$(mtproxymax tune get tg_connect 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_TG_CONNECT" ]; then
            echo "n" | mtproxymax tune set tg_connect "$TUNING_TG_CONNECT" &>/dev/null || true
            _changed=true
            log_success "tg_connect = $TUNING_TG_CONNECT"
        else
            log_info "tg_connect уже $TUNING_TG_CONNECT"
        fi

        _cur=$(mtproxymax tune get client_handshake 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
            echo "n" | mtproxymax tune set client_handshake "$TUNING_CLIENT_HANDSHAKE" &>/dev/null || true
            _changed=true
            log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
        else
            log_info "client_handshake уже $TUNING_CLIENT_HANDSHAKE"
        fi

        _cur=$(mtproxymax tune get client_keepalive 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
            echo "n" | mtproxymax tune set client_keepalive "$TUNING_CLIENT_KEEPALIVE" &>/dev/null || true
            _changed=true
            log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
        else
            log_info "client_keepalive уже $TUNING_CLIENT_KEEPALIVE"
        fi

        if [ "$_changed" = "true" ]; then
            log_info "Перезапуск MTProxyMax..."
            mtproxymax restart &>/dev/null || log_warn "Не удалось перезапустить"
        fi
        TUNING_APPLIED="true"
        save_settings
        return 0
    fi

    # Для docker / local — редактируем config.toml напрямую
    if [ -z "$DETECTED_CONFIG_PATH" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_warn "Файл конфигурации не найден — невозможно применить тюнинг автоматически"
        echo ""
        echo -e "  ${BOLD}Добавьте в config.toml вручную:${NC}"
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

    local _cfg="$DETECTED_CONFIG_PATH"
    local _changed=false

    local _cur
    _cur=$(read_config_value "tg_connect" "$_cfg")
    if [ "$_cur" != "$TUNING_TG_CONNECT" ]; then
        if grep -qE '^tg_connect[[:space:]]*=' "$_cfg"; then
            sed -i "s/^tg_connect[[:space:]]*=.*/tg_connect = $TUNING_TG_CONNECT/" "$_cfg"
        else
            sed -i "/^\[general\]/a tg_connect = $TUNING_TG_CONNECT" "$_cfg"
        fi
        _changed=true
        log_success "tg_connect = $TUNING_TG_CONNECT"
    fi

    _cur=$(read_config_value "client_handshake" "$_cfg")
    if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
        if grep -qE '^client_handshake[[:space:]]*=' "$_cfg"; then
            sed -i "s/^client_handshake[[:space:]]*=.*/client_handshake = $TUNING_CLIENT_HANDSHAKE/" "$_cfg"
        else
            sed -i "/^\[timeouts\]/a client_handshake = $TUNING_CLIENT_HANDSHAKE" "$_cfg"
        fi
        _changed=true
        log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
    fi

    _cur=$(read_config_value "client_keepalive" "$_cfg")
    if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
        if grep -qE '^client_keepalive[[:space:]]*=' "$_cfg"; then
            sed -i "s/^client_keepalive[[:space:]]*=.*/client_keepalive = $TUNING_CLIENT_KEEPALIVE/" "$_cfg"
        else
            sed -i "/^\[timeouts\]/a client_keepalive = $TUNING_CLIENT_KEEPALIVE" "$_cfg"
        fi
        _changed=true
        log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
    fi

    if [ "$_changed" = "true" ]; then
        if [ "$DETECTED_MODE" = "docker" ] && [ -n "$DETECTED_CONTAINER" ]; then
            log_info "Перезапуск контейнера $DETECTED_CONTAINER..."
            docker restart "$DETECTED_CONTAINER" &>/dev/null || log_warn "Не удалось перезапустить контейнер"
        elif [ "$DETECTED_MODE" = "local" ]; then
            log_info "Отправка SIGHUP процессу telemt..."
            pkill -HUP telemt 2>/dev/null || log_warn "Не удалось отправить сигнал"
        fi
    fi

    TUNING_APPLIED="true"
    save_settings
}

# ── NFT правила ───────────────────────────────────────────────

generate_nft_script() {
    local _ip="${SERVER_IP:-}"
    local _port="${SERVER_PORT:-443}"
    local _rate="${NFT_RATE:-1/second}"
    local _burst="${NFT_BURST:-1}"
    local _timeout="${NFT_METER_TIMEOUT:-60s}"
    local _table="${NFT_TABLE:-telemt_limit}"
    local _hook="${NFT_HOOK:-input}"

    cat > "$NFT_SCRIPT" << NFTEOF
#!/bin/sh
set -eu

TABLE="${_table}"
CHAIN="${_hook}"

nft delete table inet "\$TABLE" 2>/dev/null || true
nft add table inet "\$TABLE"
nft "add chain inet \$TABLE \$CHAIN { type filter hook ${_hook} priority 0; policy accept; }"

# Основное правило
nft "add rule inet \$TABLE \$CHAIN \\
$([ -n "$_ip" ] && echo "ip daddr ${_ip} " || echo "")tcp dport ${_port} \\
tcp flags & (syn | ack) == syn \\
meter telemt_in_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } \\
counter drop comment \\"mtpr_main_${_rate}_burst_${_burst}\\""

NFTEOF

    local _i
    for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
        local _eport="${EXTRA_RULES_PORT[$_i]:-}"
        local _eip="${EXTRA_RULES_IP[$_i]:-}"
        local _erate="${EXTRA_RULES_RATE[$_i]:-1/second}"
        local _eburst="${EXTRA_RULES_BURST[$_i]:-1}"
        [ -z "$_eport" ] && continue

        cat >> "$NFT_SCRIPT" << EXTRAEOF

# Доп. правило ${_i} — порт ${_eport}
nft "add rule inet \$TABLE \$CHAIN \\
$([ -n "$_eip" ] && echo "ip daddr ${_eip} " || echo "")tcp dport ${_eport} \\
tcp flags & (syn | ack) == syn \\
meter telemt_in_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } \\
counter drop comment \\"mtpr_extra_${_i}_${_erate}_burst_${_eburst}\\""

EXTRAEOF
    done

    cat >> "$NFT_SCRIPT" << 'TAILEOF'

echo "MTproxy-reanimation: nft правила применены"
nft list chain inet "$TABLE" "$CHAIN"
TAILEOF

    chmod +x "$NFT_SCRIPT"
}

apply_nft_rules() {
    generate_nft_script
    if /bin/sh "$NFT_SCRIPT"; then
        log_success "NFT правила применены"
    else
        log_error "Не удалось применить NFT правила"
        return 1
    fi
}

remove_nft_rules() {
    local _table="${NFT_TABLE:-telemt_limit}"
    nft delete table inet "$_table" 2>/dev/null || true
    log_success "NFT правила удалены"
}

# ── Systemd сервис ────────────────────────────────────────────

install_service() {
    generate_nft_script
    local _table="${NFT_TABLE:-telemt_limit}"

    cat > "/etc/systemd/system/${SYSTEMD_UNIT}" << SVCEOF
[Unit]
Description=MTproxy-reanimation inbound SYN limiter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh ${NFT_SCRIPT}
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet ${_table} 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SYSTEMD_UNIT" 2>/dev/null
    systemctl restart "$SYSTEMD_UNIT" 2>/dev/null
    NFT_SERVICE_ENABLED="true"
    save_settings
    log_success "Служба установлена и запущена"
}

remove_service() {
    systemctl disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SYSTEMD_UNIT}"
    systemctl daemon-reload 2>/dev/null || true
    NFT_SERVICE_ENABLED="false"
    save_settings
    log_success "Служба удалена"
}

# ── Пресеты ───────────────────────────────────────────────────

apply_preset() {
    local _preset="$1"
    case "$_preset" in
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
            log_error "Неизвестный пресет: $_preset"
            return 1
            ;;
    esac
    save_settings
    log_success "Пресет применён: $_preset (rate=$NFT_RATE burst=$NFT_BURST)"
}

# ── Счётчик дропов ────────────────────────────────────────────

show_drop_counter() {
    local _table="${NFT_TABLE:-telemt_limit}"
    local _hook="${NFT_HOOK:-input}"

    if ! nft list table inet "$_table" &>/dev/null; then
        log_warn "Активных NFT правил не найдено"
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}Счётчик дропов (Ctrl+C для выхода):${NC}"
    echo ""
    watch -n 2 "nft list chain inet $_table $_hook 2>/dev/null | grep -E 'counter|comment'"
}

# ── Полное удаление ───────────────────────────────────────────

full_uninstall() {
    echo ""
    echo -e "  ${RED}${BOLD}УДАЛЕНИЕ MTproxy-reanimation${NC}"
    echo ""
    echo -e "  Будет удалено:"
    echo -e "  ${DIM}- NFT правила${NC}"
    echo -e "  ${DIM}- Systemd служба${NC}"
    echo -e "  ${DIM}- Все настройки и скрипты${NC}"
    echo -e "  ${DIM}- Симлинк /usr/local/bin/mtpr${NC}"
    echo ""
    echo -e "  ${YELLOW}Значения тюнинга Telemt НЕ будут откачены.${NC}"
    echo ""
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _confirm
    read -r _confirm
    [ "$_confirm" != "yes" ] && { log_info "Отменено"; return; }

    remove_nft_rules 2>/dev/null || true
    remove_service 2>/dev/null || true
    rm -f "$NFT_SCRIPT"
    rm -f /usr/local/bin/mtpr
    rm -rf "$INSTALL_DIR"

    echo ""
    log_success "MTproxy-reanimation полностью удалён"

    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        echo ""
        echo -e "  ${DIM}Для отката тюнинга Telemt в MTProxyMax:${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear tg_connect${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear client_handshake${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear client_keepalive${NC}"
        echo -e "  ${CYAN}mtproxymax restart${NC}"
    fi
    echo ""
    exit 0
}

# ── Интерфейс ─────────────────────────────────────────────────

show_header() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}Telemt inbound SYN limiter + тюнинг${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""

    local _nft_status="${RED}неактивно${NC}"
    if nft list table inet "${NFT_TABLE:-telemt_limit}" &>/dev/null; then
        _nft_status="${GREEN}активно${NC}"
    fi

    local _svc_status="${DIM}не установлена${NC}"
    if systemctl is-enabled "$SYSTEMD_UNIT" &>/dev/null 2>&1; then
        if systemctl is-active "$SYSTEMD_UNIT" &>/dev/null 2>&1; then
            _svc_status="${GREEN}вкл + работает${NC}"
        else
            _svc_status="${YELLOW}вкл + остановлена${NC}"
        fi
    fi

    local _tuning_status="${DIM}не применён${NC}"
    case "$TUNING_APPLIED" in
        true)   _tuning_status="${GREEN}применён${NC}" ;;
        manual) _tuning_status="${YELLOW}вручную${NC}" ;;
    esac

    echo -e "  ${BOLD}Обнаружение:${NC}   ${DETECTED_MODE:-не найден}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    echo -e "  ${BOLD}Сеть:${NC}          ${DETECTED_NETWORK_MODE:-неизвестно} → hook ${NFT_HOOK}"
    echo -e "  ${BOLD}Конфиг:${NC}        ${DETECTED_CONFIG_PATH:-${DIM}не найден${NC}}"
    echo -e "  ${BOLD}NFT правила:${NC}   ${_nft_status}"
    echo -e "  ${BOLD}Служба:${NC}        ${_svc_status}"
    echo ""
    echo -e "  ${BOLD}IP:${NC}            ${SERVER_IP:-${DIM}любой${NC}}"
    echo -e "  ${BOLD}Порт:${NC}          ${SERVER_PORT:-${DIM}не задан${NC}}"
    echo -e "  ${BOLD}Rate:${NC}          ${NFT_RATE}"
    echo -e "  ${BOLD}Burst:${NC}         ${NFT_BURST}"
    echo -e "  ${BOLD}Meter timeout:${NC} ${NFT_METER_TIMEOUT}"
    echo ""
    echo -e "  ${BOLD}Тюнинг:${NC}        tg_connect=${TUNING_TG_CONNECT}  handshake=${TUNING_CLIENT_HANDSHAKE}  keepalive=${TUNING_CLIENT_KEEPALIVE}  (${_tuning_status})"

    if [ "$EXTRA_RULES_COUNT" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}Доп. правила:${NC}"
        local _i
        for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
            echo -e "    ${DIM}[$_i]${NC} порт=${EXTRA_RULES_PORT[$_i]:-?} ip=${EXTRA_RULES_IP[$_i]:-любой} rate=${EXTRA_RULES_RATE[$_i]:-?} burst=${EXTRA_RULES_BURST[$_i]:-?}"
        done
    fi

    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
}

show_main_menu() {
    while true; do
        show_header

        echo -e "  ${CYAN}[1]${NC}  Применить NFT правила"
        echo -e "  ${CYAN}[2]${NC}  Применить тюнинг Telemt"
        echo -e "  ${CYAN}[3]${NC}  Настройки"
        echo -e "  ${CYAN}[4]${NC}  Пресеты (жёсткий / средний / мягкий)"
        echo -e "  ${CYAN}[5]${NC}  Счётчик дропов"
        echo -e "  ${CYAN}[6]${NC}  Управление службой"
        echo -e "  ${CYAN}[7]${NC}  Доп. правила (добавить порт)"
        echo -e "  ${CYAN}[8]${NC}  Повторно обнаружить Telemt"
        echo ""
        echo -e "  ${RED}[u]${NC}  Удалить"
        echo -e "  ${CYAN}[0]${NC}  Выход"
        echo ""
        echo -en "  Выбор: "
        local _choice
        read -r _choice

        case "$_choice" in
            1)
                if [ -z "$SERVER_PORT" ]; then
                    log_error "Порт не задан — настройте в разделе Настройки"
                    read -rsn1; continue
                fi
                apply_nft_rules || true
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                ;;
            2)
                apply_tuning || true
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
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
                [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
                [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ] && SERVER_IP="$DETECTED_IP"
                if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
                    NFT_HOOK="forward"
                else
                    NFT_HOOK="input"
                fi
                save_settings
                log_success "Обнаружено: режим=$DETECTED_MODE порт=$DETECTED_PORT"
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                ;;
            u|U) full_uninstall ;;
            0|q|Q) exit 0 ;;
        esac
    done
}

show_settings_menu() {
    while true; do
        show_header
        echo -e "  ${BOLD}Настройки${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} IP сервера      [${SERVER_IP:-любой}]"
        echo -e "  ${DIM}[2]${NC} Порт            [${SERVER_PORT:-не задан}]"
        echo -e "  ${DIM}[3]${NC} Rate             [${NFT_RATE}]"
        echo -e "  ${DIM}[4]${NC} Burst            [${NFT_BURST}]"
        echo -e "  ${DIM}[5]${NC} Meter timeout    [${NFT_METER_TIMEOUT}]"
        echo -e "  ${DIM}[6]${NC} tg_connect       [${TUNING_TG_CONNECT}]"
        echo -e "  ${DIM}[7]${NC} client_handshake [${TUNING_CLIENT_HANDSHAKE}]"
        echo -e "  ${DIM}[8]${NC} client_keepalive [${TUNING_CLIENT_KEEPALIVE}]"
        echo -e "  ${DIM}[9]${NC} Определить IP из интернета"
        echo -e "  ${DIM}[c]${NC} Очистить IP (применять ко всем адресам)"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        echo -en "  Выбор: "
        local _choice
        read -r _choice

        case "$_choice" in
            1)
                echo -en "  Новый IP [${SERVER_IP:-пусто}]: "
                local _val; read -r _val
                [ -n "$_val" ] && SERVER_IP="$_val"
                save_settings
                ;;
            2)
                echo -en "  Новый порт [${SERVER_PORT:-}]: "
                local _val; read -r _val
                if [[ "$_val" =~ ^[0-9]+$ ]] && [ "$_val" -ge 1 ] && [ "$_val" -le 65535 ]; then
                    SERVER_PORT="$_val"
                    save_settings
                elif [ -n "$_val" ]; then
                    log_error "Некорректный порт"
                fi
                ;;
            3)
                echo -en "  Новый rate (напр. 1/second, 2/second): "
                local _val; read -r _val
                [ -n "$_val" ] && NFT_RATE="$_val" && save_settings
                ;;
            4)
                echo -en "  Новый burst: "
                local _val; read -r _val
                [[ "$_val" =~ ^[0-9]+$ ]] && NFT_BURST="$_val" && save_settings
                ;;
            5)
                echo -en "  Новый meter timeout (напр. 30s, 60s, 120s): "
                local _val; read -r _val
                [ -n "$_val" ] && NFT_METER_TIMEOUT="$_val" && save_settings
                ;;
            6)
                echo -en "  tg_connect [${TUNING_TG_CONNECT}]: "
                local _val; read -r _val
                [[ "$_val" =~ ^[0-9]+$ ]] && TUNING_TG_CONNECT="$_val" && save_settings
                ;;
            7)
                echo -en "  client_handshake [${TUNING_CLIENT_HANDSHAKE}]: "
                local _val; read -r _val
                [[ "$_val" =~ ^[0-9]+$ ]] && TUNING_CLIENT_HANDSHAKE="$_val" && save_settings
                ;;
            8)
                echo -en "  client_keepalive [${TUNING_CLIENT_KEEPALIVE}]: "
                local _val; read -r _val
                [[ "$_val" =~ ^[0-9]+$ ]] && TUNING_CLIENT_KEEPALIVE="$_val" && save_settings
                ;;
            9)
                log_info "Определение публичного IP..."
                local _detected_ip
                _detected_ip=$(detect_public_ip)
                if [ -n "$_detected_ip" ]; then
                    SERVER_IP="$_detected_ip"
                    save_settings
                    log_success "IP определён: $_detected_ip"
                else
                    log_error "Не удалось определить публичный IP"
                fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                ;;
            c|C)
                SERVER_IP=""
                save_settings
                log_success "IP очищен — правила будут применяться ко всем адресам"
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                ;;
            0|"") return ;;
        esac
    done
}

show_preset_menu() {
    show_header
    echo -e "  ${BOLD}Пресеты скорости${NC}"
    echo ""
    echo -e "  ${RED}[1]${NC} Жёсткий  — 1/second burst 1   ${DIM}(макс. ограничение)${NC}"
    echo -e "  ${YELLOW}[2]${NC} Средний  — 1/second burst 3   ${DIM}(баланс)${NC}"
    echo -e "  ${GREEN}[3]${NC} Мягкий   — 2/second burst 5   ${DIM}(мин. ограничение)${NC}"
    echo -e "  ${DIM}[4]${NC} Свой вариант"
    echo -e "  ${DIM}[0]${NC} Назад"
    echo ""
    echo -en "  Выбор: "
    local _choice
    read -r _choice

    case "$_choice" in
        1) apply_preset hard ;;
        2) apply_preset medium ;;
        3) apply_preset soft ;;
        4)
            echo -en "  Rate (напр. 1/second): "
            local _r; read -r _r
            echo -en "  Burst: "
            local _b; read -r _b
            [ -n "$_r" ] && NFT_RATE="$_r"
            [[ "$_b" =~ ^[0-9]+$ ]] && NFT_BURST="$_b"
            save_settings
            log_success "Свой вариант: rate=$NFT_RATE burst=$NFT_BURST"
            ;;
        0|"") return ;;
    esac

    echo ""
    echo -en "  Применить NFT правила сейчас? [Y/n]: "
    local _yn; read -r _yn
    if [[ ! "$_yn" =~ ^[nN] ]]; then
        apply_nft_rules || true
        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
    fi
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

show_service_menu() {
    show_header
    echo -e "  ${BOLD}Управление службой${NC}"
    echo ""

    local _status="${DIM}не установлена${NC}"
    if systemctl is-enabled "$SYSTEMD_UNIT" &>/dev/null 2>&1; then
        if systemctl is-active "$SYSTEMD_UNIT" &>/dev/null 2>&1; then
            _status="${GREEN}вкл + работает${NC}"
        else
            _status="${YELLOW}вкл + остановлена${NC}"
        fi
    fi
    echo -e "  Статус: ${_status}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Установить и включить службу"
    echo -e "  ${DIM}[2]${NC} Удалить службу"
    echo -e "  ${DIM}[3]${NC} Перезапустить службу"
    echo -e "  ${DIM}[4]${NC} Остановить службу (правила сохранятся)"
    echo -e "  ${DIM}[5]${NC} Логи службы"
    echo -e "  ${DIM}[0]${NC} Назад"
    echo ""
    echo -en "  Выбор: "
    local _choice
    read -r _choice

    case "$_choice" in
        1)
            if [ -z "$SERVER_PORT" ]; then
                log_error "Порт не задан — настройте в разделе Настройки"
            else
                install_service
            fi
            ;;
        2) remove_service ;;
        3) systemctl restart "$SYSTEMD_UNIT" 2>/dev/null && log_success "Служба перезапущена" || log_error "Не удалось перезапустить" ;;
        4) systemctl stop "$SYSTEMD_UNIT" 2>/dev/null && log_success "Служба остановлена" || log_error "Не удалось остановить" ;;
        5)
            echo ""
            journalctl -u "$SYSTEMD_UNIT" -n 20 --no-pager 2>/dev/null || log_warn "Логов нет"
            ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

show_extra_rules_menu() {
    while true; do
        show_header
        echo -e "  ${BOLD}Дополнительные правила${NC}"
        echo ""

        if [ "$EXTRA_RULES_COUNT" -eq 0 ]; then
            echo -e "  ${DIM}Нет дополнительных правил${NC}"
        else
            local _i
            for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
                echo -e "    ${DIM}[$_i]${NC} порт=${EXTRA_RULES_PORT[$_i]:-?}  ip=${EXTRA_RULES_IP[$_i]:-любой}  rate=${EXTRA_RULES_RATE[$_i]:-?}  burst=${EXTRA_RULES_BURST[$_i]:-?}"
            done
        fi

        echo ""
        echo -e "  ${DIM}[a]${NC} Добавить правило"
        echo -e "  ${DIM}[d]${NC} Удалить правило"
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        echo -en "  Выбор: "
        local _choice
        read -r _choice

        case "$_choice" in
            a|A)
                echo -en "  Порт: "
                local _p; read -r _p
                if ! [[ "$_p" =~ ^[0-9]+$ ]] || [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
                    log_error "Некорректный порт"; echo ""; read -rsn1 -p "  Нажмите любую клавишу..."; continue
                fi
                echo -en "  IP (пусто = любой): "
                local _eip; read -r _eip
                echo -en "  Rate [1/second]: "
                local _r; read -r _r; [ -z "$_r" ] && _r="1/second"
                echo -en "  Burst [1]: "
                local _b; read -r _b; [ -z "$_b" ] && _b="1"

                EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT + 1))
                local _idx=$EXTRA_RULES_COUNT
                EXTRA_RULES_PORT[$_idx]="$_p"
                EXTRA_RULES_IP[$_idx]="$_eip"
                EXTRA_RULES_RATE[$_idx]="$_r"
                EXTRA_RULES_BURST[$_idx]="$_b"
                save_settings
                log_success "Доп. правило $_idx добавлено"

                echo -en "  Применить правила сейчас? [Y/n]: "
                local _yn; read -r _yn
                if [[ ! "$_yn" =~ ^[nN] ]]; then
                    apply_nft_rules || true
                    [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
                fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                ;;
            d|D)
                [ "$EXTRA_RULES_COUNT" -eq 0 ] && { log_info "Нет правил для удаления"; echo ""; read -rsn1 -p "  Нажмите любую клавишу..."; continue; }
                echo -en "  Номер правила для удаления: "
                local _idx; read -r _idx
                if [[ "$_idx" =~ ^[0-9]+$ ]] && [ "$_idx" -ge 1 ] && [ "$_idx" -le "$EXTRA_RULES_COUNT" ]; then
                    local _i
                    for _i in $(seq "$_idx" $((EXTRA_RULES_COUNT - 1))); do
                        local _next=$((_i + 1))
                        EXTRA_RULES_PORT[$_i]="${EXTRA_RULES_PORT[$_next]:-}"
                        EXTRA_RULES_IP[$_i]="${EXTRA_RULES_IP[$_next]:-}"
                        EXTRA_RULES_RATE[$_i]="${EXTRA_RULES_RATE[$_next]:-}"
                        EXTRA_RULES_BURST[$_i]="${EXTRA_RULES_BURST[$_next]:-}"
                    done
                    unset "EXTRA_RULES_PORT[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_IP[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_RATE[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_BURST[$EXTRA_RULES_COUNT]"
                    EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT - 1))
                    save_settings
                    log_success "Правило удалено"

                    echo -en "  Применить правила заново? [Y/n]: "
                    local _yn; read -r _yn
                    if [[ ! "$_yn" =~ ^[nN] ]]; then
                        apply_nft_rules || true
                        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
                    fi
                else
                    log_error "Некорректный номер правила"
                fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                ;;
            0|"") return ;;
        esac
    done
}

# ── Мастер первого запуска ────────────────────────────────────

first_run_wizard() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}Мастер первоначальной настройки${NC}"
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo ""

    # Шаг 1: Обнаружение
    log_info "Поиск установленного Telemt..."
    if detect_telemt; then
        log_success "Найден: ${DETECTED_MODE}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
        [ -n "$DETECTED_CONFIG_PATH" ] && log_info "Конфиг: ${DETECTED_CONFIG_PATH}"
        [ -n "$DETECTED_PORT" ] && log_info "Порт: ${DETECTED_PORT}"
        [ -n "$DETECTED_NETWORK_MODE" ] && log_info "Сеть: ${DETECTED_NETWORK_MODE}"
    else
        log_warn "Telemt не обнаружен автоматически"
    fi

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        NFT_HOOK="forward"
    else
        NFT_HOOK="input"
    fi

    # Шаг 2: Зависимости
    echo ""
    install_dependencies || exit 1

    # Шаг 3: Порт
    echo ""
    SERVER_PORT="${DETECTED_PORT:-443}"
    echo -en "  ${BOLD}Порт прокси [${SERVER_PORT}]:${NC} "
    local _port_input
    read -r _port_input
    if [[ "$_port_input" =~ ^[0-9]+$ ]] && [ "$_port_input" -ge 1 ] && [ "$_port_input" -le 65535 ]; then
        SERVER_PORT="$_port_input"
    fi

    # Шаг 4: IP
    echo ""
    if [ -n "$DETECTED_IP" ]; then
        SERVER_IP="$DETECTED_IP"
        log_info "IP из конфига: $SERVER_IP"
    else
        log_info "Определение публичного IP..."
        SERVER_IP=$(detect_public_ip)
        [ -n "$SERVER_IP" ] && log_success "Определён: $SERVER_IP" || log_warn "Не удалось определить IP"
    fi
    echo -en "  ${BOLD}IP сервера [${SERVER_IP:-оставьте пустым для всех}]:${NC} "
    local _ip_input
    read -r _ip_input
    [ -n "$_ip_input" ] && SERVER_IP="$_ip_input"

    # Шаг 5: Пресет
    echo ""
    echo -e "  ${BOLD}Пресет ограничения:${NC}"
    echo -e "    ${RED}[1]${NC} Жёсткий  — 1/sec burst 1  ${DIM}(рекомендуется)${NC}"
    echo -e "    ${YELLOW}[2]${NC} Средний  — 1/sec burst 3"
    echo -e "    ${GREEN}[3]${NC} Мягкий   — 2/sec burst 5"
    echo ""
    echo -en "  Выбор [1]: "
    local _preset_input
    read -r _preset_input
    case "$_preset_input" in
        2) apply_preset medium ;;
        3) apply_preset soft ;;
        *) apply_preset hard ;;
    esac

    # Сохранить
    save_settings

    # Шаг 6: Применить тюнинг
    echo ""
    echo -en "  ${BOLD}Применить тюнинг Telemt? [Y/n]:${NC} "
    local _yn_tuning
    read -r _yn_tuning
    if [[ ! "$_yn_tuning" =~ ^[nN] ]]; then
        apply_tuning || true
    fi

    # Шаг 7: Применить NFT
    echo ""
    echo -en "  ${BOLD}Применить NFT правила сейчас? [Y/n]:${NC} "
    local _yn_nft
    read -r _yn_nft
    if [[ ! "$_yn_nft" =~ ^[nN] ]]; then
        apply_nft_rules || true
    fi

    # Шаг 8: Установить службу
    echo ""
    echo -en "  ${BOLD}Установить как службу (автозапуск при загрузке)? [Y/n]:${NC} "
    local _yn_svc
    read -r _yn_svc
    if [[ ! "$_yn_svc" =~ ^[nN] ]]; then
        install_service || true
    fi

    echo ""
    log_success "Настройка завершена!"
    echo ""
    echo -e "  ${DIM}Запускайте ${CYAN}mtpr${DIM} в любое время для управления${NC}"
    echo ""
    read -rsn1 -p "  Нажмите любую клавишу для входа в меню..."
}

# ── Главная точка входа ───────────────────────────────────────

main() {
    check_root

    mkdir -p "$INSTALL_DIR"

    # Копируем себя в директорию установки
    local _self="${BASH_SOURCE[0]}"
    if [ -f "$_self" ] && [ "$(realpath "$_self" 2>/dev/null)" != "$(realpath "${INSTALL_DIR}/mtpr.sh" 2>/dev/null)" ]; then
        cp "$_self" "${INSTALL_DIR}/mtpr.sh"
        chmod +x "${INSTALL_DIR}/mtpr.sh"
    fi

    # Создаём симлинк
    ln -sf "${INSTALL_DIR}/mtpr.sh" /usr/local/bin/mtpr 2>/dev/null || true

    # Загружаем настройки
    load_settings

    # Обнаруживаем telemt
    detect_telemt || true

    # Автозаполнение из обнаружения
    [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
    [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ] && SERVER_IP="$DETECTED_IP"
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        NFT_HOOK="forward"
    else
        NFT_HOOK="input"
    fi

    # Первый запуск?
    if [ ! -f "$SETTINGS_FILE" ]; then
        first_run_wizard
    fi

    # Показать меню
    show_main_menu
}

main "$@"
