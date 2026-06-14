#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MTproxy-reanimation v1.0.5
#  Telemt inbound SYN limiter + tuning manager
#  https://github.com/Liafanx/MTproxy-reanimation
# ═══════════════════════════════════════════════════════════════
set -eo pipefail

VERSION="1.0.5"
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
TUNING_TG_CONNECT="30"
TUNING_CLIENT_HANDSHAKE="90"
TUNING_CLIENT_KEEPALIVE="120"
TUNING_APPLIED="false"
NFT_SERVICE_ENABLED="false"
IOS_FIX_APPLIED="false"
IOS2_FIX_APPLIED="false"
IOS2_EXTERNAL_PORT="4443"
IOS2_TARGET_PORT=""
IOS2_MSS="92"
IOS2_TABLE="mtpr_ios2_fix"

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
TUNING_TG_CONNECT='${TUNING_TG_CONNECT}'
TUNING_CLIENT_HANDSHAKE='${TUNING_CLIENT_HANDSHAKE}'
TUNING_CLIENT_KEEPALIVE='${TUNING_CLIENT_KEEPALIVE}'
TUNING_APPLIED='${TUNING_APPLIED}'
NFT_SERVICE_ENABLED='${NFT_SERVICE_ENABLED}'
IOS_FIX_APPLIED='${IOS_FIX_APPLIED}'
IOS2_FIX_APPLIED='${IOS2_FIX_APPLIED}'
IOS2_EXTERNAL_PORT='${IOS2_EXTERNAL_PORT}'
IOS2_TARGET_PORT='${IOS2_TARGET_PORT}'
IOS2_MSS='${IOS2_MSS}'
IOS2_TABLE='${IOS2_TABLE}'
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
                IOS_FIX_APPLIED|IOS2_FIX_APPLIED|IOS2_EXTERNAL_PORT|\
                IOS2_TARGET_PORT|IOS2_MSS|IOS2_TABLE|EXTRA_RULES_COUNT)
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
    for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml /opt/mtproxymax/mtproxy/config.toml; do
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
                log_warn "Файл не похож на конфиг Telemt, но используем его"; DETECTED_CONFIG_PATH="$_custom_path"
            else
                log_error "Файл не найден: $_custom_path"; TUNING_APPLIED="manual"; save_settings; return 0
            fi ;;
    esac

    local _cfg="$DETECTED_CONFIG_PATH"
    cp "$_cfg" "${_cfg}.mtpr-backup-$(date +%s)" 2>/dev/null || true
    local _cur _changed=false _failed=false

    _cur=$(_toml_get_value "tg_connect" "$_cfg")
    if [ "$_cur" != "$TUNING_TG_CONNECT" ]; then
        if _toml_safe_set "tg_connect" "$TUNING_TG_CONNECT" "general" "$_cfg"; then
            _changed=true; log_success "tg_connect = $TUNING_TG_CONNECT"
        else log_warn "Секция [general] не найдена — tg_connect не применён"; _failed=true; fi
    else log_info "tg_connect уже $TUNING_TG_CONNECT"; fi

    _cur=$(_toml_get_value "client_handshake" "$_cfg")
    if [ "$_cur" != "$TUNING_CLIENT_HANDSHAKE" ]; then
        if _toml_safe_set "client_handshake" "$TUNING_CLIENT_HANDSHAKE" "timeouts" "$_cfg"; then
            _changed=true; log_success "client_handshake = $TUNING_CLIENT_HANDSHAKE"
        else log_warn "Секция [timeouts] не найдена — client_handshake не применён"; _failed=true; fi
    else log_info "client_handshake уже $TUNING_CLIENT_HANDSHAKE"; fi

    _cur=$(_toml_get_value "client_keepalive" "$_cfg")
    if [ "$_cur" != "$TUNING_CLIENT_KEEPALIVE" ]; then
        if _toml_safe_set "client_keepalive" "$TUNING_CLIENT_KEEPALIVE" "timeouts" "$_cfg"; then
            _changed=true; log_success "client_keepalive = $TUNING_CLIENT_KEEPALIVE"
        else log_warn "Секция [timeouts] не найдена — client_keepalive не применён"; _failed=true; fi
    else log_info "client_keepalive уже $TUNING_CLIENT_KEEPALIVE"; fi

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
                log_info "Отправка SIGHUP процессу telemt..."; pkill -HUP telemt 2>/dev/null || log_warn "Не удалось отправить сигнал"
            fi
        fi
    fi
    TUNING_APPLIED="true"; [ "$_failed" = "true" ] && TUNING_APPLIED="partial"; save_settings
}

# ── Фикс для iOS (TCP keepalive) ─────────────────────────────
ios_fix_status() {
    if [ -f "$IOS_SYSCTL_FILE" ]; then
        local _time _intvl _probes
        _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
        _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
        _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
        echo -e "${GREEN}активен${NC} (time=${_time} intvl=${_intvl} probes=${_probes})"
    else echo -e "${DIM}не применён${NC}"; fi
}

