#!/usr/bin/env bash
# ============================================================================
# provision-nodes.sh —— 通过 3x-ui 官方 REST API 创建主流节点（幂等）
# ----------------------------------------------------------------------------
# 不碰 SQLite、不改 3x-ui 源码：全程调用 /panel/api/inbounds/add
# 可单独重跑：bash /opt/xui-onekey/scripts/provision-nodes.sh --host 1.2.3.4
# ============================================================================
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${HERE}/lib.sh"

# ---------------- 默认参数 ----------------
XO_HOST=""                    # 公网 IP 或域名（写进节点链接）
XO_CLIENT_EMAIL="default"     # 3x-ui 客户端标识（跨 inbound 统一 → 一个订阅含全部节点）
XO_UUID=""                    # 为空则自动生成
XO_SUBID=""                   # 订阅 ID，为空则自动生成（portal 需要它）
XO_PROTOCOLS="reality,hy2,xhttp,ws,trojan,ss,vmess"
XO_CERT_DIR="${XO_CERT_DIR:-/etc/xui-onekey/certs}"
XO_STATE_DIR="${XO_STATE_DIR:-/etc/xui-onekey}"
XO_REMARK_PREFIX=""           # 备注前缀，例如 "🇭🇰HK-"
XO_REALITY_SNI="www.apple.com"        # xray 会警告 microsoft 系目标易被 GFW 标记
XO_REALITY_TARGET="www.apple.com:443"
XO_DRY_RUN=0
XO_FORCE=0
XO_RECREATE=0

# 端口规划（改这里即可整体换端口）
XO_P_REALITY=443
XO_P_HY2=443
XO_P_WS=8443
XO_P_TROJAN=2087
XO_P_SS=8388
XO_P_VMESS=8880
XO_P_XHTTP=2088

usage() {
  cat <<'EOF'
用法: provision-nodes.sh [选项]

  --host <ip|domain>      公网地址（必填，或从 /etc/xui-onekey/config.env 读）
  --email <name>          客户端标识，默认 default
  --uuid <uuid>           复用固定 UUID
  --sub-id <id>           复用固定订阅 ID
  --protocols <list>      reality,hy2,xhttp,ws,trojan,ss,vmess（逗号分隔）
  --cert-dir <dir>        TLS 证书目录，默认 /etc/xui-onekey/certs
  --remark-prefix <s>     节点备注前缀
  --reality-sni <host>    Reality 伪装 SNI，默认 www.microsoft.com
  --dry-run               只打印 JSON 不提交
  --force                 已存在同 tag 节点时走 update 覆盖
  --recreate              先删除同 tag 节点再重建（改造 client 结构后必须用）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           XO_HOST="$2"; shift 2 ;;
    --email)          XO_CLIENT_EMAIL="$2"; shift 2 ;;
    --uuid)           XO_UUID="$2"; shift 2 ;;
    --sub-id)         XO_SUBID="$2"; shift 2 ;;
    --protocols)      XO_PROTOCOLS="$2"; shift 2 ;;
    --cert-dir)       XO_CERT_DIR="$2"; shift 2 ;;
    --remark-prefix)  XO_REMARK_PREFIX="$2"; shift 2 ;;
    --reality-sni)    XO_REALITY_SNI="$2"; XO_REALITY_TARGET="$2:443"; shift 2 ;;
    --dry-run)        XO_DRY_RUN=1; shift ;;
    --force)          XO_FORCE=1; shift ;;
    --recreate)       XO_RECREATE=1; shift ;;
    -h | --help)      usage; exit 0 ;;
    *) ok_die "未知参数: $1（--help 查看用法）" ;;
  esac
done

ok_need_root
ok_arch
ok_install_pkgs curl jq openssl

# ---------------- 上下文 ----------------
mkdir -p "$XO_STATE_DIR" "$XO_CERT_DIR"
chmod 700 "$XO_STATE_DIR"

# 复用上次生成的凭据，保证重跑幂等
ENVF="${XO_STATE_DIR}/nodes.env"
if [[ -f "$ENVF" ]]; then
  # shellcheck disable=SC1090
  . "$ENVF"
fi

