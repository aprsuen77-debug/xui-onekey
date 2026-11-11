#!/usr/bin/env bash
# ============================================================================
#  xui-onekey —— 一键装机：3x-ui 面板 + 主流节点 + 8080 节点门户
# ----------------------------------------------------------------------------
#  用法（客户机器上，root）：
#     bash install.sh --host 1.2.3.4
#     bash install.sh --host node.example.com --acme-email me@example.com
#     bash install.sh --host 1.2.3.4 --protocols reality,hy2,ss
#
#  设计原则：
#    1) 不改 3x-ui 源码 —— 全走官方 API，升级 3x-ui 不冲突
#    2) 幂等 —— 重复执行只补缺失部分（节点按 tag 判重、门户可重装）
#    3) 可回滚 —— 所有落地物在 /opt/xui-onekey + /etc/xui-onekey，卸载一条命令
# ============================================================================
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${HERE}/scripts/lib.sh"

APP_DIR=/opt/xui-onekey
STATE_DIR=/etc/xui-onekey
BIN_DIR="${APP_DIR}/bin"
LOG_FILE=/var/log/xui-onekey-install.log

# ---------------- 默认配置（可被参数/环境变量覆盖） ----------------
HOST_ARG=""
DOMAIN_ARG=""
ACME_EMAIL=""
PANEL_PORT=""
PORTAL_PORT=8080
SUB_PORT=2096
PROTOCOLS="reality,hy2,xhttp,ws,trojan,ss,vmess"
ADMIN_USER="admin"
ADMIN_PASS=""
WEB_BASE_PATH="/"
PORTAL_TOKEN=""
REMARK_PREFIX=""
REALITY_SNI="www.microsoft.com"
SKIP_PORTAL=0
SKIP_NODES=0
ASSUME_YES=0
MODE=""                 # panel | full | nodes | upgrade | uninstall（空 = 由参数决定）

# routex 定制面板的发布位置：改成你自己的 GitHub 仓库 / OSS 即可
#   GitHub Release：https://github.com/<user>/<repo>/releases/latest/download/x-ui-linux-amd64
#   自建 OSS：    https://your-oss.example.com/routex/x-ui-linux-amd64
ROUTEX_BIN_URL="${XO_ROUTEX_BIN_URL:-https://github.com/aprsuen77-debug/routex-panel/releases/latest/download/x-ui-linux-amd64}"
ROUTEX_REQUIRED="${XO_ROUTEX_REQUIRED:-1}"   # 1=下不到就报错退出；0=回退官方面板
# 显式参数标记：重跑时 state.env 不能覆盖用户这次给的参数
EXPLICIT_PROTOCOLS=0
EXPLICIT_PANEL_PORT=0
EXPLICIT_PORTAL_TOKEN=0
EXPLICIT_ADMIN_PASS=0

# 国内镜像（按顺序尝试；可用 XO_MIRROR_* 环境变量覆盖）
MIRROR_INSTALL_SH="${XO_MIRROR_INSTALL_SH:-}"
MIRROR_GH_PREFIX="${XO_MIRROR_GH_PREFIX:-}"       # 形如 https://ghproxy.net/
REPO_RAW="${XO_REPO_RAW:-}"                       # 你自己的仓库 raw 前缀（放 portal 二进制）