ios_fix_apply() {
    echo ""; echo -e "  ${BOLD}Фикс для iOS — TCP keepalive${NC}"; echo ""
    echo -e "  ${DIM}Проблема: мобильный клиент сворачивается, ОС усыпляет${NC}"
    echo -e "  ${DIM}приложение, сокет не закрывается чисто. Сервер держит${NC}"
    echo -e "  ${DIM}мёртвое соединение часами. При возврате клиент залипает.${NC}"; echo ""
    echo -e "  ${DIM}Решение: ускоряем TCP keepalive через sysctl.${NC}"
    echo -e "  ${DIM}Мёртвый коннект будет рваться за ~105 сек:${NC}"
    echo -e "  ${DIM}  60с тишины → проба каждые 15с × 3 попытки → RST${NC}"; echo ""
    local _cur_time _cur_intvl _cur_probes
    _cur_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _cur_intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _cur_probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    echo -e "  ${BOLD}Текущие значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_cur_time:-?}  ${DIM}(дефолт: 7200)${NC}"
    echo -e "    tcp_keepalive_intvl  = ${_cur_intvl:-?}  ${DIM}(дефолт: 75)${NC}"
    echo -e "    tcp_keepalive_probes = ${_cur_probes:-?}  ${DIM}(дефолт: 9)${NC}"; echo ""
    if [ -f "$IOS_SYSCTL_FILE" ]; then
        echo -e "  ${YELLOW}Файл ${IOS_SYSCTL_FILE} уже существует.${NC}"
        echo -en "  ${BOLD}Перезаписать? [Y/n]:${NC} "
    else echo -en "  ${BOLD}Применить фикс? [Y/n]:${NC} "; fi
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    cat > "$IOS_SYSCTL_FILE" << 'SYSEOF'
# MTproxy-reanimation: фикс для iOS — TCP keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
SYSEOF
    if sysctl --system &>/dev/null; then log_success "sysctl применён"
    else
        log_warn "sysctl --system вернул ошибку, применяем вручную"
        sysctl -w net.ipv4.tcp_keepalive_time=60 2>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_intvl=15 2>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null || true
    fi
    local _new_time _new_intvl _new_probes
    _new_time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _new_intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _new_probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    echo ""; echo -e "  ${BOLD}Новые значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_new_time}"
    echo -e "    tcp_keepalive_intvl  = ${_new_intvl}"
    echo -e "    tcp_keepalive_probes = ${_new_probes}"
    if [ "${_new_time}" = "60" ] && [ "${_new_intvl}" = "15" ] && [ "${_new_probes}" = "3" ]; then
        log_success "Фикс для iOS применён"; echo -e "  ${DIM}Мёртвый коннект будет рваться за ~105 сек${NC}"
    else log_warn "Значения не совпадают с ожидаемыми — проверьте вручную"; fi
    IOS_FIX_APPLIED="true"; save_settings
}

ios_fix_remove() {
    echo ""
    if [ ! -f "$IOS_SYSCTL_FILE" ]; then
        log_info "Фикс для iOS не установлен"; IOS_FIX_APPLIED="false"; save_settings; return 0
    fi
    echo -e "  ${BOLD}Откат фикса для iOS${NC}"; echo ""
    echo -e "  ${DIM}Будет удалён: ${IOS_SYSCTL_FILE}${NC}"
    echo -e "  ${DIM}Значения ядра вернутся к дефолтным (7200 / 75 / 9)${NC}"; echo ""
    echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
    local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    rm -f "$IOS_SYSCTL_FILE"
    sysctl -w net.ipv4.tcp_keepalive_time=7200 &>/dev/null || true
    sysctl -w net.ipv4.tcp_keepalive_intvl=75 &>/dev/null || true
    sysctl -w net.ipv4.tcp_keepalive_probes=9 &>/dev/null || true
    sysctl --system &>/dev/null || true
    local _time _intvl _probes
    _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    echo ""; echo -e "  ${BOLD}Текущие значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_time}"
    echo -e "    tcp_keepalive_intvl  = ${_intvl}"
    echo -e "    tcp_keepalive_probes = ${_probes}"
    log_success "Фикс для iOS откачен"; IOS_FIX_APPLIED="false"; save_settings
}

show_ios_fix_menu() {
    show_header; echo -e "  ${BOLD}Фикс для iOS (TCP keepalive)${NC}"; echo ""
    local _status; _status=$(ios_fix_status); echo -e "  Статус: ${_status}"; echo ""
    local _time _intvl _probes
    _time=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
    _intvl=$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)
    _probes=$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null)
    local _detect_secs=$(( ${_time:-7200} + ${_intvl:-75} * ${_probes:-9} ))
    echo -e "  ${BOLD}Значения ядра:${NC}"
    echo -e "    tcp_keepalive_time   = ${_time:-?}  ${DIM}(дефолт: 7200, фикс: 60)${NC}"
    echo -e "    tcp_keepalive_intvl  = ${_intvl:-?}  ${DIM}(дефолт: 75,   фикс: 15)${NC}"
    echo -e "    tcp_keepalive_probes = ${_probes:-?}  ${DIM}(дефолт: 9,    фикс: 3)${NC}"
    echo -e "    ${DIM}Время обнаружения мёртвого коннекта: ~${_detect_secs} сек${NC}"; echo ""
    echo -e "  ${DIM}[1]${NC} Применить фикс"
    echo -e "  ${DIM}[2]${NC} Откатить фикс"
    echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in 1) ios_fix_apply ;; 2) ios_fix_remove ;; 0|"") return ;; esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

# ── Фикс для iOS вариант 2 (MSS + redirect) ──────────────────
ios2_fix_status() {
    if [ "${IOS2_FIX_APPLIED:-false}" = "true" ]; then
        local _target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
        echo -e "${GREEN}активен${NC} (порт ${IOS2_EXTERNAL_PORT} → ${_target}, mss=${IOS2_MSS})"
    else echo -e "${DIM}не применён${NC}"; fi
}

