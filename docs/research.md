# 3x-ui v3 源码级研究结论

研究基线：`MHSanaei/3x-ui` main 分支，`internal/config/version` = **3.11.0**（2026-11 拉取）。
所有结论都标了出处文件，可自行核对。

> 注意：仓库已重构为 **v3** 模块路径 `github.com/mhsanaei/3x-ui/v3`，前端换成 Vite+React，
> 旧版（v2.x）里的 `web/`、`internal/web/service/inbound.go` 单文件结构已经不适用。
> 网上大量教程是 v2 的，照抄会踩空。

---

## 1. 安装器：完全支持无人值守

`install.sh`（2130 行）开头就判断：

```bash
# install.sh:43-48
if [[ "${XUI_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    NONINTERACTIVE=1
```

意味着 **`curl ... | bash` 或 stdin 不是 tty 时自动进入非交互模式**，所有交互项退化成 env 变量或默认值。

支持的环境变量（`grep -oE 'XUI_[A-Z_]+' install.sh`）：

| 变量 | 作用 |
|---|---|
| `XUI_NONINTERACTIVE` | 强制非交互 |
| `XUI_USERNAME` / `XUI_PASSWORD` | 面板账号密码（不给则随机） |
| `XUI_PANEL_PORT` | 面板端口（不给则随机 5 位） |
| `XUI_WEB_BASE_PATH` | 面板路径 |
| `XUI_API_TOKEN` | 写进结果文件（**不会**真的创建 token，见下） |
| `XUI_DOMAIN` / `XUI_ACME_EMAIL` / `XUI_SSL_MODE` / `XUI_SSL_IPV` | 证书相关 |
| `XUI_SERVER_IP` / `XUI_ACCESS_URL` | 对外地址 |
| `XUI_DB_TYPE` / `XUI_DB_DSN` | sqlite / postgres |
| `XUI_MAIN_FOLDER` / `XUI_BIN_FOLDER` / `XUI_LOG_FOLDER` / `XUI_DB_FOLDER` / `XUI_SERVICE` | 路径 |
| `XUI_ENABLE_FAIL2BAN` | 默认自动装 fail2ban（IP 限制功能依赖它） |

安装完写机器可读结果文件（`install.sh:224`）：

```bash
/etc/xui/install-result.env   # mode 600
# XUI_USERNAME / XUI_PASSWORD / XUI_PANEL_PORT / XUI_WEB_BASE_PATH
# XUI_ACCESS_URL / XUI_API_TOKEN / XUI_DB_TYPE
```

⚠️ `XUI_API_TOKEN` 只是"写进文件"，值来自 `x-ui setting -getApiToken`（`install.sh:1466-1467`），
**不是你传什么就生效什么**。真正的 token 由 DB seeder 生成（`internal/database/db.go:3303 seedApiTokens`），
CLI 才能读到/轮换。

### 二进制下载源（国内装不上的根因）

`install.sh:1796 / 1806 / 1825` 硬编码：

```
https://github.com/MHSanaei/3x-ui/releases/download/<tag>/x-ui-linux-<arch>.tar.gz
```

只替换 install.sh 的下载地址没用，**必须同时改写 install.sh 内部的 releases 前缀**：

```bash
sed -i "s#https://github.com/MHSanaei/3x-ui/releases/download#${MIRROR}https://github.com/MHSanaei/3x-ui/releases/download#g" install.sh
```

本仓库 `install.sh` 的 `gh_url()` 就是这么干的。

---

## 2. API 层：Bearer token 全权限，够用了

入口 `internal/web/controller/api.go:195 initRouter`：