usage() {
  cat <<'EOF'
用法: install.sh [选项]

  --host <ip|domain>        对外地址（不填则自动探测公网 IP）
  --acme-email <mail>       邮箱：给了就尝试用 acme.sh 申请真证书
  --panel-port <port>       面板端口（默认随机 20000-60000）
  --portal-port <port>      门户端口，默认 8080
  --sub-port <port>         订阅服务端口，默认 2096（仅本机反代使用）
  --protocols <list>        默认 reality,hy2,xhttp,ws,trojan,ss,vmess
  --admin-user <name>       面板用户，默认 admin
  --admin-pass <pass>       面板密码，默认 123456（首登强制修改）
  --web-base-path <path>    面板路径，默认 /
  --portal-token <token>    门户访问令牌（默认随机，门户地址 /p/<token>/）
  --remark-prefix <s>       节点备注前缀，如 "🇭🇰HK-"
  --reality-sni <domain>    Reality 伪装域名，默认 www.microsoft.com
  --mode <m>                panel=只装面板 / full=完整 / nodes=只重建节点 / upgrade=只换面板本体 / uninstall=卸载
  --only-panel              等价 --mode panel
  --full                    等价 --mode full（默认）
  --skip-nodes              完整安装但跳过建节点
  --skip-portal             不装 8080 门户
  -y, --yes                 全自动，不问
  -h, --help                帮助

环境变量：
  XO_MIRROR_GH_PREFIX=https://ghproxy.net/      # GitHub 加速前缀（国内机器强烈建议）
  XO_MIRROR_INSTALL_SH=<url>                    # 自定义 install.sh 地址
  XO_REPO_RAW=<url>                             # 存放 xui-portal 二进制的 raw 前缀
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST_ARG="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --panel-port) PANEL_PORT="$2"; EXPLICIT_PANEL_PORT=1; shift 2 ;;
    --portal-port) PORTAL_PORT="$2"; shift 2 ;;
    --sub-port) SUB_PORT="$2"; shift 2 ;;
    --protocols) PROTOCOLS="$2"; EXPLICIT_PROTOCOLS=1; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; EXPLICIT_ADMIN_PASS=1; shift 2 ;;
    --web-base-path) WEB_BASE_PATH="$2"; shift 2 ;;
    --portal-token) PORTAL_TOKEN="$2"; EXPLICIT_PORTAL_TOKEN=1; shift 2 ;;
    --remark-prefix) REMARK_PREFIX="$2"; shift 2 ;;
    --reality-sni) REALITY_SNI="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --only-panel) MODE="panel"; shift ;;
    --full) MODE="full"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --skip-nodes) SKIP_NODES=1; shift ;;
    --skip-portal) SKIP_PORTAL=1; shift ;;
    -y | --yes) ASSUME_YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) ok_die "未知参数: $1（--help 查看用法）" ;;
  esac
done

# ============================ 交互菜单 ============================
show_menu() {
  local choice=""
  printf '\n'
  printf '%s\n' "  ┌────────────────────────────────────────────────┐"
  printf '%s\n' "  │            routex  一键部署脚本                │"
  printf '%s\n' "  └────────────────────────────────────────────────┘"
  printf '\n'
  printf '   %s1)%s 只安装面板        routex 面板本体，不含节点\n' "$C_C" "$C_0"
  printf '   %s2)%s 完整安装          面板 + 7 个主流节点 + 8080 节点门户\n' "$C_C" "$C_0"
  printf '   %s3)%s 只重建节点        在已有面板上重排节点与订阅\n' "$C_C" "$C_0"
  printf '   %s4)%s 只升级面板        换成最新的 routex 面板本体\n' "$C_C" "$C_0"
  printf '   %s5)%s 卸载             移除面板与门户服务\n' "$C_C" "$C_0"
  printf '   %s0)%s 退出\n' "$C_C" "$C_0"
  printf '\n'
  while true; do
    read -rp "  请选择 [0-5，回车默认 2]: " choice || choice="2"
    choice="${choice//[[:space:]]/}"
    [[ -z "$choice" ]] && choice=2
    case "$choice" in
      1) MODE=panel; break ;;
      2) MODE=full; break ;;
      3) MODE=nodes; break ;;
      4) MODE=upgrade; break ;;
      5) MODE=uninstall; break ;;
      0) printf '  已退出。\n'; exit 0 ;;
      *) printf '  %s输入无效，请输入 0-5%s\n' "$C_Y" "$C_0" ;;
    esac
  done
  printf '\n'
}

# ============================ 卸载 ============================
do_uninstall() {
  ok_step "卸载 routex"
  local ans=""
  if [[ "$ASSUME_YES" != "1" ]]; then
    read -rp "  确认卸载面板与门户？（节点配置与数据库一并删除）[y/N]: " ans || ans="n"
    [[ "${ans,,}" == "y" ]] || { ok_info "已取消"; exit 0; }
  fi
  systemctl stop xui-portal 2>/dev/null || true
  systemctl disable xui-portal 2>/dev/null || true
  rm -f /etc/systemd/system/xui-portal.service
  systemctl daemon-reload 2>/dev/null || true
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    yes | /usr/local/x-ui/x-ui 2>/dev/null || true
  fi
  if command -v x-ui >/dev/null 2>&1; then
    printf 'y\n' | x-ui uninstall 2>/dev/null || true
  fi
  rm -rf /opt/xui-onekey /etc/xui-onekey
  systemctl daemon-reload 2>/dev/null || true
  ok_log "已卸载（如仍残留 /usr/local/x-ui 可手动 rm -rf）"
}

