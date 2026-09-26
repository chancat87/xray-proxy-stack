#!/usr/bin/env bash
# xray/core.sh — Xray-core install, upgrade, service management

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_CFG="$XRAY_CFG_DIR/config.json"
XRAY_RELEASES="https://github.com/XTLS/Xray-core/releases"

# ── Timezone wizard ───────────────────────────────────────────────────────────
_tz_set_wizard() {
    [[ -z "${PSM_NO_WIZARD:-}" ]] || return 0   # psm migrate installs without questions
    local cur; cur=$(timedatectl show -p Timezone --value 2>/dev/null \
                     || cat /etc/timezone 2>/dev/null || echo "unknown")
    echo -e "\n${BOLD}$(t xray.tz.title)${NC}  $(t xray.tz.current "${CYAN}${cur}${NC}")"
    echo -e "  ${CYAN}1.${NC} $(t xray.tz.hk)"
    echo -e "  ${CYAN}2.${NC} $(t xray.tz.sg)"
    echo -e "  ${CYAN}3.${NC} $(t xray.tz.sh)"
    echo -e "  ${CYAN}4.${NC} $(t xray.tz.utc)"
    echo -e "  ${CYAN}0.${NC} $(t xray.tz.skip)"
    local choice
    read -rp "$(echo -e "${CYAN}$(t xray.tz.ask)${NC}")" choice
    choice="${choice:-1}"

    local tz=""
    case "$choice" in
        1) tz="Asia/Hong_Kong" ;;
        2) tz="Asia/Singapore" ;;
        3) tz="Asia/Shanghai"  ;;
        4) tz="UTC"            ;;
        0) log_info "$(t xray.tz.skipped)"; return ;;
        *) log_warn "$(t xray.tz.invalid)"; return ;;
    esac

    if timedatectl set-timezone "$tz" 2>/dev/null; then
        : # timedatectl handles /etc/localtime symlink automatically
    else
        # Fallback for containers / systems without timedatectl
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null || true
        echo "$tz" > /etc/timezone 2>/dev/null || true
    fi
    timedatectl set-ntp true 2>/dev/null || true
    log_ok "$(t xray.tz.done "$CYAN" "$tz" "$NC")"
}

# ── Release channel ───────────────────────────────────────────────────────────
# XTLS 把 v26.3.27 之后的每个发布都标成了 prerelease，所以 /releases/latest 返回的
# 稳定版可能落后好几个月。稳定版仍是默认，但额外给一个预览通道，让想要新功能的人
# 能拿到最新构建。
#
# 预览通道有个必须先讲清楚的代价：v26.4.13 起 REALITY 的 minClientVer 有了默认值
# 26.3.27，服务端会拒绝内核更老的客户端——大量手机 App 内置的核心都比这个老。
# 详见 _xray_reality_min_client_ver_menu，那里允许按节点显式放宽。
XRAY_STABLE_FALLBACK="v26.3.27"   # API 不可达时的兜底，必须是真实存在的稳定 tag
XRAY_MIN_CLIENT_VER_DEFAULT="26.3.27"  # 上游 v26.4.13+ 的 minClientVer 内置默认值

_xray_choose_channel() {
    # 非交互场景（管道 / 自动化）不提问，直接走稳定版
    [[ -t 0 ]] || { printf 'stable'; return; }
    echo "" >&2
    echo "  $(t xray.channel.title)" >&2
    echo "    1. $(t xray.channel.stable)" >&2
    echo "    2. $(t xray.channel.preview)" >&2
    local c; read -rp "$(echo -e "${CYAN}$(t xray.channel.ask)${NC}")" c
    case "${c:-1}" in 2) printf 'preview' ;; *) printf 'stable' ;; esac
}

