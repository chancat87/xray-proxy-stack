#!/usr/bin/env bash
# The commands the PSM panel's psm-agent runs, without questions, on a server
# that has only PSM: psm core (a core on demand), psm standalone (Snell v4/v5/v6,
# ss-rust), psm traffic (metering and limits), psm node export --format singbox
# and psm version — and PSM's own unattended install. The menus' installs are
# covered by the full suites.

set -uo pipefail
cd /opt/psm || exit 1

pass=0; fail=0; failed=()
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); failed+=("$1"); }
chk() {
    local n="$1"; shift
    if "$@" >/tmp/chk.out 2>&1; then ok "$n"; else bad "$n"; tail -15 /tmp/chk.out | sed 's/^/       /'; fi
}
sec() { echo; echo "=== $1"; }
listening() { local hex; hex=$(printf '%04X' "$1"); awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; }
# some bytes to a TCP port (the server may drop the connection: they are counted anyway)
poke() { timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; head -c 200000 /dev/zero >&3" 2>/dev/null || true; }
export -f listening poke   # the checks run them inside bash -c
musl=0; [[ -f /etc/alpine-release ]] && musl=1

sec "PSM, installed without questions (bootstrap.sh --panel does this)"
chk "PSM_UNATTENDED=1 install.sh returns, no menu" bash -c 'PSM_UNATTENDED=1 PSM_LANG=en timeout 900 bash install.sh </dev/null'
chk "the psm command exists" test -x /usr/local/bin/psm
chk "psm version answers" bash -c 'psm version | grep -Eq "^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9a-f]+|unknown)$"'
chk "psm help lists the new commands" bash -c 'psm help | grep -q "psm standalone" && psm help | grep -q "psm traffic" && psm help | grep -q "psm agent"'

sec "psm core: a core on demand"
chk "no core yet" bash -c 'psm core list --json | jq -e "all(.[]; .installed == false)"'
chk "psm core install sing-box, no questions" bash -c 'timeout 600 psm core install sing-box --json </dev/null | tee /dev/stderr | jq -e ".core == \"sing-box\" and .installed == true and .already == false"'
chk "… sing-box runs" /usr/local/bin/sing-box version
chk "--if-missing leaves it alone" bash -c 'psm core install sing-box --if-missing --json | jq -e ".already == true"'
chk "an unknown core → 2" bash -c 'psm core install v2ray; [[ $? == 2 ]]'
chk "a node on it" bash -c 'psm node add sing-box ss2022 --tag t-ss --port 30001 --json >/dev/null'
chk "psm node export --format singbox" bash -c \
    'psm node export sing-box ss2022 t-ss --server 203.0.113.5 --format singbox | jq -e ".type == \"shadowsocks\" and .server == \"203.0.113.5\" and .server_port == 30001"'
chk "a node sing-box has no outbound for says so (2)" bash -c \
    'psm node add sing-box snell --tag t-sn --port 30002 --set version=5 --json >/dev/null && { psm node export sing-box snell t-sn --server 203.0.113.5 --format singbox; [[ $? == 2 ]]; }'

sec "deleting the last Xray SS2022 node closes its port"
# it used to stay in Xray's live config, listening, although PSM no longer listed it
chk "psm core install xray" bash -c 'timeout 600 psm core install xray --json </dev/null | jq -e ".installed == true"'
# Xray rebinds while it restarts: wait for the ports rather than sampling once
chk "two Xray SS2022 nodes" bash -c 'psm node add xray ss2022 --tag xs1 --port 30401 --json >/dev/null && psm node add xray ss2022 --tag xs2 --port 30402 --json >/dev/null
    for _ in $(seq 1 15); do listening 30401 && listening 30402 && exit 0; sleep 1; done
    echo "30401=$(listening 30401 && echo up || echo down) 30402=$(listening 30402 && echo up || echo down)"; exit 1'
chk "deleting one closes its port and keeps the other" bash -c 'psm node delete xray ss2022 xs1 --yes --json >/dev/null && sleep 2 && ! listening 30401 && listening 30402'
chk "deleting the last one closes its port too" bash -c 'psm node delete xray ss2022 xs2 --yes --json >/dev/null && sleep 2 && ! listening 30402'
chk "… and no shadowsocks inbound is left in Xray" bash -c '! jq -e ".inbounds[] | select(.protocol == \"shadowsocks\")" /usr/local/etc/xray/config.json'

sec "psm traffic"
chk "set: meter t-ss without a limit" bash -c 'psm traffic set t-ss --limit-bytes 0 --json | jq -e ".tag == \"t-ss\" and .limit_bytes == 0 and .source == \"iptables\""'
poke 30001
chk "list counts its bytes" bash -c 'psm traffic list --json | jq -e ".[] | select(.tag == \"t-ss\") | .used_bytes > 1000"'
chk "the periodic check is installed" bash -c 'systemctl is-active --quiet psm-traffic.timer 2>/dev/null || test -f /etc/cron.d/psm-traffic'
chk "a limit below that, and the check pauses it" bash -c 'psm traffic set t-ss --limit-bytes 1000 --json >/dev/null && bash /opt/psm/manager.sh --traffic-check >/dev/null 2>&1; psm traffic list --json | jq -e ".[] | select(.tag == \"t-ss\") | .paused == true"'
chk "… and it refuses connections" bash -c '! timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/30001"'
chk "reset: counter at 0, running again" bash -c 'psm traffic reset t-ss --json | jq -e ".paused == false and .used_bytes == 0"'
chk "… it takes connections" timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/30001'
chk "a raised limit also lifts a pause" bash -c 'psm traffic set t-ss --limit-bytes 1000 >/dev/null; poke(){ :; }; timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/30001; head -c 200000 /dev/zero >&3" 2>/dev/null; bash /opt/psm/manager.sh --traffic-check >/dev/null 2>&1; psm traffic set t-ss --limit-gb 1 --json | jq -e ".paused == false and .limit_bytes == 1073741824"'
chk "unset: no longer metered" bash -c 'psm traffic unset t-ss --json >/dev/null && ! psm traffic list --json | jq -e ".[] | select(.tag == \"t-ss\")"'
chk "deleting a node drops its metering" bash -c 'psm traffic set t-sn --json >/dev/null && psm node delete sing-box snell t-sn --yes >/dev/null && ! psm traffic list --json | jq -e ".[] | select(.tag == \"t-sn\")"'
chk "an unknown tag → error" bash -c '! psm traffic set nope 2>&1 | grep -q .; psm traffic set nope 2>&1 | grep -q "no node"'
chk "a bad reset day → 2" bash -c 'psm traffic set t-ss --reset-day 40; [[ $? == 2 ]]'

sec "psm standalone: ss-rust"
chk "install ss2022 (aes-256, key generated)" bash -c 'timeout 600 psm standalone install ss2022 --port 30200 --method 2022-blake3-aes-256-gcm --json | tee /dev/stderr | jq -e ".active == true and .port == 30200"'
chk "… listens" listening 30200
chk "… its key is 32 bytes" bash -c '[[ $(psm standalone show ss2022 --json | jq -r .password | base64 -d | wc -c) == 32 ]]'
chk "export uri" bash -c 'psm standalone export ss2022 --server 203.0.113.5 --name hk-ss | grep -Eq "^ss://[A-Za-z0-9_-]+@203\.0\.113\.5:30200#hk-ss$"'
chk "export surge" bash -c 'psm standalone export ss2022 --server 203.0.113.5 --name hk-ss --format surge | grep -q "^hk-ss = ss, 203.0.113.5, 30200, encrypt-method=2022-blake3-aes-256-gcm, password="'
chk "export singbox" bash -c 'psm standalone export ss2022 --server 203.0.113.5 --format singbox | jq -e ".type == \"shadowsocks\" and .server_port == 30200"'
# a real connection: sing-box as the client, through ss-rust, to the internet.
# The config has that one outbound and routes everything to it: without it
# (a failed export) there is no config and no connection — never "direct".
ob=$(psm standalone export ss2022 --server 127.0.0.1 --format singbox 2>/dev/null || true)
jq -n --argjson ob "${ob:-null}" '{log: {level: "error"},
    inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: 30990}],
    outbounds: [$ob], route: {final: $ob.tag}}' > /tmp/sb-client.json 2>/dev/null || rm -f /tmp/sb-client.json