_ios2_check_client_mss() {
    # Проверяем наличие client_mss в конфиге telemt
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
                echo -e "  в файле ${CYAN}${_cfg}${NC}"
                echo -e "  и перезапустите telemt"
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
    local _target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
    if [ -z "${SERVER_PORT:-}" ]; then log_error "Основной порт Telemt не определён"; return 1; fi
    if ! [[ "${IOS2_EXTERNAL_PORT}" =~ ^[0-9]+$ ]] || [ "${IOS2_EXTERNAL_PORT}" -lt 1 ] || [ "${IOS2_EXTERNAL_PORT}" -gt 65535 ]; then
        log_error "Некорректный внешний порт iOS v2"; return 1; fi
    if ! [[ "${_target}" =~ ^[0-9]+$ ]] || [ "${_target}" -lt 1 ] || [ "${_target}" -gt 65535 ]; then
        log_error "Некорректный целевой порт iOS v2"; return 1; fi
    if [ "${IOS2_EXTERNAL_PORT}" = "${_target}" ]; then
        log_error "Внешний порт iOS v2 не должен совпадать с основным портом"; return 1; fi
    if ! [[ "${IOS2_MSS}" =~ ^[0-9]+$ ]] || [ "${IOS2_MSS}" -lt 88 ] || [ "${IOS2_MSS}" -gt 4096 ]; then
        log_error "MSS должен быть в диапазоне 88..4096"; return 1; fi

    echo ""; echo -e "  ${BOLD}Фикс для iOS вариант 2 (MSS + redirect)${NC}"; echo ""
    echo -e "  ${DIM}Создаёт отдельный внешний порт для iOS-клиентов.${NC}"
    echo -e "  ${DIM}На этом порту входящий SYN получает MSS=${IOS2_MSS},${NC}"
    echo -e "  ${DIM}затем трафик прозрачно редиректится на основной порт.${NC}"; echo ""
    echo -e "  ${DIM}Android и Desktop продолжают работать на основном порту.${NC}"
    echo -e "  ${DIM}iOS-пользователям нужно заменить порт в ссылке.${NC}"; echo ""
    echo -e "    Внешний порт iOS: ${BOLD}${IOS2_EXTERNAL_PORT}${NC}"
    echo -e "    Основной порт:    ${_target}"
    echo -e "    MSS:              ${IOS2_MSS}"; echo ""

    # Проверяем client_mss в конфиге
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
    echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "; local _confirm; read -r _confirm
    [[ "$_confirm" =~ ^[nN] ]] && { log_info "Отменено"; return 0; }
    IOS2_FIX_APPLIED="false"; save_settings
    apply_nft_rules || true
    [ "${NFT_SERVICE_ENABLED:-false}" = "true" ] && install_service
    nft delete table inet "${IOS2_TABLE}" 2>/dev/null || true
    log_success "Фикс для iOS вариант 2 отключён"
}

show_ios2_fix_menu() {
    show_header; echo -e "  ${BOLD}Фикс для iOS вариант 2 (MSS + redirect)${NC}"; echo ""
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
            echo -en "  Новый внешний порт [${IOS2_EXTERNAL_PORT}]: "; local _p; read -r _p
            if [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                IOS2_EXTERNAL_PORT="$_p"; save_settings; log_success "Внешний порт: $_p"
            elif [ -n "$_p" ]; then log_error "Некорректный порт"; fi ;;
        4)
            echo -en "  Новый целевой порт [${_target}]: "; local _p; read -r _p
            if [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then
                IOS2_TARGET_PORT="$_p"; save_settings; log_success "Целевой порт: $_p"
            elif [ -n "$_p" ]; then log_error "Некорректный порт"; fi ;;
        5)
            echo -en "  Новый MSS [${IOS2_MSS}] (88..4096): "; local _m; read -r _m
            if [[ "$_m" =~ ^[0-9]+$ ]] && [ "$_m" -ge 88 ] && [ "$_m" -le 4096 ]; then
                IOS2_MSS="$_m"; save_settings; log_success "MSS: $_m"
            elif [ -n "$_m" ]; then log_error "Некорректный MSS (88..4096)"; fi ;;
        0|"") return ;;
    esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
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
    local _ios2_enabled="${IOS2_FIX_APPLIED:-false}"
    local _ios2_table="${IOS2_TABLE:-mtpr_ios2_fix}"
    local _ios2_ext="${IOS2_EXTERNAL_PORT:-4443}"
    local _ios2_target="${IOS2_TARGET_PORT:-${SERVER_PORT:-443}}"
    local _ios2_mss="${IOS2_MSS:-92}"

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
nft "add rule inet \$TABLE \$CHAIN \\
$([ -n "$_eip" ] && echo "ip daddr ${_eip} " || echo "")tcp dport ${_eport} \\
tcp flags & (syn | ack) == syn \\
meter telemt_in_syn_extra_${_i} { ip saddr timeout ${_timeout} limit rate over ${_erate} burst ${_eburst} packets } \\
counter drop comment \\"mtpr_extra_${_i}_${_erate}_burst_${_eburst}\\""
EXTRAEOF
    done

    if [ "$_ios2_enabled" = "true" ]; then
        cat >> "$NFT_SCRIPT" << IOS2EOF