# 解析通道 → tag。预览失败回落稳定版，稳定版失败回落 XRAY_STABLE_FALLBACK。
_xray_resolve_tag() {
    local channel="$1" tag=""
    # psm migrate installs the version the old server ran
    [[ -n "${PSM_XRAY_TAG:-}" ]] && { printf '%s' "$PSM_XRAY_TAG"; return 0; }
    if [[ "$channel" == "preview" ]]; then
        log_step "$(t xray.fetching_preview)"
        tag=$(curl "${PSM_DL[@]}" -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=20" 2>/dev/null \
              | jq -r 'map(select(.draft | not)) | .[0].tag_name // empty' || true)
        if [[ "$tag" =~ ^v[0-9] ]]; then
            log_warn "$(t xray.channel.preview_warn "$tag")"
            log_warn "$(t xray.channel.min_client_warn "$XRAY_MIN_CLIENT_VER_DEFAULT")"
            printf '%s' "$tag"; return 0
        fi
        log_warn "$(t xray.preview_unavailable)"
    fi

    log_step "$(t xray.fetching_latest)"
    tag=$(gh_latest_tag XTLS/Xray-core)
    [[ "$tag" =~ ^v[0-9] ]] || { log_warn "$(t xray.latest_fallback "$XRAY_STABLE_FALLBACK")"; tag="$XRAY_STABLE_FALLBACK"; }
    printf '%s' "$tag"
}

# ── Install ───────────────────────────────────────────────────────────────────
xray_install() {
    ensure_pkg_deps curl unzip jq
    require_cmd curl unzip jq

    if is_installed xray || [[ -f "$XRAY_BIN" ]]; then
        log_info "$(t xray.installed "$($XRAY_BIN version 2>/dev/null | head -1)")"
        ask_yn "$(t xray.ask_reinstall)" N || return 0
    fi

    _tz_set_wizard

    local arch; arch=$(get_arch)
    local xray_arch
    case "$arch" in
        amd64) xray_arch="64" ;;
        arm64) xray_arch="arm64-v8a" ;;
        arm32) xray_arch="arm32-v7a" ;;
        *)     die "$(t xray.unsupported_arch "$arch")" ;;
    esac

    local channel; channel=$(_xray_choose_channel)
    local tag; tag=$(_xray_resolve_tag "$channel") || return 1

    local zip_name="Xray-linux-${xray_arch}.zip"
    local url="${XRAY_RELEASES}/download/${tag}/${zip_name}"
    local tmp_dir; tmp_dir=$(mktemp -d)

    log_step "$(t xray.downloading "$tag" "$xray_arch")"
    curl "${PSM_DL[@]}" -fsSL -o "$tmp_dir/$zip_name" "$url" \
        || die "$(t xray.download_fail "$url")"

    unzip -q "$tmp_dir/$zip_name" -d "$tmp_dir/xray"

    install -m 755 "$tmp_dir/xray/xray" /usr/local/bin/xray

    # Geo data (geoip.dat/geosite.dat) drives every geosite:/geoip: routing rule
    # — i.e. all WARP unlock + custom shunting. Xray searches /usr/local/share/xray
    # by default, so install them there. mkdir FIRST: `install`/`cp` into a
    # missing dir is a silent no-op (the previous order left geo data uninstalled
    # on a fresh box, so shunt rules never matched). The release zip bundles them;
    # warn if it somehow didn't, so a broken shunt is diagnosable.
    mkdir -p /usr/local/share/xray
    cp -f "$tmp_dir/xray"/geoip.dat   /usr/local/share/xray/ 2>/dev/null || true
    cp -f "$tmp_dir/xray"/geosite.dat /usr/local/share/xray/ 2>/dev/null || true
    if [[ ! -s /usr/local/share/xray/geoip.dat || ! -s /usr/local/share/xray/geosite.dat ]]; then
        log_warn "$(t xray.geo_warn)"
    fi

    rm -rf "$tmp_dir"
    mkdir -p "$XRAY_CFG_DIR"
    # config.json carries every node's secrets (UUIDs, passwords, private/WARP
    # keys). Keep the dir root-only so the config isn't world-readable; xray.service
    # runs as root, so this doesn't affect it.
    chmod 700 "$XRAY_CFG_DIR" 2>/dev/null || true

    if [[ -f "$XRAY_CFG" ]]; then
        if ! "$XRAY_BIN" run -test -config "$XRAY_CFG" &>/dev/null \
            && ! "$XRAY_BIN" -test -config "$XRAY_CFG" &>/dev/null; then
            local backup_cfg
            backup_cfg="${XRAY_CFG}.bad.$(date +%Y%m%d%H%M%S)"
            cp -a "$XRAY_CFG" "$backup_cfg"
            # A config the previous core accepted but this one rejects is usually
            # version-dependent output (e.g. mKCP), not broken nodes: regenerate
            # from the node stores first; only fall back to an empty skeleton —
            # which drops every node from the live config — if that fails too.
            if xray_rebuild_from_stores; then
                log_ok "$(t xray.rebuilt_for_core)"
            else
                log_warn "$(t xray.bad_config_backup "$backup_cfg")"
                _write_skeleton_config
            fi
        fi
    else
        _write_skeleton_config
    fi

    _write_xray_service
    svc_daemon_reload
    svc_enable xray
    svc_restart xray || svc_start xray
    log_ok "$(t xray.install_done "$tag")"
    _xray_post_install_wizard
}

