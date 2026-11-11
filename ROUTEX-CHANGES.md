# routex 面板二改清单

基于 `MHSanaei/3x-ui` **v3.11.0** 的定制分支，工作副本在 `~/Downloads/routex-panel/`。
二进制产物：`~/Downloads/routex-panel/dist/x-ui-linux-amd64`（88MB，ELF 64-bit，Debian 12 实测可跑）。

---

## 一、改了什么

### 1. 品牌 3x-ui → routex

| 位置 | 文件 | 改动 |
|---|---|---|
| 登录页大标 | `frontend/src/pages/login/LoginPage.tsx` | `3X-UI` → `routex` |
| 侧边栏展开 | `frontend/src/layouts/AppSidebar.tsx` | `3X-UI` → `routex`，收起时 `3X` → `R` |
| 抽屉标题 | 同上 | `3X-UI` → `routex` |
| 浏览器标题 | `frontend/src/hooks/usePageTitle.ts` | 兜底 `3X-UI` → `routex` |
| 命令面板 | `frontend/src/components/command-palette/CommandPalette.tsx` | 同上 |
| 2FA 发行方 | `frontend/src/pages/settings/TwoFactorModal.tsx` | issuer → `routex` |
| API 文档标题 | `frontend/src/pages/api-docs/ApiDocsPage.tsx` | 同上 |
| 登录页 title | `frontend/login.html` | `routex · 登录` |
| 订阅页 title | `frontend/subpage.html` | `routex · 订阅` |
| PWA manifest | `frontend/public/manifest.webmanifest` | name/short_name/theme_color |
| PWA 图标 | `frontend/public/icons/routex-*.png` | 新做的蓝青渐变 + 白色 R（16/24/32/64/192/512） |
| PWA 白名单 | `internal/web/controller/pwa.go` | 放行 `icons/routex-*.png` |
| 全部文案 | `internal/web/translation/*.json`（14 个语言） | `3X-UI`→`ROUTEX`、`3x-ui`→`routex`（各 13 处） |

### 2. 去掉上游广告，换成客服提示

| 位置 | 改动 |
|---|---|
| 后端 `internal/web/service/panel/sponsor.go` `GetSponsors()` | 直接返回空列表，**不再请求** `raw.githubusercontent.com/MHSanaei/sponsors/...`（原来每小时内网拉一次第三方 JSON） |
| 前端 `frontend/src/components/sponsor/SponsorSlot.tsx` | 整组件重写：不再渲染 SponsorCard，改成一条白底细边框的提示条：`● routex 网络问题请联系 v:Ssssihh` |
| `/panel/sponsors` 页面 | 从 `frontend/src/routes/panelRoutes.tsx` 移除路由与侧边栏入口 |
| 侧边栏外链 | `DONATE_URL` / `DOCS_URL` / `REPO_URL` 置空并隐藏按钮，不再把客户导去上游 |
| 版本徽标 | 不再跳 GitHub，只显示版本号纯文本 |

> 客服条出现在三处：登录页、仪表盘顶部、其他页面顶部（原广告位）。

### 3. ~~首次登录强制改密~~（已按需求移除）

| 层 | 实现 |
|---|---|
| 后端判定 | `internal/web/controller/api.go`：`DefaultPanelPassword = "123456"`，`usesDefaultPassword()` 用 bcrypt 比对（结果缓存，避免每请求 60ms） |
| 登录响应 | `internal/web/controller/index.go`：登录成功返回 `obj.needChangePassword` |
| API 拦截 | `requirePasswordChange` 中间件挂在 `/panel/api` 组：仍用默认密码时，除 `setting/updateUser`、`setting/all`、`server/status` 外全部 **403** `{"needChangePassword":true}` |
| 缓存失效 | `internal/web/controller/setting.go`：改密成功后 `ResetDefaultPasswordCache(user.Id)` |
| 前端弹窗 | `LoginPage.tsx`：登录成功且 `needChangePassword` 时弹出不可关闭的 Modal（`closable/maskClosable/keyboard` 全关），填写新密码 → 调 `setting/updateUser` → 提示"请用新密码重新登录" → reload |

> 为什么改密后要重新登录：改密会重建 session 与 CSRF token，直接跳 `/panel/` 会被弹回登录页。

### 4. 白色简洁主题

`frontend/src/hooks/useTheme.tsx`：

- `initialDark` 默认值 `true` → **`false`**（首次访问即浅色）
- 新增 `ROUTEX_LIGHT_TOKENS`：主色 `#2b6cff`、圆角 10/14/7、页面底 `#f5f7fa`、卡片纯白、边框 `#e4e8ef` / `#eef1f6`、文字四级灰阶、统一字体栈
- 组件级 token：Layout 全白、Menu 选中态淡蓝底 + 蓝字 + 9px 圆角、Card 20px 内边距、Table 表头 `#f7f9fc`
- `frontend/src/styles/page-shell.css`：页面底色 `#e6e8ec` → `#f5f7fa`

深色模式仍然保留（右上角切换），只是不再是默认。

---

