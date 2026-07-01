#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MTproxy-reanimation v1.1.1
#  Telemt inbound SYN limiter + tuning manager
#  https://github.com/Liafanx/MTproxy-reanimation
# ═══════════════════════════════════════════════════════════════
set -eo pipefail

VERSION="1.1.1"
GITHUB_RAW="https://raw.githubusercontent.com/Liafanx/MTproxy-reanimation/main"
INSTALL_DIR="/opt/mtproxy-reanimation"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
NFT_SCRIPT="/usr/local/sbin/mtpr-syn-limit.sh"
SYSTEMD_UNIT="mtpr-syn-limit.service"
IOS_SYSCTL_FILE="/etc/sysctl.d/99-tg-keepalive.conf"

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
NFT_MODE="classic"
NFT_IOS_RATE="15/second"
NFT_IOS_BURST="30"
NFT_OTHER_RATE="54/minute"
NFT_OTHER_BURST="1"
NFT_IOS_LIMIT_ENABLED="true"
NFT_OTHER_LIMIT_ENABLED="true"
NFT_OTHER_ACTION="icmp-host-unreachable"
NFT_IOS_DETECT="fingerprint"

TUNING_TG_CONNECT="30"
TUNING_CLIENT_HANDSHAKE="90"
TUNING_CLIENT_KEEPALIVE="120"
TUNING_APPLIED="false"
NFT_SERVICE_ENABLED="false"
IOS_FIX_APPLIED="false"
IOS_KA_TIME="60"
IOS_KA_INTVL="15"
IOS_KA_PROBES="3"
IOS_ORIG_TIME=""
IOS_ORIG_INTVL=""
IOS_ORIG_PROBES=""
IOS2_FIX_APPLIED="false"
IOS2_EXTERNAL_PORT="4443"
IOS2_TARGET_PORT=""
IOS2_MSS="92"
IOS2_TABLE="mtpr_ios2_fix"
DOCKER_BRIDGE_MODE="simple"
BRIDGE_WATCH_INTERVAL="5"
WATCHER_SCRIPT="/usr/local/sbin/mtpr-bridge-watch.sh"
WATCHER_UNIT="mtpr-bridge-watch.service"

# Оптимизация By-MEKO
MEKO_OPT_FILE="/etc/sysctl.d/99-mtpr-meko-opt.conf"
MEKO_OPT_APPLIED="false"
MEKO_ORIG_KEEPALIVE_TIME=""
MEKO_ORIG_KEEPALIVE_INTVL=""
MEKO_ORIG_KEEPALIVE_PROBES=""
MEKO_ORIG_SOMAXCONN=""
MEKO_ORIG_TCP_MAX_SYN_BACKLOG=""
MEKO_ORIG_NETDEV_MAX_BACKLOG=""
MEKO_ORIG_TCP_FASTOPEN=""
MEKO_ORIG_FILE_MAX=""
MEKO_ORIG_DEFAULT_QDISC=""
MEKO_ORIG_TCP_CONGESTION=""

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
NFT_MODE='${NFT_MODE}'
NFT_IOS_RATE='${NFT_IOS_RATE}'
NFT_IOS_BURST='${NFT_IOS_BURST}'
NFT_OTHER_RATE='${NFT_OTHER_RATE}'
NFT_OTHER_BURST='${NFT_OTHER_BURST}'
NFT_IOS_LIMIT_ENABLED='${NFT_IOS_LIMIT_ENABLED}'
NFT_OTHER_LIMIT_ENABLED='${NFT_OTHER_LIMIT_ENABLED}'
NFT_OTHER_ACTION='${NFT_OTHER_ACTION}'
NFT_IOS_DETECT='${NFT_IOS_DETECT}'
TUNING_TG_CONNECT='${TUNING_TG_CONNECT}'
TUNING_CLIENT_HANDSHAKE='${TUNING_CLIENT_HANDSHAKE}'
TUNING_CLIENT_KEEPALIVE='${TUNING_CLIENT_KEEPALIVE}'
TUNING_APPLIED='${TUNING_APPLIED}'
NFT_SERVICE_ENABLED='${NFT_SERVICE_ENABLED}'
IOS_FIX_APPLIED='${IOS_FIX_APPLIED}'
IOS_KA_TIME='${IOS_KA_TIME}'
IOS_KA_INTVL='${IOS_KA_INTVL}'
IOS_KA_PROBES='${IOS_KA_PROBES}'
IOS_ORIG_TIME='${IOS_ORIG_TIME}'
IOS_ORIG_INTVL='${IOS_ORIG_INTVL}'
IOS_ORIG_PROBES='${IOS_ORIG_PROBES}'
IOS2_FIX_APPLIED='${IOS2_FIX_APPLIED}'
IOS2_EXTERNAL_PORT='${IOS2_EXTERNAL_PORT}'
IOS2_TARGET_PORT='${IOS2_TARGET_PORT}'
IOS2_MSS='${IOS2_MSS}'
IOS2_TABLE='${IOS2_TABLE}'
MEKO_OPT_APPLIED='${MEKO_OPT_APPLIED}'
MEKO_ORIG_KEEPALIVE_TIME='${MEKO_ORIG_KEEPALIVE_TIME}'
MEKO_ORIG_KEEPALIVE_INTVL='${MEKO_ORIG_KEEPALIVE_INTVL}'
MEKO_ORIG_KEEPALIVE_PROBES='${MEKO_ORIG_KEEPALIVE_PROBES}'
MEKO_ORIG_SOMAXCONN='${MEKO_ORIG_SOMAXCONN}'
MEKO_ORIG_TCP_MAX_SYN_BACKLOG='${MEKO_ORIG_TCP_MAX_SYN_BACKLOG}'
MEKO_ORIG_NETDEV_MAX_BACKLOG='${MEKO_ORIG_NETDEV_MAX_BACKLOG}'
MEKO_ORIG_TCP_FASTOPEN='${MEKO_ORIG_TCP_FASTOPEN}'
MEKO_ORIG_FILE_MAX='${MEKO_ORIG_FILE_MAX}'
MEKO_ORIG_DEFAULT_QDISC='${MEKO_ORIG_DEFAULT_QDISC}'
MEKO_ORIG_TCP_CONGESTION='${MEKO_ORIG_TCP_CONGESTION}'
DOCKER_BRIDGE_MODE='${DOCKER_BRIDGE_MODE}'
BRIDGE_WATCH_INTERVAL='${BRIDGE_WATCH_INTERVAL}'
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
                NFT_MODE|NFT_IOS_RATE|NFT_IOS_BURST|NFT_OTHER_RATE|NFT_OTHER_BURST|NFT_OTHER_ACTION|NFT_IOS_DETECT|\
                TUNING_CLIENT_KEEPALIVE|TUNING_APPLIED|NFT_SERVICE_ENABLED|\
                IOS_FIX_APPLIED|IOS_KA_TIME|IOS_KA_INTVL|IOS_KA_PROBES|\
                IOS_ORIG_TIME|IOS_ORIG_INTVL|IOS_ORIG_PROBES|\
                IOS2_FIX_APPLIED|IOS2_EXTERNAL_PORT|\
                IOS2_TARGET_PORT|IOS2_MSS|IOS2_TABLE|\
                DOCKER_BRIDGE_MODE|BRIDGE_WATCH_INTERVAL|EXTRA_RULES_COUNT|\
                MEKO_OPT_APPLIED|\
                MEKO_ORIG_KEEPALIVE_TIME|MEKO_ORIG_KEEPALIVE_INTVL|MEKO_ORIG_KEEPALIVE_PROBES|\
                MEKO_ORIG_SOMAXCONN|MEKO_ORIG_TCP_MAX_SYN_BACKLOG|MEKO_ORIG_NETDEV_MAX_BACKLOG|\
                MEKO_ORIG_TCP_FASTOPEN|MEKO_ORIG_FILE_MAX|\
                MEKO_ORIG_DEFAULT_QDISC|MEKO_ORIG_TCP_CONGESTION|NFT_IOS_LIMIT_ENABLED|NFT_OTHER_LIMIT_ENABLED)
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
    case "$NFT_MODE" in
        classic|smart) ;;
        *) NFT_MODE="classic" ;;
    esac
    case "$NFT_OTHER_ACTION" in
        reject|drop|icmp-host-unreachable) ;;
        *) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
    esac
    case "$NFT_IOS_DETECT" in
        fingerprint|ttl) ;;
        *) NFT_IOS_DETECT="fingerprint" ;;
    esac
}

# ── Безопасное чтение значения из TOML ────────────────────────
_toml_get_value() {
    local _key="$1" _file="$2"
    [ -f "$_file" ] || return 0
    awk -v k="$_key" '
        /^[[:space:]]*#/ { next }
        $1 == k && $2 == "=" { gsub(/[^0-9]/, "", $3); print $3; exit }
    ' "$_file" 2>/dev/null
}

_toml_has_section() {
    local _section="$1" _file="$2"
    grep -qE "^\\[${_section}\\]" "$_file" 2>/dev/null
}

_toml_has_key() {
    local _key="$1" _file="$2"
    grep -qE "^${_key}[[:space:]]*=" "$_file" 2>/dev/null
}

_toml_safe_set() {
    local _key="$1" _value="$2" _section="$3" _file="$4"
    [ -f "$_file" ] || return 1
    if _toml_has_key "$_key" "$_file"; then
        sed -i "s/^${_key}[[:space:]]*=.*/${_key} = ${_value}/" "$_file"
        return 0
    fi
    if _toml_has_section "$_section" "$_file"; then
        sed -i "/^\\[${_section}\\]/a ${_key} = ${_value}" "$_file"
        return 0
    fi
    return 1
}

# ── Обнаружение Telemt ────────────────────────────────────────
_is_excluded_path() {
    local _path="$1"
    case "$_path" in
        *telemt-panel*|*telemt_panel*) return 0 ;;
    esac
    return 1
}

_looks_like_telemt_config() {
    local _file="$1"
    [ -f "$_file" ] || return 1
    grep -qE '^\[access\.users\]|^\[censorship\]|^\[general\.modes\]|^tls_domain[[:space:]]*=' "$_file" 2>/dev/null
}

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
        if command -v docker &>/dev/null && docker inspect mtproxymax &>/dev/null 2>&1; then
            if docker inspect -f '{{.HostConfig.NetworkMode}}' mtproxymax 2>/dev/null | grep -q "host"; then
                DETECTED_NETWORK_MODE="host"
            else
                DETECTED_NETWORK_MODE="bridge"
            fi
        else
            DETECTED_NETWORK_MODE="host"
        fi
        DETECTED_CONTAINER="mtproxymax"
        return 0
    fi

    # 2. Docker-контейнер с telemt
    if command -v docker &>/dev/null; then
        local _cname
        for _cname in $(docker ps --format '{{.Names}}' 2>/dev/null); do
            case "$_cname" in *panel*|*telemt-panel*|*telemt_panel*) continue ;; esac
            local _inspect
            _inspect=$(docker inspect "$_cname" 2>/dev/null) || continue
            local _is_telemt=false
            local _inspect_no_panel
            _inspect_no_panel=$(echo "$_inspect" | grep -viE 'panel')
            if echo "$_inspect_no_panel" | grep -qiE '"Image".*telemt'; then
                _is_telemt=true
            elif echo "$_inspect_no_panel" | grep -qiE 'telemt\.toml|telemt/telemt'; then
                _is_telemt=true
            elif echo "$_inspect_no_panel" | grep -qiE '"Cmd".*telemt'; then
                _is_telemt=true
            fi
            [ "$_is_telemt" = "false" ] && continue
            DETECTED_MODE="docker"
            DETECTED_CONTAINER="$_cname"
            local _mount _candidate
            local _dests="/etc/telemt.toml /etc/telemt /etc/telemt/telemt.toml /app/config.toml"
            for _dest in $_dests; do
                _mount=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"${_dest}\"}}{{.Source}}{{end}}{{end}}" "$_cname" 2>/dev/null)
                [ -z "$_mount" ] && continue
                if [ -d "$_mount" ]; then
                    for _candidate in "${_mount}/config.toml" "${_mount}/telemt.toml"; do
                        if [ -f "$_candidate" ] && ! _is_excluded_path "$_candidate" && _looks_like_telemt_config "$_candidate"; then
                            DETECTED_CONFIG_PATH="$_candidate"
                            break 2
                        fi
                    done
                elif [ -f "$_mount" ] && ! _is_excluded_path "$_mount" && _looks_like_telemt_config "$_mount"; then
                    DETECTED_CONFIG_PATH="$_mount"
                    break
                fi
            done
            local _nm
            _nm=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$_cname" 2>/dev/null)
            if [ "$_nm" = "host" ]; then
                DETECTED_NETWORK_MODE="host"
            else
                DETECTED_NETWORK_MODE="bridge"
            fi
            if [ -f "$DETECTED_CONFIG_PATH" ]; then
                local _p
                _p=$(_toml_get_value "port" "$DETECTED_CONFIG_PATH")
                [ -n "$_p" ] && DETECTED_PORT="$_p"
            fi
            return 0
        done
    fi

    # 3. Локальный процесс telemt
    if pgrep -x telemt &>/dev/null || systemctl is-active telemt.service &>/dev/null 2>&1; then
        DETECTED_MODE="local"
        DETECTED_NETWORK_MODE="host"
        local _args
        _args=$(ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -v 'telemt_panel' | head -1 | grep -oE '/[^ ]+\.toml' | head -1)
        if [ -n "$_args" ] && [ -f "$_args" ] && ! _is_excluded_path "$_args" && _looks_like_telemt_config "$_args"; then
            DETECTED_CONFIG_PATH="$_args"
        fi
        if [ -z "$DETECTED_CONFIG_PATH" ]; then
            local _cf
            for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml; do
                if [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
                    DETECTED_CONFIG_PATH="$_cf"
                    break
                fi
            done
        fi
        if [ -f "$DETECTED_CONFIG_PATH" ]; then
            local _p
            _p=$(_toml_get_value "port" "$DETECTED_CONFIG_PATH")
            [ -n "$_p" ] && DETECTED_PORT="$_p"
        fi
        return 0
    fi

    # 4. Только конфиг
    local _cf
    for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml \
               /opt/telemt/config.toml /opt/telemt/telemt.toml \
               /opt/mtproxymax/mtproxy/config.toml; do
        if [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
            DETECTED_CONFIG_PATH="$_cf"
            DETECTED_MODE="config_only"
            DETECTED_NETWORK_MODE="host"
            local _p
            _p=$(_toml_get_value "port" "$_cf")
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

docker_container_ip() {
    local _container="${1:-$DETECTED_CONTAINER}"
    [ -z "$_container" ] && return 1
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
        "$_container" 2>/dev/null | awk 'NF {print; exit}'
}

service_unit_name() {
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ] && [ "${DOCKER_BRIDGE_MODE:-simple}" = "precise" ]; then
        echo "$WATCHER_UNIT"
    else
        echo "$SYSTEMD_UNIT"
    fi
}

prompt_bridge_mode() {
    if [ "$DETECTED_NETWORK_MODE" != "bridge" ]; then
        return 0
    fi
    echo ""
    echo -e "  ${BOLD}Обнаружен Docker bridge режим${NC}"
    echo ""
    echo -e "  ${DIM}[1]${NC} Простой режим — без IP, правило только по порту"
    echo -e "      ${DIM}Плюсы:${NC} надёжно, без watcher, меньше зависимостей"
    echo -e "      ${DIM}Минусы:${NC} менее точное совпадение"
    echo ""
    echo -e "  ${DIM}[2]${NC} Точный Docker-режим — внутренний IP контейнера + watcher"
    echo -e "      ${DIM}Плюсы:${NC} точное совпадение по контейнеру"
    echo -e "      ${DIM}Минусы:${NC} нужен watcher, так как IP контейнера может меняться"
    echo ""
    echo -en "  ${BOLD}Выбор [по умолчанию 1]:${NC} "
    local _bm
    read -r _bm
    case "$_bm" in
        2) DOCKER_BRIDGE_MODE="precise" ;;
        *) DOCKER_BRIDGE_MODE="simple" ;;
    esac
    save_settings
    if [ "$DOCKER_BRIDGE_MODE" = "simple" ]; then
        log_info "Выбран простой bridge-режим — IP привязка не используется"
    else
        local _cip
        _cip=$(docker_container_ip)
        [ -n "$_cip" ] && log_info "Выбран точный bridge-режим — контейнерный IP: ${_cip}"
    fi
}

