#!/usr/bin/env bash
# agent.sh — psm agent: connect this server to a PSM panel (jinqians/psm-panel)
#
#   psm agent join --panel URL --token TOKEN   download psm-agent, join, run it as a service
#   psm agent status [--json]                  installed, joined, running
#   psm agent upgrade                          update PSM, then psm-agent itself
#   psm agent remove --yes                     stop it and forget the panel
#
# psm-agent (agent/ in this repository) opens no port: it connects out to the
# panel over HTTPS, takes tasks and runs them as psm commands. The binary comes
# from this repository's GitHub release agent-v$PSM_AGENT_VERSION and is checked
# against that release's SHA256SUMS. The panel's install command
# (bootstrap.sh --panel URL --join TOKEN) ends with `psm agent join`.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PSM_AGENT_VERSION="0.10.1"
PSM_AGENT_BIN="/usr/local/bin/psm-agent"
PSM_AGENT_CFG="/etc/psm/agent.json"
PSM_AGENT_SERVICE="psm-agent"
PSM_AGENT_UNIT="/etc/systemd/system/psm-agent.service"
# tests point these at a local copy of the release and an http:// panel
PSM_AGENT_BASE_URL="${PSM_AGENT_BASE_URL:-https://github.com/jinqians/proxy-stack/releases/download/agent-v${PSM_AGENT_VERSION}}"

_agent_err() { printf 'psm agent: %s\n' "$*" >&2; }

_agent_usage() {
    cat <<'EOF'
Usage:
  psm agent join --panel URL --token TOKEN
  psm agent status [--json]
  psm agent upgrade
  psm agent remove --yes
EOF
}

_agent_asset() {
    case "$(get_arch)" in
        amd64) echo psm-agent-linux-amd64 ;;
        arm64) echo psm-agent-linux-arm64 ;;
        arm32) echo psm-agent-linux-armv7 ;;
        *) return 1 ;;
    esac
}

# Downloads the binary for this machine; installs it only if its sha256 matches.
_agent_download() {
    local asset tmp want got
    asset=$(_agent_asset) || { _agent_err "unsupported architecture: $(uname -m)"; return 1; }
    tmp=$(mktemp -d)
    if ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/$asset" "$PSM_AGENT_BASE_URL/$asset" \
        || ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/SHA256SUMS" "$PSM_AGENT_BASE_URL/SHA256SUMS"; then
        rm -rf "$tmp"
        _agent_err "download failed: $PSM_AGENT_BASE_URL/$asset"
        return 1
    fi
    want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
    got=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
    if [[ -z "$want" || "$want" != "$got" ]]; then
        rm -rf "$tmp"
        _agent_err "checksum mismatch for $asset: not installed"
        return 1
    fi
    svc_stop "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    install -m 755 "$tmp/$asset" "$PSM_AGENT_BIN"
    rm -rf "$tmp"
}

_agent_write_service() {
    if _uses_systemd; then
        cat > "$PSM_AGENT_UNIT" <<EOF
[Unit]
Description=PSM agent (connects this server to its PSM panel; opens no port)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${PSM_AGENT_BIN} run -config ${PSM_AGENT_CFG}
Restart=always
RestartSec=5
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        psm_write_openrc_service "$PSM_AGENT_SERVICE" "PSM agent" "$PSM_AGENT_BIN" "run -config $PSM_AGENT_CFG"
    fi
}

_agent_join() {
    local panel="" token="" allow_http="${PSM_AGENT_ALLOW_HTTP:-}" have i
    while (( $# )); do
        case "$1" in
            --panel) panel="${2:-}"; shift 2 ;;
            --token|--join) token="${2:-}"; shift 2 ;;
            --allow-http) allow_http=1; shift ;;
            *) _agent_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$panel" && -n "$token" ]] || { _agent_usage >&2; return 2; }
    [[ $EUID -eq 0 ]] || { _agent_err 'run as root'; return 1; }
    _psm_detect_init
    [[ "$_PSM_INIT" != none ]] || { _agent_err 'psm-agent runs as a service: systemd or OpenRC is needed'; return 1; }

    have=$("$PSM_AGENT_BIN" version 2>/dev/null || true)
    if [[ "$have" != "$PSM_AGENT_VERSION" ]]; then
        log_step "psm-agent ${PSM_AGENT_VERSION}"
        _agent_download || return 1
    fi
    local -a args=(join -panel "$panel" -token "$token" -config "$PSM_AGENT_CFG")
    [[ -z "$allow_http" ]] || args+=(-allow-http)
    if ! "$PSM_AGENT_BIN" "${args[@]}"; then
        _agent_err 'the panel did not accept the join token (used already, older than 24 h, or mistyped?): make a new install command in the panel'
        return 1
    fi
    _agent_write_service || return 1
    svc_enable "$PSM_AGENT_SERVICE" || true
    svc_restart "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    for i in $(seq 1 10); do
        svc_is_active "$PSM_AGENT_SERVICE" && break
        sleep 1
    done
    if ! svc_is_active "$PSM_AGENT_SERVICE"; then
        _agent_err 'psm-agent did not start'
        svc_log_tail "$PSM_AGENT_SERVICE" 15 >&2
        return 1
    fi
    log_ok "Connected to ${panel}: psm-agent is running (it opens no port) and the panel shows this server online."
}