## 二、构建方式（本地，不碰客户服务器）

3x-ui 依赖 CGO 版 SQLite（`mattn/go-sqlite3`），交叉编译到 linux 必须有 Linux 的 C 编译器。
本机方案是 **zig 当 CC**，实测通过：

```bash
brew install node zig          # node 26 / zig 0.17

# 1) 前端
cd routex-panel/frontend
npm config set registry https://registry.npmmirror.com
npm install
npm run build                  # 产物落到 ../internal/web/dist/

# 2) 后端（交叉编译 linux/amd64）
cd ..
go env -w GOPROXY=https://goproxy.cn,direct
CC="zig cc -target x86_64-linux-gnu" CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
  CGO_CFLAGS="-O2 -g0" \
  go build -trimpath -ldflags "-s -w" -o dist/x-ui-linux-amd64 .

# 3) 剥离 C 侧残留符号（-s -w 只管 Go 侧；不做这步会多 12MB）
llvm-strip --strip-all dist/x-ui-linux-amd64
```

体积对比：

| 构建方式 | 体积 | 相对官方 |
|---|---|---|
| 官方 release（gcc 构建） | 73.8 MB | — |
| `go build -s -w`（zig cc） | 87.9 MB | +19% |
| `+ CGO_CFLAGS=-g0` | 82.9 MB | +12% |
| `+ llvm-strip --strip-all` | **75.4 MB** | **+2.2%** |
| `+ upx --best --lzma` | 18.7 MB | 不建议：启动要解压、常驻内存变大、易被杀软误报 |

产物校验：

```
$ file dist/x-ui-linux-amd64
ELF 64-bit LSB executable, x86-64, dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2

$ ./x-ui-linux-amd64 -v
3.11.0
```

**绝对不要在 1C1G 的客户机上跑 `go build`** —— 3x-ui 全量编译要几 GB 内存和 10 分钟 CPU，
会把线上的 xray 和门户一起拖死。这次踩过一次，已清理（swap、Go toolchain、源码包全部删除）。

---

## 三、部署 / 回滚

部署（脚本已做，等价于）：

```bash
cp -a /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.bak.$(date +%s)
systemctl stop x-ui
install -m 0755 x-ui-linux-amd64 /usr/local/x-ui/x-ui
systemctl start x-ui
/usr/local/x-ui/x-ui setting -username admin -password 123456   # 出厂默认，首登强制改
```

回滚：

```bash
systemctl stop x-ui
cp -a /usr/local/x-ui/x-ui.bak.<时间戳> /usr/local/x-ui/x-ui
systemctl start x-ui
```

x-ui 只替换自身二进制，**xray 本体、数据库 `/etc/x-ui/x-ui.db`、订阅服务、节点配置都不受影响**。

---

## 四、实测记录（189.105.70.85 / Debian 12 / 1C1G）

| 项 | 结果 |
|---|---|
| 面板 title | `189.105.70.85 - routex · 登录` |
| 品牌 | 登录页 `routex`、侧边栏 `routex`/`R` |
| 客服条 | `routex 网络问题请联系 v:Ssssihh` 三处可见 |
| 广告 | `/sponsors` 入口消失，后端不再请求上游 JSON |
| 首登改密 | admin/123456 登录 → 弹窗 → 改密 200 → 提示重新登录 → 新密码进面板 |
| 未改密时 API | 403 `{"msg":"首次登录必须先修改默认密码"}` |
| 改密后 API | 200 |
| 主题 | 登录页与面板全白，主色 #2b6cff |
| 7 个节点 | 全部正常，端口 443t/443u/8443/2088/2087/8388/8880 在听 |
| 门户 / 订阅 | 200 / 200 |
| 服务器负载 | 0.04（部署后） |

截图：`/tmp/routex-login.png`、`/tmp/routex-force-pw.png`、`/tmp/routex-dashboard.png`、`/tmp/routex-inbounds.png`

---

## 五、和上游的差异面（升级时要重打）

`x-ui update` 会用上游二进制覆盖掉定制版。要让 routex 版本持续可用：

1. 本仓库 `install.sh` 支持 `XUI_ROUTEX_BIN`（本地路径或 URL），装完自动替换；
2. 升级上游后重跑一次构建（本文第二节），把新的 `x-ui-linux-amd64` 发布出去；
3. 上表"改了什么"里的 15 个文件是补丁面，可以用 `git diff` 生成 patch 保存。

建议做法：把 `routex-panel/` 建 git 仓库，`upstream` 指向 MHSanaei/3x-ui，
每次发版 `git rebase upstream/main` 后重构建。

---

## 六、还没做 / 可继续

- 登录页背景仍是 upstream 的彩色渐变（白色卡片 + 淡紫粉底）。要更"纯白"可以改 `frontend/src/pages/login/LoginPage.css` 的 `--bg-page`。
- 深色模式没重新调色（保留了上游的深色 token）。
- favicon 之外的 `media/` 截图没替换（不影响运行）。
- 订阅页（`/s/<subId>`）的文案没动，仍是官方模板样式。
