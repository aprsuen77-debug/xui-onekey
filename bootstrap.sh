#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh —— 一键入口（客户只需要这一条命令）
# ----------------------------------------------------------------------------
#   curl -fsSL https://raw.githubusercontent.com/<you>/xui-onekey/main/bootstrap.sh | bash -s -- --host 1.2.3.4
#   国内加速：
#   curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/<you>/xui-onekey/main/bootstrap.sh | \
#     XO_MIRROR_GH_PREFIX=https://ghproxy.net/ bash -s -- --host 1.2.3.4
#
# 它做的事：把仓库 tarball 拉到 /opt/xui-onekey-src，再 exec install.sh。
# 这样 install.sh 里的 scripts/ portal/ theme/ 都在本地，不会出现管道执行的路径问题。
# ============================================================================
set -Eeuo pipefail

REPO="${XO_REPO:-yourname/xui-onekey}"        # ← 改成你自己的 GitHub 仓库
REF="${XO_REF:-main}"
DEST="${XO_SRC_DIR:-/opt/xui-onekey-src}"
MIRROR="${XO_MIRROR_GH_PREFIX:-}"

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
say() { printf "${green}[+]${plain} %s\n" "$*"; }
warn() { printf "${yellow}[!]${plain} %s\n" "$*" >&2; }
die() { printf "${red}[x]${plain} %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo -i）"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar  >/dev/null 2>&1 || die "缺少 tar"

TARBALL="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
URLS=(
  "${MIRROR}${TARBALL}"
  "${TARBALL}"
)

tmp="$(mktemp /tmp/xui-onekey.XXXXXX.tar.gz)"
trap 'rm -f "$tmp"' EXIT

ok=0
for u in "${URLS[@]}"; do
  [[ -n "$u" ]] || continue
  say "下载源码包: $u"
  if curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -o "$tmp" "$u"; then
    if tar tzf "$tmp" >/dev/null 2>&1; then ok=1; break; fi
  fi
  warn "该源不可用，尝试下一个"
done
[[ "$ok" == "1" ]] || die "源码包下载失败：请设置 XO_MIRROR_GH_PREFIX=https://ghproxy.net/ 后重试"

rm -rf "$DEST"
mkdir -p "$DEST"
tar xzf "$tmp" -C "$DEST" --strip-components=1
chmod +x "$DEST/install.sh" "$DEST"/scripts/*.sh 2>/dev/null || true
say "源码已就位: $DEST"

# curl | bash 时 stdin 是管道，弹不出菜单；提示用户用进程替换获得交互
if [[ ! -t 0 && $# -eq 0 && -z "${XO_MODE:-}" ]]; then
  warn "当前是管道执行，无法弹出交互菜单；10 秒后按「完整安装」继续"
  warn "要交互选择请改用：bash <(curl -fsSL <本脚本地址>)"
  sleep 10
fi

# 透传所有参数；XO_MODE=panel/full/nodes/upgrade/uninstall 可直接指定模式
if [[ -n "${XO_MODE:-}" && $# -eq 0 ]]; then
  exec bash "$DEST/install.sh" --mode "$XO_MODE"
fi
exec bash "$DEST/install.sh" "$@"