# Updates PSM, then psm-agent itself. The panel's 升级 agent button makes
# psm-agent run this detached (restarting the service kills its own cgroup, so
# an upgrade started inside it would not survive its first step).
#
# PSM is updated first because the release to install — PSM_AGENT_VERSION — is
# named in this very file: a shell that sourced the old copy would faithfully
# reinstall the old agent. Hence the re-exec after the pull, so that the
# download below reads the new value.
_agent_upgrade() {
    local pull=1 have
    while (( $# )); do
        case "$1" in
            --yes) shift ;;              # accepted for symmetry: nothing is destroyed
            --no-pull) pull=0; shift ;;  # set by the re-exec below
            *) _agent_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ $EUID -eq 0 ]] || { _agent_err 'run as root'; return 1; }
    [[ -f "$PSM_AGENT_CFG" ]] || { _agent_err 'this server has not joined a panel: nothing to upgrade'; return 1; }
    _psm_detect_init
    [[ "$_PSM_INIT" != none ]] || { _agent_err 'psm-agent runs as a service: systemd or OpenRC is needed'; return 1; }

    if (( pull )); then
        # shellcheck source=/dev/null
        source "$PSM_ROOT/update.sh"
        psm_update_scripts || _agent_err 'PSM could not be updated; keeping the version already checked out'
        exec bash "$PSM_ROOT/manager.sh" agent upgrade --no-pull
    fi

    have=$("$PSM_AGENT_BIN" version 2>/dev/null || true)
    if [[ "$have" == "$PSM_AGENT_VERSION" ]]; then
        log_ok "psm-agent is already ${PSM_AGENT_VERSION}."
        svc_is_active "$PSM_AGENT_SERVICE" || svc_restart "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
        return 0
    fi
    log_step "psm-agent ${have:-not installed} → ${PSM_AGENT_VERSION}"
    _agent_download || return 1       # stops the service, checks sha256, installs
    _agent_write_service || return 1  # the unit itself may have changed between versions
    svc_enable "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    svc_restart "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        svc_is_active "$PSM_AGENT_SERVICE" && break
        sleep 1
    done
    if ! svc_is_active "$PSM_AGENT_SERVICE"; then
        _agent_err 'psm-agent did not start after the upgrade'
        svc_log_tail "$PSM_AGENT_SERVICE" 15 >&2
        return 1
    fi
    log_ok "psm-agent ${PSM_AGENT_VERSION} is running; the panel shows the new version at the next sync."
}

_agent_status_json() {
    local installed=false joined=false active=false version="" panel=""
    if [[ -x "$PSM_AGENT_BIN" ]]; then installed=true; version=$("$PSM_AGENT_BIN" version 2>/dev/null || true); fi
    if [[ -f "$PSM_AGENT_CFG" ]]; then joined=true; panel=$(jq -r '.panel // ""' "$PSM_AGENT_CFG" 2>/dev/null || true); fi
    svc_is_active "$PSM_AGENT_SERVICE" 2>/dev/null && active=true
    jq -nc --argjson i "$installed" --argjson j "$joined" --argjson a "$active" --arg v "$version" --arg p "$panel" \
        '{installed: $i, version: $v, joined: $j, panel: $p, active: $a}'
}

_agent_remove() {
    [[ "${1:-}" == --yes ]] || { _agent_err 'remove needs --yes'; return 2; }
    [[ $EUID -eq 0 ]] || { _agent_err 'run as root'; return 1; }
    svc_stop "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    svc_disable "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    if _uses_systemd; then
        rm -f "$PSM_AGENT_UNIT"
        systemctl daemon-reload || true
    else
        psm_remove_openrc_service "$PSM_AGENT_SERVICE"
    fi
    rm -f "$PSM_AGENT_BIN" "$PSM_AGENT_CFG"
    log_ok 'psm-agent removed; the nodes on this server are unchanged.'
}

psm_agent_cli() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        join) _agent_join "$@" ;;
        status)
            if [[ "${1:-}" == --json ]]; then _agent_status_json
            else _agent_status_json | jq -r 'to_entries[] | "\(.key): \(.value)"'; fi ;;
        upgrade|update) _agent_upgrade "$@" ;;
        remove|uninstall) _agent_remove "$@" ;;
        help|--help|-h) _agent_usage ;;
        *) _agent_usage >&2; return 2 ;;
    esac
}