validate_ip_literal() {
    local _ip="$1"
    if [[ "$_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local _a _b _c _d
        read -r _a _b _c _d <<< "$_ip"
        for _octet in "$_a" "$_b" "$_c" "$_d"; do
            [[ "$_octet" =~ ^[0-9]+$ ]] || return 1
            [ "$_octet" -ge 0 ] && [ "$_octet" -le 255 ] || return 1
        done
        return 0
    fi
    return 1
}

# ── Зависимости ───────────────────────────────────────────────
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
            _changed=true; log_success "tg_connect = $TUNING_TG_CONNECT"
        else log_info "tg_connect уже $TUNING_TG_CONNECT"; fi

        _cur=$(mtproxymax tune get client_handshake 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
            echo "n" | mtproxymax tune set client_handshake "$TUNING_CLIENT_HANDSHAKE" &>/dev/null || true
            _changed=true; log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
        else log_info "client_handshake уже $TUNING_CLIENT_HANDSHAKE"; fi

        _cur=$(mtproxymax tune get client_keepalive 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' ')
        if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
            echo "n" | mtproxymax tune set client_keepalive "$TUNING_CLIENT_KEEPALIVE" &>/dev/null || true
            _changed=true; log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
        else log_info "client_keepalive уже $TUNING_CLIENT_KEEPALIVE"; fi

        if [ "$_changed" = "true" ]; then
            log_info "Перезапуск MTProxyMax..."
            mtproxymax restart &>/dev/null || log_warn "Не удалось перезапустить"
        fi
        TUNING_APPLIED="true"; save_settings; return 0
    fi

    if [ -z "$DETECTED_CONFIG_PATH" ] || [ ! -f "$DETECTED_CONFIG_PATH" ]; then
        log_warn "Файл конфигурации не найден — невозможно применить тюнинг автоматически"
        echo ""; echo -e "  ${BOLD}Добавьте в config.toml вручную:${NC}"; echo ""
        echo "  [general]"; echo "  tg_connect = $TUNING_TG_CONNECT"; echo ""
        echo "  [timeouts]"; echo "  client_handshake = $TUNING_CLIENT_HANDSHAKE"
        echo "  client_keepalive = $TUNING_CLIENT_KEEPALIVE"; echo ""
        TUNING_APPLIED="manual"; save_settings; return 0
    fi

    echo ""; echo -e "  ${BOLD}Обнаруженный конфиг:${NC} ${DETECTED_CONFIG_PATH}"
    if ! _looks_like_telemt_config "$DETECTED_CONFIG_PATH"; then
        log_error "Файл ${DETECTED_CONFIG_PATH} не похож на конфиг Telemt"
        log_info "Пропускаю автоматический тюнинг"
        echo ""; echo -e "  ${BOLD}Добавьте в конфиг Telemt вручную:${NC}"; echo ""
        echo "  [general]"; echo "  tg_connect = $TUNING_TG_CONNECT"; echo ""
        echo "  [timeouts]"; echo "  client_handshake = $TUNING_CLIENT_HANDSHAKE"
        echo "  client_keepalive = $TUNING_CLIENT_KEEPALIVE"; echo ""
        TUNING_APPLIED="manual"; save_settings; return 0
    fi

    echo -en "  ${BOLD}Редактировать этот файл? [Y/n/p(указать путь)]:${NC} "
    local _confirm_cfg; read -r _confirm_cfg
    case "$_confirm_cfg" in
        n|N)
            log_info "Пропущено. Добавьте параметры вручную."
            echo ""; echo "  [general]"; echo "  tg_connect = $TUNING_TG_CONNECT"; echo ""
            echo "  [timeouts]"; echo "  client_handshake = $TUNING_CLIENT_HANDSHAKE"
            echo "  client_keepalive = $TUNING_CLIENT_KEEPALIVE"; echo ""
            TUNING_APPLIED="manual"; save_settings; return 0 ;;
        p|P)
            echo -en "  Путь к конфигу Telemt: "; local _custom_path; read -r _custom_path
            if [ -f "$_custom_path" ] && _looks_like_telemt_config "$_custom_path"; then
                DETECTED_CONFIG_PATH="$_custom_path"; log_success "Конфиг принят: $_custom_path"
            elif [ -f "$_custom_path" ]; then
                log_warn "Файл не похож на конфиг Telemt, но используем его"
                DETECTED_CONFIG_PATH="$_custom_path"
            else
                log_error "Файл не найден: $_custom_path"
                TUNING_APPLIED="manual"; save_settings; return 0
            fi ;;
    esac

    local _cfg="$DETECTED_CONFIG_PATH"
    cp "$_cfg" "${_cfg}.mtpr-backup-$(date +%s)" 2>/dev/null || true
    local _cur _changed=false _failed=false _timeouts_created=false

    _cur=$(_toml_get_value "tg_connect" "$_cfg")
    if [ "$_cur" != "$TUNING_TG_CONNECT" ]; then
        if _toml_safe_set "tg_connect" "$TUNING_TG_CONNECT" "general" "$_cfg"; then
            _changed=true; log_success "tg_connect = $TUNING_TG_CONNECT"
        else
            log_warn "Секция [general] не найдена в конфиге"
            echo -en "  ${BOLD}Создать секцию [general] и применить tg_connect? [Y/n]:${NC} "
            local _cr; read -r _cr
            if [[ ! "$_cr" =~ ^[nN]$ ]]; then
                printf '\n[general]\ntg_connect = %s\n' "$TUNING_TG_CONNECT" >> "$_cfg"
                _changed=true
                log_success "Секция [general] создана, tg_connect = $TUNING_TG_CONNECT"
            else
                _failed=true
            fi
        fi
    else log_info "tg_connect уже $TUNING_TG_CONNECT"; fi

    _cur=$(_toml_get_value "client_handshake" "$_cfg")
    if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
        if _toml_safe_set "client_handshake" "$TUNING_CLIENT_HANDSHAKE" "timeouts" "$_cfg"; then
            _changed=true; log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
        else
            log_warn "Секция [timeouts] не найдена в конфиге"
            echo -en "  ${BOLD}Создать секцию [timeouts] и применить client_handshake + client_keepalive? [Y/n]:${NC} "
            local _cr; read -r _cr
            if [[ ! "$_cr" =~ ^[nN]$ ]]; then
                printf '\n[timeouts]\nclient_handshake = %s\nclient_keepalive = %s\n' \
                    "$TUNING_CLIENT_HANDSHAKE" "$TUNING_CLIENT_KEEPALIVE" >> "$_cfg"
                _changed=true
                _timeouts_created=true
                log_success "Секция [timeouts] создана"
            else
                _failed=true
            fi
        fi
    else log_info "client_handshake уже $TUNING_CLIENT_HANDSHAKE"; fi

    if [ "${_timeouts_created:-false}" != "true" ]; then
        _cur=$(_toml_get_value "client_keepalive" "$_cfg")
        if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
            if _toml_safe_set "client_keepalive" "$TUNING_CLIENT_KEEPALIVE" "timeouts" "$_cfg"; then
                _changed=true; log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
            else
                log_warn "Секция [timeouts] не найдена — client_keepalive не применён"
                _failed=true
            fi
        else log_info "client_keepalive уже $TUNING_CLIENT_KEEPALIVE"; fi
    fi

    if [ "$_failed" = "true" ]; then
        echo ""; echo -e "  ${YELLOW}Некоторые параметры не удалось применить автоматически.${NC}"
        echo -e "  ${BOLD}Добавьте вручную в ${_cfg}:${NC}"; echo ""
        echo "  [general]"; echo "  tg_connect = $TUNING_TG_CONNECT"; echo ""
        echo "  [timeouts]"; echo "  client_handshake = $TUNING_CLIENT_HANDSHAKE"
        echo "  client_keepalive = $TUNING_CLIENT_KEEPALIVE"; echo ""
    fi

    if [ "$_changed" = "true" ]; then
        if [ "$DETECTED_MODE" = "docker" ] && [ -n "$DETECTED_CONTAINER" ]; then
            log_info "Перезапуск контейнера $DETECTED_CONTAINER..."
            docker restart "$DETECTED_CONTAINER" &>/dev/null || log_warn "Не удалось перезапустить контейнер"
        elif [ "$DETECTED_MODE" = "local" ]; then
            if systemctl is-active telemt.service &>/dev/null 2>&1; then
                log_info "Перезапуск службы telemt..."
                systemctl restart telemt.service &>/dev/null || log_warn "Не удалось перезапустить службу"
            else
                log_info "Отправка SIGHUP процессу telemt..."
                pkill -HUP telemt 2>/dev/null || log_warn "Не удалось отправить сигнал"
            fi
        fi
    fi
    TUNING_APPLIED="true"
    [ "$_failed" = "true" ] && TUNING_APPLIED="partial"
    save_settings
}

# ── Фикс для iOS (TCP keepalive) ─────────────────────────────
ios_fix_status() {
    if [ -f "$IOS_SYSCTL_FILE" ]; then
        local _time _intvl _probes
        _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        echo -e "${GREEN}v1 активен${NC} (time=${_time} intvl=${_intvl} probes=${_probes})"
    else
        echo -e "${DIM}не применён${NC}"
    fi
}

ios_fix_apply() {
    echo ""; echo -e "  ${BOLD}Фикс для iOS (вариант 1) — TCP keepalive${NC}"; echo ""
    echo -e "  ${DIM}Проблема: мобильный клиент сворачивается, ОС усыпляет${NC}"
    echo -e "  ${DIM}приложение, сокет не закрывается чисто. Сервер держит${NC}"
    echo -e "  ${DIM}мёртвое соединение часами. При возврате клиент залипает.${NC}"; echo ""
    echo -e "  ${DIM}Решение: ускоряем TCP keepalive через sysctl.${NC}"; echo ""

    local _cur_time _cur_intvl _cur_probes
    _cur_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _cur_intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _cur_probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)

    echo -e "  ${BOLD}Текущие значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_cur_time:-?}  ${DIM}(дефолт: 7200)${NC}"
    echo -e "    tcp_keepalive_intvl  = ${_cur_intvl:-?}  ${DIM}(дефолт: 75)${NC}"
    echo -e "    tcp_keepalive_probes = ${_cur_probes:-?}  ${DIM}(дефолт: 9)${NC}"; echo ""

    echo -e "  ${BOLD}Параметры фикса (Enter = оставить текущее):${NC}"
    echo -en "    tcp_keepalive_time   [${IOS_KA_TIME}]: "
    local _t; read -r _t
    [[ "$_t" =~ ^[0-9]+$ ]] && IOS_KA_TIME="$_t"

    echo -en "    tcp_keepalive_intvl  [${IOS_KA_INTVL}]: "
    local _i; read -r _i
    [[ "$_i" =~ ^[0-9]+$ ]] && IOS_KA_INTVL="$_i"

    echo -en "    tcp_keepalive_probes [${IOS_KA_PROBES}]: "
    local _p; read -r _p
    [[ "$_p" =~ ^[0-9]+$ ]] && IOS_KA_PROBES="$_p"

    local _detect_secs=$(( IOS_KA_TIME + IOS_KA_INTVL * IOS_KA_PROBES ))
    echo ""
    echo -e "  ${DIM}Мёртвый коннект будет рваться за ~${_detect_secs} сек${NC}"
    echo -e "  ${DIM}  ${IOS_KA_TIME}с тишины → проба каждые ${IOS_KA_INTVL}с × ${IOS_KA_PROBES} попыток → RST${NC}"; echo ""

    if [ -f "$IOS_SYSCTL_FILE" ]; then
        echo -e "  ${YELLOW}Файл ${IOS_SYSCTL_FILE} уже существует.${NC}"
        echo -en "  ${BOLD}Перезаписать? [Y/n]:${NC} "
    else
        echo -en "  ${BOLD}Применить фикс? [Y/n]:${NC} "
    fi
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    if [ -z "$IOS_ORIG_TIME" ]; then
        IOS_ORIG_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
        IOS_ORIG_INTVL=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "75")
        IOS_ORIG_PROBES=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "9")
        log_info "Сохранены оригинальные значения: time=${IOS_ORIG_TIME} intvl=${IOS_ORIG_INTVL} probes=${IOS_ORIG_PROBES}"
    fi

    printf '# MTproxy-reanimation: фикс для iOS v1 — TCP keepalive\nnet.ipv4.tcp_keepalive_time = %s\nnet.ipv4.tcp_keepalive_intvl = %s\nnet.ipv4.tcp_keepalive_probes = %s\n' \
        "$IOS_KA_TIME" "$IOS_KA_INTVL" "$IOS_KA_PROBES" > "$IOS_SYSCTL_FILE"

    if sysctl --system &>/dev/null; then
        log_success "sysctl применён"
    else
        log_warn "sysctl --system вернул ошибку, применяем вручную"
        sysctl -w "net.ipv4.tcp_keepalive_time=${IOS_KA_TIME}" 2>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_intvl=${IOS_KA_INTVL}" 2>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_probes=${IOS_KA_PROBES}" 2>/dev/null || true
    fi

    local _new_time _new_intvl _new_probes
    _new_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _new_intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _new_probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    echo ""; echo -e "  ${BOLD}Новые значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_new_time}"
    echo -e "    tcp_keepalive_intvl  = ${_new_intvl}"
    echo -e "    tcp_keepalive_probes = ${_new_probes}"

    if [ "${_new_time}" = "${IOS_KA_TIME}" ] && \
       [ "${_new_intvl}" = "${IOS_KA_INTVL}" ] && \
       [ "${_new_probes}" = "${IOS_KA_PROBES}" ]; then
        log_success "Фикс для iOS (v1) применён"
    else
        log_warn "Значения не совпадают с ожидаемыми — проверьте вручную"
    fi
    IOS_FIX_APPLIED="true"; save_settings
}

ios_fix_remove() {
    echo ""
    if [ ! -f "$IOS_SYSCTL_FILE" ]; then
        log_info "Фикс для iOS (v1) не установлен"
        IOS_FIX_APPLIED="false"; save_settings; return 0
    fi

    local _rt="${IOS_ORIG_TIME:-7200}"
    local _ri="${IOS_ORIG_INTVL:-75}"
    local _rp="${IOS_ORIG_PROBES:-9}"

    echo -e "  ${BOLD}Откат фикса для iOS (вариант 1)${NC}"; echo ""
    echo -e "  ${DIM}Будет удалён: ${IOS_SYSCTL_FILE}${NC}"
    echo -e "  ${DIM}Будут восстановлены: time=${_rt} intvl=${_ri} probes=${_rp}${NC}"; echo ""
    echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    rm -f "$IOS_SYSCTL_FILE"
    log_info "Восстановление значений: time=${_rt} intvl=${_ri} probes=${_rp}"
    sysctl -w "net.ipv4.tcp_keepalive_time=${_rt}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_intvl=${_ri}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_probes=${_rp}" &>/dev/null || true
    sysctl --system &>/dev/null || true

    IOS_ORIG_TIME=""
    IOS_ORIG_INTVL=""
    IOS_ORIG_PROBES=""

    local _time _intvl _probes
    _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    echo ""; echo -e "  ${BOLD}Текущие значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_time}"
    echo -e "    tcp_keepalive_intvl  = ${_intvl}"
    echo -e "    tcp_keepalive_probes = ${_probes}"
    log_success "Фикс для iOS (v1) откачен"
    IOS_FIX_APPLIED="false"; save_settings
}

