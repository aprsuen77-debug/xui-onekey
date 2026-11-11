#!/usr/bin/env bash
# ============================================================================
# lib.sh —— xui-onekey 公共函数库（被 install.sh / provision-nodes.sh source）
# ============================================================================
# 约定：
#   * 所有函数前缀 ok_ / 变量前缀 XO_
#   * 不在此文件里做任何破坏性动作
# ============================================================================

# ---------- 输出 ----------
if [[ -t 1 ]]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;34m'; C_C=$'\033[0;36m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_C=''; C_0=''
fi

# 诊断信息一律写 stderr：脚本里大量 CRT="$(ensure_self_signed)" 这类捕获，
# 日志混进 stdout 会污染返回值（曾经把 "生成自签证书..." 拼进证书路径）
ok_log()  { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
ok_info() { printf '%s[·]%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok_warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
ok_die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
ok_step() { printf '\n%s==> %s%s\n' "$C_C" "$*" "$C_0"; }

# ---------- 环境 ----------
ok_need_root() {
  [[ $EUID -eq 0 ]] && return 0
  # 本地 dry-run / 调试用（只跳过权限检查，不跳过任何实际动作）
  [[ "${XO_ALLOW_NONROOT:-0}" == "1" ]] && { ok_warn "非 root 模式：仅用于 --dry-run 本地验证"; return 0; }
  ok_die "请用 root 运行（sudo -i 后重试）"
}

ok_os() {
  [[ -f /etc/os-release ]] || ok_die "无法识别系统（缺少 /etc/os-release）"
  # shellcheck disable=SC1091
  . /etc/os-release
  XO_OS_ID="${ID:-unknown}"
  XO_OS_LIKE="${ID_LIKE:-}"
  XO_OS_VER="${VERSION_ID:-0}"
}

ok_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)  XO_ARCH=amd64 ;;
    aarch64 | arm64) XO_ARCH=arm64 ;;
    armv7l)          XO_ARCH=armv7 ;;
    armv6l)          XO_ARCH=armv6 ;;
    i386 | i686)     XO_ARCH=386 ;;
    s390x)           XO_ARCH=s390x ;;
    *) ok_die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

ok_pkg_mgr() {
  if   command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  elif command -v apk     >/dev/null 2>&1; then echo apk
  elif command -v pacman  >/dev/null 2>&1; then echo pacman
  else echo none; fi
}

# ok_install_pkgs curl jq openssl tar qrencode
ok_install_pkgs() {
  local mgr missing=() p
  mgr=$(ok_pkg_mgr)
  for p in "$@"; do
    case "$p" in
      qrencode) command -v qrencode >/dev/null 2>&1 || missing+=("$p") ;;
      jq)       command -v jq       >/dev/null 2>&1 || missing+=("$p") ;;
      *)        command -v "$p"     >/dev/null 2>&1 || missing+=("$p") ;;
    esac
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  ok_info "安装依赖: ${missing[*]}"
  case "$mgr" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null 2>&1 || ok_warn "部分依赖安装失败: ${missing[*]}"
      ;;
    dnf) dnf install -y -q "${missing[@]}" >/dev/null 2>&1 || ok_warn "部分依赖安装失败" ;;
    yum) yum install -y -q "${missing[@]}" >/dev/null 2>&1 || ok_warn "部分依赖安装失败" ;;
    apk) apk add --no-cache "${missing[@]}" >/dev/null 2>&1 || ok_warn "部分依赖安装失败" ;;
    pacman) pacman -Sy --noconfirm --needed "${missing[@]}" >/dev/null 2>&1 || ok_warn "部分依赖安装失败" ;;
    *) ok_warn "未知包管理器，请手动安装: ${missing[*]}" ;;
  esac
}

