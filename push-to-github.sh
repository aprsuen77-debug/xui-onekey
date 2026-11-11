#!/usr/bin/env bash
# ============================================================================
# push-to-github.sh —— 把两个仓库推到 GitHub 并发布面板二进制
# ----------------------------------------------------------------------------
# 用法：
#   GITHUB_TOKEN=ghp_xxx bash push-to-github.sh
#   GITHUB_TOKEN=ghp_xxx GITHUB_USER=yourname bash push-to-github.sh
#
# token 需要：repo 权限（classic）或
#            Contents: Read and write + Metadata: Read（fine-grained）
#
# 做的事：
#   1) 自动读 /user 拿用户名
#   2) 创建 routex-panel（3x-ui fork 源码）→ 推送 → 发 Release 附 x-ui-linux-amd64
#   3) 创建 xui-onekey（安装脚本）→ 把占位 URL 换成真实地址 → 推送
# ============================================================================
set -Eeuo pipefail

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
[[ -n "$TOKEN" ]] || { echo "缺少 GITHUB_TOKEN"; exit 1; }
API="https://api.github.com"

PANEL_DIR="${PANEL_DIR:-$HOME/Downloads/routex-panel}"
ONKEY_DIR="${ONKEY_DIR:-$HOME/Downloads/xui-onekey}"
PANEL_REPO="${PANEL_REPO:-routex-panel}"
ONKEY_REPO="${ONKEY_REPO:-xui-onekey}"
BIN_FILE="${BIN_FILE:-${PANEL_DIR}/dist/x-ui-linux-amd64}"

say() { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

gh_api() { # method path [json]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then
    curl -sS -X "$m" -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$d" "${API}${p}"
  else
    curl -sS -X "$m" -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}${p}"
  fi
}

# ---------------- 0) 身份 ----------------
ME="$(gh_api GET /user)"
USER="${GITHUB_USER:-$(jq -r '.login // empty' <<<"$ME")}"
[[ -n "$USER" ]] || die "取不到 GitHub 用户名，检查 token：$(jq -r '.message // .' <<<"$ME")"
say "GitHub 用户：${USER}"

create_repo() { # $1=repo  $2=desc
  local repo="$1" desc="$2" out
  out="$(gh_api GET "/repos/${USER}/${repo}")"
  if [[ "$(jq -r '.id // empty' <<<"$out")" != "" ]]; then
    say "仓库已存在，跳过创建：${USER}/${repo}"
    return 0
  fi
  out="$(gh_api POST /user/repos "{\"name\":\"${repo}\",\"description\":\"${desc}\",\"private\":false,\"has_issues\":true,\"has_wiki\":false}")"
  [[ "$(jq -r '.id // empty' <<<"$out")" != "" ]] || die "创建 ${repo} 失败：$(jq -r '.message // .' <<<"$out")"
  say "已创建仓库：${USER}/${repo}"
}

push_repo() { # $1=dir  $2=repo
  local dir="$1" repo="$2"
  cd "$dir"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://${USER}:${TOKEN}@github.com/${USER}/${repo}.git"
  git push -q -u origin main --force
  git remote set-url origin "https://github.com/${USER}/${repo}.git"
  say "已推送 ${repo}（$(git rev-list --count HEAD) 个提交，$(git ls-files | wc -l | tr -d ' ') 个文件）"
}

# ---------------- 1) 面板源码 ----------------
create_repo "$PANEL_REPO" "routex 面板：3x-ui v3.11.0 定制版（品牌/白色主题/首登强制改密/去广告）"
push_repo "$PANEL_DIR" "$PANEL_REPO"

# ---------------- 2) Release + 二进制 ----------------
if [[ -f "$BIN_FILE" ]]; then
  TAG="${TAG:-v3.11.0-routex}"
  REL="$(gh_api GET "/repos/${USER}/${PANEL_REPO}/releases/tags/${TAG}")"
  if [[ "$(jq -r '.id // empty' <<<"$REL")" == "" ]]; then
    REL="$(gh_api POST "/repos/${USER}/${PANEL_REPO}/releases" \
      "{\"tag_name\":\"${TAG}\",\"name\":\"routex panel ${TAG}\",\"body\":\"routex 定制面板（3x-ui v3.11.0）。默认账号 admin/123456，首次登录强制改密。\"}")"
    [[ "$(jq -r '.id // empty' <<<"$REL")" != "" ]] || die "创建 Release 失败：$(jq -r '.message // .' <<<"$REL")"
    say "已创建 Release ${TAG}"
  else
    say "Release ${TAG} 已存在，覆盖上传"
  fi

  UP_URL="$(jq -r '.upload_url' <<<"$REL" | sed 's/{?name,label}//')"
  SIZE_MB=$(awk -v s="$(stat -f%z "$BIN_FILE" 2>/dev/null || stat -c%s "$BIN_FILE")" 'BEGIN{printf "%.1f", s/1048576}')
  say "上传 $(basename "$BIN_FILE")（${SIZE_MB} MB）…"
  RESP="$(curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${BIN_FILE}" \
    "${UP_URL}?name=x-ui-linux-amd64&label=linux-amd64")"
  [[ "$(jq -r '.id // empty' <<<"$RESP")" != "" ]] || die "上传失败：$(jq -r '.message // .' <<<"$RESP")"
  say "二进制已发布：https://github.com/${USER}/${PANEL_REPO}/releases/download/${TAG}/x-ui-linux-amd64"
else
  warn "找不到 $BIN_FILE，跳过 Release"
fi

# ---------------- 3) 安装脚本 ----------------
create_repo "$ONKEY_REPO" "routex 一键部署：交互菜单 + 7 个主流节点 + 8080 节点门户"
cd "$ONKEY_DIR"

# 把占位地址换成真实地址
if [[ -f install.sh ]]; then
  sed -i.bak "s#https://github.com/yourname/routex-panel/releases/latest/download/x-ui-linux-amd64#https://github.com/${USER}/${PANEL_REPO}/releases/latest/download/x-ui-linux-amd64#g" install.sh
  rm -f install.sh.bak
fi
if [[ -f bootstrap.sh ]]; then
  sed -i.bak "s#REPO=\"\${XO_REPO:-yourname/xui-onekey}\"#REPO=\"\${XO_REPO:-${USER}/${ONKEY_REPO}}\"#" bootstrap.sh
  sed -i.bak2 "s#yourname/xui-onekey#${USER}/${ONKEY_REPO}#g" bootstrap.sh 2>/dev/null || true
  rm -f bootstrap.sh.bak bootstrap.sh.bak2
fi
if [[ -f README.md ]]; then
  sed -i.bak "s#yourname/xui-onekey#${USER}/${ONKEY_REPO}#g; s#yourname/routex-panel#${USER}/${PANEL_REPO}#g" README.md
  rm -f README.md.bak
fi

git add -A
git -c user.name=routex -c user.email=routex@localhost commit -q -m "chore: 指向 ${USER} 的仓库地址" 2>/dev/null || true
push_repo "$ONKEY_DIR" "$ONKEY_REPO"

echo
say "全部完成"
echo
echo "  面板源码 : https://github.com/${USER}/${PANEL_REPO}"
echo "  二进制   : https://github.com/${USER}/${PANEL_REPO}/releases"
echo "  安装脚本 : https://github.com/${USER}/${ONKEY_REPO}"
echo
echo "  客户一键安装（交互菜单）:"
echo "    bash <(curl -fsSL https://raw.githubusercontent.com/${USER}/${ONKEY_REPO}/main/bootstrap.sh)"
echo