show_ios_fix_menu() {
    show_header
    echo -e "  ${BOLD}Фикс для iOS (вариант 1) — TCP keepalive${NC}"; echo ""
    local _status; _status=$(ios_fix_status)
    echo -e "  Статус: ${_status}"; echo ""
    local _time _intvl _probes
    _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    local _detect_secs=$(( ${_time:-7200} + ${_intvl:-75} * ${_probes:-9} ))
    echo -e "  ${BOLD}Значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_time:-?}  ${DIM}(дефолт: 7200, фикс: ${IOS_KA_TIME})${NC}"
    echo -e "    tcp_keepalive_intvl  = ${_intvl:-?}  ${DIM}(дефолт: 75,   фикс: ${IOS_KA_INTVL})${NC}"
    echo -e "    tcp_keepalive_probes = ${_probes:-?}  ${DIM}(дефолт: 9,    фикс: ${IOS_KA_PROBES})${NC}"
    echo -e "    ${DIM}Время обнаружения мёртвого коннекта: ~${_detect_secs} сек${NC}"; echo ""
    if [ -n "$IOS_ORIG_TIME" ]; then
        echo -e "  ${DIM}Значения до установки фикса: time=${IOS_ORIG_TIME} intvl=${IOS_ORIG_INTVL} probes=${IOS_ORIG_PROBES}${NC}"
        echo ""
    fi
    echo -e "  ${DIM}[1]${NC} Применить / обновить фикс"
    echo -e "  ${DIM}[2]${NC} Откатить фикс"
    echo -e "  ${DIM}[3]${NC} Изменить keepalive_time   [${IOS_KA_TIME}]"
    echo -e "  ${DIM}[4]${NC} Изменить keepalive_intvl  [${IOS_KA_INTVL}]"
    echo -e "  ${DIM}[5]${NC} Изменить keepalive_probes [${IOS_KA_PROBES}]"
    echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in
        1) ios_fix_apply ;;
        2) ios_fix_remove ;;
        3) echo -en "  tcp_keepalive_time [${IOS_KA_TIME}]: "; local _v; read -r _v
           [[ "$_v" =~ ^[0-9]+$ ]] && { IOS_KA_TIME="$_v"; save_settings; log_success "keepalive_time = $_v"; } ;;
        4) echo -en "  tcp_keepalive_intvl [${IOS_KA_INTVL}]: "; local _v; read -r _v
           [[ "$_v" =~ ^[0-9]+$ ]] && { IOS_KA_INTVL="$_v"; save_settings; log_success "keepalive_intvl = $_v"; } ;;
        5) echo -en "  tcp_keepalive_probes [${IOS_KA_PROBES}]: "; local _v; read -r _v
           [[ "$_v" =~ ^[0-9]+$ ]] && { IOS_KA_PROBES="$_v"; save_settings; log_success "keepalive_probes = $_v"; } ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

# ── Фикс для iOS вариант 2 (MSS + redirect) ──────────────────
ios2_fix_status() {
    if [ "${IOS2_FIX_APPLIED:-false}" = "true" ]; then
        local _target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
        echo -e "${GREEN}активен${NC} (порт ${IOS2_EXTERNAL_PORT} → ${_target}, mss=${IOS2_MSS})"
    else
        echo -e "${DIM}не применён${NC}"
    fi
}

_ios2_check_client_mss() {
    local _cfg="${DETECTED_CONFIG_PATH:-}"
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        if grep -qE '^client_mss[[:space:]]*=' "$_cfg" 2>/dev/null; then
            echo ""
            echo -e "  ${RED}${BOLD}⚠ ВНИМАНИЕ!${NC}"
            echo -e "  ${RED}В конфиге Telemt обнаружен параметр client_mss${NC}"
            echo -e "  ${RED}Файл: ${_cfg}${NC}"
            echo ""
            echo -e "  ${YELLOW}Фикс для iOS вариант 2 использует MSS через nftables,${NC}"
            echo -e "  ${YELLOW}а параметр client_mss в конфиге задаёт MSS на ВСЕ соединения.${NC}"
            echo -e "  ${YELLOW}Эти два метода конфликтуют!${NC}"
            echo ""
            echo -e "  ${BOLD}Что нужно сделать:${NC}"
            if [ "$DETECTED_MODE" = "mtproxymax" ]; then
                echo -e "  ${CYAN}mtproxymax tune clear client_mss${NC}"
                echo -e "  ${CYAN}mtproxymax restart${NC}"
            else
                echo -e "  Удалите или закомментируйте строку ${BOLD}client_mss = ...${NC}"
                echo -e "  в файле ${CYAN}${_cfg}${NC} и перезапустите telemt"
            fi
            echo ""
            echo -en "  ${BOLD}Продолжить всё равно? [y/N]:${NC} "
            local _proceed; read -r _proceed
            [[ "$_proceed" =~ ^[yY] ]] || return 1
        fi
    fi
    return 0
}

ios2_fix_apply() {
    if [ "${NFT_MODE:-classic}" = "smart" ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ Smart By-MEKO активен — iOS Fix v2 не нужен.${NC}"
        echo -e "  ${DIM}Smart автоматически разделяет iOS и Android на одном порту.${NC}"
        echo ""
        echo -en "  ${BOLD}Всё равно включить iOS Fix v2? [y/N]:${NC} "
        local _force; read -r _force
        [[ "$_force" =~ ^[yY] ]] || { log_info "Отменено"; return 0; }
    fi

    local _target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
    if [ -z "${SERVER_PORT:-}" ]; then
        log_error "Основной порт Telemt не определён"; return 1; fi
    if ! [[ "${IOS2_EXTERNAL_PORT}" =~ ^[0-9]+$ ]] || \
       [ "${IOS2_EXTERNAL_PORT}" -lt 1 ] || [ "${IOS2_EXTERNAL_PORT}" -gt 65535 ]; then
        log_error "Некорректный внешний порт iOS v2"; return 1; fi
    if ! [[ "${_target}" =~ ^[0-9]+$ ]] || \
       [ "${_target}" -lt 1 ] || [ "${_target}" -gt 65535 ]; then
        log_error "Некорректный целевой порт iOS v2"; return 1; fi
    if [ "${IOS2_EXTERNAL_PORT}" = "${_target}" ]; then
        log_error "Внешний порт iOS v2 не должен совпадать с основным портом"; return 1; fi
    if ! [[ "${IOS2_MSS}" =~ ^[0-9]+$ ]] || \
       [ "${IOS2_MSS}" -lt 88 ] || [ "${IOS2_MSS}" -gt 4096 ]; then
        log_error "MSS должен быть в диапазоне 88..4096"; return 1; fi

    echo ""; echo -e "  ${BOLD}Фикс для iOS вариант 2 (MSS + redirect)${NC}"; echo ""
    echo -e "  ${DIM}Создаёт отдельный внешний порт для iOS-клиентов.${NC}"
    echo -e "  ${DIM}На этом порту входящий SYN получает MSS=${IOS2_MSS},${NC}"
    echo -e "  ${DIM}затем трафик прозрачно редиректится на основной порт.${NC}"; echo ""
    echo -e "    Внешний порт iOS: ${BOLD}${IOS2_EXTERNAL_PORT}${NC}"
    echo -e "    Основной порт:    ${_target}"
    echo -e "    MSS:              ${IOS2_MSS}"; echo ""

    _ios2_check_client_mss || return 0

    echo -en "  ${BOLD}Применить? [Y/n]:${NC} "
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    IOS2_FIX_APPLIED="true"
    IOS2_TARGET_PORT="${_target}"
    save_settings
    apply_nft_rules || return 1
    [ "${NFT_SERVICE_ENABLED:-false}" = "true" ] && install_service

    log_success "Фикс для iOS вариант 2 применён"
    echo ""
    echo -e "  ${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}Инструкция для пользователей iOS:${NC}"
    echo -e "  ${DIM}───────────────────────────────────────────${NC}"
    echo -e "  В прокси-ссылке замените порт ${_target} на ${IOS2_EXTERNAL_PORT}"
    echo ""
    echo -e "  ${DIM}Было:${NC}  tg://proxy?server=IP&${RED}port=${_target}${NC}&secret=..."
    echo -e "  ${DIM}Стало:${NC} tg://proxy?server=IP&${GREEN}port=${IOS2_EXTERNAL_PORT}${NC}&secret=..."
    echo ""
    echo -e "  ${DIM}Secret и IP остаются прежними.${NC}"
    echo -e "  ${DIM}Android и Desktop продолжают использовать порт ${_target}.${NC}"
    echo -e "  ${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ Не забудьте открыть порт ${IOS2_EXTERNAL_PORT} в фаерволе!${NC}"
}

ios2_fix_remove() {
    echo ""
    if [ "${IOS2_FIX_APPLIED:-false}" != "true" ]; then
        log_info "Фикс для iOS вариант 2 не установлен"; return 0; fi
    echo -e "  ${BOLD}Отключение фикса для iOS вариант 2${NC}"; echo ""
    echo -e "  ${DIM}Будет удалён редирект порта ${IOS2_EXTERNAL_PORT} → ${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}${NC}"
    echo -e "  ${DIM}и правило MSS=${IOS2_MSS}${NC}"; echo ""
    echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    IOS2_FIX_APPLIED="false"; save_settings
    apply_nft_rules || true
    [ "${NFT_SERVICE_ENABLED:-false}" = "true" ] && install_service
    nft delete table inet "${IOS2_TABLE}" 2>/dev/null || true
    log_success "Фикс для iOS вариант 2 отключён"
}

show_ios2_fix_menu() {
    show_header
    if [ "${NFT_MODE:-classic}" = "smart" ]; then
        echo -e "  ${YELLOW}⚠ Smart By-MEKO активен — iOS Fix v2 не нужен.${NC}"
        echo -e "  ${DIM}  Smart автоматически разделяет iOS/Android на одном порту.${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}Фикс для iOS вариант 2 (MSS + redirect)${NC}"; echo ""
    local _status; _status=$(ios2_fix_status)
    local _target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
    echo -e "  Статус: ${_status}"; echo ""
    echo -e "  ${BOLD}Текущие параметры:${NC}"
    echo -e "    Внешний порт iOS: ${IOS2_EXTERNAL_PORT}"
    echo -e "    Основной порт:    ${_target}"
    echo -e "    MSS:              ${IOS2_MSS}"; echo ""
    echo -e "  ${DIM}[1]${NC} Применить / обновить"
    echo -e "  ${DIM}[2]${NC} Отключить"
    echo -e "  ${DIM}[3]${NC} Изменить внешний порт iOS [${IOS2_EXTERNAL_PORT}]"
    echo -e "  ${DIM}[4]${NC} Изменить целевой порт [${_target}]"
    echo -e "  ${DIM}[5]${NC} Изменить MSS [${IOS2_MSS}]"
    echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in
        1) ios2_fix_apply ;;
        2) ios2_fix_remove ;;
        3)
            echo -en "  Новый внешний порт [${IOS2_EXTERNAL_PORT}]: "
            local _p; read -r _p
            if [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                IOS2_EXTERNAL_PORT="$_p"; save_settings
                log_success "Внешний порт: $_p"; prompt_apply_nft_rules
            elif [ -n "$_p" ]; then log_error "Некорректный порт"; fi ;;
        4)
            echo -en "  Новый целевой порт [${_target}]: "
            local _p; read -r _p
            if [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                IOS2_TARGET_PORT="$_p"; save_settings
                log_success "Целевой порт: $_p"; prompt_apply_nft_rules
            elif [ -n "$_p" ]; then log_error "Некорректный порт"; fi ;;
        5)
            echo -en "  Новый MSS [${IOS2_MSS}] (88..4096): "
            local _m; read -r _m
            if [[ "$_m" =~ ^[0-9]+$ ]] && [ "$_m" -ge 88 ] && [ "$_m" -le 4096 ]; then
                IOS2_MSS="$_m"; save_settings
                log_success "MSS: $_m"; prompt_apply_nft_rules
            elif [ -n "$_m" ]; then log_error "Некорректный MSS (88..4096)"; fi ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

# ── Оптимизация By-MEKO ───────────────────────────────────────
meko_opt_status() {
    if [ -f "$MEKO_OPT_FILE" ]; then
        local _ka
        _ka=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        echo -e "${GREEN}применена${NC} (keepalive: ${_ka}s/$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)s×$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null))"
    else
        echo -e "${DIM}не применена${NC}"
    fi
}

meko_opt_apply() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Оптимизация системы By-MEKO${NC}"
    echo ""
    echo -e "  ${DIM}Применяет набор sysctl-параметров из проекта MTPROTO-FIX-By-MEKO:${NC}"
    echo ""
    echo -e "  ${BOLD}TCP keepalive${NC} — ускоряет обнаружение мёртвых сокетов:"
    echo -e "    tcp_keepalive_time  = ${YELLOW}45${NC}   ${DIM}(было: $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null), дефолт: 7200)${NC}"
    echo -e "    tcp_keepalive_intvl = ${YELLOW}15${NC}   ${DIM}(было: $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null), дефолт: 75)${NC}"
    echo -e "    tcp_keepalive_probes= ${YELLOW}3${NC}    ${DIM}(было: $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null), дефолт: 9)${NC}"
    echo ""
    echo -e "  ${BOLD}Сетевые очереди:${NC}"
    echo -e "    net.core.somaxconn              = ${YELLOW}65535${NC}  ${DIM}(было: $(sysctl -n net.core.somaxconn 2>/dev/null))${NC}"
    echo -e "    net.ipv4.tcp_max_syn_backlog    = ${YELLOW}65535${NC}  ${DIM}(было: $(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null))${NC}"
    echo -e "    net.core.netdev_max_backlog     = ${YELLOW}65535${NC}  ${DIM}(было: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null))${NC}"
    echo ""
    echo -e "  ${BOLD}Прочее:${NC}"
    echo -e "    net.ipv4.tcp_fastopen           = ${YELLOW}3${NC}      ${DIM}(было: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null))${NC}"
    echo -e "    fs.file-max                     = ${YELLOW}2097152${NC} ${DIM}(было: $(sysctl -n fs.file-max 2>/dev/null))${NC}"
    echo -e "    net.core.default_qdisc          = ${YELLOW}fq${NC}     ${DIM}(было: $(sysctl -n net.core.default_qdisc 2>/dev/null))${NC}"
    echo -e "    net.ipv4.tcp_congestion_control = ${YELLOW}bbr${NC}    ${DIM}(было: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))${NC}"
    echo ""
    echo -e "  ${DIM}Все текущие значения будут сохранены для последующего отката.${NC}"
    echo ""

    if [ -f "$MEKO_OPT_FILE" ]; then
        echo -e "  ${YELLOW}Оптимизация уже применена. Применить заново?${NC}"
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    else
        echo -en "  ${BOLD}Применить оптимизацию? [Y/n]:${NC} "
    fi
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    # Сохраняем текущие значения (только если ещё не сохранены)
    if [ -z "$MEKO_ORIG_KEEPALIVE_TIME" ]; then
        MEKO_ORIG_KEEPALIVE_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
        MEKO_ORIG_KEEPALIVE_INTVL=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "75")
        MEKO_ORIG_KEEPALIVE_PROBES=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "9")
        MEKO_ORIG_SOMAXCONN=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "4096")
        MEKO_ORIG_TCP_MAX_SYN_BACKLOG=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "512")
        MEKO_ORIG_NETDEV_MAX_BACKLOG=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "1000")
        MEKO_ORIG_TCP_FASTOPEN=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "1")
        MEKO_ORIG_FILE_MAX=$(sysctl -n fs.file-max 2>/dev/null || echo "65536")
        MEKO_ORIG_DEFAULT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "pfifo_fast")
        MEKO_ORIG_TCP_CONGESTION=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
        log_info "Сохранены оригинальные значения для отката"
    fi

    # Записываем файл оптимизации
    cat > "$MEKO_OPT_FILE" << 'SYSEOF'