```
/panel/api/openapi.json                 # 完整 OpenAPI（可直接生成客户端）
/panel/api/inbounds/*                   # list / add / update / del / allLinks / import / fallbacks
/panel/api/clients/*                    # 跨 inbound 的客户端 CRUD、批量、重置流量、在线状态
/panel/api/groups/*                     # 客户端分组
/panel/api/server/*                     # 状态、重启 xray、版本、getNewX25519Cert、备份
/panel/api/nodes/*                      # 多面板/多节点管理
/panel/api/hosts/*                      # 订阅链接的 per-inbound 覆写（Host 表）
/panel/api/setting/*                    # 全部设置 + apiTokens 管理
/panel/api/xray/*                       # xray 模板配置
```

鉴权（`api.go:36 checkAPIAuth`）：

```go
if after, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer "); ok {
    if row, matched := a.apiTokenService.MatchToken(after); matched { ... }
}
```

- `Authorization: Bearer <token>` 直接放行，**跳过 CSRF**（`middleware/security.go:42`：`if c.GetBool("api_authed") { c.Next(); return }`）
- 没有 token 且未登录 → 返回 **404**（不是 401，防扫描）
- token 有 scope：`admin`（全权限）/ `monitor`（只读状态）/ `node-sync`（节点同步白名单）

三种取 token 的方式，按可靠性排序：

1. `x-ui setting -getApiToken`（root 本机，最稳；会轮换 token）
2. `x-ui setting -getApiToken -tokenName xxx -tokenScope admin`（具名 token，不轮换别人的）
3. `POST /login`（要处理 CSRF，见 `session.ValidateCSRFToken`，不推荐脚本用）

响应统一外壳（`controller/util.go:176`）：

```json
{"success": true, "msg": "", "obj": <payload>}
```

---

## 3. Inbound 数据模型：可以直传 JSON 对象

`internal/database/model/model.go:53`：

```go
type Inbound struct {
    Id        int    `json:"id"`
    Remark    string `json:"remark"`
    Enable    bool   `json:"enable"`
    Listen    string `json:"listen"`
    Port      int    `json:"port"`
    Protocol  Protocol `json:"protocol"`   // 见下
    Settings  string `json:"settings"`      // JSON 字符串
    StreamSettings string `json:"streamSettings"`
    Tag       string `json:"tag"`           // gorm:"unique"
    Sniffing  string `json:"sniffing"`
    NodeID    *int   `json:"nodeId,omitempty"`
    ShareAddrStrategy string `json:"shareAddrStrategy"` // node | listen | custom
    ShareAddr string `json:"shareAddr"`
    ...
}
```

**关键点 1**：`Settings/StreamSettings/Sniffing` 声明是 `string`，但实现了 `UnmarshalJSON`
（`model.go:215`），传 **JSON 对象或字符串都会被接受**。所以 `curl -d '{"settings":{...}}'` 直接可用，
不需要自己 stringify 再转义（这是 v2 时代最容易写错的地方）。

**关键点 2**：`ShareAddrStrategy` + `ShareAddr`（`server.go:1878 resolveInboundAddress`）。
设为 `custom` + 公网 IP/域名后，**分享链接里的地址被钉死**，不再依赖请求上下文。这是让
"反代 / CDN / 面板换域名" 之后链接仍然正确的关键手段：

```go
case "custom":
    candidates = []string{strings.TrimSpace(inbound.ShareAddr), nodeAddr, listenAddr}
```

**关键点 3**：协议枚举（`model.go:29-41`）：

```
vmess vless trojan shadowsocks wireguard hysteria http mixed tunnel tun mtproto amneziawg tuic masque
```

v3 比 v2 多了 `mtproto`（Telegram 代理）、`amneziawg`（需要内核模块，`scripts/install-amneziawg-kernel.sh`）、
`tuic`（独立子服务 `internal/tuic`）、`masque`。

**关键点 4**：`tag` 有唯一索引 → 幂等判重就用 tag，不用查 remark。

---

## 4. 订阅体系：这是整套方案最值钱的部分

### 4.1 独立端口 + 三条路径

订阅服务是**独立 HTTP 服务**，默认 `2096`（`service/setting.go:174 "subPort":"2096"`）。
路径全部随机生成（`db.go:1509 seedRandomSubscriptionPaths`）：