chk "the client config routes through the ss-rust outbound" bash -c 'jq -e ".outbounds[0].type == \"shadowsocks\" and .route.final == .outbounds[0].tag" /tmp/sb-client.json'
/usr/local/bin/sing-box run -c /tmp/sb-client.json >/tmp/sb-client.log 2>&1 & sbc=$!
sleep 2
chk "a client gets through it (HTTP 204)" bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 20 -x socks5h://127.0.0.1:30990 https://www.gstatic.com/generate_204) == 204 ]]'
chk "metered as ss2022" bash -c 'psm traffic set ss2022 --json >/dev/null && curl -s -o /dev/null --max-time 20 -x socks5h://127.0.0.1:30990 https://www.gstatic.com/generate_204; psm traffic list --json | jq -e ".[] | select(.tag == \"ss2022\") | .used_bytes > 0"'
kill "$sbc" 2>/dev/null
chk "install again on a new port replaces it" bash -c 'psm standalone install ss2022 --port 30201 --json >/dev/null && listening 30201 && ! listening 30200'
chk "a wrong-length key → 2" bash -c 'psm standalone install ss2022 --port 30202 --password "$(openssl rand -base64 8)"; [[ $? == 2 ]]'
chk "a port in use → error" bash -c '! psm standalone install ss2022 --port 30001 2>&1 | tee /dev/stderr | grep -q "in use" && false || true; psm standalone install ss2022 --port 30001 2>&1 | grep -q "in use"'
chk "remove" bash -c 'psm standalone remove ss2022 --yes --json | jq -e ".status == \"removed\"" && ! listening 30201 && ! test -e /usr/local/bin/ss-rust'
chk "… and its metering" bash -c '! psm traffic list --json | jq -e ".[] | select(.tag == \"ss2022\")"'