# MTproxy-reanimation: оптимизация By-MEKO
# Источник: github.com/Mekotofeuka/MTPR-FIX-By-MEKO
net.ipv4.tcp_keepalive_time = 45
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_fastopen = 3
fs.file-max = 2097152
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSEOF

    # Применяем
    if sysctl --system &>/dev/null; then
        log_success "sysctl применён"
    else
        log_warn "sysctl --system вернул ошибку, применяем вручную"
        sysctl -w net.ipv4.tcp_keepalive_time=45 2>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_intvl=15 2>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null || true
        sysctl -w net.core.somaxconn=65535 2>/dev/null || true
        sysctl -w net.ipv4.tcp_max_syn_backlog=65535 2>/dev/null || true
        sysctl -w net.core.netdev_max_backlog=65535 2>/dev/null || true
        sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
        sysctl -w fs.file-max=2097152 2>/dev/null || true
        sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
    fi

    # Проверяем результат
    echo ""
    echo -e "  ${BOLD}Применённые значения:${NC}"
    echo -e "    tcp_keepalive_time   = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)"
    echo -e "    tcp_keepalive_intvl  = $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)"
    echo -e "    tcp_keepalive_probes = $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)"
    echo -e "    somaxconn            = $(sysctl -n net.core.somaxconn 2>/dev/null)"
    echo -e "    congestion_control   = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    MEKO_OPT_APPLIED="true"
    save_settings
    echo ""
    log_success "Оптимизация By-MEKO применена"
    echo -e "  ${DIM}Для отката: меню → [m] Оптимизация By-MEKO → Откатить${NC}"
}

meko_opt_remove() {
    echo ""
    if [ ! -f "$MEKO_OPT_FILE" ]; then
        log_info "Оптимизация By-MEKO не установлена"
        MEKO_OPT_APPLIED="false"
        save_settings
        return 0
    fi

    echo -e "  ${BOLD}Откат оптимизации By-MEKO${NC}"; echo ""
    echo -e "  ${DIM}Будет удалён: ${MEKO_OPT_FILE}${NC}"
    echo -e "  ${DIM}Значения будут восстановлены к тем, что были до применения:${NC}"
    echo ""
    echo -e "    tcp_keepalive_time   → ${MEKO_ORIG_KEEPALIVE_TIME:-7200}"
    echo -e "    tcp_keepalive_intvl  → ${MEKO_ORIG_KEEPALIVE_INTVL:-75}"
    echo -e "    tcp_keepalive_probes → ${MEKO_ORIG_KEEPALIVE_PROBES:-9}"
    echo -e "    somaxconn            → ${MEKO_ORIG_SOMAXCONN:-4096}"
    echo -e "    tcp_max_syn_backlog  → ${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-512}"
    echo -e "    netdev_max_backlog   → ${MEKO_ORIG_NETDEV_MAX_BACKLOG:-1000}"
    echo -e "    tcp_fastopen         → ${MEKO_ORIG_TCP_FASTOPEN:-1}"
    echo -e "    file-max             → ${MEKO_ORIG_FILE_MAX:-65536}"
    echo -e "    default_qdisc        → ${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}"
    echo -e "    congestion_control   → ${MEKO_ORIG_TCP_CONGESTION:-cubic}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }

    rm -f "$MEKO_OPT_FILE"

    # Восстанавливаем
    sysctl -w "net.ipv4.tcp_keepalive_time=${MEKO_ORIG_KEEPALIVE_TIME:-7200}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_intvl=${MEKO_ORIG_KEEPALIVE_INTVL:-75}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_keepalive_probes=${MEKO_ORIG_KEEPALIVE_PROBES:-9}" &>/dev/null || true
    sysctl -w "net.core.somaxconn=${MEKO_ORIG_SOMAXCONN:-4096}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_max_syn_backlog=${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-512}" &>/dev/null || true
    sysctl -w "net.core.netdev_max_backlog=${MEKO_ORIG_NETDEV_MAX_BACKLOG:-1000}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_fastopen=${MEKO_ORIG_TCP_FASTOPEN:-1}" &>/dev/null || true
    sysctl -w "fs.file-max=${MEKO_ORIG_FILE_MAX:-65536}" &>/dev/null || true
    sysctl -w "net.core.default_qdisc=${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}" &>/dev/null || true
    sysctl -w "net.ipv4.tcp_congestion_control=${MEKO_ORIG_TCP_CONGESTION:-cubic}" &>/dev/null || true
    sysctl --system &>/dev/null || true

    # Очищаем сохранённые оригиналы
    MEKO_ORIG_KEEPALIVE_TIME=""
    MEKO_ORIG_KEEPALIVE_INTVL=""
    MEKO_ORIG_KEEPALIVE_PROBES=""
    MEKO_ORIG_SOMAXCONN=""
    MEKO_ORIG_TCP_MAX_SYN_BACKLOG=""
    MEKO_ORIG_NETDEV_MAX_BACKLOG=""
    MEKO_ORIG_TCP_FASTOPEN=""
    MEKO_ORIG_FILE_MAX=""
    MEKO_ORIG_DEFAULT_QDISC=""
    MEKO_ORIG_TCP_CONGESTION=""

    MEKO_OPT_APPLIED="false"
    save_settings

    echo ""
    echo -e "  ${BOLD}Текущие значения после отката:${NC}"
    echo -e "    tcp_keepalive_time   = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)"
    echo -e "    tcp_keepalive_intvl  = $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)"
    echo -e "    congestion_control   = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo ""
    log_success "Оптимизация By-MEKO откачена"
}

show_meko_opt_menu() {
    show_header
    echo -e "  ${BOLD}Оптимизация системы By-MEKO${NC}"; echo ""
    echo -e "  Статус: $(meko_opt_status)"; echo ""

    if [ -n "$MEKO_ORIG_KEEPALIVE_TIME" ]; then
        echo -e "  ${DIM}Значения до применения оптимизации:${NC}"
        echo -e "    keepalive: ${MEKO_ORIG_KEEPALIVE_TIME}s / ${MEKO_ORIG_KEEPALIVE_INTVL}s × ${MEKO_ORIG_KEEPALIVE_PROBES}"
        echo -e "    congestion: ${MEKO_ORIG_TCP_CONGESTION:-cubic}  qdisc: ${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}"
        echo ""
    fi

    echo -e "  ${DIM}[1]${NC} Применить / обновить"
    echo -e "  ${DIM}[2]${NC} Откатить"
    echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in
        1) meko_opt_apply ;;
        2) meko_opt_remove ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

# ── NFT правила ───────────────────────────────────────────────
generate_nft_script() {
    local _ip="${SERVER_IP:-}"
    local _port="${SERVER_PORT:-443}"
    local _timeout="${NFT_METER_TIMEOUT:-60s}"
    local _table="${NFT_TABLE:-telemt_limit}"
    local _hook="${NFT_HOOK:-input}"
    local _ios2_enabled="${IOS2_FIX_APPLIED:-false}"
    local _ios2_table="${IOS2_TABLE:-mtpr_ios2_fix}"
    local _ios2_ext="${IOS2_EXTERNAL_PORT:-4443}"
    local _ios2_target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
    local _ios2_mss="${IOS2_MSS:-92}"

    local _bridge_precise="false"
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ] && \
       [ "${DOCKER_BRIDGE_MODE:-simple}" = "precise" ] && \
       [ -n "$DETECTED_CONTAINER" ]; then
        _bridge_precise="true"
    fi

    cat > "$NFT_SCRIPT" << NFTEOF
#!/bin/sh
set -eu
TABLE="${_table}"
CHAIN="${_hook}"
IOS2_TABLE="${_ios2_table}"
nft delete table inet "\$TABLE" 2>/dev/null || true
nft delete table inet "\$IOS2_TABLE" 2>/dev/null || true
nft add table inet "\$TABLE"
nft "add chain inet \$TABLE \$CHAIN { type filter hook ${_hook} priority 0; policy accept; }"
NFTEOF

    if [ "${NFT_MODE:-classic}" = "smart" ]; then
        _generate_smart_rules "$_bridge_precise" "$_ip" "$_port" "$_timeout"
    else
        _generate_classic_rules "$_bridge_precise" "$_ip" "$_port" "$_timeout"
    fi

    local _i
    for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
        local _eport="${EXTRA_RULES_PORT[$_i]:-}"
        local _eip="${EXTRA_RULES_IP[$_i]:-}"
        local _erate="${EXTRA_RULES_RATE[$_i]:-1/second}"
        local _eburst="${EXTRA_RULES_BURST[$_i]:-1}"
        [ -z "$_eport" ] && continue
        local _extra_action="drop"
        if [ "${NFT_MODE:-classic}" = "smart" ]; then
            case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
                drop)
                    _extra_action="drop" ;;
                icmp-host-unreachable)
                    _extra_action="reject with icmp type host-unreachable" ;;
                *)
                    _extra_action="reject with tcp reset" ;;
            esac
        fi
        if [ -n "$_eip" ]; then
            cat >> "$NFT_SCRIPT" << EXTRAIPEOF
nft "add rule inet \$TABLE \$CHAIN ip daddr ${_eip} tcp dport ${_eport} tcp flags & (syn | ack) == syn meter telemt_in_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } counter ${_extra_action} comment \\"mtpr_extra_${_i}\\""
EXTRAIPEOF
        else
            cat >> "$NFT_SCRIPT" << EXTRANIPEOF
nft "add rule inet \$TABLE \$CHAIN tcp dport ${_eport} tcp flags & (syn | ack) == syn meter telemt_in_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } counter ${_extra_action} comment \\"mtpr_extra_${_i}\\""
EXTRANIPEOF
        fi
    done

    if [ "$_ios2_enabled" = "true" ]; then
        cat >> "$NFT_SCRIPT" << IOS2EOF
nft add table inet "\$IOS2_TABLE"
nft "add chain inet \$IOS2_TABLE mangle_pre { type filter hook prerouting priority mangle; policy accept; }"
nft "add chain inet \$IOS2_TABLE nat_pre { type nat hook prerouting priority dstnat; policy accept; }"
IOS2EOF
        if [ -n "$_ip" ]; then
            cat >> "$NFT_SCRIPT" << IOS2IPEOF
nft "add rule inet \$IOS2_TABLE mangle_pre ip daddr ${_ip} tcp dport ${_ios2_ext} tcp flags & (syn | rst) == syn tcp option maxseg size set ${_ios2_mss} counter comment \\"mtpr_ios2_mss\\""
nft "add rule inet \$IOS2_TABLE nat_pre ip daddr ${_ip} tcp dport ${_ios2_ext} counter redirect to :${_ios2_target} comment \\"mtpr_ios2_redirect\\""
IOS2IPEOF
        else
            cat >> "$NFT_SCRIPT" << IOS2NIPEOF
nft "add rule inet \$IOS2_TABLE mangle_pre tcp dport ${_ios2_ext} tcp flags & (syn | rst) == syn tcp option maxseg size set ${_ios2_mss} counter comment \\"mtpr_ios2_mss\\""
nft "add rule inet \$IOS2_TABLE nat_pre tcp dport ${_ios2_ext} counter redirect to :${_ios2_target} comment \\"mtpr_ios2_redirect\\""
IOS2NIPEOF
        fi
    fi

    cat >> "$NFT_SCRIPT" << 'TAILEOF'
echo "MTproxy-reanimation: nft правила применены"
nft list table inet "$TABLE" 2>/dev/null || true
nft list table inet "$IOS2_TABLE" 2>/dev/null || true
TAILEOF

    chmod +x "$NFT_SCRIPT"
}

# ── Classic правила ───────────────────────────────────────────
_generate_classic_rules() {
    local _bridge_precise="$1" _ip="$2" _port="$3" _timeout="$4"
    local _rate="${NFT_RATE:-1/second}"
    local _burst="${NFT_BURST:-1}"

    if [ "$_bridge_precise" = "true" ]; then
        cat >> "$NFT_SCRIPT" << BRIDGEOF
CONTAINER="${DETECTED_CONTAINER}"
TARGET_IP=""
for i in \$(seq 1 60); do
    RUNNING="\$(docker inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null || true)"
    if [ "\$RUNNING" = "true" ]; then
        TARGET_IP="\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "\$CONTAINER" 2>/dev/null | awk 'NF {print; exit}')"
        [ -n "\$TARGET_IP" ] && break
    fi
    sleep 1
done
if [ -z "\$TARGET_IP" ]; then
    echo "Не удалось определить IP контейнера: \$CONTAINER" >&2
    exit 1
fi
nft "add rule inet \$TABLE \$CHAIN ip daddr \$TARGET_IP tcp dport ${_port} tcp flags & (syn | ack) == syn meter telemt_in_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtpr_main\\""
BRIDGEOF
    elif [ "$DETECTED_NETWORK_MODE" = "bridge" ] && [ "${DOCKER_BRIDGE_MODE:-simple}" = "simple" ]; then
        cat >> "$NFT_SCRIPT" << SIMPLEBRIDGEOF
nft "add rule inet \$TABLE \$CHAIN tcp dport ${_port} tcp flags & (syn | ack) == syn meter telemt_in_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtpr_main\\""
SIMPLEBRIDGEOF
    elif [ -n "$_ip" ]; then
        cat >> "$NFT_SCRIPT" << HOSTIPEOF
nft "add rule inet \$TABLE \$CHAIN ip daddr ${_ip} tcp dport ${_port} tcp flags & (syn | ack) == syn meter telemt_in_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtpr_main\\""
HOSTIPEOF
    else
        cat >> "$NFT_SCRIPT" << HOSTNIPEOF
nft "add rule inet \$TABLE \$CHAIN tcp dport ${_port} tcp flags & (syn | ack) == syn meter telemt_in_syn_main { ip saddr timeout ${_timeout} limit rate over ${_rate} burst ${_burst} packets } counter drop comment \\"mtpr_main\\""
HOSTNIPEOF
    fi
}

# ── Smart By-MEKO правила ─────────────────────────────────────
_generate_smart_rules() {
    local _bridge_precise="$1" _ip="$2" _port="$3" _timeout="$4"
    local _ios_rate="${NFT_IOS_RATE:-15/second}"
    local _ios_burst="${NFT_IOS_BURST:-30}"
    local _other_rate="${NFT_OTHER_RATE:-54/minute}"
    local _other_burst="${NFT_OTHER_BURST:-1}"
    local _ios_limit="${NFT_IOS_LIMIT_ENABLED:-true}"
    local _other_limit="${NFT_OTHER_LIMIT_ENABLED:-true}"
    local _ios_detect="${NFT_IOS_DETECT:-fingerprint}"

    local _ip_match=""
    [ -n "$_ip" ] && [ "$DETECTED_NETWORK_MODE" != "bridge" ] && _ip_match="ip daddr ${_ip} "

    if [ "$_bridge_precise" = "true" ]; then
        log_warn "Smart режим в bridge/precise: ip daddr контейнера не используется"
    fi

    # ── Выбор метода идентификации iOS ──────────────────────
    local _ios_match
    if [ "$_ios_detect" = "ttl" ]; then
        _ios_match="ip ttl < 65 meta length 64"
    else
        _ios_match="@th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000"
    fi

    if [ "$_ios_limit" = "true" ]; then
        # ── 1. iOS → meter лимит → ACCEPT
        cat >> "$NFT_SCRIPT" << SMART1EOF
nft "add rule inet \$TABLE \$CHAIN ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ${_ios_match} meter mtpr_ios { ip saddr timeout ${_timeout} limit rate ${_ios_rate} burst ${_ios_burst} packets } counter accept comment \\"mtpr_smart_ios_accept\\""
SMART1EOF
        # ── 2. iOS превысившие → reject tcp reset
        cat >> "$NFT_SCRIPT" << SMART2EOF
nft "add rule inet \$TABLE \$CHAIN ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ${_ios_match} counter reject with tcp reset comment \\"mtpr_smart_ios_reject\\""
SMART2EOF
    else
        # ── 1. iOS → безусловный ACCEPT (лимит отключён)
        cat >> "$NFT_SCRIPT" << SMART1NOLIMEOF
nft "add rule inet \$TABLE \$CHAIN ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn ${_ios_match} counter accept comment \\"mtpr_smart_ios_accept\\""
SMART1NOLIMEOF
    fi

    # ── Other action cmd ────────────────────────────────────
    local _other_action_cmd
    case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
        drop)
            _other_action_cmd="drop" ;;
        icmp-host-unreachable)
            _other_action_cmd="reject with icmp type host-unreachable" ;;
        *)
            _other_action_cmd="reject with tcp reset" ;;
    esac

    if [ "$_other_limit" = "true" ]; then
        # ── 3. Other → meter лимит → ACCEPT
        cat >> "$NFT_SCRIPT" << SMART3EOF