```go
{Key: "subPath",      Value: "/" + random.NumLower(16) + "/"},
{Key: "subJsonPath",  Value: "/" + random.NumLower(16) + "/"},
{Key: "subClashPath", Value: "/" + random.NumLower(16) + "/"},
```

路由（`internal/sub/controller.go:346`）：

```
<subPath><subid>        → 通用订阅
<subPath><subid>/hwid-status
<subJsonPath><subid>    → sing-box JSON
<subClashPath><subid>   → Clash/Mihomo YAML（需 subClashEnable=true）
/mihomo/<subid>         → 别名
/clash-legacy/<subid>   → 旧版 Clash 兼容
```

### 4.2 `/sub/<id>` 是"按 UA 自动变形"的

`controller.go:477 subs()` 的判定顺序：

```
1. ?format=info        → 返回 JSON 摘要（流量/到期/邮箱）
2. Accept: text/html   → 返回完整订阅页（HTML！）
3. UA 命中 clash       → 返回 Clash YAML
4. UA 命中 sing-box    → 返回 sing-box JSON
5. 其它                → 返回 base64 链接列表（v2rayN/v2rayNG 格式）
```

**这意味着：一个订阅 URL 就能同时服务所有客户端**——这正好是"兼容市面上的所有代理软件"的答案，
不用自己搞多套格式。

### 4.3 内置订阅页 = 免费的门户原型

`Accept: text/html` 时渲染 `internal/web/dist/subpage.html`（Vite 产物），注入：

```js
window.__SUB_PAGE_DATA__ = {sId, enabled, isOnline, download, upload, total, used,
  remained, expire, lastOnline, subUrl, subJsonUrl, subClashUrl, subTitle,
  subSupportUrl, subUpdates, links, emails, datepicker, announce}
```

前端 `frontend/src/pages/sub/` 已经有：

- `SubQrButton`：二维码
- `SubLinksTab`：逐节点链接
- `SubAppsTab` + `appIcons`：**8 个客户端的 deeplink 一键导入**（Android/iOS 分栏）
- 流量/到期/在线状态

`frontend/src/pages/sub/subPageModel.ts:47 buildSubApps()` 里是官方验证过的 scheme 全集（见 node-matrix.md）。

### 4.4 subId 是 per-client 的，且可跨 inbound 复用

- 每个 client 有自己的 `subId`（`db.go:601` 迁移时补齐，`random.NumLower(16)`）
- 一个订阅 = **所有包含同一 subId 的 inbound 的节点**
- 源码注释明确支持（`client_add_dedupe_test.go:47`）：
  > `checkEmailsExistForClients exempts a matching subId (so one identity can span inbounds)`

所以"一个订阅链接包含全部节点 + 合并流量"的正确做法是：
**所有 inbound 里放同一个 `email` + 同一个 `uuid/password` + 同一个 `subId`**。
（本仓库 `provision-nodes.sh` 就是这么做的。）

### 4.5 subURI：把订阅地址钉到你自己的域名/端口

`sub/service.go:3429 BuildURLs()`：

```go
subURL = s.buildSingleURL(configuredSubURI, base, subPath, subId)
// subURI 有值时，json/clash URL 也用它的 scheme://host 作为 base
```

所以设 `subURI=http://IP:8080/sub/` 后，面板/订阅页/二维码里给出的订阅地址**全部指向 8080**。
配合 8080 反代 → 客户永远只看到一个端口，2096 可以完全关在防火墙后面。

### 4.6 换皮：subThemeDir（零改源码）

`controller.go:778 loadSubTemplate()`：`subThemeDir` 指向的目录里有 `index.html` 或 `sub.html`
就用它渲染（Go `html/template`，数据 = 上面那个 map），失败自动回落官方页面。

坑：`html/template` 会把 `href="v2rayng://..."` 这类自定义 scheme 过滤成 `#ZgotmplZ`。
规避方式（`theme/index.html` 已实现）：URL 放 `data-*` 属性或 `<script>` 里的 JS 字符串，再在 JS 里跳转。