sec "psm standalone: Snell"
if (( musl )); then
    chk "Snell is refused on musl, with the reason" bash -c 'psm standalone install snell --port 30100 2>&1 | grep -q musl'
else
    for v in 4 5 6; do
        port=$((30100 + v))
        chk "Snell v$v installs" bash -c "timeout 600 psm standalone install snell --port $port --version $v --psk testpsk${v}abcdef --json | tee /dev/stderr | jq -e '.active == true and .port == $port and .version == \"$v\"'"
        chk "… listens on $port" listening "$port"
        chk "… the build is v$v" grep -q "^v$v\." /etc/snell/psm-build
        chk "… Surge line with version=$v" bash -c "psm standalone export snell --server 203.0.113.5 --name hk-snell | grep -qx 'hk-snell = snell, 203.0.113.5, $port, psk=testpsk${v}abcdef, version=$v'"
    done
    chk "the menus' config file is the one written" grep -q '^listen = .*:30106$' /etc/snell/users/snell-main.conf
    chk "no URI for Snell (2)" bash -c 'psm standalone export snell --server 203.0.113.5 --format uri; [[ $? == 2 ]]'
    chk "remove" bash -c 'psm standalone remove snell --yes --json | jq -e ".status == \"removed\"" && ! listening 30106 && ! test -e /usr/local/bin/snell-server'
fi
chk "a bad Snell version → 2" bash -c 'psm standalone install snell --port 30110 --version 3; [[ $? == 2 ]]'

sec "nodes as the panel makes them: no certificate, a firewall that drops"
# What psm-agent runs for the panel on a server with neither a domain nor an
# open port: the TLS protocols get a self-signed certificate (and links that
# accept it), and each node opens its port in the firewall and shuts it again.
chk "a firewall that drops new connections (iptables)" bash -c \
    'iptables -I INPUT 1 -i lo -j ACCEPT && iptables -I INPUT 2 -m state --state ESTABLISHED,RELATED -j ACCEPT && iptables -P INPUT DROP'