[[ -n "$XO_HOST" ]] || XO_HOST="${XO_PUBLIC_HOST:-}"
[[ -n "$XO_HOST" ]] || ok_die "缺少 --host（公网 IP 或域名）"

XO_UUID="${XO_UUID:-${XO_CLIENT_UUID:-}}"
XO_UUID="${XO_UUID:-$(ok_rand_uuid)}"
XO_SUBID="${XO_SUBID:-${XO_CLIENT_SUBID:-}}"
XO_SUBID="${XO_SUBID:-$(ok_rand_hex 8)}"
XO_SS_KEY="${XO_SS_KEY:-$(ok_ss_key 16)}"                # 服务端主密钥（2022-blake3-aes-128-gcm => 16 字节）
XO_SS_CLIENT_KEY="${XO_SS_CLIENT_KEY:-$(ok_ss_key 16)}"  # 客户端密钥，必须与服务端密钥不同（SS2022 多用户规范）
XO_HY2_AUTH="${XO_HY2_AUTH:-$(ok_rand_pass 24)}"
XO_TROJAN_PWD="${XO_TROJAN_PWD:-$(ok_rand_hex 16)}"
XO_WS_PATH="${XO_WS_PATH:-/$(ok_rand_hex 4)}"
XO_VMESS_PATH="${XO_VMESS_PATH:-/$(ok_rand_hex 4)}"
XO_TROJAN_PATH="${XO_TROJAN_PATH:-/$(ok_rand_hex 4)}"
XO_XHTTP_PATH="${XO_XHTTP_PATH:-/$(ok_rand_hex 4)}"

ok_load_panel_ctx
ok_info "面板: ${XO_PANEL_URL}${XO_BASE_PATH}  客户端: ${XO_CLIENT_EMAIL}  subId: ${XO_SUBID}"

# ---------------- 自签证书（HY2 / TLS 节点用） ----------------
ensure_self_signed() {
  local crt="${XO_CERT_DIR}/self.crt" key="${XO_CERT_DIR}/self.key"
  if [[ -s "$crt" && -s "$key" ]]; then
    echo "$crt"; return 0
  fi
  ok_info "生成自签证书（CN=${XO_HOST}，10 年）"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$key" -out "$crt" -subj "/CN=${XO_HOST}" \
    -addext "subjectAltName=DNS:${XO_HOST},IP:${XO_HOST}" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
         -keyout "$key" -out "$crt" -subj "/CN=${XO_HOST}" >/dev/null 2>&1
  chmod 600 "$key"
  echo "$crt"
}
CRT="$(ensure_self_signed)"
KEY="${XO_CERT_DIR}/self.key"

# 优先使用真实证书（acme 签发过的话）
if [[ -s "${XO_CERT_DIR}/fullchain.pem" && -s "${XO_CERT_DIR}/privkey.pem" ]]; then
  CRT="${XO_CERT_DIR}/fullchain.pem"
  KEY="${XO_CERT_DIR}/privkey.pem"
  ok_info "使用 ACME 证书: $CRT"
fi

# 自签证书的 SHA256 指纹（hex）。
# xray 26 已移除 allowInsecure；客户端要靠 pinnedPeerCertSha256(=pinSHA256 参数) 或
# verifyPeerCertByName(=vcn 参数) 才能连自签证书。3x-ui 会把 tlsSettings.settings 里的
# 这两个字段写进订阅链接（sub/service.go:1669），但不写进 xray 运行配置。
CERT_PIN=""
if [[ -s "$CRT" ]]; then
  CERT_PIN="$(openssl x509 -in "$CRT" -outform DER 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}' | tr -d '\r\n')"
  [[ "$CERT_PIN" =~ ^[0-9a-fA-F]{64}$ ]] || CERT_PIN=""
  [[ -n "$CERT_PIN" ]] && ok_info "证书指纹(hex): ${CERT_PIN:0:16}…"
fi