# iOS fix v2: MSS + redirect
nft add table inet "\$IOS2_TABLE"
nft "add chain inet \$IOS2_TABLE mangle_prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add chain inet \$IOS2_TABLE nat_prerouting { type nat hook prerouting priority dstnat; policy accept; }"
nft "add rule inet \$IOS2_TABLE mangle_prerouting \\
$([ -n "$_ip" ] && echo "ip daddr ${_ip} " || echo "")tcp dport ${_ios2_ext} \\
tcp flags & (syn | rst) == syn \\
tcp option maxseg size set ${_ios2_mss} \\
counter comment \\"mtpr_ios2_mss_${_ios2_mss}\\""
nft "add rule inet \$IOS2_TABLE nat_prerouting \\
$([ -n "$_ip" ] && echo "ip daddr ${_ip} " || echo "")tcp dport ${_ios2_ext} \\
counter redirect to :${_ios2_target} comment \\"mtpr_ios2_redirect_${_ios2_ext}_to_${_ios2_target}\\""
IOS2EOF
    fi

    cat >> "$NFT_SCRIPT" << 'TAILEOF'
echo "MTproxy-reanimation: nft правила применены"
nft list table inet "$TABLE" 2>/dev/null || true
nft list table inet "$IOS2_TABLE" 2>/dev/null || true
TAILEOF
    chmod +x "$NFT_SCRIPT"
}

apply_nft_rules() {
    generate_nft_script
    if /bin/sh "$NFT_SCRIPT"; then log_success "NFT правила применены"
    else log_error "Не удалось применить NFT правила"; return 1; fi
}

remove_nft_rules() {
    local _table="${NFT_TABLE:-telemt_limit}"
    local _ios2_table="${IOS2_TABLE:-mtpr_ios2_fix}"
    nft delete table inet "$_table" 2>/dev/null || true
    nft delete table inet "$_ios2_table" 2>/dev/null || true
    log_success "NFT правила удалены"
}

# ── Systemd сервис ────────────────────────────────────────────
install_service() {
    generate_nft_script
    local _table="${NFT_TABLE:-telemt_limit}"
    local _ios2_table="${IOS2_TABLE:-mtpr_ios2_fix}"
    cat > "/etc/systemd/system/${SYSTEMD_UNIT}" << SVCEOF
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
SVCEOF
    systemctl daemon-reload
    systemctl enable "$SYSTEMD_UNIT" 2>/dev/null
    systemctl restart "$SYSTEMD_UNIT" 2>/dev/null
    NFT_SERVICE_ENABLED="true"; save_settings
    log_success "Служба установлена и запущена"
}

remove_service() {
    systemctl disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SYSTEMD_UNIT}"
    systemctl daemon-reload 2>/dev/null || true
    NFT_SERVICE_ENABLED="false"; save_settings; log_success "Служба удалена"
}

# ── Пресеты ───────────────────────────────────────────────────
apply_preset() {
    local _preset="$1"
    case "$_preset" in
        hard)   NFT_RATE="1/second"; NFT_BURST="1" ;;
        medium) NFT_RATE="1/second"; NFT_BURST="3" ;;
        soft)   NFT_RATE="2/second"; NFT_BURST="5" ;;
        *)      log_error "Неизвестный пресет: $_preset"; return 1 ;;
    esac
    save_settings; log_success "Пресет применён: $_preset (rate=$NFT_RATE burst=$NFT_BURST)"
}

# ── Счётчик дропов ────────────────────────────────────────────
show_drop_counter() {
    local _table="${NFT_TABLE:-telemt_limit}"
    local _hook="${NFT_HOOK:-input}"
    if ! nft list table inet "$_table" &>/dev/null; then
        log_warn "Активных NFT правил не найдено"; return 1; fi
    echo ""; echo -e "  ${BOLD}Счётчик дропов (Ctrl+C для выхода):${NC}"; echo ""
    watch -n 2 "nft list chain inet $_table $_hook 2>/dev/null | grep -E 'counter|comment'"
}

# ── Полное удаление ───────────────────────────────────────────
full_uninstall() {
    echo ""; echo -e "  ${RED}${BOLD}УДАЛЕНИЕ MTproxy-reanimation${NC}"; echo ""
    echo -e "  Будет удалено:"
    echo -e "  ${DIM}- NFT правила${NC}"
    echo -e "  ${DIM}- Systemd служба${NC}"
    echo -e "  ${DIM}- iOS фикс (sysctl keepalive)${NC}"
    echo -e "  ${DIM}- iOS фикс вариант 2 (MSS + redirect)${NC}"
    echo -e "  ${DIM}- Все настройки и скрипты${NC}"
    echo -e "  ${DIM}- Симлинк /usr/local/bin/mtpr${NC}"; echo ""
    echo -e "  ${YELLOW}Значения тюнинга Telemt НЕ будут откачены.${NC}"
    echo -e "  ${YELLOW}Бэкапы конфигов (*.mtpr-backup-*) останутся на месте.${NC}"; echo ""
    echo -en "  ${BOLD}Введите 'yes' для подтверждения:${NC} "
    local _confirm; read -r _confirm
    [ "$_confirm" != "yes" ] && { log_info "Отменено"; return; }
    if [ -f "$IOS_SYSCTL_FILE" ]; then
        rm -f "$IOS_SYSCTL_FILE"
        sysctl -w net.ipv4.tcp_keepalive_time=7200 &>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_intvl=75 &>/dev/null || true
        sysctl -w net.ipv4.tcp_keepalive_probes=9 &>/dev/null || true
        sysctl --system &>/dev/null || true
        log_success "iOS фикс откачен"
    fi
    remove_nft_rules 2>/dev/null || true
    remove_service 2>/dev/null || true
    rm -f "$NFT_SCRIPT"; rm -f /usr/local/bin/mtpr; rm -rf "$INSTALL_DIR"
    echo ""; log_success "MTproxy-reanimation полностью удалён"
    if [ "$DETECTED_MODE" = "mtproxymax" ]; then
        echo ""; echo -e "  ${DIM}Для отката тюнинга в MTProxyMax:${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear tg_connect${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear client_handshake${NC}"
        echo -e "  ${CYAN}mtproxymax tune clear client_keepalive${NC}"
        echo -e "  ${CYAN}mtproxymax restart${NC}"
    elif [ -n "$DETECTED_CONFIG_PATH" ]; then
        echo ""; echo -e "  ${DIM}Для отката тюнинга вручную восстановите бэкап:${NC}"
        echo -e "  ${CYAN}ls ${DETECTED_CONFIG_PATH}.mtpr-backup-*${NC}"
        echo -e "  ${CYAN}cp <backup-file> ${DETECTED_CONFIG_PATH}${NC}"
        echo -e "  ${DIM}Затем перезапустите telemt${NC}"
    fi
    echo ""; exit 0
}

