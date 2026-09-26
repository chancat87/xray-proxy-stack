#!/usr/bin/env bash
# Validate every snapshot against the REAL proxy cores.
#
# config-regression.sh pins what the builders emit; this pins that the cores
# accept it. Each snapshot fragment is wrapped into a minimal complete config
# and handed to `xray run -test`, `sing-box check` or `mihomo -t`. A core that
# is not installed is skipped, so the offline CI job stays green without them.
#
#   XRAY_BINS="/opt/xray-stable/xray /opt/xray-pre/xray"   (default: xray on PATH)
#   SINGBOX_BIN=/path/sing-box                             (default: sing-box on PATH)
#   MIHOMO_BIN=/path/mihomo                                (default: mihomo on PATH)
#   XRAY_ASSET_DIR=/dir/with/geosite.dat                   (default: next to each xray)

set -uo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_DIR="$PSM_ROOT/tests/snapshots"

for cmd in jq openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "missing test dependency: $cmd" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Snapshots point at certificate paths that only exist on a real server. Swap
# every cert/key string for a throwaway self-signed pair instead of touching /etc.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=psm-test -keyout "$tmp/key.pem" -out "$tmp/crt.pem" >/dev/null 2>&1 \
    || { echo "cannot create a test certificate" >&2; exit 2; }
# Fixtures also carry placeholder REALITY private keys ("private-test-key"),
# which every core rightly rejects. Any 32 random bytes are a valid X25519
# private key, so substitute one (base64url, no padding — all three cores).
x25519_key="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
with_test_certs() {
    jq --arg crt "$tmp/crt.pem" --arg key "$tmp/key.pem" --arg pk "$x25519_key" '
        walk(if type == "string" then
                 (if test("(fullchain\\.pem|\\.crt)$") then $crt
                  elif test("(privkey\\.pem|\\.key)$") then $key
                  else . end)
             elif type == "object" and (.type // "") == "wireguard" then
                 .   # real WireGuard keys: standard padded base64, not the X25519 placeholder form
             elif type == "object" then
                 with_entries(if .key == "privateKey" or .key == "private_key"
                                 or .key == "private-key"
                              then .value = $pk else . end)
             else . end)' "$1"
}

passed=0 failed=0 skipped=0
# SHOW_WARNINGS=1: also print what a core warns about in a config it accepts —
# deprecations are next release's failures (sing-box: "deprecated … will be
# removed in 1.16.0"; Xray: "[Warning] … deprecated").
warnings() {   # warnings <core output>
    [[ "${SHOW_WARNINGS:-0}" == 1 ]] || return 0
    printf '%s\n' "$1" | grep -iE 'deprecat|will be removed|removed in|\[warn|level=warn|WARN' \
        | grep -viE 'ClientHello|failed to .*(listen|dial)' | sed 's/^/       warn: /' | head -n 8
}
report() {   # report <ok|FAIL|skip> <core> <snapshot> [error output]
    case "$1" in
        ok)   passed=$((passed + 1)) ;;
        FAIL) failed=$((failed + 1)) ;;
        skip) skipped=$((skipped + 1)) ;;
    esac
    printf '%-4s [%s] %s\n' "$1" "$2" "$3"
    [[ -n "${4:-}" ]] && printf '%s\n' "$4" | tail -n 4 | sed 's/^/       /'
    return 0
}

# ── Xray ──────────────────────────────────────────────────────────────────────
xray_wrap() {   # fragment → full config on stdout
    local frag="$1" name="$2"
    case "$name" in
        xray-vpngate)
            jq -n --argjson o "$frag" '{outbounds: [{protocol: "freedom", tag: "direct"}, $o]}' ;;
        xray-route-*|ruleset-xray-inline)
            jq -n --argjson r "$frag" '
                ($r | if type == "array" then . else [.] end) as $rules
                | {outbounds: ([{protocol: "freedom", tag: "direct"}]
                               + ([$rules[].outboundTag] | unique
                                  | map(select(. != "direct") | {protocol: "blackhole", tag: .}))),
                   routing: {rules: $rules}}' ;;
        *)
            jq -n --argjson i "$frag" '{inbounds: [$i], outbounds: [{protocol: "freedom", tag: "direct"}]}' ;;
    esac
}