fwc() { iptables -C INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null; }
export -f fwc
chk "sing-box Hysteria2 without a certificate is made" bash -c 'psm node add sing-box hysteria2 --tag t-hy --port 30501 --json | jq -e ".status == \"created\""'
chk "… self-signed for www.bing.com, insecure" bash -c \
    'n=$(psm node show sing-box hysteria2 t-hy --json | jq -c .item.node); jq -e ".insecure == 1 and .sni == \"www.bing.com\"" <<<"$n" && openssl x509 -in "$(jq -r .cert_path <<<"$n")" -noout -subject | grep -q "CN *= *www.bing.com"'
chk "… udp/30501 open in the firewall" fwc 30501 udp
chk "… its link says insecure=1" bash -c 'psm node export sing-box hysteria2 t-hy --server 203.0.113.5 | grep -q "insecure=1"'
ob=$(psm node export sing-box hysteria2 t-hy --server 127.0.0.1 --format singbox 2>/dev/null || true)
jq -n --argjson ob "${ob:-null}" '{log: {level: "error"},
    inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: 30991}],
    outbounds: [$ob], route: {final: $ob.tag}}' > /tmp/sb-hy.json 2>/dev/null || rm -f /tmp/sb-hy.json
/usr/local/bin/sing-box run -c /tmp/sb-hy.json >/tmp/sb-hy.log 2>&1 & sbc=$!
sleep 2
chk "a client gets through it, accepting the certificate (HTTP 204)" bash -c \
    '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 20 -x socks5h://127.0.0.1:30991 https://www.gstatic.com/generate_204) == 204 ]] || { tail -5 /tmp/sb-hy.log; false; }'
kill "$sbc" 2>/dev/null
chk "sing-box VLESS over WebSocket, no certificate, an SNI of our own" bash -c \
    'psm node add sing-box vless --tag t-vl --port 30502 --set transport=ws --set sni=vl.example.org --json | jq -e ".status == \"created\"" && fwc 30502 tcp'
chk "… its link accepts the certificate (allowInsecure=1)" bash -c 'psm node export sing-box vless t-vl --server 203.0.113.5 | grep -q "sni=vl.example.org&type=ws&allowInsecure=1"'
# a self-signed certificate is pinned, not skipped (Xray refuses allowInsecure since 2026-06-01)
chk "… as a sing-box outbound: its public key pinned, not insecure" bash -c \
    'psm node export sing-box vless t-vl --server 203.0.113.5 --format singbox | jq -e "(.tls.certificate_public_key_sha256 | length) == 1 and (.tls.insecure | not) and .tls.server_name == \"vl.example.org\""'
chk "… as a mihomo proxy: skip-cert-verify and its fingerprint, ws" bash -c \
    'psm node export sing-box vless t-vl --server 203.0.113.5 --format clash | jq -e ".type == \"vless\" and .\"skip-cert-verify\" == true and (.fingerprint | test(\"^[0-9a-f]{64}$\")) and .network == \"ws\" and .servername == \"vl.example.org\" and .port == 30502"'
chk "… its link: allowInsecure and pcs" bash -c \
    '[[ $(psm node export sing-box vless t-vl --server 203.0.113.5) =~ allowInsecure=1\&pcs=[0-9a-f]{64} ]]'
chk "SS2022 as a mihomo proxy" bash -c \
    'psm node export sing-box ss2022 t-ss --server 203.0.113.5 --format clash | jq -e ".type == \"ss\" and .server == \"203.0.113.5\" and .port == 30001 and (.cipher | startswith(\"2022-\"))"'
chk "Snell has no mihomo proxy (mihomo speaks Snell v1-v3 only) → 2" bash -c \
    'psm node add sing-box snell --tag t-sn2 --port 30509 --set version=5 --json >/dev/null && { psm node export sing-box snell t-sn2 --server 203.0.113.5 --format clash; rc=$?; psm node delete sing-box snell t-sn2 --yes >/dev/null; [[ $rc == 2 ]]; }'