nft "add rule inet \$TABLE \$CHAIN ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn meter mtpr_other { ip saddr timeout ${_timeout} limit rate ${_other_rate} burst ${_other_burst} packets } counter accept comment \\"mtpr_smart_other_accept\\""
SMART3EOF
        # ── 4. Other превысившие → настраиваемое действие
        cat >> "$NFT_SCRIPT" << SMART4EOF
nft "add rule inet \$TABLE \$CHAIN ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn counter ${_other_action_cmd} comment \\"mtpr_smart_other_reject\\""
SMART4EOF
    else
        # ── 3. Other → безусловный ACCEPT (лимит отключён)
        cat >> "$NFT_SCRIPT" << SMART3NOLIMEOF
nft "add rule inet \$TABLE \$CHAIN ${_ip_match}tcp dport ${_port} tcp flags & (syn | ack) == syn counter accept comment \\"mtpr_smart_other_accept\\""
SMART3NOLIMEOF
    fi
}

# ── Smart By-MEKO: включение ──────────────────────────────────
enable_smart_mode() {
    echo ""
    echo -e "  ${CYAN}${BOLD}★ NFT Smart By-MEKO${NC}"
    echo ""
    echo -e "  ${BOLD}Как работает:${NC}"
    echo ""
    local _detect_method="${NFT_IOS_DETECT:-fingerprint}"
    if [ "$_detect_method" = "ttl" ]; then
        echo -e "  ${DIM}  iOS определяются по TTL+Length (устаревший метод):${NC}"
        echo -e "  ${DIM}  • iOS (ip ttl < 65, len 64) — лимит ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}${NC}"
    else
        echo -e "  ${DIM}  iOS определяются по TCP SYN fingerprint:${NC}"
        echo -e "  ${DIM}  • iOS (TCP fingerprint) — лимит ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}${NC}"
    fi
    echo -e "  ${DIM}  • Остальные — строгий лимит ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST}${NC}"
    echo ""
    local _action_desc
    case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
        icmp-host-unreachable)
            _action_desc="ICMP host-unreachable — клиент мгновенно понимает что путь закрыт,\n             переключается на основное соединение, медиа без задержек." ;;
        drop)
            _action_desc="DROP — тихое уничтожение (может вызывать задержки медиа)." ;;
        *)
            _action_desc="REJECT (tcp reset) — быстрый reconnect, небольшая задержка медиа." ;;
    esac
    echo -e "  ${DIM}  Non-iOS action: ${_action_desc}${NC}"
    echo ""
    echo -e "  ${DIM}  Один порт для всех клиентов.${NC}"
    echo -e "  ${DIM}  iOS Fix v2 и client_mss в конфиге не нужны.${NC}"
    echo ""
    echo -e "  ${DIM}  Источник идеи: github.com/Mekotofeuka/MTPR-FIX-By-MEKO${NC}"
    echo ""

    if [ "${IOS2_FIX_APPLIED:-false}" = "true" ]; then
        echo -e "  ${YELLOW}⚠ iOS Fix v2 сейчас активен (порт ${IOS2_EXTERNAL_PORT}).${NC}"
        echo -e "  ${YELLOW}  Smart режим заменяет его — iOS Fix v2 будет отключён.${NC}"
        echo ""
    fi

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ] && [ "${DOCKER_BRIDGE_MODE:-simple}" = "precise" ]; then
        echo -e "  ${YELLOW}⚠ Bridge/precise режим: ip daddr контейнера не будет использоваться.${NC}"
        if [ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ]; then
            echo -e "  ${YELLOW}  Smart идентифицирует клиентов по TTL+Length — это работает корректно.${NC}"
        else
            echo -e "  ${YELLOW}  Smart идентифицирует клиентов по TCP fingerprint — это работает корректно.${NC}"
        fi
        echo ""
    fi

    echo -en "  ${BOLD}Включить Smart режим? [Y/n]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Отменено"; return 0; }

    if [ "${IOS2_FIX_APPLIED:-false}" = "true" ]; then
        IOS2_FIX_APPLIED="false"
        nft delete table inet "${IOS2_TABLE}" 2>/dev/null || true
        log_info "iOS Fix v2 отключён (Smart режим его заменяет)"
    fi

    NFT_MODE="smart"
    save_settings
    apply_nft_rules || { log_error "Не удалось применить правила"; return 1; }
    [ "${NFT_SERVICE_ENABLED:-false}" = "true" ] && install_service

    echo ""
    log_success "Smart By-MEKO активирован"
    echo ""
    echo -e "  ${BOLD}Что изменилось:${NC}"
    echo -e "    ${GREEN}✓${NC} iOS и Android на одном порту ${SERVER_PORT}"
    echo -e "    ${GREEN}✓${NC} REJECT вместо DROP — быстрый reconnect"
    echo -e "    ${GREEN}✓${NC} iOS Fix v2 / отдельный порт не нужен"
    echo -e "    ${GREEN}✓${NC} client_mss в конфиге не нужен"
    echo ""
}

show_smart_settings_menu() {
    while true; do
        show_header
        echo -e "  ${BOLD}Настройки Smart By-MEKO${NC}"; echo ""
        echo -e "  ${BOLD}Текущие параметры:${NC}"

        # iOS статус
        if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "    iOS лимит:    ${GREEN}включён${NC} — ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}"
        else
            echo -e "    iOS лимит:    ${YELLOW}отключён${NC} ${DIM}(безусловный ACCEPT)${NC}"
        fi

        # Other статус
        if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
            local _action_display
            case "${NFT_OTHER_ACTION:-icmp-host-unreachable}" in
                icmp-host-unreachable) _action_display="${GREEN}icmp-host-unreachable${NC}" ;;
                drop)                  _action_display="${YELLOW}drop${NC}" ;;
                *)                     _action_display="${DIM}reject (tcp reset)${NC}" ;;
            esac
            echo -e "    Other лимит:  ${GREEN}включён${NC} — ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST} → ${_action_display}"
        else
            echo -e "    Other лимит:  ${YELLOW}отключён${NC} ${DIM}(безусловный ACCEPT)${NC}"
        fi

        echo -e "    Timeout:      ${NFT_METER_TIMEOUT}"
        local _detect_display
        if [ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ]; then
            _detect_display="${YELLOW}TTL+Length${NC} ${DIM}(ip ttl < 65, len 64 — устаревший)${NC}"
        else
            _detect_display="${GREEN}TCP fingerprint${NC} ${DIM}(рекомендуется)${NC}"
        fi
        echo -e "    iOS detect:   ${_detect_display}"
        echo ""

        echo -e "  ${BOLD}iOS настройки:${NC}"
        if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "  ${DIM}[1]${NC} iOS Rate    [${NFT_IOS_RATE}]"
            echo -e "  ${DIM}[2]${NC} iOS Burst   [${NFT_IOS_BURST}]"
            echo -e "  ${DIM}[3]${NC} ${YELLOW}Отключить лимит для iOS${NC} ${DIM}(→ безусловный ACCEPT)${NC}"
        else
            echo -e "  ${DIM}[1]${NC} iOS Rate    ${DIM}[${NFT_IOS_RATE}] (лимит отключён)${NC}"
            echo -e "  ${DIM}[2]${NC} iOS Burst   ${DIM}[${NFT_IOS_BURST}] (лимит отключён)${NC}"
            echo -e "  ${DIM}[3]${NC} ${GREEN}Включить лимит для iOS${NC} ${DIM}(${NFT_IOS_RATE} burst ${NFT_IOS_BURST})${NC}"
        fi

        echo ""
        echo -e "  ${BOLD}Other настройки (Android/Desktop):${NC}"
        if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "  ${DIM}[4]${NC} Other Rate  [${NFT_OTHER_RATE}]"
            echo -e "  ${DIM}[5]${NC} Other Burst [${NFT_OTHER_BURST}]"
            echo -e "  ${DIM}[6]${NC} Other Action"
            echo -e "  ${DIM}[7]${NC} ${YELLOW}Отключить лимит для Other${NC} ${DIM}(→ безусловный ACCEPT)${NC}"
        else
            echo -e "  ${DIM}[4]${NC} Other Rate  ${DIM}[${NFT_OTHER_RATE}] (лимит отключён)${NC}"
            echo -e "  ${DIM}[5]${NC} Other Burst ${DIM}[${NFT_OTHER_BURST}] (лимит отключён)${NC}"
            echo -e "  ${DIM}[6]${NC} Other Action ${DIM}(лимит отключён — action не применяется)${NC}"
            echo -e "  ${DIM}[7]${NC} ${GREEN}Включить лимит для Other${NC} ${DIM}(${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST})${NC}"
        fi

        echo ""
        echo -e "  ${DIM}[8]${NC} Переключить на Classic режим"
        echo -e "  ${DIM}[9]${NC} Метод идентификации iOS [$([ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ] && echo "TTL+Length" || echo "fingerprint")]"
        echo -e "  ${DIM}[0]${NC} Назад"; echo ""
        echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            1)
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит iOS отключён — сначала включите его [3]"
                else
                    echo -en "  iOS Rate [${NFT_IOS_RATE}]: "; local _v; read -r _v
                    [ -n "$_v" ] && { NFT_IOS_RATE="$_v"; save_settings; log_success "iOS Rate: ${_v}"; prompt_apply_nft_rules; }
                fi ;;
            2)
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит iOS отключён — сначала включите его [3]"
                else
                    echo -en "  iOS Burst [${NFT_IOS_BURST}]: "; local _v; read -r _v
                    [[ "$_v" =~ ^[0-9]+$ ]] && { NFT_IOS_BURST="$_v"; save_settings; log_success "iOS Burst: ${_v}"; prompt_apply_nft_rules; }
                fi ;;
            3)
                if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
                    echo ""
                    echo -e "  ${YELLOW}Отключение лимита для iOS:${NC}"
                    echo -e "  ${DIM}Все iOS-устройства будут пропускаться без ограничений.${NC}"
                    echo -e "  ${DIM}Правило: fingerprint совпал → ACCEPT (без meter).${NC}"
                    echo ""
                    echo -en "  ${BOLD}Отключить лимит iOS? [y/N]:${NC} "
                    local _yn; read -r _yn
                    if [[ "$_yn" =~ ^[yY]$ ]]; then
                        NFT_IOS_LIMIT_ENABLED="false"
                        save_settings
                        log_success "Лимит iOS отключён"
                        prompt_apply_nft_rules
                    else
                        log_info "Отменено"
                    fi
                else
                    NFT_IOS_LIMIT_ENABLED="true"
                    save_settings
                    log_success "Лимит iOS включён (${NFT_IOS_RATE} burst ${NFT_IOS_BURST})"
                    prompt_apply_nft_rules
                fi ;;
            4)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит Other отключён — сначала включите его [7]"
                else
                    echo -en "  Other Rate [${NFT_OTHER_RATE}]: "; local _v; read -r _v
                    [ -n "$_v" ] && { NFT_OTHER_RATE="$_v"; save_settings; log_success "Other Rate: ${_v}"; prompt_apply_nft_rules; }
                fi ;;
            5)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит Other отключён — сначала включите его [7]"
                else
                    echo -en "  Other Burst [${NFT_OTHER_BURST}]: "; local _v; read -r _v
                    [[ "$_v" =~ ^[0-9]+$ ]] && { NFT_OTHER_BURST="$_v"; save_settings; log_success "Other Burst: ${_v}"; prompt_apply_nft_rules; }
                fi ;;
            6)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" != "true" ]; then
                    log_warn "Лимит Other отключён — action не применяется"
                else
                    echo ""
                    echo -e "  ${BOLD}Выбор действия для non-iOS устройств:${NC}"; echo ""
                    echo -e "  ${GREEN}[1]${NC} icmp-host-unreachable ${DIM}(рекомендуется)${NC}"
                    echo -e "      ${DIM}Сервер притворяется недоступным узлом.${NC}"
                    echo -e "      ${DIM}Telegram мгновенно понимает: «этот путь закрыт» —${NC}"
                    echo -e "      ${DIM}и сразу переключается на основное соединение.${NC}"
                    echo -e "      ${DIM}Медиа начинает отправляться без задержек.${NC}"
                    echo ""
                    echo -e "  ${CYAN}[2]${NC} reject (tcp reset) ${DIM}(оригинал By-MEKO)${NC}"
                    echo -e "      ${DIM}Жёсткий сброс TCP. Быстрый reconnect,${NC}"
                    echo -e "      ${DIM}но небольшая задержка при старте отправки медиа.${NC}"
                    echo ""
                    echo -e "  ${YELLOW}[3]${NC} drop ${DIM}(не рекомендуется)${NC}"
                    echo -e "      ${DIM}Тихое уничтожение пакета. Telegram ждёт таймаута —${NC}"
                    echo -e "      ${DIM}отправка медиа может полностью зависать.${NC}"
                    echo ""
                    echo -en "  ${BOLD}Выбор [1]: ${NC}"
                    local _ac; read -r _ac
                    case "${_ac:-1}" in
                        2) NFT_OTHER_ACTION="reject" ;;
                        3) NFT_OTHER_ACTION="drop" ;;
                        *) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
                    esac
                    save_settings
                    log_success "Other Action: ${NFT_OTHER_ACTION}"
                    prompt_apply_nft_rules
                fi ;;
            7)
                if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
                    echo ""
                    echo -e "  ${YELLOW}Отключение лимита для Other (Android/Desktop):${NC}"
                    echo -e "  ${DIM}Все non-iOS устройства будут пропускаться без ограничений.${NC}"
                    echo -e "  ${DIM}Правило: fingerprint НЕ совпал → ACCEPT (без meter).${NC}"
                    echo -e "  ${YELLOW}Внимание: это отключает защиту от SYN-флуда!${NC}"
                    echo ""
                    echo -en "  ${BOLD}Отключить лимит Other? [y/N]:${NC} "
                    local _yn; read -r _yn
                    if [[ "$_yn" =~ ^[yY]$ ]]; then
                        NFT_OTHER_LIMIT_ENABLED="false"
                        save_settings
                        log_success "Лимит Other отключён"
                        prompt_apply_nft_rules
                    else
                        log_info "Отменено"
                    fi
                else
                    NFT_OTHER_LIMIT_ENABLED="true"
                    save_settings
                    log_success "Лимит Other включён (${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST})"
                    prompt_apply_nft_rules
                fi ;;
            8)
                NFT_MODE="classic"
                save_settings
                log_success "Переключено на Classic"
                prompt_apply_nft_rules ;;
            9)
                echo ""
                echo -e "  ${BOLD}Метод идентификации iOS-устройств:${NC}"; echo ""
                echo -e "  ${GREEN}[1]${NC} TCP fingerprint ${DIM}(рекомендуется)${NC}"
                echo -e "      ${DIM}Точное определение iOS по TCP SYN payload:${NC}"
                echo -e "      ${DIM}@th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103${NC}"
                echo -e "      ${DIM}@th,224,24 0x10108 @th,320,32 0x4020000${NC}"
                echo -e "      ${DIM}Работает независимо от TTL и длины пакета.${NC}"
                echo ""
                echo -e "  ${YELLOW}[2]${NC} TTL + Length ${DIM}(устаревший, v1.0.9)${NC}"
                echo -e "      ${DIM}Определение iOS по: ip ttl < 65 AND meta length 64${NC}"
                echo -e "      ${DIM}Менее точно. Используйте если fingerprint не работает.${NC}"
                echo ""
                local _cur_detect="${NFT_IOS_DETECT:-fingerprint}"
                if [ "$_cur_detect" = "ttl" ]; then
                    echo -e "  ${DIM}Текущий метод: ${YELLOW}TTL+Length${NC}"
                else
                    echo -e "  ${DIM}Текущий метод: ${GREEN}fingerprint${NC}"
                fi
                echo ""
                echo -en "  ${BOLD}Выбор [1]: ${NC}"
                local _dm; read -r _dm
                case "${_dm:-1}" in
                    2)
                        NFT_IOS_DETECT="ttl"
                        save_settings
                        log_success "Метод идентификации iOS: TTL+Length"
                        prompt_apply_nft_rules ;;
                    *)
                        NFT_IOS_DETECT="fingerprint"
                        save_settings
                        log_success "Метод идентификации iOS: TCP fingerprint"
                        prompt_apply_nft_rules ;;
                esac ;;
            0|"") return ;;
        esac
        echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
    done
}