# ---------- 随机 ----------
ok_rand_hex()  { openssl rand -hex "${1:-8}"; }
ok_rand_b64()  { openssl rand -base64 "${1:-32}" | tr -d '\n'; }
ok_rand_pass() {
  # 纯 bash 实现：不用 tr|head（pipefail 下 head 提前退出会让上游 SIGPIPE，整条命令 141）
  local n="${1:-16}" s
  s="$(openssl rand -base64 $((n * 2 + 8)) | tr -d '\n')"
  s="${s//[!A-Za-z0-9]/}"
  printf '%s' "${s:0:n}"
}
ok_rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; }

# SS2022 服务端密码必须是 N 字节 key 的 base64
ok_ss_key() { # 16 => aes-128-gcm, 32 => aes-256-gcm（base64 of N random bytes）
  openssl rand -base64 "${1:-16}" | tr -d '\n'
}

# ---------- 端口 ----------
ok_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$" && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -iUDP:"$port" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 1
}

# ok_pick_port 起始端口 结束端口 [排除列表...]
ok_pick_port() {
  local lo="$1" hi="$2"; shift 2
  local p ex
  for ((p = lo; p <= hi; p++)); do
    ok_port_in_use "$p" && continue
    for ex in "$@"; do [[ "$p" == "$ex" ]] && continue 2; done
    echo "$p"; return 0
  done
  return 1
}

# ---------- HTTP ----------
# ok_fetch <url> <out> [超时秒]
ok_fetch() {
  local url="$1" out="$2" tmo="${3:-60}"
  curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time "$tmo" -o "$out" "$url"
}

# 按候选 URL 依次尝试下载（用于国内镜像）
ok_fetch_any() {
  local out="$1"; shift
  local u
  for u in "$@"; do
    [[ -n "$u" ]] || continue
    ok_info "下载: $u"
    if ok_fetch "$u" "$out" 120; then
      [[ -s "$out" ]] && { echo "$u" > "${out}.from"; return 0; }
    fi
    ok_warn "失败，换下一个源"
  done
  return 1
}

# ---------- 3x-ui API ----------
# 全局：XO_PANEL_URL  XO_BASE_PATH  XO_API_TOKEN
xo_api() { # method path [json]
  local method="$1" path="$2" data="${3:-}"
  local url="${XO_PANEL_URL}${XO_BASE_PATH}panel/api/${path}"
  local args=(-sS -X "$method" "$url"
    -H "Authorization: Bearer ${XO_API_TOKEN}"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json'
    --connect-timeout 10 --max-time 60)
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}"
}

xo_api_ok() { # 同上，但失败即退出
  local out
  out=$(xo_api "$@") || ok_die "API 请求失败: $1 $2"
  if [[ "$(jq -r '.success // false' <<<"$out" 2>/dev/null)" != "true" ]]; then
    if grep -qiE "unauthorized|401" <<<"$out"; then
      rm -f "${XO_STATE_DIR:-/etc/xui-onekey}/api.token"
      ok_die "API token 已失效（可能被面板轮换过）。已清除缓存，请重跑本脚本"
    fi
    ok_die "API 返回失败: $1 $2 -> $(jq -r '.msg // .' <<<"$out" 2>/dev/null | awk '{printf "%s", substr($0,1,300)}')"
  fi
  printf '%s' "$out"
}

# 从 x-ui CLI 读配置（root 本机）
xo_cli_show() { /usr/local/x-ui/x-ui setting -show true 2>/dev/null; }
xo_cli_field() { xo_cli_show | awk -v k="$1" 'index($0,k": ")==1 {sub("^"k": ",""); print; exit}' | tr -d '\r'; }