# ── Интерфейс ─────────────────────────────────────────────────
show_header() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""; echo -e "  ${CYAN}${BOLD}MTproxy-reanimation${NC} ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}Telemt inbound SYN limiter + тюнинг${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"; echo ""
    local _nft_status="${RED}неактивно${NC}"
    if nft list table inet "${NFT_TABLE:-telemt_limit}" &>/dev/null; then _nft_status="${GREEN}активно${NC}"; fi
    local _svc_status="${DIM}не установлена${NC}"
    if systemctl is-enabled "$SYSTEMD_UNIT" &>/dev/null 2>&1; then
        if systemctl is-active "$SYSTEMD_UNIT" &>/dev/null 2>&1; then _svc_status="${GREEN}вкл + работает${NC}"
        else _svc_status="${YELLOW}вкл + остановлена${NC}"; fi; fi
    local _tuning_status="${DIM}не применён${NC}"
    case "$TUNING_APPLIED" in
        true) _tuning_status="${GREEN}применён${NC}" ;; manual) _tuning_status="${YELLOW}вручную${NC}" ;;
        partial) _tuning_status="${YELLOW}частично${NC}" ;; esac
    local _ios_status; _ios_status=$(ios_fix_status)
    local _ios2_status; _ios2_status=$(ios2_fix_status)
    echo -e "  ${BOLD}Обнаружение:${NC}   ${DETECTED_MODE:-не найден}$([ -n "$DETECTED_CONTAINER" ] && echo " (${DETECTED_CONTAINER})")"
    echo -e "  ${BOLD}Сеть:${NC}          ${DETECTED_NETWORK_MODE:-неизвестно} → hook ${NFT_HOOK}"
    echo -e "  ${BOLD}Конфиг:${NC}        ${DETECTED_CONFIG_PATH:-${DIM}не найден${NC}}"
    echo -e "  ${BOLD}NFT правила:${NC}   ${_nft_status}"
    echo -e "  ${BOLD}Служба:${NC}        ${_svc_status}"; echo ""
    echo -e "  ${BOLD}IP:${NC}            ${SERVER_IP:-${DIM}любой${NC}}"
    echo -e "  ${BOLD}Порт:${NC}          ${SERVER_PORT:-${DIM}не задан${NC}}"
    echo -e "  ${BOLD}Rate:${NC}          ${NFT_RATE}"
    echo -e "  ${BOLD}Burst:${NC}         ${NFT_BURST}"
    echo -e "  ${BOLD}Meter timeout:${NC} ${NFT_METER_TIMEOUT}"; echo ""
    echo -e "  ${BOLD}Тюнинг:${NC}        tg_connect=${TUNING_TG_CONNECT}  handshake=${TUNING_CLIENT_HANDSHAKE}  keepalive=${TUNING_CLIENT_KEEPALIVE}  (${_tuning_status})"
    echo -e "  ${BOLD}iOS фикс:${NC}      ${_ios_status}"
    echo -e "  ${BOLD}iOS фикс v2:${NC}   ${_ios2_status}"
    if [ "$EXTRA_RULES_COUNT" -gt 0 ]; then
        echo ""; echo -e "  ${BOLD}Доп. правила:${NC}"
        local _i; for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
            echo -e "    ${DIM}[$_i]${NC} порт=${EXTRA_RULES_PORT[$_i]:-?} ip=${EXTRA_RULES_IP[$_i]:-любой} rate=${EXTRA_RULES_RATE[$_i]:-?} burst=${EXTRA_RULES_BURST[$_i]:-?}"
        done; fi
    echo ""; echo -e "  ${DIM}────────────────────────────────────────${NC}"
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
        echo -e "  ${CYAN}[9]${NC}  Фикс для iOS (TCP keepalive)"
        echo -e "  ${CYAN}[a]${NC}  Фикс для iOS вариант 2 (MSS + redirect)"
        echo ""
        echo -e "  ${RED}[u]${NC}  Удалить"
        echo -e "  ${CYAN}[0]${NC}  Выход"; echo ""
        echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            1) if [ -z "$SERVER_PORT" ]; then log_error "Порт не задан — настройте в разделе Настройки"; read -rsn1; continue; fi
               apply_nft_rules || true; echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            2) apply_tuning || true; echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            3) show_settings_menu ;; 4) show_preset_menu ;; 5) show_drop_counter || true ;;
            6) show_service_menu ;; 7) show_extra_rules_menu ;;
            8) detect_telemt || true
               [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
               [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ] && SERVER_IP="$DETECTED_IP"
               if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then NFT_HOOK="forward"; else NFT_HOOK="input"; fi
               save_settings; log_success "Обнаружено: режим=$DETECTED_MODE порт=${DETECTED_PORT:-?}"
               echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            9) show_ios_fix_menu ;; a|A) show_ios2_fix_menu ;;
            u|U) full_uninstall ;; 0|q|Q) exit 0 ;; esac; done
}