# ---------------- Reality 密钥 ----------------
REALITY_JSON="$(xo_api_ok GET 'server/getNewX25519Cert')"
R_PRIV="$(jq -r '.obj.privateKey' <<<"$REALITY_JSON")"
R_PUB="$(jq -r '.obj.publicKey' <<<"$REALITY_JSON")"
[[ -n "$R_PRIV" && "$R_PRIV" != "null" ]] || ok_die "Reality 密钥生成失败"
R_SID="$(ok_rand_hex 4)"
ok_info "Reality 密钥对已生成（shortId=${R_SID}）"

# ---------------- 现有 inbound 快照（幂等判重） ----------------
EXISTING="$(xo_api_ok GET 'inbounds/list')"
has_tag()  { jq -e --arg t "$1" '.obj[]? | select(.tag==$t)' <<<"$EXISTING" >/dev/null 2>&1; }
id_of_tag(){ jq -r --arg t "$1" '[.obj[]? | select(.tag==$t) | .id] | first // empty' <<<"$EXISTING"; }
port_taken(){ jq -e --argjson p "$1" '.obj[]? | select(.port==$p) | .id' <<<"$EXISTING" >/dev/null 2>&1; }

# ---------------- 公共片段 ----------------
sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

# 客户端身份模型（实测结论，别改）：
#   * subId 在 3x-ui 里是 **client 唯一**的（clients/add 会拒绝重复 subId），
#     所以"一个订阅含全部节点"必须靠 **同一个 email 挂多个 inbound**，而不是多 email 共享 subId。
#   * 同一 email 的 id/password/auth 是全局共享字段，不同协议如果各写各的会被互相覆盖
#     （实测：trojan 的 hex 密码被 SS 的 base64 密码顶掉 → trojan 链接密码与服务端不一致）。
#   * 解法：所有协议共用同一份 id/password/auth。Trojan 的密码是任意字符串，直接用
#     SS2022 的 base64 客户端密钥即可；SS 需要 base64、VLESS/VMess 用 UUID、HY2 用 auth。
client_body() { # $1=额外字段 JSON（如 {"flow":"xtls-rprx-vision"}）
  local extra='{}'
  if [[ $# -gt 0 && -n "${1:-}" ]]; then extra="$1"; fi
  jq -nc --arg id "$XO_UUID" --arg email "$XO_CLIENT_EMAIL" --arg sub "$XO_SUBID" \
     --arg pw "$XO_SS_CLIENT_KEY" --arg auth "$XO_HY2_AUTH" --argjson ex "$extra" \
    '{id:$id,email:$email,password:$pw,auth:$auth,flow:"",
      limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}
     + ($ex | del(.flow))
     | if ($ex|has("flow")) then .flow=$ex.flow else . end'
}

# $1=sni  $2=alpn-json
# 注意：自签证书场景必须带 pinnedPeerCertSha256（hex），否则 xray 26+ 客户端连不上
tls_block() {
  local pins='[]'
  if [[ -n "$CERT_PIN" ]]; then
    pins="$(printf '["%s"]' "$CERT_PIN")"
  fi
  jq -nc --arg sni "$1" --arg crt "$CRT" --arg key "$KEY" --argjson alpn "$2" --argjson pins "$pins" \
    '{serverName:$sni,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,
      disableSystemRoot:false,enableSessionResumption:false,
      certificates:[{certificateFile:$crt,keyFile:$key,oneTimeLoading:false,usage:"encipherment",buildChain:false}],
      alpn:$alpn,echServerKeys:"",
      settings:{fingerprint:"chrome",echConfigList:"",pinnedPeerCertSha256:$pins}}'
}

ss_client() {
  jq -nc --arg id "$XO_UUID" --arg email "$XO_CLIENT_EMAIL" --arg sub "$XO_SUBID" --arg pw "$XO_SS_CLIENT_KEY" \
    '{method:"",password:$pw,email:$email,id:$id,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}'
}