# 确保 XO_PANEL_URL / XO_BASE_PATH / XO_API_TOKEN 已就绪
ok_load_panel_ctx() {
  # 已显式给出面板地址 + token（远程面板 / 本地测试）时，不再读本机 x-ui CLI
  if [[ -n "${XO_PANEL_URL:-}" && -n "${XO_API_TOKEN:-}" ]]; then
    XO_BASE_PATH="${XO_BASE_PATH:-/}"
    [[ "$XO_BASE_PATH" == /* ]] || XO_BASE_PATH="/${XO_BASE_PATH}"
    [[ "$XO_BASE_PATH" == */ ]] || XO_BASE_PATH="${XO_BASE_PATH}/"
    XO_PANEL_PORT="${XO_PANEL_PORT:-$(sed -E 's#.*:([0-9]+).*#\1#' <<<"$XO_PANEL_URL")}"
    return 0
  fi
  local port bp
  port=$(xo_cli_field port)
  bp=$(xo_cli_field webBasePath)
  [[ -n "$port" ]] || ok_die "读不到面板端口（x-ui setting -show 失败）"
  XO_PANEL_PORT="$port"
  XO_BASE_PATH="${bp:-/}"
  [[ "$XO_BASE_PATH" == /* ]] || XO_BASE_PATH="/${XO_BASE_PATH}"
  [[ "$XO_BASE_PATH" == */ ]] || XO_BASE_PATH="${XO_BASE_PATH}/"
  XO_PANEL_URL="http://127.0.0.1:${XO_PANEL_PORT}"
  ok_resolve_api_token
}

# token 解析：已落盘就直接复用，**不探活**。
# 原因：`x-ui setting -getApiToken` 每调用一次就轮换一次（旧的立刻失效），
# 而面板重启后的几秒里探活会误判，导致每次重跑都把 portal.json 的 token 换掉。
ok_resolve_api_token() {
  local tokf="${XO_STATE_DIR:-/etc/xui-onekey}/api.token"
  [[ -n "${XO_API_TOKEN:-}" ]] && return 0

  if [[ -s "$tokf" ]]; then
    XO_API_TOKEN="$(tr -d '\r\n' < "$tokf")"
    if [[ -n "$XO_API_TOKEN" ]]; then
      ok_info "复用已保存的 API token"
      return 0
    fi
  fi

  XO_API_TOKEN="$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | awk '/^apiToken: /{print $2; exit}' | tr -d '\r')"
  [[ -n "$XO_API_TOKEN" ]] || ok_die "取不到 API Token（面板是否在运行？）"
  if mkdir -p "$(dirname "$tokf")" 2>/dev/null && : > "$tokf" 2>/dev/null; then
    ( umask 077; printf '%s' "$XO_API_TOKEN" > "$tokf" )
  fi
  ok_info "已生成并保存新的 API token"
  sync_portal_token
}

# token 与门户配置保持一致，否则门户所有 API 调用 401 → 页面 502
sync_portal_token() {
  local pj="${XO_STATE_DIR:-/etc/xui-onekey}/portal.json"
  [[ -f "$pj" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local old; old="$(jq -r '.apiToken // empty' "$pj" 2>/dev/null)"
  [[ "$old" == "$XO_API_TOKEN" ]] && return 0
  jq --arg t "$XO_API_TOKEN" '.apiToken = $t' "$pj" > "${pj}.tmp" 2>/dev/null \
    && mv -f "${pj}.tmp" "$pj" && chmod 600 "$pj"
  systemctl restart xui-portal >/dev/null 2>&1 || true
  ok_info "已同步门户 API token 并重启 xui-portal"
}

# ---------- 公网信息 ----------
ok_public_ip() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip https://cdn.jsdelivr.net/gh/ipinfo/ipinfo@master/ip; do
    ip=$(curl -4fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9.]+$ ]] && { echo "$ip"; return 0; }
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  return 1
}

# ---------- 防火墙提示 ----------
ok_open_firewall() {
  local ports=("$@")
  local p
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${ports[@]}"; do ufw allow "${p}" >/dev/null 2>&1 || true; done
    ok_info "已在 ufw 放通: ${ports[*]}"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${ports[@]}"; do firewall-cmd --permanent --add-port="${p}" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok_info "已在 firewalld 放通: ${ports[*]}"
  fi
  if command -v iptables >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1 && ! command -v firewall-cmd >/dev/null 2>&1; then
    for p in "${ports[@]}"; do
      iptables -C INPUT -p tcp --dport "${p%%/*}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -p tcp --dport "${p%%/*}" -j ACCEPT 2>/dev/null || true
    done
  fi
}