validate_xray() {
    local bin="$1" label snap name out cfg asset
    label="xray $("$bin" version 2>/dev/null | awk 'NR==1{print $2}')"
    asset="${XRAY_ASSET_DIR:-$(dirname "$bin")}"
    for snap in "$SNAPSHOT_DIR"/xray-*.json "$SNAPSHOT_DIR"/ruleset-xray-inline.json; do
        name="$(basename "$snap" .json)"
        case "$name" in xray-xhttp-mkcp*) continue ;; esac   # legacy/finalmask pairs, below
        cfg="$tmp/$name.json"
        xray_wrap "$(with_test_certs "$snap")" "$name" > "$cfg"
        if [[ "$name" == xray-route-geosite && ! -s "$asset/geosite.dat" ]]; then
            report skip "$label" "$name (no geosite.dat in $asset)"; continue
        fi
        if out=$(XRAY_LOCATION_ASSET="$asset" "$bin" run -test -config "$cfg" 2>&1); then
            report ok "$label" "$name"; warnings "$out"
        else
            report FAIL "$label" "$name" "$out"
        fi
    done

    # mKCP seed/header: three forms, and PSM writes the first the installed Xray
    # takes, in this order (_xray_kcp_form): mkcp-legacy, finalmask, legacy.
    # What must hold is that every core accepts one of them; the one it lands on
    # is reported.
    local style base pair
    for base in xray-xhttp-mkcp xray-xhttp-mkcp-enc; do
        [[ -f "$SNAPSHOT_DIR/$base.json" ]] || continue
        style=""
        # an Xray that ignores finalmask altogether (v25) passes any form; PSM
        # detects it with a mask type that does not exist, and so does this
        local order=("$base-mkcplegacy:mkcp-legacy" "$base-finalmask:finalmask" "$base:legacy")
        jq -n '{inbounds: [{port: 1, protocol: "vless", settings: {clients: [], decryption: "none"},
                  streamSettings: {network: "kcp", security: "none", finalmask: {udp: [{type: "psm-no-such-mask"}]}}}],
                outbounds: [{protocol: "freedom"}]}' > "$tmp/kcp-probe.json"
        "$bin" run -test -config "$tmp/kcp-probe.json" &>/dev/null && order=("$base:legacy")
        for pair in "${order[@]}"; do
            name="${pair%%:*}"
            [[ -f "$SNAPSHOT_DIR/$name.json" ]] || continue
            cfg="$tmp/$name.json"
            xray_wrap "$(with_test_certs "$SNAPSHOT_DIR/$name.json")" "$name" > "$cfg"
            if out=$("$bin" run -test -config "$cfg" 2>&1); then style="${pair#*:}"; break; fi
        done
        if [[ -n "$style" ]]; then
            report ok "$label" "$base ($style form)"; warnings "$out"
        else
            report FAIL "$label" "$base (neither form accepted)" "$out"
        fi
    done
}