---

## 5. Reality 密钥：有现成 API

`GET /panel/api/server/getNewX25519Cert` → `{"privateKey": "...", "publicKey": "..."}`
（`service/server.go:2666 GetNewX25519Cert`，内部 `exec xray x25519`）

不用自己造 x25519，也不用碰数据库。

---

## 6. 三条落地路线（选一条）

### 路线 A：外壳仓库（**本仓库采用**）

```
客户机器: install.sh → 官方 install.sh → REST API 建节点 → 独立 portal 服务 → 8080
```

- ✅ 上游升级零冲突，`x-ui update` 安全
- ✅ 全部逻辑是 bash + 一个 Go 小服务，改起来快
- ✅ 出问题好定位（分层清晰）
- ❌ 8080 页面是"我们自己的"，跟面板的订阅页是两套 UI（但数据同源，不冲突）
- ❌ 多一个 systemd 服务（`xui-portal`）

### 路线 B：只换皮，不写门户

`subThemeDir` + 把 8080 反代到 `2096` 的订阅页。
最省事，官方订阅页自带二维码 + 8 客户端跳转 + 流量统计。
代价：页面结构受 `__SUB_PAGE_DATA__` 限制，一个 subId 一页（多客户要多个链接）。

### 路线 C：真 fork，改 Go

在 `internal/web/controller/` 加 `portal.go`，注册到 `web.go:259` 的 `g` 路由组，
`//go:embed` 自己的 HTML。好处是同一个进程、同一个端口、能读 DB；代价：

- 需要前端构建（`go:embed internal/web/dist`，得先 `cd frontend && npm run build`）
- 上游 rebase 要重打补丁（v3 迭代很快，平均每周都有改动）
- 客户机器上要发自己的二进制（多架构 × 签名）

**建议**：先用 A 上线跑通商业闭环；等量大了、真要"完全去品牌化"再转 C。

---

## 7. v3 里值得用但容易忽略的能力

| 能力 | 位置 | 场景 |
|---|---|---|
| 多节点管理（master/slave） | `/panel/api/nodes/*`、`model.Node` | 一台面板管 N 台落地机，客户只连 master |
| Host 表（per-inbound 订阅覆写） | `/panel/api/hosts/*`、`sub/host_sub.go` | 同一节点对不同客户显示不同域名/备注 |
| 订阅 HWID 设备限制 | `sub/hwid_controller_test.go`、`client_hwid.go` | 防订阅链接被分享给多人 |
| 流量日历重置 | `trafficReset: hourly/daily/weekly/monthly` | 机场套餐按月清零 |
| fail2ban 自动配置 | `install.sh setup_fail2ban` | `limitIp` 真正生效的前提 |
| 订阅公告/客服/标题 | `subTitle` `subAnnounce` `subSupportUrl` | 门户页放你的品牌与客服 |
| 外部订阅聚合 | `sub/external_subscription.go` | 把上游/兄弟机场的订阅混进自己的 |
| Happ/Incy 专有订阅参数 | `sub/happ.go`、`sub/incy.go` | 这俩客户端的专属优化字段 |

---

## 8. 实测验证（2026-11，Xray 26.11.9）

这套编排不是纸面推演，7 个协议配置用真实 xray 二进制跑过：

```
$ xray run -test -c xray-test.json
Configuration OK.

$ xray run -c xray-test.json
[Warning] core: Xray 26.11.9 started
$ lsof -nP -i | grep xray
TCP *:12087   # trojan-ws
TCP *:12088   # vless-xhttp
TCP *:1443    # vless-reality
TCP *:18388   # ss2022
TCP *:18443   # vless-ws
TCP *:18880   # vmess-ws
UDP *:1443    # hysteria2    ← 与 TCP 1443 同端口共存
UDP *:18388   # ss2022 udp
```

### 实测中发现并修掉的两个真问题