# ── Rebuild after a core change ───────────────────────────────────────────────
# Some inbound fields are generated per Xray version (mKCP seed/header — see
# xray/xhttp.sh), so a config written for the previous core can be rejected by
# the new one although every node is fine. Regenerate all PSM-managed inbounds
# from the node stores, then test the finished config once (the per-module
# test/restart is deferred: intermediate states would fail it).
xray_rebuild_from_stores() {
    local entry fn
    unset _XRAY_KCP_FORM            # the probe result belongs to the old binary
    PSM_XRAY_DEFER_RESTART=1
    for entry in reality:_reality_apply_all vision:_vision_apply_all \
                 xhttp:_xhttp_apply_all ss2022:_xss_apply_to_xray \
                 trojan:_trojan_apply_all vmess:_vmess_apply_all socks:_socks_apply_all \
                 hysteria2:_xhy2_apply_all; do
        fn="${entry#*:}"
        declare -f "$fn" &>/dev/null || source "$LIB_DIR/xray/${entry%%:*}.sh" 2>/dev/null || continue
        declare -f "$fn" &>/dev/null && { "$fn" >/dev/null 2>&1 || true; }
    done
    unset PSM_XRAY_DEFER_RESTART
    "$XRAY_BIN" run -test -config "$XRAY_CFG" &>/dev/null
}

# ── VLESS Encryption (post-quantum) ───────────────────────────────────────────
# `xray vlessenc` prints two ready-made pairs; the ephemeral key exchange is
# ML-KEM-768 + X25519 either way, only the server authentication differs:
#   x25519   (default) short strings, fine for links and QR codes
#   mlkem768 post-quantum authentication, but a ~1.6 KB client string
# Prints "<decryption>\t<encryption>" (server / client halves).
xray_vlessenc_gen() {
    local auth="${1:-x25519}" want="X25519"
    [[ "$auth" == "mlkem768" ]] && want="ML-KEM-768"
    "$XRAY_BIN" vlessenc 2>/dev/null | awk -v want="$want" '
        /^Authentication:/   { on = index($0, want) > 0; next }
        on && /"decryption"/ { sub(/^[^:]*: *"/, ""); sub(/"$/, ""); d = $0 }
        on && /"encryption"/ { sub(/^[^:]*: *"/, ""); sub(/"$/, ""); e = $0 }
        END { if (d == "" || e == "") exit 1; printf "%s\t%s\n", d, e }'
}

# Interactive: offer VLESS Encryption. Prints the pair, or nothing when declined.
# $1: the default answer (Y for mKCP, which has no TLS; N otherwise).
xray_ask_vlessenc() {
    ask_yn "$(t common.vlessenc.ask)" "${1:-N}" || return 0
    echo -e "  $(t common.vlessenc.auth1)" >&2
    echo -e "  $(t common.vlessenc.auth2)" >&2
    local c; read -rp "$(echo -e "${CYAN}$(t common.vlessenc.ask_auth)${NC}")" c
    local auth="x25519"; [[ "$c" == "2" ]] && auth="mlkem768"
    xray_vlessenc_gen "$auth" || { log_error "$(t common.vlessenc.gen_fail)"; return 1; }
}

_write_skeleton_config() {
    cat > "$XRAY_CFG" <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
    mkdir -p /var/log/xray
}