# ---------------- 各协议 payload ----------------
payload_reality() {
  jq -nc --arg remark "${XO_REMARK_PREFIX}REALITY-${XO_P_REALITY}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_REALITY" --arg tag "xo-vless-reality" --argjson sniff "$sniffing" \
    --argjson client "$(client_body '{"flow":"xtls-rprx-vision"}')" \
    --arg priv "$R_PRIV" --arg pub "$R_PUB" --arg sid "$R_SID" \
    --arg sni "$XO_REALITY_SNI" --arg target "$XO_REALITY_TARGET" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"vless",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{clients:[$client],decryption:"none",encryption:"none",fallbacks:[]},
    streamSettings:{
      network:"tcp", tcpSettings:{header:{type:"none"}}, security:"reality",
      realitySettings:{
        show:false,xver:0,target:$target,serverNames:[$sni],
        privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],
        settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}
      }
    },
    sniffing:$sniff
  }'
}

payload_hy2() {
  local cert_json
  cert_json="$(tls_block "$XO_HOST" '["h3"]')"
  jq -nc --arg remark "${XO_REMARK_PREFIX}HY2-${XO_P_HY2}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_HY2" --arg tag "xo-hysteria2" --argjson sniff "$sniffing" \
    --arg auth "$XO_HY2_AUTH" --argjson tls "$cert_json" \
    --arg email "$XO_CLIENT_EMAIL" --arg sub "$XO_SUBID" --arg pwd "$XO_SS_CLIENT_KEY" --arg id "$XO_UUID" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"hysteria",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{version:2,clients:[{id:$id,auth:$auth,password:$pwd,email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}]},
    streamSettings:{
      network:"hysteria",
      hysteriaSettings:{version:2,udpIdleTimeout:60},
      security:"tls", tlsSettings:$tls
    },
    sniffing:$sniff
  }'
}

payload_ws() {
  local cert_json
  cert_json="$(tls_block "$XO_HOST" '["http/1.1"]')"
  jq -nc --arg remark "${XO_REMARK_PREFIX}VLESS-WS-${XO_P_WS}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_WS" --arg tag "xo-vless-ws" --argjson sniff "$sniffing" \
    --argjson client "$(client_body)" --argjson tls "$cert_json" --arg path "$XO_WS_PATH" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"vless",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{clients:[$client],decryption:"none",encryption:"none",fallbacks:[]},
    streamSettings:{
      network:"ws",
      wsSettings:{acceptProxyProtocol:false,path:$path,host:$host,headers:{},heartbeatPeriod:0},
      security:"tls", tlsSettings:$tls
    },
    sniffing:$sniff
  }'
}

payload_trojan() {
  local cert_json
  cert_json="$(tls_block "$XO_HOST" '["http/1.1"]')"
  jq -nc --arg remark "${XO_REMARK_PREFIX}TROJAN-${XO_P_TROJAN}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_TROJAN" --arg tag "xo-trojan-ws" --argjson sniff "$sniffing" \
    --arg pwd "$XO_SS_CLIENT_KEY" --arg email "$XO_CLIENT_EMAIL" --arg id "$XO_UUID" --arg sub "$XO_SUBID" \
    --argjson tls "$cert_json" --arg path "$XO_TROJAN_PATH" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"trojan",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{clients:[{id:$id,password:$pwd,email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}],fallbacks:[]},
    streamSettings:{
      network:"ws",
      wsSettings:{acceptProxyProtocol:false,path:$path,host:$host,headers:{},heartbeatPeriod:0},
      security:"tls", tlsSettings:$tls
    },
    sniffing:$sniff
  }'
}

payload_ss() {
  jq -nc --arg remark "${XO_REMARK_PREFIX}SS2022-${XO_P_SS}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_SS" --arg tag "xo-ss2022" --argjson sniff "$sniffing" \
    --argjson client "$(ss_client)" --arg key "$XO_SS_KEY" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"shadowsocks",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{method:"2022-blake3-aes-128-gcm",password:$key,network:"tcp,udp",clients:[$client],ivCheck:false},
    streamSettings:{network:"tcp",tcpSettings:{header:{type:"none"}},security:"none"},
    sniffing:$sniff
  }'
}