# ── sing-box ──────────────────────────────────────────────────────────────────
validate_singbox() {
    local bin="$1" ver label snap name out cfg frag
    ver="$("$bin" version 2>/dev/null | awk 'NR==1{print $3}')"
    label="sing-box $ver"
    for snap in "$SNAPSHOT_DIR"/singbox-*.json "$SNAPSHOT_DIR"/ruleset-singbox-source.json; do
        name="$(basename "$snap" .json)"
        # The legacy branch is only emitted for cores older than 1.12 (it uses
        # domain_strategy, which 1.14 removed): not applicable to a newer core.
        if [[ "$name" == singbox-vpngate-legacy ]] \
            && [[ "$(printf '%s\n1.12.0\n' "${ver%%-*}" | sort -V | head -1)" == "1.12.0" ]]; then
            report skip "$label" "$name (branch only used below 1.12)"; continue
        fi
        cfg="$tmp/$name.json"
        frag="$(with_test_certs "$snap")"
        if [[ "$name" == ruleset-singbox-source ]]; then
            printf '%s' "$frag" > "$cfg"
            if out=$("$bin" rule-set compile "$cfg" -o "$tmp/$name.srs" 2>&1); then
                report ok "$label" "$name"
            else
                report FAIL "$label" "$name" "$out"
            fi
            continue
        fi
        if jq -e '.type == "wireguard"' <<<"$frag" >/dev/null; then
            # A WireGuard server is an endpoint, not an inbound (lib/singbox/wireguard.sh)
            jq -n --argjson e "$frag" '{endpoints: [$e], outbounds: [{type: "direct", tag: "direct"}]}' > "$cfg"
        elif jq -e 'has("listen_port")' <<<"$frag" >/dev/null; then
            jq -n --argjson i "$frag" '{inbounds: [$i], outbounds: [{type: "direct", tag: "direct"}]}' > "$cfg"
        else
            # Outbounds may reference the "psm-local" resolver that the real
            # config.json defines at top level (lib/singbox/core.sh).
            jq -n --argjson o "$frag" '{dns: {servers: [{type: "local", tag: "psm-local"}]},
                                        outbounds: [{type: "direct", tag: "direct"}, $o]}' > "$cfg"
        fi
        if out=$("$bin" check -c "$cfg" 2>&1); then
            report ok "$label" "$name"; warnings "$out"
        else
            report FAIL "$label" "$name" "$out"
        fi
    done
}

# ── mihomo ────────────────────────────────────────────────────────────────────
validate_mihomo() {
    local bin="$1" label snap name out dir frag
    label="mihomo $("$bin" -v 2>/dev/null | awk 'NR==1{print $3}')"
    for snap in "$SNAPSHOT_DIR"/mihomo-*.json; do
        name="$(basename "$snap" .json)"
        dir="$tmp/mh-$name"; mkdir -p "$dir"
        frag="$(with_test_certs "$snap")"
        # YAML is a superset of JSON, so the wrapper can stay JSON.
        if jq -e 'has("port")' <<<"$frag" >/dev/null; then
            jq -n --argjson l "$frag" '{"mixed-port": 0, listeners: [$l], rules: ["MATCH,DIRECT"]}'
        else
            jq -n --argjson p "$frag" '{"mixed-port": 0, proxies: [$p], rules: ["MATCH,DIRECT"]}'
        fi > "$dir/config.yaml"
        if out=$("$bin" -t -d "$dir" -f "$dir/config.yaml" 2>&1); then
            report ok "$label" "$name"; warnings "$out"
        else
            report FAIL "$label" "$name" "$out"
        fi
    done
}

# ── Run ───────────────────────────────────────────────────────────────────────
xray_bins="${XRAY_BINS:-$(command -v xray 2>/dev/null || true)}"
singbox_bin="${SINGBOX_BIN:-$(command -v sing-box 2>/dev/null || true)}"
mihomo_bin="${MIHOMO_BIN:-$(command -v mihomo 2>/dev/null || true)}"

ran=0
for b in $xray_bins; do [[ -x "$b" ]] && { validate_xray "$b"; ran=1; }; done
[[ -n "$singbox_bin" && -x "$singbox_bin" ]] && { validate_singbox "$singbox_bin"; ran=1; }
[[ -n "$mihomo_bin" && -x "$mihomo_bin" ]] && { validate_mihomo "$mihomo_bin"; ran=1; }

if (( ! ran )); then
    echo "core validation: skipped (no xray / sing-box / mihomo binary found)"
    exit 0
fi
echo "core validation: $passed ok, $failed failed, $skipped skipped"
(( failed == 0 ))