**1. Hysteria2 的传输层不是 `tcp`**

3x-ui 仓库里的 golden fixture `frontend/src/test/golden/fixtures/inbound-full/hysteria-tls.json`
写的是 `"network": "tcp"`，但那是**前端测试数据**，直接拿去给 xray 会炸：

```
Failed to start: main: failed to create server > proxy/hysteria: not hysteria transport
```

正确写法（依据 `internal/util/link/outbound.go:616` 与 `model.go:275` 的 heal 逻辑）：

```json
"streamSettings": {
  "network": "hysteria",
  "hysteriaSettings": { "version": 2, "udpIdleTimeout": 60 },
  "security": "tls",
  "tlsSettings": { "alpn": ["h3"], ... }
}
```

另外 `settings.version` 和 `streamSettings.hysteriaSettings.version` **都必须是 2**
（`HealHysteriaVersion` / `HealHysteriaStreamVersion` 就是在补这个），
写错会让**整台机器的 xray 起不来**，不只是 hysteria 节点。

**2. Reality 的 target 别用 microsoft**

```
[Warning] REALITY: Choosing "www.microsoft.com" as the target will increase
the likelihood of your server's IP being blocked by the GFW
```

默认目标已改为 `www.apple.com`。可选项：`www.apple.com`、`swdist.apple.com`、
`dl.google.com`、`www.cloudflare.com`（要求：支持 TLS1.3 + HTTP/2，且在你客户网络可达）。

另外 xray 还会提示「Reality 监听非 443 端口会提高被封概率」—— 生产环境 Reality 就放 443。

---

## 9. Xray 26 的弃用信号（做产品必须知道）

`xray run -test` 在 2026 版已经会对这些配置打 deprecation 警告：

| 配置 | 警告 | 官方建议 |
|---|---|---|
| WebSocket 传输 | `WebSocket transport ... is deprecated ... migrate to XHTTP H2 & H3` | 换 **XHTTP** |
| Trojan（无 flow） | `Trojan (with no Flow) is deprecated` | 换 VLESS + Flow |
| Shadowsocks（无 FS） | `Shadowsocks (with no Forward Secrecy) is deprecated` | 换 VLESS Encryption |
| VMess（无 FS） | `VMess (with no Forward Secrecy) is deprecated` | 换 VLESS Encryption |

**对二开的含义**：

1. 新部署的主力应该是 **VLESS + Reality + Vision**，备用 **VLESS + XHTTP + TLS**（3x-ui 已支持，
   `network:"xhttp"` + `xhttpSettings:{path,host,mode}`）。
2. WS / Trojan / SS / VMess 还能用，但属于"给老客户端兜底"的过渡方案，不要当卖点宣传。
3. 本仓库已把 `xhttp` 加进默认编排（`--protocols reality,hy2,xhttp,ws,trojan,ss,vmess`）；
   `ws` 保留只是为了兼容不吃 XHTTP 的旧客户端。
4. 如果客户端的 Clash/mihomo 版本较老，XHTTP 可能不认 —— 这就是要同时留 WS 的原因。

---

## 10. 真机实测：189.105.70.85（Debian 12 / 1C1G）发现的 17 个 bug

这一节是**实际部署一遍**后回填的。前 9 个是本地也踩到的，后 7 个只有真机才会暴露。

### A. 设置类

**1. `POST /panel/api/setting/update` 的 body 必须平铺**

```go
// controller/setting.go:36
type updateSettingForm struct {
    entity.AllSetting       // ← 内嵌，JSON 字段提升到顶层
    TwoFactorCode string
}
```

传 `{"allSetting":{...}}` 会让所有字段反序列化成零值，然后被 `validate:"gte=1"` 拦下：
`request body failed validation` + `issues:[{field:"webPort",rule:"gte",param:"1"}]`。

**这次是 validator 救了一命**——如果没有校验，`webPort=0` 直接把面板写死。

正确：`{"webPort":20000,"subPath":"/s/",...}`。