chk "psm core install mihomo" bash -c 'timeout 600 psm core install mihomo --json </dev/null | jq -e ".installed == true"'
chk "mihomo TUIC without a certificate: made, insecure, udp/30503 open" bash -c \
    'psm node add mihomo tuic --tag t-tu --port 30503 --json >/dev/null && psm node show mihomo tuic t-tu --json | jq -e ".item.node.insecure == 1" && fwc 30503 udp'
chk "certificate files that are not there → 2, nothing made" bash -c \
    'psm node add sing-box anytls --tag t-bad --port 30504 --set cert_path=/nope.crt --set key_path=/nope.key; [[ $? == 2 ]] && ! psm node show sing-box anytls t-bad --json'
chk "Xray Vision for a domain without a certificate → 2, saying what to do" bash -c \
    'out=$(psm node add xray vision --tag t-vis --port 30505 --set domain=nocert.example.com 2>&1); rc=$?; [[ $rc == 2 ]] && grep -q "no certificate for nocert.example.com" <<<"$out" && ! psm node show xray vision t-vis --json'
chk "a port the firewall already let in is not PSM's to shut" bash -c \
    'iptables -I INPUT -p tcp --dport 30506 -j ACCEPT && psm node add sing-box ss2022 --tag t-open --port 30506 --json >/dev/null && fwc 30506 udp && ! grep -qx "30506/tcp" /opt/psm/config/firewall-ports'
chk "deleting a node shuts its port" bash -c 'psm node delete sing-box hysteria2 t-hy --yes >/dev/null && ! fwc 30501 udp'
chk "a new port opens the new one and shuts the old one" bash -c 'psm node update sing-box vless t-vl --port 30507 --json >/dev/null && fwc 30507 tcp && ! fwc 30502 tcp'
chk "deleting t-open leaves the rule it found" bash -c 'psm node delete sing-box ss2022 t-open --yes >/dev/null && fwc 30506 tcp && ! fwc 30506 udp'
chk "… and only what PSM opened is written down" bash -c \
    'psm node delete sing-box vless t-vl --yes >/dev/null && psm node delete mihomo tuic t-tu --yes >/dev/null && ! test -s /opt/psm/config/firewall-ports'
iptables -D INPUT -p tcp --dport 30506 -j ACCEPT; iptables -P INPUT ACCEPT
iptables -D INPUT -i lo -j ACCEPT; iptables -D INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