_write_xray_service() {
    # The core runs as psm-core; systemd resolves User= before ExecStartPre,
    # so the user has to exist when the unit is written (lib/coreperm.sh).
    source "$LIB_DIR/coreperm.sh"; psm_core_user_ensure
    if ! _uses_systemd; then
        psm_write_openrc_service xray "Xray Service" "$XRAY_BIN" "run -config $XRAY_CFG" "" \
            "$PSM_CORE_USER" "/bin/bash $LIB_DIR/coreperm.sh xray"
        return
    fi
    cat > "$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
$(psm_core_unit_lines xray)
ExecStart=${XRAY_BIN} run -config ${XRAY_CFG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

xray_gen_x25519_keys() {
    local output private_key public_key
    output=$("$XRAY_BIN" x25519 2>&1) || {
        log_error "$(t xray.x25519_gen_fail)"
        echo "$output" >&2
        return 1
    }

    private_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    public_key=$(echo "$output" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        log_error "$(t xray.x25519_parse_fail)"
        echo "$output" >&2
        return 1
    fi

    printf '%s\t%s\n' "$private_key" "$public_key"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
xray_upgrade() {
    log_step "$(t xray.upgrading)"
    xray_install
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
xray_uninstall() {
    echo -e "\n${YELLOW}$(t xray.uninstall_warn)${NC}"
    ask_yn "$(t xray.ask_uninstall)" N || return 0

    # ── Stop service ──────────────────────────────────────────────────────────
    svc_stop xray 2>/dev/null || true
    svc_disable xray || true
    systemctl disable --now psm-reality-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/psm-reality-watchdog.service /etc/systemd/system/psm-reality-watchdog.timer
    psm_cron_remove psm-reality-watchdog

    # ── Clean protocol nodes: SNI entries + traffic records ───────────────────
    source "$LIB_DIR/nginx.sh"   2>/dev/null || true
    source "$LIB_DIR/traffic.sh" 2>/dev/null || true
    [[ -f "${CFG_DIR}/traffic/state.json" ]] && _trf_init 2>/dev/null || true

    # Reality
    if [[ -f "$CFG_DIR/xray/reality.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/reality.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _listen _sn; do
            [[ "$_listen" == "127.0.0.1" ]] && _sni_remove_entry "$_sn" 2>/dev/null || true
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_reality_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/reality.json"
    fi

    # Vision
    if [[ -f "$CFG_DIR/xray/vision.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vision.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _listen _domain; do
            _sni_remove_entry "$_domain" 2>/dev/null || true
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_vision_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/vision.json"
    fi

    # XHTTP
    if [[ -f "$CFG_DIR/xray/xhttp.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _listen _mode _domain; do
            [[ -n "$_domain" ]] && _sni_remove_entry "$_domain" 2>/dev/null || true
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_xhttp_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/xhttp.json"
    fi

    # SS2022
    if [[ -f "$CFG_DIR/xray/ss2022.json" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh" 2>/dev/null || true
        while IFS=$'\t' read -r _tag _port _method _listen; do
            _trf_cleanup_node "$_tag" 2>/dev/null || true
        done < <(_xss_list 2>/dev/null)
        rm -f "$CFG_DIR/xray/ss2022.json"
    fi

    # Custom outbounds (incl. WARP) + routing rules + saved WARP identity
    rm -f "$CFG_DIR/xray/outbounds.json" "$CFG_DIR/xray/routing_rules.json" \
          "$CFG_DIR/xray/warp_account.json" "$CFG_DIR/xray/reality_watchdog.json"

    # ── Binary, service, Xray config dir, geo data, logs ─────────────────────
    psm_remove_openrc_service xray
    rm -f  "$XRAY_BIN" "$XRAY_SERVICE"
    rm -rf "$XRAY_CFG_DIR" /usr/local/share/xray /var/log/xray
    svc_daemon_reload

    log_ok "$(t xray.uninstalled)"
}

# ── Config helpers ────────────────────────────────────────────────────────────
xray_get_inbounds() {
    jq -r '.inbounds[]? | "\(.tag // "unnamed")\t\(.protocol)\t\(.port)"' "$XRAY_CFG" 2>/dev/null
}

xray_add_inbound() {
    local fragment="$1"
    local tmp; tmp=$(mktemp)
    jq ".inbounds += [$fragment]" "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"
}

xray_remove_inbound_by_tag() {
    local tag="$1"
    local tmp; tmp=$(mktemp)
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$XRAY_CFG" > "$tmp" && mv "$tmp" "$XRAY_CFG"
}

xray_update_inbound() {
    local tag="$1" new_json="$2"
    xray_remove_inbound_by_tag "$tag"
    xray_add_inbound "$new_json"
}

# ── Safe config replacement ───────────────────────────────────────────────────
# Atomically replace XRAY_CFG with a candidate file ONLY if it's non-empty valid
# JSON. Guards against jq pipelines that failed halfway and produced empty or
# partial output — writing that would wipe the running config. On failure the
# existing config is left untouched and we return non-zero. (Full Xray semantic
# validation is done by the caller's xray_test_restart, which then also reports.)
_xray_write_cfg_checked() {
    local candidate="$1"
    if [[ ! -s "$candidate" ]] || ! jq -e . "$candidate" >/dev/null 2>&1; then
        log_error "$(t xray.write_invalid)"
        rm -f "$candidate"
        return 1
    fi
    mv -f "$candidate" "$XRAY_CFG"
}

# ── Status & logs ─────────────────────────────────────────────────────────────
xray_version() {
    "$XRAY_BIN" version 2>/dev/null | head -3
}

xray_logs() {
    echo -e "$(t xray.logs.menu)"
    read -rp "$(echo -e "${CYAN}$(t xray.ask_select)${NC}")" lc
    case "$lc" in
        1) tail -f /var/log/xray/access.log ;;
        2) tail -f /var/log/xray/error.log ;;
        3) svc_logs xray ;;
    esac
}

# ── Post-install protocol wizard ─────────────────────────────────────────────
_xray_post_install_wizard() {
    [[ -z "${PSM_NO_WIZARD:-}" ]] || return 0   # psm migrate installs without questions
    echo ""
    ask_yn "$(t xray.ask_protocol_now)" Y || return 0
    echo -e "\n  $(t xray.protocol_choose)"
    echo -e "  1. $(t xray.protocol.reality)"
    echo -e "  2. $(t xray.protocol.vision)"
    echo -e "  3. $(t xray.protocol.xhttp)"
    echo -e "  4. $(t xray.protocol.ss2022)"
    echo -e "  5. $(t xray.protocol.trojan)"
    echo -e "  6. $(t xray.protocol.vmess)"
    echo -e "  7. $(t xray.protocol.socks)"
    echo -e "  8. $(t xray.protocol.hysteria2)"
    read -rp "$(echo -e "${CYAN}$(t xray.ask_select_default)${NC}")" pc
    echo ""
    case "${pc:-1}" in
        8) source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"; xhy2_add_node ;;
        1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"; reality_add_node ;;
        2) source "$(dirname "${BASH_SOURCE[0]}")/vision.sh";  vision_add_node ;;
        3) source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh";   xhttp_add_node ;;
        4) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh";  xss_add_node ;;
        5) source "$(dirname "${BASH_SOURCE[0]}")/trojan.sh"; trojan_add_node ;;
        6) source "$(dirname "${BASH_SOURCE[0]}")/vmess.sh"; vmess_add_node ;;
        7) source "$(dirname "${BASH_SOURCE[0]}")/socks.sh"; socks_add_node ;;
        *) log_info "$(t xray.protocol_skipped)" ;;
    esac
}

# ── Dependency & install check ────────────────────────────────────────────────
_xray_check_deps() {
    ensure_pkg_deps curl unzip jq
}

_xray_require_installed() {
    if [[ ! -f "$XRAY_BIN" ]]; then
        log_warn "$(t xray.need_install)"
        press_enter
        return 1
    fi
}

# Warn (don't hard-block — reusing a port across sibling nodes/redeploys is
# legitimate) if a freshly-chosen port collides with anything PSM already
# knows about (SSH, other protocols, honeypot ports) or is currently
# listening. Same detection the Docker app-store deploy flow reuses.
# Returns 0 = proceed, 1 = abort. Only call this for a port the user just
# picked — not for ports inherited via SNI/port reuse between sibling nodes.
_xray_check_port_conflict() {
    local port="$1"
    source "$LIB_DIR/security/honeypot.sh" 2>/dev/null || return 0
    declare -f _hp_is_reserved_port &>/dev/null || return 0
    _hp_is_reserved_port "$port" || return 0
    log_warn "$(t xray.port_conflict "$port")"
    ask_yn "$(t xray.ask_use_port)" N
}

# ── Centralized node viewer ───────────────────────────────────────────────────
_xray_view_all_nodes() {
    source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/vision.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/trojan.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/vmess.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/socks.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"

    # 展示前把 config.json 中的手动修改（端口/UUID/密码）同步回各协议的
    # 节点存储，否则这里和后续 show 函数显示的都是旧值。
    _reality_sync_from_live || true
    _vision_sync_from_live  || true
    _xhttp_sync_from_live   || true
    _xss_sync_from_live     || true
    _trojan_sync_from_live  || true
    _vmess_sync_from_live   || true
    # socks 没有 sync_from_live：它的凭据不在 config.json 里做二次编辑的场景，
    # 且 noauth 节点根本没有可同步的字段。

    local -a _protos _tags
    local i=0

    echo -e "\n${BOLD}${BLUE}══ $(t xray.nodes.title) ════════════════${NC}"

    while IFS=$'\t' read -r tag port listen sn; do
        i=$((i+1)); _protos+=("reality"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Reality]${NC}  %-18s  port=%-6s  listen=%-15s  sni=%s\n" \
               "$i" "$tag" "$port" "$listen" "$sn"
    done < <(_reality_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen domain; do
        i=$((i+1)); _protos+=("vision"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${BLUE}[Vision]${NC}   %-18s  port=%-6s  listen=%-15s  domain=%s\n" \
               "$i" "$tag" "$port" "$listen" "$domain"
    done < <(_vision_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen mode domain; do
        i=$((i+1)); _protos+=("xhttp"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${YELLOW}[XHTTP/%-8s]${NC} %-18s  port=%-6s  listen=%-15s  domain=%s\n" \
               "$i" "$mode" "$tag" "$port" "$listen" "$domain"
    done < <(_xhttp_list 2>/dev/null)

    while IFS=$'\t' read -r tag port method _; do
        i=$((i+1)); _protos+=("ss2022"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${CYAN}[SS2022]${NC}   %-18s  port=%-6s  %s\n" \
               "$i" "$tag" "$port" "$method"
    done < <(_xss_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen domain; do
        i=$((i+1)); _protos+=("trojan"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Trojan]${NC}   %-18s  port=%-6s  listen=%-15s  domain=%s\n" \
               "$i" "$tag" "$port" "$listen" "$domain"
    done < <(_trojan_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen domain; do
        i=$((i+1)); _protos+=("vmess"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${BLUE}[VMess]${NC}    %-18s  port=%-6s  listen=%-15s  domain=%s\n" \
               "$i" "$tag" "$port" "$listen" "$domain"
    done < <(_vmess_list 2>/dev/null)

    while IFS=$'\t' read -r tag port listen auth; do
        i=$((i+1)); _protos+=("socks"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${YELLOW}[SOCKS5]${NC}   %-18s  port=%-6s  listen=%-15s  auth=%s\n" \
               "$i" "$tag" "$port" "$listen" "$auth"
    done < <(_socks_list 2>/dev/null)

    while IFS=$'\t' read -r tag port sni obfs; do
        i=$((i+1)); _protos+=("hysteria2"); _tags+=("$tag")
        printf "  ${CYAN}%2d.${NC} ${GREEN}[Hy2]${NC}      %-18s  port=%-6s  sni=%-15s  obfs=%s\n" \
               "$i" "$tag" "$port" "$sni" "$obfs"
    done < <(_xhy2_list 2>/dev/null)

    if (( i == 0 )); then
        log_warn "$(t xray.no_nodes)"
        return
    fi

    echo -e "${BOLD}${BLUE}════════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t xray.ask_node_share): ${NC}")" sel

    [[ -z "$sel" || "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_warn "$(t xray.invalid_option)"; return
    fi

    local proto="${_protos[$((sel-1))]}"
    local tag="${_tags[$((sel-1))]}"
    echo ""
    case "$proto" in
        reality) reality_show_uri  "$tag" ;;
        vision)  vision_show_share "$tag" ;;
        xhttp)   xhttp_show_share  "$tag" ;;
        ss2022)  _xss_uri          "$tag" ;;
        trojan)  trojan_show_share "$tag" ;;
        vmess)   vmess_show_share  "$tag" ;;
        socks)   socks_show_share  "$tag" ;;
        hysteria2) xhy2_show_share "$tag" ;;
    esac
}

# ── Protocol nodes sub-menu ───────────────────────────────────────────────────
_xray_protocol_menu() {
    while true; do
        show_menu "$(t xray.protocol_menu.title)" \
            "$(t xray.protocol_menu.reality)" \
            "$(t xray.protocol_menu.vision)" \
            "$(t xray.protocol_menu.xhttp)" \
            "$(t xray.protocol_menu.ss2022)" \
            "$(t xray.protocol_menu.trojan)" \
            "$(t xray.protocol_menu.vmess)" \
            "$(t xray.protocol_menu.socks)" \
            "$(t xray.protocol_menu.hysteria2)"

        case "$MENU_CHOICE" in
            8) source "$(dirname "${BASH_SOURCE[0]}")/hysteria2.sh"; xhy2_menu ;;
            1) source "$(dirname "${BASH_SOURCE[0]}")/reality.sh"; reality_menu ;;
            2) source "$LIB_DIR/nginx.sh"; source "$(dirname "${BASH_SOURCE[0]}")/vision.sh"; vision_menu ;;
            3) source "$LIB_DIR/nginx.sh"; source "$(dirname "${BASH_SOURCE[0]}")/xhttp.sh"; xhttp_menu ;;
            4) source "$(dirname "${BASH_SOURCE[0]}")/ss2022.sh"; xss_menu ;;
            5) source "$LIB_DIR/nginx.sh"; source "$(dirname "${BASH_SOURCE[0]}")/trojan.sh"; trojan_menu ;;
            6) source "$LIB_DIR/nginx.sh"; source "$(dirname "${BASH_SOURCE[0]}")/vmess.sh"; vmess_menu ;;
            7) source "$(dirname "${BASH_SOURCE[0]}")/socks.sh"; socks_menu ;;
            0) return ;;
        esac
    done
}