**2. `subUpdates` 是 `int`，不是 `string`**

```go
SubUpdates int `json:"subUpdates" validate:"gte=0,lte=525600"`
```

DB 里存的是字符串 `"12"`，但 API 层是 int。写 `"12"` → 反序列化失败 →
表面现象是 `request body failed validation`，实际是 JSON 类型不匹配。

**3. 失败信息要打 `obj.issues`**

`jsonMsg` 只给一句 `request body failed validation`，真正的原因在
`obj.issues[].field/rule`。不打印这个，排障全靠猜。

### B. API token 类（最阴的坑）

**4. `x-ui setting -getApiToken` 每次调用都会轮换 token**

CLI 帮助原文：*"Print an API token for CLI use, **regenerating it and invalidating the previous one**"*。

后果：脚本阶段 1 取一次（写进变量），阶段 5 又调了一次 → `portal.json` 里写的是第二次的值，
但真正在用的是第一次 → 门户所有 API 调用 401 → 页面 **502**。

修复：token 落盘到 `/etc/xui-onekey/api.token`，每次先探活（`GET server/status`）再决定是否重建。

**5. 门户 502 只有一个原因：面板 API 401**

`portal` 的所有数据来自 `inbounds/list` + `inbounds/allLinks`。token 失效 →
`panel api ...: http 401` → `http.Error(w, ..., 502)`。所以看到 502 先查 token，
不要查网络。

### C. 编排类

**6. Hysteria2 的传输层是 `hysteria`，不是 `tcp`**

```
Failed to start: proxy/hysteria: not hysteria transport
```

3x-ui 仓库里的 golden fixture 写的是 `"network":"tcp"`（前端测试数据），照抄必炸。
正确：

```json
"streamSettings": {
  "network": "hysteria",
  "hysteriaSettings": { "version": 2, "udpIdleTimeout": 60 },
  "security": "tls", "tlsSettings": { "alpn": ["h3"], ... }
}
```

且 `settings.version` 与 `streamSettings.hysteriaSettings.version` **都必须是 2**。

**7. WS 的 ALPN 不能带 `h2`**

服务端 `alpn:["h2","http/1.1"]` + 客户端协商到 h2 → WS 握手卡死（无报错、纯超时）。
实测三组对照：

| 服务端/客户端 alpn | 结果 |
|---|---|
| `["http/1.1"]` | ✅ 204 |
| `["h2","http/1.1"]` | ❌ 超时 |
| `["http/1.1"]` + host 留空 | ✅ 204 |

XHTTP 可以带 h2，WS/Trojan-WS/VMess-WS 只能 http/1.1。

**8. `--force` 更新节点会把 clients 清空**

`UpdateInbound` 里：

```go
// inbound.go:2116
// The form posts back the clients and enable it loaded; both have their
// own endpoints, so only a master's push may change them here.
inbound.Settings = keepStoredClients(inbound.Settings, stored.Settings)
```

提交的 clients 被丢弃，保留 DB 里的。所以**不能用 update 增删客户端**（增删要走
`/panel/api/clients/add|del|update`）。我第一次重建时删了 client 再 update →
7 个节点全部 `clients=[]`，订阅 0 条链接。

**9. subId 在 `clients/add` 里是唯一的**

```
{"success":false,"msg":"subId already in use: da2556b23a642541"}
```

所以"多个 email 共享一个 subId"这条路走不通。一个订阅含全部节点的唯一模型是：
**同一个 email 挂多个 inbound**（`exempts a matching subId` 说的是这个）。

**10. 同一 email 跨 inbound 时，id/password/auth 是全局共享字段**

实测：trojan 的 32 位 hex 密码被 SS2022 的 base64 密钥覆盖 →
服务端 `settings.clients[0].password=399b...`，链接里却是 `XSY6...` →
Trojan 认证失败（表现为 TCP 连上、无错误、纯超时）。