payload_vmess() {
  local cert_json
  cert_json="$(tls_block "$XO_HOST" '["http/1.1"]')"
  jq -nc --arg remark "${XO_REMARK_PREFIX}VMESS-WS-${XO_P_VMESS}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_VMESS" --arg tag "xo-vmess-ws" --argjson sniff "$sniffing" \
    --arg id "$XO_UUID" --arg email "$XO_CLIENT_EMAIL" --arg sub "$XO_SUBID" --arg pwd "$XO_SS_CLIENT_KEY" \
    --argjson tls "$cert_json" --arg path "$XO_VMESS_PATH" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"vmess",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{clients:[{id:$id,security:"auto",email:$email,password:$pwd,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}]},
    streamSettings:{
      network:"ws",
      wsSettings:{acceptProxyProtocol:false,path:$path,host:$host,headers:{},heartbeatPeriod:0},
      security:"tls", tlsSettings:$tls
    },
    sniffing:$sniff
  }'
}

payload_xhttp() {
  local cert_json
  cert_json="$(tls_block "$XO_HOST" '["h2","http/1.1"]')"
  jq -nc --arg remark "${XO_REMARK_PREFIX}XHTTP-${XO_P_XHTTP}" --arg host "$XO_HOST" \
    --argjson port "$XO_P_XHTTP" --arg tag "xo-vless-xhttp" --argjson sniff "$sniffing" \
    --argjson client "$(client_body)" --argjson tls "$cert_json" --arg path "$XO_XHTTP_PATH" '
  {
    remark:$remark, enable:true, listen:"", port:$port, tag:$tag, protocol:"vless",
    shareAddrStrategy:"custom", shareAddr:$host,
    settings:{clients:[$client],decryption:"none",encryption:"none",fallbacks:[]},
    streamSettings:{
      network:"xhttp",
      xhttpSettings:{path:$path,host:$host,mode:"auto"},
      security:"tls", tlsSettings:$tls
    },
    sniffing:$sniff
  }'
}

# ---------------- 客户端补建/同步 ----------------
# 3x-ui 的 UpdateInbound 会用 keepStoredClients 丢弃提交上来的 clients
# （internal/web/service/inbound.go:2116：「only a master's push may change them here」），
# 所以更新 inbound 时绝不能靠 settings.clients 来增删客户端，必须走 clients API。
ensure_client() { # $1=email  $2=inbound_id  $3=client-json(平铺)
  local email="$1" id="$2" cj="$3" cur enc
  enc="$(printf '%s' "$email" | jq -sRr @uri)"

  cur="$(xo_api GET "clients/get/${enc}" 2>/dev/null || true)"
  # clients/get 返回 {"obj":{"client":{...}}}，也兼容直接平铺
  if [[ "$(jq -r '.success // false' <<<"$cur" 2>/dev/null)" == "true" ]] \
     && [[ "$(jq -r '.obj.client.email // .obj.email // empty' <<<"$cur" 2>/dev/null)" == "$email" ]]; then
    # 已存在：同步凭据（每协议独立 email，不会互相覆盖）
    if xo_api POST "clients/update/${enc}" "$cj" | jq -e '.success == true' >/dev/null 2>&1; then
      ok_info "  client 凭据已同步: ${email}"
    else
      ok_warn "  client 凭据同步失败: ${email}"
    fi
  else
    if xo_api POST 'clients/add' "$(jq -nc --argjson c "$cj" --argjson ids "[$id]" '{client:$c, inboundIds:$ids}')" \
         | jq -e '.success == true' >/dev/null 2>&1; then
      ok_log "  client 已补建: ${email} → inbound ${id}"
    else
      ok_warn "  client 补建失败: ${email}"
    fi
  fi
}

