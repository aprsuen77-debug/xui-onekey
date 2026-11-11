#!/usr/bin/env bash
# ============================================================================
# install-routex.sh —— 从本机自建分发源一键安装（测试用，不依赖 GitHub）
# ----------------------------------------------------------------------------
# 用法（在客户机器上，root）：
#   bash <(curl -fsSL http://189.105.70.85:8090/install-routex.sh)
#
# 想改成你自己的分发服务器：改下面两行 BASE 即可。
# ============================================================================
set -Eeuo pipefail

BASE="${ROUTEX_BASE:-http://189.105.70.85:8090}"

export XO_SRC_URL="${XO_SRC_URL:-${BASE}/xui-onekey.tar.gz}"
export XO_ROUTEX_BIN_URL="${XO_ROUTEX_BIN_URL:-${BASE}/x-ui-linux-amd64}"

exec bash <(curl -fsSL "${BASE}/bootstrap.sh") "$@"