generate_bridge_watch_script() {
    cat > "$WATCHER_SCRIPT" << EOF
#!/bin/sh
set -eu

CONTAINER="${DETECTED_CONTAINER}"
NFT_SCRIPT="${NFT_SCRIPT}"
INTERVAL="${BRIDGE_WATCH_INTERVAL}"

LAST_IP=""

echo "MTproxy-reanimation: watching container \$CONTAINER for bridge precise mode"

while true; do
    RUNNING="\$(docker inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null || true)"

    if [ "\$RUNNING" = "true" ]; then
        IP="\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "\$CONTAINER" 2>/dev/null | awk 'NF {print; exit}')"

        if [ -n "\$IP" ] && [ "\$IP" != "\$LAST_IP" ]; then
            echo "Container IP changed: \${LAST_IP:-none} -> \$IP"
            /bin/sh "\$NFT_SCRIPT" || true
            LAST_IP="\$IP"
        fi
    else
        if [ -n "\$LAST_IP" ]; then
            echo "Container \$CONTAINER is not running"
            LAST_IP=""
        fi
    fi

    sleep "\$INTERVAL"
done
EOF
    chmod +x "$WATCHER_SCRIPT"
    log_success "Watcher-скрипт создан: ${WATCHER_SCRIPT}"
}

apply_nft_rules() {
    generate_nft_script
    if /bin/sh "$NFT_SCRIPT"; then
        log_success "NFT правила применены (режим: ${NFT_MODE:-classic})"
    else
        log_error "Не удалось применить NFT правила"; return 1
    fi
}

remove_nft_rules() {
    local _table="${NFT_TABLE:-telemt_limit}"
    local _ios2_table="${IOS2_TABLE:-mtpr_ios2_fix}"
    nft delete table inet "$_table" 2>/dev/null || true
    nft delete table inet "$_ios2_table" 2>/dev/null || true
    log_success "NFT правила удалены"
}

prompt_apply_nft_rules() {
    if [ -z "$SERVER_PORT" ] && [ "${IOS2_FIX_APPLIED:-false}" != "true" ]; then
        log_warn "Порт не задан — NFT-правила сейчас применить нельзя"
        return 0
    fi
    echo ""
    echo -en "  ${BOLD}Применить новые NFT-правила сейчас? [Y/n]:${NC} "
    local _yn; read -r _yn
    if [[ ! "$_yn" =~ ^[nN]$ ]]; then
        apply_nft_rules || true
        [ "${NFT_SERVICE_ENABLED:-false}" = "true" ] && install_service
    fi
}

# ── Systemd сервис ────────────────────────────────────────────
install_service() {
    generate_nft_script

    systemctl disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
    systemctl disable --now "$WATCHER_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SYSTEMD_UNIT}"
    rm -f "/etc/systemd/system/${WATCHER_UNIT}"

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ] && [ "${DOCKER_BRIDGE_MODE:-simple}" = "precise" ]; then
        generate_bridge_watch_script

        cat > "/etc/systemd/system/${WATCHER_UNIT}" << EOF
[Unit]
Description=MTproxy-reanimation Docker bridge watcher
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCHER_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$WATCHER_UNIT" 2>/dev/null
        systemctl restart "$WATCHER_UNIT" 2>/dev/null
        log_success "Установлена watcher-служба для точного Docker-режима"
    else
        local _table="${NFT_TABLE:-telemt_limit}"
        local _ios2_table="${IOS2_TABLE:-mtpr_ios2_fix}"

        cat > "/etc/systemd/system/${SYSTEMD_UNIT}" << EOF
[Unit]
Description=MTproxy-reanimation inbound SYN limiter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh ${NFT_SCRIPT}
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet ${_table} 2>/dev/null || true; /usr/sbin/nft delete table inet ${_ios2_table} 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SYSTEMD_UNIT" 2>/dev/null
        systemctl restart "$SYSTEMD_UNIT" 2>/dev/null
        log_success "Установлена обычная nft-служба"
    fi

    NFT_SERVICE_ENABLED="true"
    save_settings
}

remove_service() {
    systemctl disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
    systemctl disable --now "$WATCHER_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SYSTEMD_UNIT}"
    rm -f "/etc/systemd/system/${WATCHER_UNIT}"
    rm -f "$WATCHER_SCRIPT"
    systemctl daemon-reload 2>/dev/null || true
    NFT_SERVICE_ENABLED="false"
    save_settings
    log_success "Службы удалены"
}

# ── Пресеты ───────────────────────────────────────────────────
apply_preset() {
    local _preset="$1"
    case "$_preset" in
        hard)   NFT_MODE="classic"; NFT_RATE="1/second"; NFT_BURST="1" ;;
        medium) NFT_MODE="classic"; NFT_RATE="1/second"; NFT_BURST="3" ;;
        soft)   NFT_MODE="classic"; NFT_RATE="2/second"; NFT_BURST="5" ;;
        smart)
            NFT_MODE="smart"
            NFT_IOS_RATE="15/second"
            NFT_IOS_BURST="30"
            NFT_OTHER_RATE="54/minute"
            NFT_OTHER_BURST="1"
            ;;
        *) log_error "Неизвестный пресет: $_preset"; return 1 ;;
    esac
    save_settings
    if [ "$_preset" = "smart" ]; then
        log_success "Пресет: Smart By-MEKO"
    else
        log_success "Пресет применён: $_preset (rate=$NFT_RATE burst=$NFT_BURST)"
    fi
}

# ── Счётчик дропов ────────────────────────────────────────────
show_drop_counter() {
    local _table="${NFT_TABLE:-telemt_limit}"
    local _hook="${NFT_HOOK:-input}"
    if ! nft list table inet "$_table" &>/dev/null; then
        log_warn "Активных NFT правил не найдено"; return 1; fi
    echo ""
    if [ "${NFT_MODE:-classic}" = "smart" ]; then
        echo -e "  ${BOLD}Счётчик правил Smart By-MEKO (Ctrl+C для выхода):${NC}"
    else
        echo -e "  ${BOLD}Счётчик дропов Classic (Ctrl+C для выхода):${NC}"
    fi
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
    echo -e "  ${DIM}- iOS фикс (sysctl keepalive)${NC}"
    echo -e "  ${DIM}- iOS фикс вариант 2 (MSS + redirect)${NC}"
    echo -e "  ${DIM}- Оптимизация системы By-MEKO (sysctl)${NC}"
    echo -e "  ${DIM}- Все настройки и скрипты${NC}"
    echo -e "  ${DIM}- Симлинк /usr/local/bin/mtpr${NC}"
    echo ""
    echo -e "  ${YELLOW}Во время удаления будет предложен откат конфигурации / тюнинга,${NC}"
    echo -e "  ${YELLOW}если для этого доступны сохранённые настройки или бэкап.${NC}"
    echo -e "  ${YELLOW}Если вы выберете восстановление из бэкапа, все изменения,${NC}"
    echo -e "  ${YELLOW}внесённые после установки реаниматора, будут потеряны.${NC}"
    echo ""
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _confirm; read -r _confirm
    [ "$_confirm" != "yes" ] && { log_info "Отменено"; return; }

    if [ -f "$IOS_SYSCTL_FILE" ]; then
        rm -f "$IOS_SYSCTL_FILE"
        local _restore_time="${IOS_ORIG_TIME:-7200}"
        local _restore_intvl="${IOS_ORIG_INTVL:-75}"
        local _restore_probes="${IOS_ORIG_PROBES:-9}"
        sysctl -w "net.ipv4.tcp_keepalive_time=${_restore_time}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_intvl=${_restore_intvl}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_probes=${_restore_probes}" &>/dev/null || true
        sysctl --system &>/dev/null || true
        log_success "iOS фикс откачен (time=${_restore_time} intvl=${_restore_intvl} probes=${_restore_probes})"
    fi

    # Откат оптимизации By-MEKO
    if [ -f "$MEKO_OPT_FILE" ]; then
        rm -f "$MEKO_OPT_FILE"
        sysctl -w "net.ipv4.tcp_keepalive_time=${MEKO_ORIG_KEEPALIVE_TIME:-7200}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_intvl=${MEKO_ORIG_KEEPALIVE_INTVL:-75}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_keepalive_probes=${MEKO_ORIG_KEEPALIVE_PROBES:-9}" &>/dev/null || true
        sysctl -w "net.core.somaxconn=${MEKO_ORIG_SOMAXCONN:-4096}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_max_syn_backlog=${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-512}" &>/dev/null || true
        sysctl -w "net.core.netdev_max_backlog=${MEKO_ORIG_NETDEV_MAX_BACKLOG:-1000}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_fastopen=${MEKO_ORIG_TCP_FASTOPEN:-1}" &>/dev/null || true
        sysctl -w "fs.file-max=${MEKO_ORIG_FILE_MAX:-65536}" &>/dev/null || true
        sysctl -w "net.core.default_qdisc=${MEKO_ORIG_DEFAULT_QDISC:-pfifo_fast}" &>/dev/null || true
        sysctl -w "net.ipv4.tcp_congestion_control=${MEKO_ORIG_TCP_CONGESTION:-cubic}" &>/dev/null || true
        sysctl --system &>/dev/null || true
        log_success "Оптимизация By-MEKO откачена"
    fi    

    remove_nft_rules 2>/dev/null || true
    remove_service 2>/dev/null || true
    rm -f "$NFT_SCRIPT"
    rm -f /usr/local/bin/mtpr
    rm -rf "$INSTALL_DIR"
    echo ""; log_success "MTproxy-reanimation полностью удалён"

    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        echo ""
        echo -en "  ${BOLD}Откатить тюнинг MTProxyMax? [y/N]:${NC} "
        local _revert_mpx; read -r _revert_mpx
        if [[ "$_revert_mpx" =~ ^[yY]$ ]]; then
            mtproxymax tune clear tg_connect &>/dev/null || true
            mtproxymax tune clear client_handshake &>/dev/null || true
            mtproxymax tune clear client_keepalive &>/dev/null || true
            mtproxymax restart &>/dev/null || true
            log_success "Тюнинг MTProxyMax откачен"
        else
            echo ""
            echo -e "  ${DIM}Для ручного отката:${NC}"
            echo -e "  ${CYAN}mtproxymax tune clear tg_connect${NC}"
            echo -e "  ${CYAN}mtproxymax tune clear client_handshake${NC}"
            echo -e "  ${CYAN}mtproxymax tune clear client_keepalive${NC}"
            echo -e "  ${CYAN}mtproxymax restart${NC}"
        fi
    elif [ -n "$DETECTED_CONFIG_PATH" ]; then
        local _backup_file=""
        _backup_file=$(ls -1t "${DETECTED_CONFIG_PATH}".mtpr-backup-* 2>/dev/null | head -1)
        if [ -n "$_backup_file" ] && [ -f "$_backup_file" ]; then
            echo ""
            echo -e "  ${BOLD}Найден бэкап конфигурации:${NC}"
            echo -e "  ${CYAN}${_backup_file}${NC}"
            echo ""
            echo -e "  ${YELLOW}Внимание! Все изменения, внесённые после установки${NC}"
            echo -e "  ${YELLOW}реаниматора, будут потеряны.${NC}"
            echo ""
            echo -en "  ${BOLD}Восстановить конфигурацию из бэкапа? [y/N]:${NC} "
            local _restore; read -r _restore
            if [[ "$_restore" =~ ^[yY]$ ]]; then
                cp "$_backup_file" "$DETECTED_CONFIG_PATH"
                log_success "Конфигурация восстановлена из бэкапа"
                if [ "$DETECTED_MODE" = "docker" ] && [ -n "$DETECTED_CONTAINER" ]; then
                    docker restart "$DETECTED_CONTAINER" &>/dev/null && \
                        log_success "Контейнер ${DETECTED_CONTAINER} перезапущен" || \
                        log_warn "Не удалось перезапустить контейнер"
                elif [ "$DETECTED_MODE" = "local" ]; then
                    if systemctl is-active telemt.service &>/dev/null 2>&1; then
                        systemctl restart telemt.service &>/dev/null && \
                            log_success "Служба telemt перезапущена" || \
                            log_warn "Не удалось перезапустить telemt"
                    else
                        pkill -HUP telemt 2>/dev/null || log_warn "Не удалось отправить сигнал telemt"
                    fi
                fi
            else
                echo ""
                echo -e "  ${DIM}Бэкап остался по пути:${NC}"
                echo -e "  ${CYAN}${_backup_file}${NC}"
                echo ""
                echo -e "  ${DIM}Для ручного восстановления:${NC}"
                echo -e "  ${CYAN}cp ${_backup_file} ${DETECTED_CONFIG_PATH}${NC}"
                echo -e "  ${DIM}Затем перезапустите telemt${NC}"
            fi
        else
            echo ""
            echo -e "  ${DIM}Бэкапы конфигурации не найдены.${NC}"
            echo -e "  ${DIM}Если тюнинг был применён, откатите параметры вручную.${NC}"
        fi
    fi
    echo ""; exit 0
}