# ---------------- 提交 ----------------
apply_node() { # $1=tag  $2=payload
  local tag="$1" payload="$2" id out email cj

  email="$(jq -r '.settings.clients[0].email // empty' <<<"$payload")"
  cj="$(jq -c '.settings.clients[0] // {}' <<<"$payload")"

  [[ "$XO_DRY_RUN" == "1" ]] && { jq -c . <<<"$payload"; return 0; }

  # --recreate：先删掉同 tag 节点（update 无法增删 client，改 client 结构只能重建）
  if [[ "$XO_RECREATE" == "1" ]] && has_tag "$tag"; then
    id="$(id_of_tag "$tag")"
    ok_info "删除旧节点 $tag (id=$id)"
    xo_api POST "inbounds/del/${id}" >/dev/null 2>&1 || true
    EXISTING="$(xo_api_ok GET 'inbounds/list')"
  fi

  if has_tag "$tag"; then
    if [[ "$XO_FORCE" != "1" ]]; then
      ok_info "节点已存在，跳过: $tag"
      # 即使跳过建节点，也要保证 client 在（之前删过 client 的话能自愈）
      id="$(id_of_tag "$tag")"
      [[ -n "$id" && -n "$email" ]] && ensure_client "$email" "$id" "$cj"
      return 0
    fi
    id="$(id_of_tag "$tag")"
    ok_info "更新已有节点 $tag (id=$id)"
    # 关键：更新时清空 clients，避免与 keepStoredClients 打架
    out="$(xo_api POST "inbounds/update/${id}" "$(jq -c '.settings.clients=[]' <<<"$payload")")" || ok_die "更新失败: $tag"
    if [[ "$(jq -r '.success // false' <<<"$out")" != "true" ]]; then
      ok_warn "节点 $tag 更新失败: $(jq -r '.msg // .' <<<"$out" | awk '{printf "%s", substr($0,1,400)}')"
      return 1
    fi
  else
    out="$(xo_api POST 'inbounds/add' "$payload")" || ok_die "创建失败: $tag"
    if [[ "$(jq -r '.success // false' <<<"$out")" != "true" ]]; then
      ok_warn "节点 $tag 提交失败: $(jq -r '.msg // .' <<<"$out" | awk '{printf "%s", substr($0,1,400)}')"
      return 1
    fi
    id="$(jq -r '.obj.id // empty' <<<"$out")"
  fi

  [[ -n "$email" ]] && ensure_client "$email" "${id:-0}" "$cj"
  ok_log "节点就绪: $tag"
}

IFS=',' read -r -a PROTO_ARR <<<"$XO_PROTOCOLS"
for p in "${PROTO_ARR[@]}"; do
  case "$p" in
    reality) apply_node "xo-vless-reality" "$(payload_reality)" ;;
    hy2 | hysteria2) apply_node "xo-hysteria2" "$(payload_hy2)" ;;
    ws)      apply_node "xo-vless-ws" "$(payload_ws)" ;;
    trojan)  apply_node "xo-trojan-ws" "$(payload_trojan)" ;;
    ss | shadowsocks) apply_node "xo-ss2022" "$(payload_ss)" ;;
    vmess)   apply_node "xo-vmess-ws" "$(payload_vmess)" ;;
    xhttp)   apply_node "xo-vless-xhttp" "$(payload_xhttp)" ;;
    *) ok_warn "未知协议，忽略: $p" ;;
  esac
done

# ---------------- 落盘状态 ----------------
cat >"$ENVF" <<EOF
# xui-onekey 节点凭据（重跑时复用，勿删）
XO_PUBLIC_HOST='${XO_HOST}'
XO_CLIENT_EMAIL='${XO_CLIENT_EMAIL}'
XO_CLIENT_UUID='${XO_UUID}'
XO_CLIENT_SUBID='${XO_SUBID}'
XO_SS_KEY='${XO_SS_KEY}'
XO_SS_CLIENT_KEY='${XO_SS_CLIENT_KEY}'
XO_HY2_AUTH='${XO_HY2_AUTH}'
XO_TROJAN_PWD='${XO_TROJAN_PWD}'
XO_WS_PATH='${XO_WS_PATH}'
XO_TROJAN_PATH='${XO_TROJAN_PATH}'
XO_VMESS_PATH='${XO_VMESS_PATH}'
XO_XHTTP_PATH='${XO_XHTTP_PATH}'
EOF
chmod 600 "$ENVF"

# ---------------- 导出链接 ----------------
LINKS_JSON="$(xo_api_ok GET 'inbounds/allLinks')"
jq -r '.obj[]?' <<<"$LINKS_JSON" > "${XO_STATE_DIR}/links.txt" 2>/dev/null || true
ok_log "链接已导出: ${XO_STATE_DIR}/links.txt （$(wc -l < "${XO_STATE_DIR}/links.txt" | tr -d ' ') 条）"

ok_log "节点编排完成。UUID=${XO_UUID}  subId=${XO_SUBID}"