show_settings_menu() {
    while true; do
        show_header; echo -e "  ${BOLD}Настройки${NC}"; echo ""
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
        echo -e "  ${DIM}[0]${NC} Назад"; echo ""
        echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            1) echo -en "  Новый IP [${SERVER_IP:-пусто}]: "; local _val; read -r _val
               [ -n "$_val" ] && SERVER_IP="$_val"; save_settings ;;
            2) echo -en "  Новый порт [${SERVER_PORT:-}]: "; local _val; read -r _val
               if [[ "$_val" =~ ^[0-9]+$ ]] && [ "$_val" -ge 1 ] && [ "$_val" -le 65535 ]; then SERVER_PORT="$_val"; save_settings
               elif [ -n "$_val" ]; then log_error "Некорректный порт"; fi ;;
            3) echo -en "  Новый rate (напр. 1/second, 2/second): "; local _val; read -r _val
               [ -n "$_val" ] && NFT_RATE="$_val" && save_settings ;;
            4) echo -en "  Новый burst: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && NFT_BURST="$_val" && save_settings ;;
            5) echo -en "  Новый meter timeout (напр. 30s, 60s, 120s): "; local _val; read -r _val
               [ -n "$_val" ] && NFT_METER_TIMEOUT="$_val" && save_settings ;;
            6) echo -en "  tg_connect [${TUNING_TG_CONNECT}]: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && TUNING_TG_CONNECT="$_val" && save_settings ;;
            7) echo -en "  client_handshake [${TUNING_CLIENT_HANDSHAKE}]: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && TUNING_CLIENT_HANDSHAKE="$_val" && save_settings ;;
            8) echo -en "  client_keepalive [${TUNING_CLIENT_KEEPALIVE}]: "; local _val; read -r _val
               [[ "$_val" =~ ^[0-9]+$ ]] && TUNING_CLIENT_KEEPALIVE="$_val" && save_settings ;;
            9) log_info "Определение публичного IP..."; local _detected_ip; _detected_ip=$(detect_public_ip)
               if [ -n "$_detected_ip" ]; then SERVER_IP="$_detected_ip"; save_settings; log_success "IP определён: $_detected_ip"
               else log_error "Не удалось определить публичный IP"; fi
               echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            c|C) SERVER_IP=""; save_settings; log_success "IP очищен — правила будут применяться ко всем адресам"
                 echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            0|"") return ;; esac; done
}

show_preset_menu() {
    show_header; echo -e "  ${BOLD}Пресеты скорости${NC}"; echo ""
    echo -e "  ${RED}[1]${NC} Жёсткий  — 1/second burst 1   ${DIM}(макс. ограничение)${NC}"
    echo -e "  ${YELLOW}[2]${NC} Средний  — 1/second burst 3   ${DIM}(баланс)${NC}"
    echo -e "  ${GREEN}[3]${NC} Мягкий   — 2/second burst 5   ${DIM}(мин. ограничение)${NC}"
    echo -e "  ${DIM}[4]${NC} Свой вариант"; echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in 1) apply_preset hard ;; 2) apply_preset medium ;; 3) apply_preset soft ;;
        4) echo -en "  Rate (напр. 1/second): "; local _r; read -r _r
           echo -en "  Burst: "; local _b; read -r _b
           [ -n "$_r" ] && NFT_RATE="$_r"; [[ "$_b" =~ ^[0-9]+$ ]] && NFT_BURST="$_b"
           save_settings; log_success "Свой вариант: rate=$NFT_RATE burst=$NFT_BURST" ;;
        0|"") return ;; esac
    echo ""; echo -en "  Применить NFT правила сейчас? [Y/n]: "; local _yn; read -r _yn
    if [[ ! "$_yn" =~ ^[nN] ]]; then apply_nft_rules || true
        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service; fi
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

show_service_menu() {
    show_header; echo -e "  ${BOLD}Управление службой${NC}"; echo ""
    local _status="${DIM}не установлена${NC}"
    if systemctl is-enabled "$SYSTEMD_UNIT" &>/dev/null 2>&1; then
        if systemctl is-active "$SYSTEMD_UNIT" &>/dev/null 2>&1; then _status="${GREEN}вкл + работает${NC}"
        else _status="${YELLOW}вкл + остановлена${NC}"; fi; fi
    echo -e "  Статус: ${_status}"; echo ""
    echo -e "  ${DIM}[1]${NC} Установить и включить службу"
    echo -e "  ${DIM}[2]${NC} Удалить службу"
    echo -e "  ${DIM}[3]${NC} Перезапустить службу"
    echo -e "  ${DIM}[4]${NC} Остановить службу (правила сохранятся)"
    echo -e "  ${DIM}[5]${NC} Логи службы"; echo -e "  ${DIM}[0]${NC} Назад"; echo ""
    echo -en "  Выбор: "; local _choice; read -r _choice
    case "$_choice" in
        1) if [ -z "$SERVER_PORT" ]; then log_error "Порт не задан — настройте в разделе Настройки"; else install_service; fi ;;
        2) remove_service ;;
        3) systemctl restart "$SYSTEMD_UNIT" 2>/dev/null && log_success "Служба перезапущена" || log_error "Не удалось перезапустить" ;;
        4) systemctl stop "$SYSTEMD_UNIT" 2>/dev/null && log_success "Служба остановлена" || log_error "Не удалось остановить" ;;
        5) echo ""; journalctl -u "$SYSTEMD_UNIT" -n 20 --no-pager 2>/dev/null || log_warn "Логов нет" ;;
        0|"") return ;; esac
    echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
}