# ── Интерфейс ─────────────────────────────────────────────────
show_header() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""; echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC} ${DIM}by LiafanX${NC}"
    echo -e "  ${DIM}Telemt inbound SYN limiter + тюнинг${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"; echo ""

    local _nft_status="${RED}неактивно${NC}"
    if nft list table inet "${NFT_TABLE:-telemt_limit}" &>/dev/null; then
        if [ "${NFT_MODE:-classic}" = "smart" ]; then
            local _ios_lim_info _other_lim_info
            if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
                _ios_lim_info="iOS: ${NFT_IOS_RATE}/${NFT_IOS_BURST}"
            else
                _ios_lim_info="iOS: unlimited"
            fi
            if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
                _other_lim_info="Other: ${NFT_OTHER_RATE}/${NFT_OTHER_BURST}"
            else
                _other_lim_info="Other: unlimited"
            fi
            _nft_status="${GREEN}Smart By-MEKO${NC} (${_ios_lim_info} ${_other_lim_info})"
            else
            _nft_status="${GREEN}Classic${NC} (${NFT_RATE} burst ${NFT_BURST})"
        fi
    fi

    local _svc_status="${DIM}не установлена${NC}"
    local _active_unit; _active_unit=$(service_unit_name)
    if systemctl is-enabled "$_active_unit" &>/dev/null 2>&1; then
        if systemctl is-active "$_active_unit" &>/dev/null 2>&1; then
            _svc_status="${GREEN}вкл + работает${NC}"
        else
            _svc_status="${YELLOW}вкл + остановлена${NC}"
        fi
    fi

    local _tuning_status="${DIM}не применён${NC}"
    case "$TUNING_APPLIED" in
        true)    _tuning_status="${GREEN}применён${NC}" ;;
        manual)  _tuning_status="${YELLOW}вручную${NC}" ;;
        partial) _tuning_status="${YELLOW}частично${NC}" ;;
    esac

    local _ios_status;  _ios_status=$(ios_fix_status)
    local _ios2_status; _ios2_status=$(ios2_fix_status)

    echo -e "  ${BOLD}Обнаружение:${NC}   ${DETECTED_MODE:-не найден}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        echo -e "  ${BOLD}Сеть:${NC}          bridge → hook ${NFT_HOOK} (${DOCKER_BRIDGE_MODE})"
    else
        echo -e "  ${BOLD}Сеть:${NC}          ${DETECTED_NETWORK_MODE:-неизвестно} → hook ${NFT_HOOK}"
    fi
    echo -e "  ${BOLD}Конфиг:${NC}        ${DETECTED_CONFIG_PATH:-${DIM}не найден${NC}}"
    echo -e "  ${BOLD}NFT правила:${NC}   ${_nft_status}"
    echo -e "  ${BOLD}NFT режим:${NC}     ${NFT_MODE:-classic}"
    echo -e "  ${BOLD}Служба:${NC}        ${_svc_status}"; echo ""

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        if [ "${DOCKER_BRIDGE_MODE:-simple}" = "precise" ] && [ -n "$DETECTED_CONTAINER" ]; then
            local _cip; _cip=$(docker_container_ip)
            echo -e "  ${BOLD}IP режим:${NC}      ${GREEN}авто по IP контейнера${NC}"
            echo -e "  ${BOLD}IP Контейнера:${NC}  ${_cip:-${DIM}не найден${NC}}"
        else
            echo -e "  ${BOLD}IP режим:${NC}      ${DIM}без IP привязки (только по порту)${NC}"
        fi
    else
        echo -e "  ${BOLD}IP привязка:${NC}   ${SERVER_IP:-${DIM}отключена (все IP сервера)${NC}}"
    fi

    echo -e "  ${BOLD}Порт:${NC}          ${SERVER_PORT:-${DIM}не задан${NC}}"
    if [ "${NFT_MODE:-classic}" = "smart" ]; then
        if [ "${NFT_IOS_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "  ${BOLD}iOS Rate:${NC}      ${NFT_IOS_RATE} burst ${NFT_IOS_BURST}"
        else
            echo -e "  ${BOLD}iOS Rate:${NC}      ${YELLOW}отключён (unlimited)${NC}"
        fi
        local _detect_short
        [ "${NFT_IOS_DETECT:-fingerprint}" = "ttl" ] && _detect_short="${YELLOW}TTL+Len${NC}" || _detect_short="${GREEN}fingerprint${NC}"
        echo -e "  ${BOLD}iOS detect:${NC}    ${_detect_short}"        
        if [ "${NFT_OTHER_LIMIT_ENABLED:-true}" = "true" ]; then
            echo -e "  ${BOLD}Other Rate:${NC}    ${NFT_OTHER_RATE} burst ${NFT_OTHER_BURST}"
        else
            echo -e "  ${BOLD}Other Rate:${NC}    ${YELLOW}отключён (unlimited)${NC}"
        fi
    else
        echo -e "  ${BOLD}Rate:${NC}          ${NFT_RATE}"
        echo -e "  ${BOLD}Burst:${NC}         ${NFT_BURST}"
    fi
    echo -e "  ${BOLD}Meter timeout:${NC} ${NFT_METER_TIMEOUT}"
    echo ""
    echo -e "  ${BOLD}Тюнинг:${NC}        tg_connect=${TUNING_TG_CONNECT}  handshake=${TUNING_CLIENT_HANDSHAKE}  keepalive=${TUNING_CLIENT_KEEPALIVE}  (${_tuning_status})"
    echo -e "  ${BOLD}iOS фикс v1:${NC}   ${_ios_status}"
    echo -e "  ${BOLD}iOS фикс v2:${NC}   ${_ios2_status}"
    echo -e "  ${BOLD}MEKO оптимизация:${NC} $(meko_opt_status)"
    if [ "$EXTRA_RULES_COUNT" -gt 0 ]; then
        echo ""; echo -e "  ${BOLD}Доп. правила:${NC}"
        local _i; for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
            echo -e "    ${DIM}[$_i]${NC} порт=${EXTRA_RULES_PORT[$_i]:-?} ip=${EXTRA_RULES_IP[$_i]:-любой} rate=${EXTRA_RULES_RATE[$_i]:-?} burst=${EXTRA_RULES_BURST[$_i]:-?}"
        done
    fi
    echo ""; echo -e "  ${DIM}────────────────────────────────────────${NC}"
}

show_main_menu() {
    while true; do
        show_header
        echo -e "  ${GREEN}[s]${NC}  ${BOLD}★ Smart By-MEKO${NC} ${DIM}(iOS/Android авторазделение + REJECT)${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Применить NFT правила"
        echo -e "  ${CYAN}[2]${NC}  Применить тюнинг Telemt"
        echo -e "  ${CYAN}[3]${NC}  Настройки"
        echo -e "  ${CYAN}[4]${NC}  Пресеты (жёсткий / средний / мягкий / smart)"
        echo -e "  ${CYAN}[5]${NC}  Счётчик срабатывания правил (смотреть live) - выход ctrl+c"
        echo -e "  ${CYAN}[6]${NC}  Управление службой"
        echo -e "  ${CYAN}[7]${NC}  Доп. правила (добавить порт)"
        echo -e "  ${CYAN}[8]${NC}  Повторно обнаружить Telemt"
        echo -e "  ${CYAN}[9]${NC}  Фикс для iOS вариант 1 (TCP keepalive)"
        echo -e "  ${CYAN}[a]${NC}  Фикс для iOS вариант 2 (MSS + redirect)"
        echo -e "  ${CYAN}[m]${NC}  Оптимизация системы By-MEKO"
        if [ "${NFT_MODE:-classic}" = "smart" ]; then
            echo -e "  ${CYAN}[c]${NC}  Настройки Smart режима"
        fi
        echo ""
        echo -e "  ${RED}[u]${NC}  Удалить"
        echo -e "  ${CYAN}[0]${NC}  Выход"; echo ""
        echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            s|S) enable_smart_mode; echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            1)
                if [ -z "$SERVER_PORT" ]; then
                    log_error "Порт не задан — настройте в разделе Настройки"
                    read -rsn1; continue
                fi
                apply_nft_rules || true
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            2) apply_tuning || true; echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            3) show_settings_menu ;;
            4) show_preset_menu ;;
            5) show_drop_counter || true ;;
            6) show_service_menu ;;
            7) show_extra_rules_menu ;;
            8)
                detect_telemt || true
                [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
                if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
                    NFT_HOOK="forward"
                else
                    [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ] && SERVER_IP="$DETECTED_IP"
                    NFT_HOOK="input"
                fi
                save_settings
                log_success "Обнаружено: режим=$DETECTED_MODE порт=${DETECTED_PORT:-?}"
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            9) show_ios_fix_menu ;;
            a|A) show_ios2_fix_menu ;;
            c|C) [ "${NFT_MODE:-classic}" = "smart" ] && show_smart_settings_menu ;;
            m|M) show_meko_opt_menu ;;
            u|U) full_uninstall ;;
            0|q|Q) exit 0 ;;
        esac
    done
}

show_settings_menu() {
    while true; do
        show_header; echo -e "  ${BOLD}Настройки${NC}"; echo ""
        if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
            echo -e "  ${DIM}[1]${NC} Привязка к IPv4 [${DIM}не используется в bridge${NC}]"
        else
            echo -e "  ${DIM}[1]${NC} Привязка к IPv4 [${SERVER_IP:-отключена}]"
        fi
        echo -e "  ${DIM}[2]${NC} Порт            [${SERVER_PORT:-не задан}]"
        echo -e "  ${DIM}[3]${NC} Rate             [${NFT_RATE}]"
        echo -e "  ${DIM}[4]${NC} Burst            [${NFT_BURST}]"
        echo -e "  ${DIM}[5]${NC} Meter timeout    [${NFT_METER_TIMEOUT}]"
        echo -e "  ${DIM}[6]${NC} tg_connect       [${TUNING_TG_CONNECT}]"
        echo -e "  ${DIM}[7]${NC} client_handshake [${TUNING_CLIENT_HANDSHAKE}]"
        echo -e "  ${DIM}[8]${NC} client_keepalive [${TUNING_CLIENT_KEEPALIVE}]"
        echo -e "  ${DIM}[9]${NC} Определить IP из интернета"
        if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
            echo -e "  ${DIM}[b]${NC} Режим Docker bridge [${DOCKER_BRIDGE_MODE}]"
        fi
        echo -e "  ${DIM}[c]${NC} Очистить IP (применять ко всем адресам)"
        echo -e "  ${DIM}[0]${NC} Назад"; echo ""
        echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            1)
                if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
                    log_info "В bridge-режиме привязка к внешнему IPv4 не используется"
                    log_info "Используйте [b] для выбора bridge-режима: simple или precise"
                    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
                    continue
                fi
                echo ""
                echo -e "  ${DIM}Enter  — оставить текущее значение${NC}"
                echo -e "  ${DIM}none   — убрать привязку к IP${NC}"
                echo -e "  ${DIM}auto   — автоопределить публичный IPv4${NC}"
                echo -e "  ${DIM}или введите свой IPv4 вручную${NC}"
                echo ""
                while true; do
                    echo -en "  ${BOLD}IPv4 сервера [${SERVER_IP:-none}]:${NC} "
                    local _val; read -r _val
                    [ -z "$_val" ] && break
                    case "$_val" in
                        none|NONE|clear|CLEAR|-)
                            SERVER_IP=""; save_settings
                            log_success "Привязка к IP отключена"
                            prompt_apply_nft_rules; break ;;
                        auto|AUTO)
                            log_info "Определение публичного IP..."
                            local _detected_ip; _detected_ip=$(detect_public_ip)
                            if [ -n "$_detected_ip" ] && validate_ip_literal "$_detected_ip"; then
                                SERVER_IP="$_detected_ip"; save_settings
                                log_success "IP определён: ${SERVER_IP}"
                                prompt_apply_nft_rules; break
                            else
                                log_error "Не удалось определить корректный публичный IPv4"
                            fi ;;
                        *)
                            if validate_ip_literal "$_val"; then
                                SERVER_IP="$_val"; save_settings
                                log_success "IP установлен: ${SERVER_IP}"
                                prompt_apply_nft_rules; break
                            else
                                log_error "Некорректный IPv4. Введите IPv4, Enter, none, clear, - или auto"
                            fi ;;
                    esac
                done ;;
            2)
                echo -en "  Новый порт [${SERVER_PORT:-}]: "
                local _val; read -r _val
                if [[ "$_val" =~ ^[0-9]+$ ]] && [ "$_val" -ge 1 ] && [ "$_val" -le 65535 ]; then
                    SERVER_PORT="$_val"; save_settings
                    log_success "Порт установлен: ${SERVER_PORT}"; prompt_apply_nft_rules
                elif [ -n "$_val" ]; then log_error "Некорректный порт"; fi ;;
            3)
                echo -en "  Новый rate (напр. 1/second, 2/second): "
                local _val; read -r _val
                if [ -n "$_val" ]; then
                    NFT_RATE="$_val"; save_settings
                    log_success "Rate установлен: ${NFT_RATE}"; prompt_apply_nft_rules
                fi ;;
            4)
                echo -en "  Новый burst: "
                local _val; read -r _val
                if [[ "$_val" =~ ^[0-9]+$ ]]; then
                    NFT_BURST="$_val"; save_settings
                    log_success "Burst установлен: ${NFT_BURST}"; prompt_apply_nft_rules
                elif [ -n "$_val" ]; then log_error "Некорректный burst"; fi ;;
            5)
                echo -en "  Новый meter timeout (напр. 30s, 60s, 120s): "
                local _val; read -r _val
                if [ -n "$_val" ]; then
                    NFT_METER_TIMEOUT="$_val"; save_settings
                    log_success "Meter timeout установлен: ${NFT_METER_TIMEOUT}"; prompt_apply_nft_rules
                fi ;;
            6) echo -en "  tg_connect [${TUNING_TG_CONNECT}]: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && { TUNING_TG_CONNECT="$_val"; save_settings; } ;;
            7) echo -en "  client_handshake [${TUNING_CLIENT_HANDSHAKE}]: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && { TUNING_CLIENT_HANDSHAKE="$_val"; save_settings; } ;;
            8) echo -en "  client_keepalive [${TUNING_CLIENT_KEEPALIVE}]: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && { TUNING_CLIENT_KEEPALIVE="$_val"; save_settings; } ;;
            9)
                log_info "Определение публичного IP..."
                local _detected_ip; _detected_ip=$(detect_public_ip)
                if [ -n "$_detected_ip" ]; then
                    SERVER_IP="$_detected_ip"; save_settings
                    log_success "IP определён: $_detected_ip"; prompt_apply_nft_rules
                else
                    log_error "Не удалось определить публичный IP"
                fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            b|B)
                if [ "$DETECTED_NETWORK_MODE" != "bridge" ]; then
                    log_info "Режим Docker bridge недоступен"
                else
                    prompt_bridge_mode; prompt_apply_nft_rules
                fi ;;
            c|C)
                SERVER_IP=""; save_settings
                log_success "IP очищен — правила будут применяться ко всем адресам"
                prompt_apply_nft_rules
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            0|"") return ;;
        esac
    done
}

show_preset_menu() {
    show_header; echo -e "  ${BOLD}Пресеты${NC}"; echo ""
    echo -e "  ${GREEN}[s]${NC} ${BOLD}★ Smart By-MEKO${NC} ${DIM}(рекомендуется)${NC}"
    echo -e "      ${DIM}iOS/Android авторазделение + REJECT. Подключение 3-8 сек.${NC}"; echo ""
    echo -e "  ${RED}[1]${NC} Жёсткий (Classic)  — 1/second burst 1"
    echo -e "  ${YELLOW}[2]${NC} Средний (Classic)  — 1/second burst 3"
    echo -e "  ${GREEN}[3]${NC} Мягкий (Classic)   — 2/second burst 5"
    echo -e "  ${DIM}[4]${NC} Свой вариант (Classic)"
    echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in
        s|S) enable_smart_mode; return ;;
        1) apply_preset hard ;;
        2) apply_preset medium ;;
        3) apply_preset soft ;;
        4)
            echo -en "  Rate (напр. 1/second): "; local _r; read -r _r
            echo -en "  Burst: "; local _b; read -r _b
            [ -n "$_r" ] && NFT_RATE="$_r"
            [[ "$_b" =~ ^[0-9]+$ ]] && NFT_BURST="$_b"
            NFT_MODE="classic"; save_settings
            log_success "Свой вариант: rate=$NFT_RATE burst=$NFT_BURST" ;;
        0|"") return ;;
    esac
    echo ""; echo -en "  Применить NFT правила сейчас? [Y/n]: "; local _yn; read -r _yn
    if [[ ! "$_yn" =~ ^[nN] ]]; then
        apply_nft_rules || true
        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
    fi
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

show_service_menu() {
    show_header
    echo -e "  ${BOLD}Управление службой${NC}"; echo ""
    local _unit; _unit=$(service_unit_name)
    local _status="${DIM}не установлена${NC}"
    if systemctl is-enabled "$_unit" &>/dev/null 2>&1; then
        if systemctl is-active "$_unit" &>/dev/null 2>&1; then
            _status="${GREEN}вкл + работает${NC}"
        else
            _status="${YELLOW}вкл + остановлена${NC}"
        fi
    fi
    echo -e "  Активная служба: ${_unit}"
    echo -e "  Статус: ${_status}"; echo ""
    echo -e "  ${DIM}[1]${NC} Установить и включить службу"
    echo -e "  ${DIM}[2]${NC} Удалить службу"
    echo -e "  ${DIM}[3]${NC} Перезапустить службу"
    echo -e "  ${DIM}[4]${NC} Остановить службу (правила сохранятся)"
    echo -e "  ${DIM}[5]${NC} Логи службы"
    echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in
        1)
            if [ -z "$SERVER_PORT" ]; then
                log_error "Порт не задан — настройте в разделе Настройки"
            else
                install_service
            fi ;;
        2) remove_service ;;
        3) systemctl restart "$_unit" 2>/dev/null && log_success "Служба перезапущена" || log_error "Не удалось перезапустить" ;;
        4) systemctl stop "$_unit" 2>/dev/null && log_success "Служба остановлена" || log_error "Не удалось остановить" ;;
        5) echo ""; journalctl -u "$_unit" -n 20 --no-pager 2>/dev/null || log_warn "Логов нет" ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