sec "exits: one node's traffic through WARP (psm node … --exit), in each core"
# Cloudflare's trace, fetched by a sing-box client through a node, says
# warp=on only when the request left through WARP. 1.1.1.1 is not in the AI
# sites, so with --exit-sites ai it goes out directly (warp=off).
trace_via() {   # <sing-box outbound json> <local port>
    jq -n --argjson ob "$1" --argjson p "$2" '{log: {level: "error"},
        inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: $p}],
        outbounds: [$ob], route: {final: $ob.tag}}' > "/tmp/sb-ex-$2.json" || return 1
    /usr/local/bin/sing-box run -c "/tmp/sb-ex-$2.json" >"/tmp/sb-ex-$2.log" 2>&1 & local pid=$!
    sleep 2
    curl -s --max-time 20 -x "socks5h://127.0.0.1:$2" https://1.1.1.1/cdn-cgi/trace
    kill "$pid" 2>/dev/null
}
warp_is() {   # <on|off> <core> <tag> <local port> <the node's port>
    local ob t i
    # setting a node's exit rewrites its core's routing, which restarts the
    # core: wait for the node to listen again before dialling it
    for i in $(seq 1 15); do listening "$5" && break; sleep 2; done
    ob=$(psm node export "$2" ss2022 "$3" --server 127.0.0.1 --format singbox 2>/dev/null) || { echo "no outbound for $3"; return 1; }
    for i in 1 2; do
        t=$(trace_via "$ob" "$4")
        grep -q "^warp=$1\$" <<<"$t" && return 0
        sleep 3
    done
    echo "trace: ${t:-nothing}"; tail -5 "/tmp/sb-ex-$4.log"; return 1
}
rule_for() {   # <core> <tag>: that node's exit rule, as the core has it
    case "$1" in
        sing-box) jq -c --arg t "$2" '.route.rules[] | select(.inbound == [$t])' /etc/sing-box/config.json ;;
        xray)     jq -c --arg t "$2" '.routing.rules[] | select(.inboundTag == [$t])' /usr/local/etc/xray/config.json ;;
        mihomo)   grep -F "IN-NAME,$2" /etc/mihomo/config.yaml ;;
    esac
}
export -f trace_via warp_is rule_for   # the checks run them inside bash -c
p=30600
for core in sing-box xray mihomo; do
    p=$((p + 1)); tag="ex-${core//-/}"
    chk "$core: an SS2022 node whose traffic all leaves through WARP" bash -c \
        "psm node add $core ss2022 --tag $tag --port $p --exit warp --exit-sites all --json | jq -e '.status == \"created\"'"
    chk "$core: … a client through it comes out of Cloudflare WARP (warp=on)" warp_is on "$core" "$tag" $((p + 100)) "$p"
    chk "$core: … only AI sites through WARP now: 1.1.1.1 goes out directly (warp=off)" bash -c \
        "psm node update $core ss2022 $tag --exit-sites ai --json >/dev/null"
    chk "$core: … warp=off" warp_is off "$core" "$tag" $((p + 200)) "$p"
    case "$core" in
        sing-box) chk "$core: … its rule: this inbound and the AI rule sets" bash -c "rule_for $core $tag | jq -e '(.rule_set | index(\"geosite-openai\")) and (.rule_set | index(\"geosite-google-gemini\")) and .outbound == \"out-warp\"'" ;;
        xray)     chk "$core: … its rule: this inbound and the AI geosites" bash -c "rule_for $core $tag | jq -e '(.domain | index(\"geosite:openai\")) and .outboundTag == \"out-warp\"'" ;;
        mihomo)   chk "$core: … its rule: this listener AND one of the AI geosites" bash -c "rule_for $core $tag | grep -q 'AND,((IN-NAME,$tag),(OR,((GEOSITE,openai),(GEOSITE,anthropic),(GEOSITE,google-gemini)))),warp-out'" ;;
    esac
done
chk "sing-box stays up with geosite rules, from rule sets on disk" bash -c \
    'systemctl is-active --quiet sing-box 2>/dev/null || rc-service sing-box status >/dev/null 2>&1; rc=$?
     jq -e "[.route.rule_set[]? | select(.tag | startswith(\"geosite-\"))] | length > 0 and all(.[]; .type == \"local\" and .format == \"binary\")" /etc/sing-box/config.json
     ls /etc/sing-box/rulesets/geosite-openai.srs >/dev/null && [[ $rc == 0 ]]'
chk "sing-box: --exit none takes the rule away" bash -c \
    'psm node update sing-box ss2022 ex-singbox --exit none --json >/dev/null && [[ -z $(rule_for sing-box ex-singbox) ]]'
chk "psm exit status: WARP registered, rules counted" bash -c \
    'psm exit status --json | jq -e ".warp.registered and .cores.xray.node_rules == 1 and .cores.mihomo.node_rules == 1 and .cores[\"sing-box\"].node_rules == 0"'
chk "deleting the nodes takes their rules away" bash -c \
    'for c in sing-box xray mihomo; do psm node delete $c ss2022 ex-${c//-/} --yes >/dev/null || exit 1; done; psm exit status --json | jq -e "[.cores[].node_rules] | add == 0" && [[ -z $(rule_for mihomo ex-mihomo) ]]'
chk "a bad exit → 2, nothing made" bash -c \
    'psm node add sing-box ss2022 --tag ex-bad --port 30650 --exit tor; [[ $? == 2 ]] && ! psm node show sing-box ss2022 ex-bad --json'
chk "a site name that is not one → 2" bash -c \
    'psm node add sing-box ss2022 --tag ex-bad --port 30650 --exit warp --exit-sites "openai;rm"; [[ $? == 2 ]]'