show_extra_rules_menu() {
    while true; do
        show_header; echo -e "  ${BOLD}Дополнительные правила${NC}"; echo ""
        if [ "$EXTRA_RULES_COUNT" -eq 0 ]; then echo -e "  ${DIM}Нет дополнительных правил${NC}"
        else local _i; for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
            echo -e "    ${DIM}[$_i]${NC} порт=${EXTRA_RULES_PORT[$_i]:-?}  ip=${EXTRA_RULES_IP[$_i]:-любой}  rate=${EXTRA_RULES_RATE[$_i]:-?}  burst=${EXTRA_RULES_BURST[$_i]:-?}"
        done; fi; echo ""
        echo -e "  ${DIM}[a]${NC} Добавить правило"; echo -e "  ${DIM}[d]${NC} Удалить правило"
        echo -e "  ${DIM}[0]${NC} Назад"; echo ""; echo -en "  Выбор: "; local _choice; read -r _choice
        case "$_choice" in
            a|A)
                echo -en "  Порт: "; local _p; read -r _p
                if ! [[ "$_p" =~ ^[0-9]+$ ]] || [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
                    log_error "Некорректный порт"; echo ""; read -rsn1 -p "  Нажмите любую клавишу..."; continue; fi
                echo -en "  IP (пусто = любой): "; local _eip; read -r _eip
                echo -en "  Rate [1/second]: "; local _r; read -r _r; [ -z "$_r" ] && _r="1/second"
                echo -en "  Burst [1]: "; local _b; read -r _b; [ -z "$_b" ] && _b="1"
                EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT + 1)); local _idx=$EXTRA_RULES_COUNT
                EXTRA_RULES_PORT[$_idx]="$_p"; EXTRA_RULES_IP[$_idx]="$_eip"
                EXTRA_RULES_RATE[$_idx]="$_r"; EXTRA_RULES_BURST[$_idx]="$_b"
                save_settings; log_success "Доп. правило $_idx добавлено"
                echo -en "  Применить правила сейчас? [Y/n]: "; local _yn; read -r _yn
                if [[ ! "$_yn" =~ ^[nN] ]]; then apply_nft_rules || true
                    [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service; fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            d|D)
                [ "$EXTRA_RULES_COUNT" -eq 0 ] && { log_info "Нет правил для удаления"; echo ""; read -rsn1 -p "  Нажмите любую клавишу..."; continue; }
                echo -en "  Номер правила для удаления: "; local _idx; read -r _idx
                if [[ "$_idx" =~ ^[0-9]+$ ]] && [ "$_idx" -ge 1 ] && [ "$_idx" -le "$EXTRA_RULES_COUNT" ]; then
                    local _i; for _i in $(seq "$_idx" $((EXTRA_RULES_COUNT - 1))); do
                        local _next=$((_i + 1))
                        EXTRA_RULES_PORT[$_i]="${EXTRA_RULES_PORT[$_next]:-}"
                        EXTRA_RULES_IP[$_i]="${EXTRA_RULES_IP[$_next]:-}"
                        EXTRA_RULES_RATE[$_i]="${EXTRA_RULES_RATE[$_next]:-}"
                        EXTRA_RULES_BURST[$_i]="${EXTRA_RULES_BURST[$_next]:-}"
                    done
                    unset "EXTRA_RULES_PORT[$EXTRA_RULES_COUNT]"; unset "EXTRA_RULES_IP[$EXTRA_RULES_COUNT]"
                    unset "EXTRA_RULES_RATE[$EXTRA_RULES_COUNT]"; unset "EXTRA_RULES_BURST[$EXTRA_RULES_COUNT]"
                    EXTRA_RULES_COUNT=$((EXTRA_RULES_COUNT - 1)); save_settings; log_success "Правило удалено"
                    echo -en "  Применить правила заново? [Y/n]: "; local _yn; read -r _yn
                    if [[ ! "$_yn" =~ ^[nN] ]]; then apply_nft_rules || true
                        [ "$NFT_SERVICE_ENABLED" = "true" ] && install_service; fi
                else log_error "Некорректный номер правила"; fi
                echo ""; read -rsn1 -p "  Нажмите любую клавишу..." ;;
            0|"") return ;; esac; done
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
            echo ""; echo -en "  ${DIM}Указать другой путь к конфигу? [n/путь]:${NC} "
            local _alt_cfg; read -r _alt_cfg
            if [ -n "$_alt_cfg" ] && [ "$_alt_cfg" != "n" ] && [ "$_alt_cfg" != "N" ]; then
                if [ -f "$_alt_cfg" ]; then DETECTED_CONFIG_PATH="$_alt_cfg"; log_success "Конфиг: $_alt_cfg"
                    local _p; _p=$(_toml_get_value "port" "$_alt_cfg"); [ -n "$_p" ] && DETECTED_PORT="$_p"
                else log_error "Файл не найден: $_alt_cfg"; fi; fi; fi
    else
        log_warn "Telemt не обнаружен автоматически"; echo ""
        echo -en "  ${BOLD}Указать путь к конфигу Telemt вручную? [n/путь]:${NC} "
        local _manual_cfg; read -r _manual_cfg
        if [ -n "$_manual_cfg" ] && [ "$_manual_cfg" != "n" ] && [ "$_manual_cfg" != "N" ]; then
            if [ -f "$_manual_cfg" ]; then DETECTED_CONFIG_PATH="$_manual_cfg"; DETECTED_MODE="manual"; DETECTED_NETWORK_MODE="host"
                log_success "Конфиг: $_manual_cfg"; local _p; _p=$(_toml_get_value "port" "$_manual_cfg"); [ -n "$_p" ] && DETECTED_PORT="$_p"
            else log_error "Файл не найден: $_manual_cfg"; fi; fi; fi

    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then NFT_HOOK="forward"; else NFT_HOOK="input"; fi
    echo ""; install_dependencies || exit 1
    echo ""; SERVER_PORT="${DETECTED_PORT:-443}"
    echo -en "  ${BOLD}Порт прокси [${SERVER_PORT}]:${NC} "
    local _port_input; read -r _port_input
    if [[ "$_port_input" =~ ^[0-9]+$ ]] && [ "$_port_input" -ge 1 ] && [ "$_port_input" -le 65535 ]; then SERVER_PORT="$_port_input"; fi
    echo ""
    if [ -n "$DETECTED_IP" ]; then SERVER_IP="$DETECTED_IP"; log_info "IP из конфига: $SERVER_IP"
    else log_info "Определение публичного IP..."; SERVER_IP=$(detect_public_ip)
        [ -n "$SERVER_IP" ] && log_success "Определён: $SERVER_IP" || log_warn "Не удалось определить IP"; fi
    echo -en "  ${BOLD}IP сервера [${SERVER_IP:-оставьте пустым для всех}]:${NC} "
    local _ip_input; read -r _ip_input; [ -n "$_ip_input" ] && SERVER_IP="$_ip_input"
    echo ""; echo -e "  ${BOLD}Пресет ограничения:${NC}"
    echo -e "    ${RED}[1]${NC} Жёсткий  — 1/sec burst 1  ${DIM}(рекомендуется)${NC}"
    echo -e "    ${YELLOW}[2]${NC} Средний  — 1/sec burst 3"
    echo -e "    ${GREEN}[3]${NC} Мягкий   — 2/sec burst 5"; echo ""
    echo -en "  Выбор [1]: "; local _preset_input; read -r _preset_input
    case "$_preset_input" in 2) apply_preset medium ;; 3) apply_preset soft ;; *) apply_preset hard ;; esac
    save_settings
    echo ""; echo -en "  ${BOLD}Применить тюнинг Telemt? [Y/n]:${NC} "
    local _yn_tuning; read -r _yn_tuning
    if [[ ! "$_yn_tuning" =~ ^[nN] ]]; then apply_tuning || true; fi
    echo ""; echo -en "  ${BOLD}Применить фикс для iOS (TCP keepalive)? [Y/n]:${NC} "
    local _yn_ios; read -r _yn_ios
    if [[ ! "$_yn_ios" =~ ^[nN] ]]; then
        cat > "$IOS_SYSCTL_FILE" << 'SYSEOF'