show_extra_rules_menu() {
    while true; do
        show_header; echo -e "  ${BOLD}Дополнительные правила${NC}"; echo ""
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
        echo -e "  ${DIM}[0]${NC} Назад"; echo ""
        echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            a|A)
                echo -en "  Порт: "; local _p; read -r _p
                if ! [[ "$_p" =~ ^[0-9]+$ ]] || [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
                    log_error "Некорректный порт"; echo ""; read -rsn1 -p "  Нажмите любую клавишу..."; continue
                fi
                echo -en "  IP (пусто = любой): "; local _eip; read -r _eip
                echo -en "  Rate [1/second]: "; local _r; read -r _r; [ -z "$_r" ] && _r="1/second"
                echo -en "  Burst [1]: "; local _b; read -r _b; [ -z "$_b" ] && _b="1"
                EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT + 1))
                local _idx=$EXTRA_RULES_COUNT
                EXTRA_RULES_PORT[$_idx]="$_p"; EXTRA_RULES_IP[$_idx]="$_eip"
                EXTRA_RULES_RATE[$_idx]="$_r"; EXTRA_RULES_BURST[$_idx]="$_b"
                save_settings; log_success "Доп. правило $_idx добавлено"
                echo -en "  Применить правила сейчас? [Y/n]: "; local _yn; read -r _yn
                if [[ ! "$_yn" =~ ^[nN] ]]; then
                    apply_nft_rules || true
                    [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
                fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            d|D)
                [ "$EXTRA_RULES_COUNT" -eq 0 ] && { log_info "Нет правил для удаления"; echo ""; read -rsn1 -p "  Нажмите любую клавишу..."; continue; }
                echo -en "  Номер правила для удаления: "; local _idx; read -r _idx
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
                    save_settings; log_success "Правило удалено"
                    echo -en "  Применить правила заново? [Y/n]: "; local _yn; read -r _yn
                    if [[ ! "$_yn" =~ ^[nN] ]]; then
                        apply_nft_rules || true
                        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service
                    fi
                else
                    log_error "Некорректный номер правила"
                fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            0|"") return ;;
        esac
    done
}

# ── Мастер первого запуска ────────────────────────────────────
first_run_wizard() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""; echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}Мастер первоначальной настройки${NC}"; echo ""
    echo -e "  ${DIM}────────────────────────────────────────${NC}"; echo ""

    log_info "Поиск установленного Telemt..."
    if detect_telemt; then
        log_success "Найден: ${DETECTED_MODE}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
        [ -n "$DETECTED_CONFIG_PATH" ] && log_info "Конфиг: ${DETECTED_CONFIG_PATH}"
        [ -n "$DETECTED_PORT" ] && log_info "Порт: ${DETECTED_PORT}"
        [ -n "$DETECTED_NETWORK_MODE" ] && log_info "Сеть: ${DETECTED_NETWORK_MODE}"
        if [ -n "$DETECTED_CONFIG_PATH" ]; then
            echo ""; echo -en "  ${DIM}Указать другой путь к конфигу? [N/путь]:${NC} "
            local _alt_cfg; read -r _alt_cfg
            if [ -n "$_alt_cfg" ] && [ "$_alt_cfg" != "n" ] && [ "$_alt_cfg" != "N" ]; then
                if [ -f "$_alt_cfg" ]; then
                    DETECTED_CONFIG_PATH="$_alt_cfg"; log_success "Конфиг: $_alt_cfg"
                    local _p; _p=$(_toml_get_value "port" "$_alt_cfg"); [ -n "$_p" ] && DETECTED_PORT="$_p"
                else
                    log_error "Файл не найден: $_alt_cfg"
                fi
            fi
        fi
    else
        log_warn "Telemt не обнаружен автоматически"; echo ""
        echo -en "  ${BOLD}Указать путь к конфигу Telemt вручную? [n/путь]:${NC} "
        local _manual_cfg; read -r _manual_cfg
        if [ -n "$_manual_cfg" ] && [ "$_manual_cfg" != "n" ] && [ "$_manual_cfg" != "N" ]; then
            if [ -f "$_manual_cfg" ]; then
                DETECTED_CONFIG_PATH="$_manual_cfg"; DETECTED_MODE="manual"; DETECTED_NETWORK_MODE="host"
                log_success "Конфиг: $_manual_cfg"
                local _p; _p=$(_toml_get_value "port" "$_manual_cfg"); [ -n "$_p" ] && DETECTED_PORT="$_p"
            else
                log_error "Файл не найден: $_manual_cfg"
            fi
        fi
    fi

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        NFT_HOOK="forward"; SERVER_IP=""
    else
        NFT_HOOK="input"
    fi

    echo ""
    install_dependencies || exit 1

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        prompt_bridge_mode
    fi

    # Порт
    echo ""; SERVER_PORT="${DETECTED_PORT:-443}"
    echo -en "  ${BOLD}Порт прокси [${SERVER_PORT}]:${NC} "
    local _port_input; read -r _port_input
    if [[ "$_port_input" =~ ^[0-9]+$ ]] && [ "$_port_input" -ge 1 ] && [ "$_port_input" -le 65535 ]; then
        SERVER_PORT="$_port_input"
    fi

    # IP
    echo ""
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
        if [ "${DOCKER_BRIDGE_MODE:-simple}" = "simple" ]; then
            log_info "Docker bridge / простой режим: внешний IP не используется"
        else
            local _cip; _cip=$(docker_container_ip)
            log_info "Docker bridge / точный режим: будет использоваться IP контейнера"
            [ -n "$_cip" ] && log_info "Текущий IP контейнера: ${_cip}"
        fi
        SERVER_IP=""
    else
        echo -e "  ${DIM}Можно привязать правило к конкретному IPv4-адресу сервера.${NC}"
        echo -e "  ${DIM}Если IP не указывать — правило будет работать для всех${NC}"
        echo -e "  ${DIM}локальных IP сервера на выбранном порту.${NC}"
        echo ""
        echo -en "  ${BOLD}Указать IPv4 сервера? [Y/n]:${NC} "
        local _use_ip; read -r _use_ip

        if [[ ! "$_use_ip" =~ ^[nN]$ ]]; then
            if [ -n "$DETECTED_IP" ]; then
                SERVER_IP="$DETECTED_IP"
                log_info "IP из конфига: $SERVER_IP"
            else
                log_info "Определение публичного IP..."
                SERVER_IP=$(detect_public_ip)
                [ -n "$SERVER_IP" ] && log_success "Определён: $SERVER_IP" || log_warn "Не удалось определить IP"
            fi

            echo ""
            echo -e "  ${DIM}Enter  — оставить найденный IP${NC}"
            echo -e "  ${DIM}none   — не использовать привязку к IP${NC}"
            echo -e "  ${DIM}или введите свой IPv4 вручную${NC}"
            echo ""

            while true; do
                echo -en "  ${BOLD}IPv4 сервера [${SERVER_IP:-none}]:${NC} "
                local _ip_input; read -r _ip_input
                [ -z "$_ip_input" ] && break
                case "$_ip_input" in
                    none|NONE|clear|CLEAR|-) SERVER_IP=""; break ;;
                esac
                if validate_ip_literal "$_ip_input"; then
                    SERVER_IP="$_ip_input"; break
                else
                    log_error "Некорректный IPv4. Введите IPv4, Enter, none, clear или -"
                fi
            done

            if [ -n "$SERVER_IP" ]; then
                log_success "Будет использоваться IP: $SERVER_IP"
            else
                log_info "Привязка к IP отключена"
            fi
        else
            SERVER_IP=""
            log_info "Привязка к IP отключена"
        fi
    fi

    # Пресет NFT
    echo ""; echo -e "  ${BOLD}Режим NFT SYN Limiter:${NC}"; echo ""
    echo -e "  ${GREEN}[s]${NC} ${BOLD}★ Smart By-MEKO${NC} ${DIM}(рекомендуется)${NC}"
    echo -e "      ${DIM}iOS/Android авторазделение по TTL + REJECT. Подключение 3-8 сек.${NC}"
    echo -e "      ${DIM}Один порт для всех клиентов.${NC}"; echo ""
    echo -e "  ${DIM}Или Classic режим:${NC}"
    echo -e "    ${RED}[1]${NC} Жёсткий  — 1/sec burst 1"
    echo -e "    ${YELLOW}[2]${NC} Средний  — 1/sec burst 3"
    echo -e "    ${GREEN}[3]${NC} Мягкий   — 2/sec burst 5"; echo ""
    echo -en "  Выбор [s]: "; local _preset_input; read -r _preset_input
    case "$_preset_input" in
        1) apply_preset hard ;;
        2) apply_preset medium ;;
        3) apply_preset soft ;;
        *) apply_preset smart ;;
    esac

    # Выбор действия для non-iOS (только для Smart режима)
    if [ "${NFT_MODE:-classic}" = "smart" ]; then
        echo ""
        echo -e "  ${BOLD}Действие для non-iOS устройств (Android / Desktop):${NC}"; echo ""
        echo -e "  ${GREEN}[1]${NC} ${BOLD}icmp-host-unreachable${NC} ${DIM}(рекомендуется — по умолчанию)${NC}"
        echo -e "      ${DIM}Сервер притворяется недоступным узлом сети.${NC}"
        echo -e "      ${DIM}Telegram сразу понимает что параллельный путь закрыт${NC}"
        echo -e "      ${DIM}и переключается на основное соединение без задержек.${NC}"
        echo -e "      ${DIM}Результат: медиа начинает отправляться быстро.${NC}"
        echo ""
        echo -e "  ${CYAN}[2]${NC} reject (tcp reset)  ${DIM}(оригинал By-MEKO)${NC}"
        echo -e "      ${DIM}Жёсткий TCP сброс. Быстрый reconnect,${NC}"
        echo -e "      ${DIM}но небольшая задержка при старте отправки медиа.${NC}"
        echo ""
        echo -e "  ${YELLOW}[3]${NC} drop  ${DIM}(не рекомендуется)${NC}"
        echo -e "      ${DIM}Telegram зависает в ожидании — отправка медиа может не работать.${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор [1]:${NC} "
        local _action_choice; read -r _action_choice
        case "${_action_choice:-1}" in
            2) NFT_OTHER_ACTION="reject" ;;
            3) NFT_OTHER_ACTION="drop" ;;
            *) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
        esac
        log_success "Other Action: ${NFT_OTHER_ACTION}"
    fi

    save_settings

    # Тюнинг
    echo ""
    echo -e "  ${BOLD}Тюнинг Telemt — будут применены следующие параметры:${NC}"; echo ""
    echo -e "  ${DIM}[general]${NC}"
    echo -e "    tg_connect       = ${BOLD}${TUNING_TG_CONNECT}${NC}  ${DIM}(таймаут подключения к Telegram DC)${NC}"
    echo ""
    echo -e "  ${DIM}[timeouts]${NC}"
    echo -e "    client_handshake = ${BOLD}${TUNING_CLIENT_HANDSHAKE}${NC}  ${DIM}(ожидание начального handshake)${NC}"
    echo -e "    client_keepalive = ${BOLD}${TUNING_CLIENT_KEEPALIVE}${NC}  ${DIM}(ожидание активности клиента)${NC}"
    echo ""
    echo -en "  ${BOLD}Применить тюнинг Telemt? [Y/n]:${NC} "
    local _yn_tuning; read -r _yn_tuning
    if [[ ! "$_yn_tuning" =~ ^[nN] ]]; then apply_tuning || true; fi

    # iOS Fix v1
    echo ""
    echo -en "  ${BOLD}Применить фикс для iOS вариант 1 (TCP keepalive)? [y/N]:${NC} "
    local _yn_ios; read -r _yn_ios
    if [[ "$_yn_ios" =~ ^[yY]$ ]]; then
        if [ -z "$IOS_ORIG_TIME" ]; then
            IOS_ORIG_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "7200")
            IOS_ORIG_INTVL=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "75")
            IOS_ORIG_PROBES=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "9")
        fi
        printf '# MTproxy-reanimation: фикс для iOS — TCP keepalive\nnet.ipv4.tcp_keepalive_time = 60\nnet.ipv4.tcp_keepalive_intvl = 15\nnet.ipv4.tcp_keepalive_probes = 3\n' \
            > "$IOS_SYSCTL_FILE"
        sysctl --system &>/dev/null || true
        IOS_FIX_APPLIED="true"; save_settings
        log_success "Фикс для iOS применён"
    fi

    # Подсказка про iOS Fix v2 при Classic режиме
    if [ "${NFT_MODE:-classic}" = "classic" ]; then
        echo ""
        log_info "iOS Fix v2 (MSS + redirect) доступен в меню: [a] Фикс для iOS вариант 2"
    fi

    # Оптимизация By-MEKO
    echo ""
    echo -e "  ${BOLD}Оптимизация системы By-MEKO${NC}"
    echo -e "  ${DIM}Набор sysctl-параметров из проекта MTPROTO-FIX-By-MEKO.${NC}"
    echo -e "  ${DIM}TCP keepalive 45s/15s×3, BBR, расширенные очереди.${NC}"
    echo -e "  ${DIM}Текущие значения будут сохранены для отката.${NC}"
    echo ""
    echo -en "  ${BOLD}Применить оптимизацию By-MEKO? [y/N]:${NC} "
    local _yn_meko; read -r _yn_meko
    if [[ "$_yn_meko" =~ ^[yY]$ ]]; then
        meko_opt_apply
    fi

    # NFT правила
    echo ""
    echo -en "  ${BOLD}Применить NFT правила сейчас? [Y/n]:${NC} "
    local _yn_nft; read -r _yn_nft
    if [[ ! "$_yn_nft" =~ ^[nN] ]]; then apply_nft_rules || true; fi

    # Служба
    echo ""
    echo -en "  ${BOLD}Установить как службу (автозапуск при загрузке)? [Y/n]:${NC} "
    local _yn_svc; read -r _yn_svc
    if [[ ! "$_yn_svc" =~ ^[nN] ]]; then install_service || true; fi

    echo ""; log_success "Настройка завершена!"; echo ""
    echo -e "  ${DIM}Запускайте ${CYAN}mtpr${DIM} в любое время для управления${NC}"; echo ""
    read -rsn1 -p "  Нажмите любую клавишу для входа в меню..."
}

# ── Проверка обновлений ───────────────────────────────────────
check_for_update() {
    local _remote_ver
    _remote_ver=$(curl -fsS --max-time 5 "${GITHUB_RAW}/version" 2>/dev/null | tr -d '[:space:]') || true
    [ -z "$_remote_ver" ] && return 0
    [ "$_remote_ver" = "$VERSION" ] && return 0

    echo ""
    echo -e "  ${YELLOW}${BOLD}Доступно обновление: v${VERSION} → v${_remote_ver}${NC}"
    echo -en "  ${BOLD}Обновить сейчас? [Y/n]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[nN] ]] && return 0

    log_info "Скачивание обновления..."
    local _tmp="/tmp/mtpr-update-$$.sh"
    if curl -fsS --max-time 30 "${GITHUB_RAW}/mtpr.sh" -o "$_tmp" 2>/dev/null; then
        if ! bash -n "$_tmp" 2>/dev/null; then
            log_error "Скачанный файл содержит ошибки синтаксиса — обновление отменено"
            rm -f "$_tmp"; return 1
        fi
        cp "${INSTALL_DIR}/mtpr.sh" "${INSTALL_DIR}/mtpr.sh.backup-$(date +%s)" 2>/dev/null || true
        mv "$_tmp" "${INSTALL_DIR}/mtpr.sh"
        chmod +x "${INSTALL_DIR}/mtpr.sh"
        log_success "Обновлено до v${_remote_ver}"
        log_info "Перезапуск..."
        exec "${INSTALL_DIR}/mtpr.sh"
    else
        log_error "Не удалось скачать обновление"
        rm -f "$_tmp"
    fi
}

# ── Главная точка входа ───────────────────────────────────────
main() {
    check_root
    mkdir -p "$INSTALL_DIR"
    local _self="${BASH_SOURCE[0]}"
    if [ -f "$_self" ] && \
       [ "$(realpath "$_self" 2>/dev/null)" != "$(realpath "${INSTALL_DIR}/mtpr.sh" 2>/dev/null)" ]; then
        cp "$_self" "${INSTALL_DIR}/mtpr.sh"
        chmod +x "${INSTALL_DIR}/mtpr.sh"
    fi
    ln -sf "${INSTALL_DIR}/mtpr.sh" /usr/local/bin/mtpr 2>/dev/null || true
    load_settings
    detect_telemt || true
    [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
    [ -z "$SERVER_IP" ]   && [ -n "$DETECTED_IP" ]   && SERVER_IP="$DETECTED_IP"
    check_for_update || true
    if [ ! -f "$SETTINGS_FILE" ]; then
        if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then
            NFT_HOOK="forward"
        else
            NFT_HOOK="input"
        fi
        first_run_wizard
    fi
    show_main_menu
}

main "$@"