# ── Menu ──────────────────────────────────────────────────────────────────────
xray_menu() {
    _xray_check_deps
    while true; do
        show_menu "$(t xray.menu.title)" \
            "$(t xray.menu.install)" \
            "$(t xray.menu.upgrade)" \
            "$(t xray.menu.uninstall)" \
            "$(t xray.menu.nodes)" \
            "$(t xray.menu.routing)" \
            "$(t xray.menu.version)" \
            "$(t xray.menu.inbounds)" \
            "$(t xray.menu.test)" \
            "$(t xray.menu.restart)" \
            "$(t xray.menu.status)" \
            "$(t xray.menu.logs)" \
            "$(t xray.menu.share)" \
            "$(t exm.menu_item)" \
            "$(t nme.menu_item)"

        case "$MENU_CHOICE" in
            1)  xray_install;    press_enter ;;
            2)  xray_upgrade;    press_enter ;;
            3)  xray_uninstall;  press_enter ;;
            4)  _xray_require_installed && _xray_protocol_menu ;;
            5)  _xray_require_installed && {
                    source "$(dirname "${BASH_SOURCE[0]}")/routing.sh"
                    route_menu
                } ;;
            6)  xray_version;    press_enter ;;
            7)  echo -e "\n${BOLD}$(t xray.inbounds_title)${NC}"; xray_get_inbounds; press_enter ;;
            8)  "$XRAY_BIN" -test -config "$XRAY_CFG" && log_ok "$(t xray.config_ok)" || log_error "$(t xray.config_bad)"; press_enter ;;
            9)  xray_test_restart; press_enter ;;
            10) svc_status xray;   press_enter ;;
            11) xray_logs ;;
            12) _xray_require_installed && { _xray_view_all_nodes; press_enter; } ;;
            13) _xray_require_installed && { source "$LIB_DIR/exit_cli.sh"; exit_menu_node xray; press_enter; } ;;
            14) _xray_require_installed && { source "$LIB_DIR/exit_cli.sh"; node_menu_edit xray; press_enter; } ;;
            0)  return ;;
        esac
    done
}