# MTproxy-reanimation: фикс для iOS — TCP keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
SYSEOF
        sysctl --system &>/dev/null || true; IOS_FIX_APPLIED="true"; save_settings
        log_success "Фикс для iOS применён"; fi
    echo ""; echo -en "  ${BOLD}Применить NFT правила сейчас? [Y/n]:${NC} "
    local _yn_nft; read -r _yn_nft
    if [[ ! "$_yn_nft" =~ ^[nN] ]]; then apply_nft_rules || true; fi
    echo ""; echo -en "  ${BOLD}Установить как службу (автозапуск при загрузке)? [Y/n]:${NC} "
    local _yn_svc; read -r _yn_svc
    if [[ ! "$_yn_svc" =~ ^[nN] ]]; then install_service || true; fi
    echo ""; log_success "Настройка завершена!"; echo ""
    echo -e "  ${DIM}Запускайте ${CYAN}mtpr${DIM} в любое время для управления${NC}"; echo ""
    read -rsn1 -p "  Нажмите любую клавишу для входа в меню..."
}

# ── Главная точка входа ───────────────────────────────────────
main() {
    check_root; mkdir -p "$INSTALL_DIR"
    local _self="${BASH_SOURCE[0]}"
    if [ -f "$_self" ] && [ "$(realpath "$_self" 2>/dev/null)" != "$(realpath "${INSTALL_DIR}/mtpr.sh" 2>/dev/null)" ]; then
        cp "$_self" "${INSTALL_DIR}/mtpr.sh"; chmod +x "${INSTALL_DIR}/mtpr.sh"; fi
    ln -sf "${INSTALL_DIR}/mtpr.sh" /usr/local/bin/mtpr 2>/dev/null || true
    load_settings; detect_telemt || true
    [ -z "$SERVER_PORT" ] && [ -n "$DETECTED_PORT" ] && SERVER_PORT="$DETECTED_PORT"
    [ -z "$SERVER_IP" ] && [ -n "$DETECTED_IP" ] && SERVER_IP="$DETECTED_IP"
    if [ "$DETECTED_NETWORK_MODE" = "bridge" ]; then NFT_HOOK="forward"; else NFT_HOOK="input"; fi
    if [ ! -f "$SETTINGS_FILE" ]; then first_run_wizard; fi
    show_main_menu
}

main "$@"