# ============================ 只重建节点 ============================
do_nodes_only() {
  ok_need_root
  [[ -x /usr/local/x-ui/x-ui ]] || ok_die "未检测到面板，请先执行选项 1/2"
  ok_load_panel_ctx
  [[ -n "$HOST_ARG" ]] || HOST_ARG="$(ok_public_ip || true)"
  [[ -n "$HOST_ARG" ]] || ok_die "探测不到公网 IP，请用 --host 指定"
  XO_HOST="$HOST_ARG"
  bash "${HERE}/scripts/provision-nodes.sh" --host "$XO_HOST" --protocols "$PROTOCOLS" \
    --cert-dir "${STATE_DIR}/certs" --remark-prefix "$REMARK_PREFIX" --reality-sni "$REALITY_SNI"
  ok_log "节点已重建"
}

# ============================ 只换面板本体 ============================
do_upgrade_panel() {
  ok_step "升级 routex 面板本体"
  # 复用安装阶段的替换逻辑：支持 http(s) URL 与本地文件，失败自动回滚
  replace_with_routex
  return 0
}

# ============================ 阶段 0：预检 ============================
stage_preflight() {
  ok_step "阶段 0/6  环境预检"
  ok_need_root
  ok_os
  ok_arch
  ok_install_pkgs curl tar openssl jq
  mkdir -p "$APP_DIR" "$STATE_DIR" "$BIN_DIR"
  chmod 700 "$STATE_DIR"
  touch "$LOG_FILE"
  ok_info "系统: ${XO_OS_ID} ${XO_OS_VER} / ${XO_ARCH}"

  # 时间同步（TLS/Reality 对时间敏感，偏移过大会直接连不上）
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
  fi

  # BBR（可选，失败不阻断）
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    modprobe tcp_bbr 2>/dev/null || true
    {
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
    } > /etc/sysctl.d/99-xui-onekey-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
  fi

  [[ -n "$HOST_ARG" ]] || HOST_ARG="$(ok_public_ip || true)"
  [[ -n "$HOST_ARG" ]] || ok_die "探测不到公网 IP，请用 --host 指定"
  XO_HOST="$HOST_ARG"
  ok_info "对外地址: ${XO_HOST}"

  if [[ -n "$DOMAIN_ARG" ]]; then
    ok_info "绑定域名: ${DOMAIN_ARG}（节点链接仍使用 --host 值）"
  fi

  # 重跑幂等：优先复用上次落盘的状态（否则会生成新密码/新 token，把客户已有入口作废）
  local statef="${STATE_DIR}/state.env"
  local _proto="$PROTOCOLS" _pport="$PANEL_PORT" _ptoken="$PORTAL_TOKEN" _apass="$ADMIN_PASS"
  if [[ -f "$statef" ]]; then
    # shellcheck disable=SC1090
    . "$statef"
    ok_info "复用上次状态: ${statef}"
    [[ "$EXPLICIT_PROTOCOLS" == "1" ]] && PROTOCOLS="$_proto"
    [[ "$EXPLICIT_PANEL_PORT" == "1" ]] && PANEL_PORT="$_pport"
    [[ "$EXPLICIT_PORTAL_TOKEN" == "1" ]] && PORTAL_TOKEN="$_ptoken"
    [[ "$EXPLICIT_ADMIN_PASS" == "1" ]] && ADMIN_PASS="$_apass"
  fi
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    . /etc/x-ui/install-result.env
    ADMIN_USER="${ADMIN_USER_OVERRIDE:-${XUI_USERNAME:-$ADMIN_USER}}"
    [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="${XUI_PASSWORD:-}"
  fi

  # routex：出厂默认密码固定 123456，面板首次登录会强制要求改密（见 ROUTEX-CHANGES.md）
  [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="123456"
  [[ -n "$PANEL_PORT" ]] || PANEL_PORT="$(ok_pick_port 20000 60000 || echo 2053)"
  [[ -n "$PORTAL_TOKEN" ]] || PORTAL_TOKEN="$(ok_rand_hex 8)"

  ok_info "面板端口: ${PANEL_PORT} / 门户端口: ${PORTAL_PORT} / 订阅端口: ${SUB_PORT}"

  umask 077
  cat >"${STATE_DIR}/state.env" <<EOF
# xui-onekey 本地状态（重跑时复用；删掉会导致新生成密码/token）
ADMIN_USER='${ADMIN_USER}'
ADMIN_PASS='${ADMIN_PASS}'
PANEL_PORT='${PANEL_PORT}'
PORTAL_PORT='${PORTAL_PORT}'
SUB_PORT='${SUB_PORT}'
PORTAL_TOKEN='${PORTAL_TOKEN}'
PROTOCOLS='${PROTOCOLS}'
EOF
  chmod 600 "${STATE_DIR}/state.env"
}

# 整体重写状态文件：比 sed 逐行改安全（sed 嵌套引号会写出 PANEL_PORT='"20000"' 这种坏值）
save_state() {
  [[ -d "$STATE_DIR" ]] || return 0
  (
    umask 077
    cat >"${STATE_DIR}/state.env" <<EOF
# xui-onekey 本地状态（重跑时复用；删掉会导致新生成密码/token）
ADMIN_USER='${ADMIN_USER}'
ADMIN_PASS='${ADMIN_PASS}'
PANEL_PORT='${PANEL_PORT}'
PORTAL_PORT='${PORTAL_PORT}'
SUB_PORT='${SUB_PORT}'
PORTAL_TOKEN='${PORTAL_TOKEN}'
PROTOCOLS='${PROTOCOLS}'
EOF
  )
}

# ============================ 阶段 1：装 3x-ui ============================
gh_url() { # 把 github 直链按镜像前缀改写
  local u="$1"
  if [[ -n "$MIRROR_GH_PREFIX" ]]; then
    printf '%s%s' "$MIRROR_GH_PREFIX" "$u"
  else
    printf '%s' "$u"
  fi
}

# routex：把上游二进制换成定制版（routex 品牌 / 白色主题 / 首登强制改密 / 去广告）
replace_with_routex() {
  local src="${ROUTEX_BIN_URL:-}" rbin="/tmp/x-ui-routex.$$" ver latest
  if [[ -z "$src" ]]; then
    ok_warn "未配置 routex 面板地址，继续使用上游面板"
    return 0
  fi
  if [[ "$src" =~ ^https?:// ]]; then
    ok_info "下载 routex 面板: $src"
    if ! ok_fetch "$src" "$rbin" 600; then
      if [[ "$ROUTEX_REQUIRED" == "1" ]]; then
        ok_die "routex 面板下载失败：请把 XO_ROUTEX_BIN_URL 指向你自己的发布地址"
      fi
      ok_warn "下载失败，回退上游面板"
      return 0
    fi
  else
    [[ -f "$src" ]] || ok_die "routex 面板文件不存在: $src"
    cp -f "$src" "$rbin"
  fi

  chmod +x "$rbin"
  ver="$("$rbin" -v 2>/dev/null || true)"
  if [[ -z "$ver" ]]; then
    ok_warn "拿到的文件不是可执行面板，回退上游"
    rm -f "$rbin"
    return 0
  fi

  systemctl stop x-ui
  cp -a /usr/local/x-ui/x-ui "/usr/local/x-ui/x-ui.upstream.$(date +%s).bak" 2>/dev/null || true
  install -m 0755 "$rbin" /usr/local/x-ui/x-ui
  rm -f "$rbin"
  systemctl start x-ui
  sleep 3
  if ! systemctl is-active --quiet x-ui; then
    ok_warn "routex 面板启动失败，回滚上游版本"
    latest="$(ls -1t /usr/local/x-ui/x-ui.upstream.*.bak 2>/dev/null | head -1)"
    if [[ -n "$latest" ]]; then install -m 0755 "$latest" /usr/local/x-ui/x-ui; fi
    systemctl start x-ui
    [[ "$ROUTEX_REQUIRED" == "1" ]] && ok_die "routex 面板不可用，已回滚"
    return 0
  fi
  # 等面板 HTTP 就绪，避免下面取 token 时误判失效
  local i
  for i in $(seq 1 20); do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PANEL_PORT:-20000}${XO_BASE_PATH:-/}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  ok_log "已切换到 routex 面板（版本 ${ver}）"
  return 0
}

stage_install_panel() {
  ok_step "阶段 1/6  安装 3x-ui 面板"

  if [[ -x /usr/local/x-ui/x-ui && -f /etc/systemd/system/x-ui.service ]]; then
    PANEL_FRESH_INSTALL=0
    ok_info "已检测到 3x-ui，跳过安装（升级请用 x-ui update / 本脚本选项 4）"
    systemctl is-active --quiet x-ui || systemctl start x-ui
  else
    local tmp=/tmp/xui-install.$$
    ok_info "下载官方 install.sh"
    ok_fetch_any "$tmp" \
      "$MIRROR_INSTALL_SH" \
      "$(gh_url https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)" \
      "https://cdn.jsdelivr.net/gh/MHSanaei/3x-ui@main/install.sh" \
      "https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh" \
      || ok_die "install.sh 下载失败，请设置 XO_MIRROR_GH_PREFIX 或 XO_MIRROR_INSTALL_SH"

    # 官方脚本内部还要从 github releases 拉二进制 → 同样走镜像
    if [[ -n "$MIRROR_GH_PREFIX" ]]; then
      sed -i.bak "s#https://github.com/MHSanaei/3x-ui/releases/download#${MIRROR_GH_PREFIX}https://github.com/MHSanaei/3x-ui/releases/download#g" "$tmp"
      sed -i "s#https://raw.githubusercontent.com/MHSanaei/3x-ui#${MIRROR_GH_PREFIX}https://raw.githubusercontent.com/MHSanaei/3x-ui#g" "$tmp"
    fi
    chmod +x "$tmp"

    ok_info "非交互安装（用户名 ${ADMIN_USER}，端口 ${PANEL_PORT}）"
    XUI_NONINTERACTIVE=1 \
    XUI_USERNAME="$ADMIN_USER" \
    XUI_PASSWORD="$ADMIN_PASS" \
    XUI_PANEL_PORT="$PANEL_PORT" \
    XUI_WEB_BASE_PATH="$WEB_BASE_PATH" \
      bash "$tmp" </dev/null >>"$LOG_FILE" 2>&1 || {
        ok_warn "安装日志末尾:"
        tail -30 "$LOG_FILE" >&2
        ok_die "3x-ui 安装失败"
      }
    rm -f "$tmp" "${tmp}.bak"
    PANEL_FRESH_INSTALL=1
    ok_log "3x-ui 安装完成"
  fi

  # 等待服务就绪
  local i
  for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ":${PANEL_PORT} " || curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${PANEL_PORT}/" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  systemctl is-active --quiet x-ui || ok_die "x-ui 服务未运行：journalctl -u x-ui -n 50"

  # 等 CLI 可用（面板首次启动会做 DB 迁移，可能要几秒）
  # 注意：这里绝不能调 -getApiToken —— 它每调一次就轮换一次 token，
  # 会把已部署门户的 portal.json 立刻弄成 401。用只读的 -show 探测。
  local t
  for t in $(seq 1 30); do
    if /usr/local/x-ui/x-ui setting -show true >/dev/null 2>&1; then break; fi
    sleep 1
  done
  replace_with_routex

  ok_load_panel_ctx
  local probe
  probe="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${XO_PANEL_URL}${XO_BASE_PATH}panel/api/inbounds/list" -H "Authorization: Bearer ${XO_API_TOKEN}")"
  [[ "$probe" == "200" ]] || ok_warn "API 探活返回 ${probe}（继续，稍后重试）"
  # 以面板实际值为准（重跑时 state.env 里的端口可能已经过时）
  PANEL_PORT="$XO_PANEL_PORT"
  save_state
  ok_log "面板 API 可用（${XO_PANEL_URL}${XO_BASE_PATH}）"
}

# ============================ 阶段 2：证书（可选） ============================
stage_certificates() {
  ok_step "阶段 2/6  TLS 证书"
  local certdir="${STATE_DIR}/certs"
  mkdir -p "$certdir"

  if [[ -s "${certdir}/fullchain.pem" && -s "${certdir}/privkey.pem" ]]; then
    ok_info "已有证书，跳过"
    return 0
  fi

  if [[ -z "$ACME_EMAIL" || -z "$DOMAIN_ARG" ]]; then
    ok_info "未提供域名/邮箱 → 使用 Reality + 自签证书模式（无需 CA）"
    return 0
  fi

  ok_info "用 acme.sh 申请 ${DOMAIN_ARG} 证书（standalone:80）"
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl -fsSL "$(gh_url https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh)" -o /tmp/acme.sh || {
      ok_warn "acme.sh 下载失败，退回自签模式"; return 0; }
    bash /tmp/acme.sh --install --accountemail "$ACME_EMAIL" >/dev/null 2>&1 || true
  fi

  # standalone 需要 80 空闲
  if ok_port_in_use 80; then
    ok_warn "80 端口被占用，跳过 ACME（可改用 DNS 模式或先释放 80）"
    return 0
  fi

  /root/.acme.sh/acme.sh --issue -d "$DOMAIN_ARG" --standalone --keylength ec-256 --force >/dev/null 2>&1 \
    && /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN_ARG" --ecc \
        --fullchain-file "${certdir}/fullchain.pem" \
        --key-file "${certdir}/privkey.pem" \
        --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1 \
    && ok_log "证书签发成功：${certdir}" \
    || ok_warn "ACME 失败，退回自签模式（节点仍可用，客户端需允许不安全）"
}

# ============================ 阶段 3：订阅服务配置 ============================
stage_subscription() {
  ok_step "阶段 3/6  订阅服务配置"

  local cur merged
  cur="$(xo_api_ok POST 'setting/all' '{}')"
  # 注意：updateSettingForm 内嵌 entity.AllSetting，JSON 字段提升到顶层，
  # 所以 body 必须是平铺的 {...}，绝对不能包成 {"allSetting":{...}}（否则全零 → 校验失败/设置被清）
  merged="$(jq -c --arg subPath "/s/" --arg jsonPath "/json/" --arg clashPath "/clash/" \
    --arg subPort "$SUB_PORT" --arg pubhost "$XO_HOST" --arg portalPort "$PORTAL_PORT" '
    .obj
    | del(.hasTgBotToken,.hasTwoFactorToken,.hasLdapPassword,.hasWarpSecret,.hasNordSecret,
          .hasSmtpPassword,.hasDiscordBotToken,.hasApiToken)
    | .subPort = ($subPort|tonumber)
    | .subListen = ""
    | .subPath = $subPath
    | .subJsonPath = $jsonPath
    | .subClashPath = $clashPath
    | .subClashEnable = true
    | .subJsonEnable  = true
    | .subEnable = true
    # 关键：让 /sub/<id> 按 UA 自动返回 Clash / sing-box（默认是关的，
    # 不开的话 Clash 客户端拉 /sub/ 只会拿到 base64 链接列表，导入后是空配置）
    | .subClashAutoDetect = true
    | .subJsonAutoDetect  = true
    | .subClashUserAgentRegex = "(?i)(clash|mihomo|stash|flclash|verge)"
    | .subJsonUserAgentRegex  = "(?i)(sing-box|singbox|sfa|sfi|sfm|sft|hiddify|karing)"
    | .subUpdates = 12
    | .trustedProxyCIDRs = "127.0.0.1/32,::1/128"
    | .subURI      = ("http://" + $pubhost + ":" + $portalPort + "/sub/")
    | .subJsonURI  = ("http://" + $pubhost + ":" + $portalPort + "/json/")
    | .subClashURI = ("http://" + $pubhost + ":" + $portalPort + "/clash/")
  ' <<<"$cur")"

  [[ "$merged" != "null" && -n "$merged" ]] || ok_die "读取设置失败"

  local out
  out="$(xo_api POST 'setting/update' "$merged")"
  if [[ "$(jq -r '.success // false' <<<"$out")" != "true" ]]; then
    ok_warn "设置更新失败: $(jq -r '.msg // .' <<<"$out" | awk '{printf "%s", substr($0,1,200)}')"
    local issues
    issues="$(jq -r '(.obj.issues // [])[]? | "\(.field): \(.rule // .message)"' <<<"$out" 2>/dev/null | paste -sd', ' -)"
    [[ -n "$issues" ]] && ok_warn "校验失败字段: $issues"
    ok_warn "（订阅仍可用，但订阅地址可能指向 2096 端口）"
  else
    ok_log "订阅路径已固定为 /s/ /json/ /clash/，订阅地址统一走 ${PORTAL_PORT}"
  fi

  # 重启订阅服务（x-ui 会随面板重启重建监听）
  systemctl restart x-ui >/dev/null 2>&1 || true
  sleep 2
  ok_info "订阅服务监听: 0.0.0.0:${SUB_PORT}"
}

# ============================ 阶段 4：建节点 ============================
stage_nodes() {
  ok_step "阶段 4/6  创建主流节点"
  if [[ "$SKIP_NODES" == "1" ]]; then ok_info "已跳过"; return 0; fi

  bash "${HERE}/scripts/provision-nodes.sh" \
    --host "$XO_HOST" \
    --protocols "$PROTOCOLS" \
    --cert-dir "${STATE_DIR}/certs" \
    --remark-prefix "$REMARK_PREFIX" \
    --reality-sni "$REALITY_SNI"

  # 记录订阅 ID 供门户使用
  # shellcheck disable=SC1091
  . "${STATE_DIR}/nodes.env"
  ok_log "订阅 ID: ${XO_CLIENT_SUBID}"
}

# ============================ 阶段 5：8080 门户 ============================
stage_portal() {
  ok_step "阶段 5/6  部署 8080 节点门户"
  if [[ "$SKIP_PORTAL" == "1" ]]; then ok_info "已跳过"; return 0; fi

  local bin="${BIN_DIR}/xui-portal"
  if [[ ! -x "$bin" ]]; then
    if [[ -x "${HERE}/bin/xui-portal-linux-${XO_ARCH}" ]]; then
      ok_info "使用仓库自带二进制: bin/xui-portal-linux-${XO_ARCH}"
      install -m 0755 "${HERE}/bin/xui-portal-linux-${XO_ARCH}" "$bin"
    elif command -v go >/dev/null 2>&1 && [[ -d "${HERE}/portal" ]]; then
      ok_info "本机编译门户（go build）"
      ( cd "${HERE}/portal" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$bin" . ) || ok_die "go build 失败"
    else
      ok_info "下载预编译门户二进制（linux-${XO_ARCH}）"
      [[ -n "$REPO_RAW" ]] || ok_die "未设置 XO_REPO_RAW，且本机没有 go —— 无法获取门户二进制"
      ok_fetch_any "$bin" \
        "$(gh_url "${REPO_RAW%/}/bin/xui-portal-linux-${XO_ARCH}")" \
        || ok_die "门户二进制下载失败"
      chmod +x "$bin"
    fi
  fi

  if [[ -f "${STATE_DIR}/nodes.env" ]]; then
    # shellcheck disable=SC1091
    . "${STATE_DIR}/nodes.env"
  fi
  ok_load_panel_ctx

  local cfg="${STATE_DIR}/portal.json"
  jq -n \
    --arg listen ":${PORTAL_PORT}" \
    --arg panel "$XO_PANEL_URL" \
    --arg basePath "$XO_BASE_PATH" \
    --arg token "$XO_API_TOKEN" \
    --arg publicHost "$XO_HOST" \
    --arg portalToken "$PORTAL_TOKEN" \
    --arg subPort "$SUB_PORT" \
    --arg subId "$XO_CLIENT_SUBID" \
    --arg brand "NODE PORTAL" '
  {
    listen:$listen, panel:$panel, basePath:$basePath, apiToken:$token,
    publicHost:$publicHost, portalToken:$portalToken,
    subUpstream:("http://127.0.0.1:"+$subPort),
    fixedSubId:$subId, brand:$brand, open:false
  }' >"$cfg"
  chmod 600 "$cfg"

  cat >/etc/systemd/system/xui-portal.service <<EOF
[Unit]
Description=xui-onekey node portal (8080)
After=network.target x-ui.service
Wants=x-ui.service

[Service]
Type=simple
ExecStart=${bin} -config ${cfg}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable xui-portal >/dev/null 2>&1
  systemctl restart xui-portal
  sleep 1
  systemctl is-active --quiet xui-portal || {
    journalctl -u xui-portal -n 20 --no-pager >&2
    ok_die "门户启动失败"
  }

  # 冒烟测试：门户页要能拿到 200（502 = 面板 API token 失效 / 面板不可达）
  local code i
  for i in $(seq 1 10); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORTAL_PORT}/p/${PORTAL_TOKEN}/" 2>/dev/null || true)"
    [[ "$code" == "200" ]] && break
    sleep 1
  done
  if [[ "$code" == "200" ]]; then
    ok_log "门户已启动并自检通过: http://${XO_HOST}:${PORTAL_PORT}/p/${PORTAL_TOKEN}/"
  else
    ok_warn "门户返回 ${code}（非 200）。检查：journalctl -u xui-portal -n 30"
    ok_warn "常见原因：portal.json 里的 apiToken 已失效 → 重跑本脚本会重新对齐"
  fi
}

# ============================ 阶段 6：收尾 ============================
stage_finish() {
  ok_step "阶段 6/6  收尾"

  local ports=("${PORTAL_PORT}/tcp" "${PANEL_PORT}/tcp")
  local p
  IFS=',' read -r -a PROTOS <<<"$PROTOCOLS"
  for p in "${PROTOS[@]}"; do
    case "$p" in
      reality) ports+=("443/tcp") ;;
      hy2 | hysteria2) ports+=("443/udp") ;;
      ws) ports+=("8443/tcp") ;;
      trojan) ports+=("2087/tcp") ;;
      ss | shadowsocks) ports+=("8388/tcp" "8388/udp") ;;
      vmess) ports+=("8880/tcp") ;;
      xhttp) ports+=("2088/tcp") ;;
    esac
  done
  ok_open_firewall "${ports[@]}"

  if [[ -f "${STATE_DIR}/nodes.env" ]]; then
    # shellcheck disable=SC1091
    . "${STATE_DIR}/nodes.env"
  fi

  local sum="${STATE_DIR}/summary.txt"
  {
    echo "=============== xui-onekey 安装结果 $(date '+%F %T') ==============="
    echo "面板地址   : http://${XO_HOST}:${PANEL_PORT}${XO_BASE_PATH}"
    echo "面板账号   : ${ADMIN_USER}"
    if [[ "${PANEL_FRESH_INSTALL:-1}" == "1" ]]; then
      echo "面板密码   : ${ADMIN_PASS}   （首次登录会强制要求修改）"
    else
      echo "面板密码   : 沿用原有密码（如需重置：x-ui setting -username admin -password 新密码）"
    fi
    if [[ "$MODE" == "panel" ]]; then
      echo "安装模式   : 仅面板（未创建节点，可随时运行脚本选 3 补建）"
    else
      echo "门户地址   : http://${XO_HOST}:${PORTAL_PORT}/p/${PORTAL_TOKEN}/"
      echo "订阅地址   : http://${XO_HOST}:${PORTAL_PORT}/sub/${XO_CLIENT_SUBID:-}"
      echo "Clash 订阅 : http://${XO_HOST}:${PORTAL_PORT}/clash/${XO_CLIENT_SUBID:-}"
      echo "Sing-box   : http://${XO_HOST}:${PORTAL_PORT}/json/${XO_CLIENT_SUBID:-}"
      echo "节点 UUID  : ${XO_CLIENT_UUID:-}"
      echo "节点协议   : ${PROTOCOLS}"
    fi
    echo "-----------------------------------------------"
    echo "重跑建节点 : bash ${HERE}/scripts/provision-nodes.sh --host ${XO_HOST}"
    echo "查看链接   : cat ${STATE_DIR}/links.txt"
    echo "重启面板   : systemctl restart x-ui"
    echo "重启门户   : systemctl restart xui-portal"
    echo "==============================================="
  } >"$sum"
  chmod 600 "$sum"

  echo
  sed -n '1,20p' "$sum"
  echo
  if command -v qrencode >/dev/null 2>&1 && [[ -n "${XO_CLIENT_SUBID:-}" ]]; then
    ok_info "订阅二维码（手机扫码直接导入）:"
    qrencode -t ANSIUTF8 "http://${XO_HOST}:${PORTAL_PORT}/sub/${XO_CLIENT_SUBID}" || true
  fi
  ok_log "全部完成。结果已存 ${sum}"
}

# ============================ 主流程 ============================
main() {
  # 无参数 + 有终端 → 弹菜单；有参数 → 按参数走（可脚本化）
  if [[ -z "$MODE" && $# -eq 0 && -t 0 && -t 1 ]]; then
    show_menu
  fi
  [[ -n "$MODE" ]] || MODE=full

  case "$MODE" in
    panel)
      # 只装面板：不建节点、不装门户
      SKIP_NODES=1; SKIP_PORTAL=1
      stage_preflight
      stage_install_panel
      stage_finish
      ;;
    nodes)
      do_nodes_only
      ;;
    upgrade)
      do_upgrade_panel
      ;;
    uninstall)
      do_uninstall
      ;;
    full|*)
      stage_preflight
      stage_install_panel
      stage_certificates
      stage_subscription
      stage_nodes
      stage_portal
      stage_finish
      ;;
  esac
}

main "$@"
