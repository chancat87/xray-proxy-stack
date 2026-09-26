#!/usr/bin/env bash
# tests/integration/xray-link.sh — a share link as an Xray client imports it.
#
# v2rayN, v2rayNG, Happ … turn a vless:// trojan:// vmess:// hysteria2:// link
# into an Xray outbound; this does the same for the e2e suites, so PSM's links
# are checked with the client most people use. As in v2rayN 7.25 on Xray 26.x:
# pcs (vmess: "pcs") and pinSHA256 become tlsSettings.pinnedPeerCertSha256, and
# allowInsecure / insecure are dropped — Xray refuses "allowInsecure" outright
# since 2026-06-01, so a self-signed node without a pin cannot connect.
#
#   source tests/integration/xray-link.sh
#   xray_link_client <link> <socks port> > client.json   # a whole client config
#
# Needs bash, jq and base64.

_xl_urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

# xray_link_outbound <link>: one outbound, tagged "proxy"; status 1 for a
# scheme it does not handle.
xray_link_outbound() {
    local link="$1" scheme rest q user hostport host port qj kv k v
    scheme=${link%%://*}; rest=${link#*://}; rest=${rest%%#*}
    if [[ "$scheme" == vmess ]]; then
        printf '%s' "$rest" | base64 -d 2>/dev/null | jq -c '
            { tag: "proxy", protocol: "vmess",
              settings: { vnext: [ { address: .add, port: (.port | tonumber),
                                     users: [ { id: .id, security: (.scy // "auto") } ] } ] },
              streamSettings: ({ network: (.net // "tcp") }
                + (if (.net // "") == "ws" then { wsSettings: { path: (.path // "/"), host: (.host // "") } } else {} end)
                + (if (.tls // "") == "tls" then
                     { security: "tls",
                       tlsSettings: ({ serverName: (.sni // .host // ""), fingerprint: "chrome" }
                         + (if (.pcs // "") != "" then { pinnedPeerCertSha256: .pcs } else {} end)) }
                   else {} end)) }'
        return
    fi
    case "$scheme" in vless|trojan|hysteria2|hy2) ;; *) return 1 ;; esac
    q=""; [[ "$rest" == *\?* ]] && q=${rest#*\?}
    rest=${rest%%\?*}; rest=${rest%/}
    user=${rest%@*}; hostport=${rest##*@}
    port=${hostport##*:}; port=${port%%,*}          # hysteria2 "port,hop-range": the node port
    host=${hostport%:*}; host=${host#[}; host=${host%]}
    qj='{}'
    local IFS='&'
    for kv in $q; do
        [[ -n "$kv" ]] || continue
        k=${kv%%=*}; v=""; [[ "$kv" == *=* ]] && v=${kv#*=}
        qj=$(jq -c --arg k "$k" --arg v "$(_xl_urldecode "$v")" '.[$k] = $v' <<<"$qj")
    done
    jq -cn --arg scheme "$scheme" --arg user "$(_xl_urldecode "$user")" --arg host "$host" \
        --argjson port "$port" --argjson q "$qj" '
      def tls($alpn):
        { security: "tls",
          tlsSettings: ({ serverName: ($q.sni // $host), fingerprint: ($q.fp // "chrome") }
            + (if $alpn != null then { alpn: $alpn }
               elif ($q.alpn // "") != "" then { alpn: ($q.alpn | split(",")) } else {} end)
            + (if ($q.pcs // $q.pinSHA256 // "") != "" then { pinnedPeerCertSha256: ($q.pcs // $q.pinSHA256) } else {} end)) };
      def net:
        ($q.type // "tcp") as $t
        | { network: $t }
          + (if   $t == "ws"          then { wsSettings: { path: ($q.path // "/"), host: ($q.host // "") } }
             elif $t == "httpupgrade" then { httpupgradeSettings: { path: ($q.path // "/"), host: ($q.host // "") } }
             elif $t == "grpc"        then { grpcSettings: { serviceName: ($q.serviceName // "") } }
             elif $t == "xhttp"       then { xhttpSettings: ({ path: ($q.path // "/"), mode: ($q.mode // "auto") }
                                                            + (if ($q.host // "") != "" then { host: $q.host } else {} end)) }
             # mKCP as v2rayN 7.25 writes it for Xray 26: the seed and the header as
             # finalmask mkcp-legacy masks (Xray v26.9.9 takes kcpSettings.seed again,
             # but that form no longer interoperates with anything else)
             elif $t == "kcp"         then { kcpSettings: {},
                                             finalmask: { udp: (
                                               [ { type: "mkcp-legacy", settings: (if ($q.seed // "") != "" then { value: $q.seed } else {} end) } ]
                                               + (if ($q.headerType // "none") == "none" then []
                                                  else [ { type: "mkcp-legacy", settings: { header: ($q.headerType | sub("-video$"; "")) } } ] end)) } }
             else {} end);
      def sec:
        ($q.security // "none") as $s
        | if $s == "tls" then tls(null)
          elif $s == "reality" then
            { security: "reality",
              realitySettings: { serverName: ($q.sni // ""), fingerprint: ($q.fp // "chrome"),
                                 publicKey: ($q.pbk // ""), shortId: ($q.sid // ""), spiderX: ($q.spx // "") } }
          else {} end;
      if $scheme == "vless" then
        { tag: "proxy", protocol: "vless",
          settings: { vnext: [ { address: $host, port: $port,
                                 users: [ ({ id: $user, encryption: ($q.encryption // "none") }
                                           + (if ($q.flow // "") != "" then { flow: $q.flow } else {} end)) ] } ] },
          streamSettings: (net + sec) }
      elif $scheme == "trojan" then
        { tag: "proxy", protocol: "trojan",
          settings: { servers: [ { address: $host, port: $port, password: $user } ] },
          streamSettings: (net + tls(null)) }
      else
        { tag: "proxy", protocol: "hysteria",
          settings: { version: 2, address: $host, port: $port },
          streamSettings: ({ network: "hysteria", hysteriaSettings: { version: 2, auth: $user } } + tls(["h3"])
            + (if ($q.obfs // "") != "" then
                 { finalmask: { udp: [ { type: "salamander",
                     settings: ({ password: ($q["obfs-password"] // "") }
                                + (if $q.obfs == "gecko" then { packetSize: "512-1200" } else {} end)) } ] } }
               else {} end)) }
      end'
}

# xray_link_client <link> <socks port>: a client config — a local SOCKS inbound, the link's outbound
xray_link_client() {
    local ob; ob=$(xray_link_outbound "$1") || return 1
    jq -n --argjson ob "$ob" --argjson p "$2" '{
        log: { loglevel: "warning" },
        inbounds: [ { listen: "127.0.0.1", port: $p, protocol: "socks", settings: { udp: true } } ],
        outbounds: [ $ob ] }'
}