修复：**所有协议共用同一份 id/password/auth**。Trojan 密码是任意字符串，
直接用 SS2022 的 base64 客户端密钥即可。

### D. 证书类（2026 年最大的变化）

**11. xray 26 已移除 `allowInsecure`**

```
The feature "allowInsecure" has been removed and migrated to
"pinnedPeerCertSha256"(pcs) and "verifyPeerCertByName"(vcn).
```

自签证书的节点，客户端不能再"勾选忽略证书"。要么 `pcs`（证书指纹），要么 `vcn`。

**12. `pinnedPeerCertSha256` 必须是 **hex**，不是 base64**

```
encoding/hex: invalid byte: U+0059 'Y'
```

64 位小写 hex，`openssl x509 -outform DER | openssl dgst -sha256 -hex` 就是。

**13. 服务端要主动把 pin 写进订阅链接**

3x-ui 从 `tlsSettings.settings.pinnedPeerCertSha256`（数组）生成链接里的
`pcs=`（vless/ws）或 `pinSHA256=`（hysteria2），从 `tlsSettings.settings.verifyPeerCertByName`
生成 `vcn=`（`sub/service.go:1669`）。这些字段是 panel-only，不会进 xray 运行配置。

所以只要在建节点时写好，客户端扫码就能直连自签证书节点——**不用教用户改设置**。

**17. `/sub/<id>` 的 UA 自适应默认是关的**

`subClashAutoDetect` / `subJsonAutoDetect` 出厂 `false`（`setting.go:106/109`）。
不开的话，Clash 用户拉 `/sub/<id>` 只会拿到 base64 链接列表 → 导入后空配置。
开着之后实测：

| UA | 返回 |
|---|---|
| `clash-verge` / `mihomo` | Clash YAML |
| `sing-box` | sing-box JSON |
| `v2rayN` / `Shadowrocket` / `Happ` | base64 链接列表 |
| 浏览器（`Accept: text/html`） | HTML 订阅页 |

这才是"一个订阅 URL 通吃所有客户端"的开关。本仓库在阶段 3 已强制打开，
并自定义了 UA 正则覆盖 stash/flclash/verge 与 hiddify/karing。

### E. 脚本类

**14. 日志写 stdout 会污染 `$( )` 捕获**

`CRT="$(ensure_self_signed)"` 里如果函数内 `echo` 了日志，证书路径变成
`"[·] 生成自签证书...\n/etc/.../self.crt"` → 写进 inbound → xray 起不来。
所有 `ok_log/ok_info` 必须写 stderr。

**15. `set -o pipefail` + `head -c` = 随机退出码 141**

```bash
tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16   # head 提前关闭 → tr 收到 SIGPIPE → 141
```

在 `set -euo pipefail` 下整条命令失败 → 脚本无声退出。改用纯 bash 截取或 awk。

**16. 重跑时 `PANEL_PORT` 被 state.env 的旧值覆盖**

第一次跑的 state 里存了 20001（当时 20000 被占），面板实际在 20000 →
summary 显示错误端口。修复：阶段 1 结束后用 CLI 真实值回写 state。

---

## 11. 修复后的验收结果

```
# 7 个协议，用订阅链接里的真实参数，xray 客户端直连
vless-tcp    204  egress=189.105.70.85    ← VLESS+Reality+Vision
hy2          204  egress=189.105.70.85    ← Hysteria2
vless-xhttp  204  egress=189.105.70.85    ← XHTTP
vless-ws     204  egress=189.105.70.85    ← WS
trojan-ws    204  egress=189.105.70.85    ← Trojan
ss2022       204  egress=189.105.70.85    ← Shadowsocks 2022
vmess-ws     204  egress=189.105.70.85    ← VMess
--- 通过 7/7
```

门户自检：`200`、7 个节点卡、流量统计 299.67 KB / 不限、12 个客户端入口全部可点。
幂等：连续重跑 `install.sh` 与 `provision-nodes.sh` 均无报错、不重复建节点、不换密码。