sec "exits: the free residential line (VPNGate)"
# VPNGate's lines are volunteers' home connections; from a datacenter none may
# answer. That is reported as skipped, with the reason, not as a pass.
if vg_out=$(timeout 900 psm exit vpngate --core sing-box --country JP --json 2>&1); then
    ok "a residential line is up ($(jq -r '.vpngate.country + " " + .vpngate.ip' <<<"$(tail -1 <<<"$vg_out")" 2>/dev/null))"
    direct_ip=$(curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace | awk -F= '/^ip=/ {print $2}')
    chk "a node whose traffic leaves through it" bash -c \
        'psm node add sing-box ss2022 --tag ex-vg --port 30660 --exit vpngate --exit-sites all --json | jq -e ".status == \"created\""'
    vg_ip() { local ob t i; for i in $(seq 1 15); do listening 30660 && break; sleep 2; done
        ob=$(psm node export sing-box ss2022 ex-vg --server 127.0.0.1 --format singbox) || return 1
        t=$(trace_via "$ob" 30760); ip=$(awk -F= '/^ip=/ {print $2}' <<<"$t"); [[ -n "$ip" && "$ip" != "$direct_ip" ]] || { echo "exit ip ${ip:-none}, direct $direct_ip"; return 1; }; }
    chk "… a client through it comes out of another IP than the server's" vg_ip
    chk "… deleting the node takes its rule away, the line stays" bash -c \
        'psm node delete sing-box ss2022 ex-vg --yes >/dev/null && psm exit status --json | jq -e ".vpngate.installed and .cores[\"sing-box\"].node_rules == 0"'
elif grep -qE "answered|no residential" <<<"$vg_out"; then
    echo "  skip VPNGate: $(grep -E 'answered|no residential' <<<"$vg_out" | tail -1) — volunteer lines, not a PSM failure"
else
    bad "psm exit vpngate"; tail -15 <<<"$vg_out" | sed 's/^/       /'
fi

sec "psm sni find: camouflage targets from a mapping engine (a stand-in for Netlas)"
# The engine is played by a local server with Netlas's answer format; the
# hosts in it are real, so the TLS checks are real.
command -v python3 >/dev/null || { apt-get install -y -qq python3 >/dev/null 2>&1 || apk add -q python3 >/dev/null 2>&1 || dnf -y -q install python3 >/dev/null 2>&1; }
mkdir -p /tmp/netlas/api/responses /tmp/netlas/api/users/current
items=""
for h in www.cloudflare.com www.apple.com dl.google.com; do
    ip=$(curl -4 -s -o /dev/null -w '%{remote_ip}' --max-time 10 "https://$h/")
    [[ -n "$ip" ]] && items+=$(jq -nc --arg n "$h" --arg ip "$ip" '{data: {ip: $ip, certificate: {subject: {common_name: [$n]}}}}'),
done
printf '{"items":[%s]}' "${items%,}" > /tmp/netlas/api/responses/index.html
echo '{"requests_left": 50}' > /tmp/netlas/api/users/current/index.html
(cd /tmp/netlas && exec python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1) & netlas=$!
sleep 1
chk "camouflage targets from the engine, each passing a TLS handshake" bash -c \
    'SNI_NETLAS_BASE=http://127.0.0.1:18080 psm sni find --engine netlas --key-stdin --json <<<"k-test-123" | tee /dev/stderr | jq -e "(.candidates | length > 0) and all(.candidates[]; .sni != \"\" and (.dest | test(\":443$\")))"'
chk "… the key was used for the search, not kept" bash -c '! grep -rqs k-test-123 /opt/psm/config'
chk "no key → error, saying so" bash -c 'out=$(psm sni find --engine quake --json 2>&1); rc=$?; [[ $rc == 1 ]] && grep -q "no API key" <<<"$out"'
chk "an unknown engine → 2" bash -c 'psm sni find --engine shodan --key-stdin <<<"k"; [[ $? == 2 ]]'
kill "$netlas" 2>/dev/null

echo
echo "=== RESULT: $pass ok, $fail failed"
(( fail == 0 )) || { printf '  - %s\n' "${failed[@]}"; exit 1; }
