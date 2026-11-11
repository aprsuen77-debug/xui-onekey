# 部署流程与排障

## 1. 端到端时序

```
客户                   bootstrap.sh            install.sh             3x-ui              8080 portal
 │                          │                      │                     │                    │
 ├─ curl | bash ───────────>│                      │                     │                    │
 │                          ├─ 拉 tarball 到 /opt ─>│                     │                    │
 │                          └─ exec install.sh ────>│                     │                    │
 │                                                  ├─ 阶段0 预检          │                    │
 │                                                  ├─ 跑官方 install.sh ─>│                    │
 │                                                  │                     ├─ 装 xray+写 DB     │
 │                                                  │<─ 等端口/API ready ──┤                    │
 │                                                  ├─ x-ui setting -getApiToken              │
 │                                                  ├─ GET server/getNewX25519Cert            │
 │                                                  ├─ POST inbounds/add ×6 ─────────────────>│
 │                                                  │                     ├─ 重启 xray(合并)   │
 │                                                  ├─ POST setting/update（subPath/subURI）   │
 │                                                  ├─ 写 portal.json + systemd ──────────────>│
 │                                                  │                     │                    ├─ 起 :8080
 │<─ 终端凭据卡 + 二维码 ────────────────────────────┤                     │                    │
 ├─ 手机打开 http://IP:8080/p/<token>/ ─────────────────────────────────────────────────────>│
 │                                                  │                     │<─ GET inbounds/list ┤
 │<─ 节点卡片 + 12 个客户端一键导入 ───────────────────────────────────────────────────────────┤
 ├─ 点 v2rayNG → v2rayng://install-config?url=... ─> 客户端拉 /sub/<id> ───> 2096 <───────────┤
```

## 2. 每阶段的输入 / 输出 / 失败点

### 阶段 0 预检

| | |
|---|---|
| 输入 | `--host`（或自动探测公网 IP） |
| 输出 | `HOST / PANEL_PORT / PORTAL_PORT / ADMIN_PASS / PORTAL_TOKEN` |
| 失败点 | 探测不到公网 IP（NAT 机器）→ 脚本退出，需 `--host` 手动指定；`timedatectl` 失败不阻断 |

**判断**：客户机器如果在内网/NAT 后面（家宽、部分云厂商弹性 IP 未绑定），节点做出来也用不了。
上线前先确认 `curl ifconfig.me` 返回的 IP 从外网能通。

### 阶段 1 装面板

| | |
|---|---|
| 输入 | `XUI_*` 环境变量 |
| 输出 | `/usr/local/x-ui/`、`x-ui.service`、`/etc/x-ui/install-result.env` |
| 失败点 | GitHub 直连超时（**最常见**）；官方 install.sh 里 releases 下载没走镜像；端口被占 |

**兜底**：如果客户机器实在拉不动 GitHub，把 `x-ui-linux-<arch>.tar.gz` 提前放到自己的对象存储，
`XO_MIRROR_GH_PREFIX` 指向它（只要前缀拼得上路径即可）。

### 阶段 2 证书

| | |
|---|---|
| 分支 | 有域名+邮箱 → acme.sh standalone（需 80 空闲）；否则 → 自签 |
| 输出 | `/etc/xui-onekey/certs/{fullchain,privkey}.pem` 或 `{self.crt,self.key}` |
| 失败点 | 80 被占（Nginx/Apache 在跑）；DNS 未解析到本机；Let's Encrypt 限流 |

**判断**：只有 IP 的机器别折腾证书。Reality 不需要证书，HY2 自签 + 客户端勾"允许不安全"就行。
ACME 失败脚本会自动回落到自签，不会中断。

### 阶段 3 订阅配置

| | |
|---|---|
| 动作 | `POST setting/all` → jq 改 → `POST setting/update` |
| 改的字段 | `subPort` `subPath=/s/` `subJsonPath` `subClashPath` `subClashEnable=true` `subURI/subJsonURI/subClashURI` `trustedProxyCIDRs` |
| 失败点 | `setting/update` 是**全量覆盖**语义（遍历 `AllSetting` 所有字段写库），所以必须先读再整包回写 |

**坑**：`UpdateAllSetting` 用反射遍历结构体字段逐个写库（`service/setting.go:1702`），
漏传的字段会被写成零值。**永远不要只 POST 一个 `{"subPath":"/s/"}`**。

**坑**：`subDomain` 一旦设置，`sub.DomainValidatorMiddleware` 会校验请求 Host 必须匹配，
8080 反代（Host 是 `IP:8080`）会被 403。所以本方案**故意不设 subDomain**，改用 subURI 钉地址。

### 阶段 4 建节点

| | |
|---|---|
| 动作 | 6 次 `POST /panel/api/inbounds/add` |
| 幂等 | 按 `tag` 判重；`--force` 走 `update/<id>` |
| 失败点 | Reality 密钥接口失败；端口被别的服务占；`settings` JSON 结构不合法；email 重复但 subId 不同 |

**坑（重启风暴）**：每次 add 都会 `SetToNeedRestart()`，xray 可能反复重启。
6 个节点串行加完通常只重启 1-2 次（runtime 有合并），但如果发现 `journalctl` 里 xray 疯狂重启，
就把 `--protocols` 拆成两批跑。

### 阶段 5 门户

| | |
|---|---|
| 动作 | 编译/下载二进制 → 写 `portal.json` → systemd → 健康检查 |
| 输出 | `http://IP:8080/p/<token>/` |
| 失败点 | 客户机器没 go 且没配 `XO_REPO_RAW`（二进制下不到）；8080 被占；SELinux 限制端口绑定（RHEL 系） |

### 阶段 6 收尾

防火墙按协议清单放通；`summary.txt` 落盘；终端打订阅二维码。

---

## 3. 排障手册

| 症状 | 原因 | 处理 |
|---|---|---|
| `install.sh` 卡在下载 | GitHub 不通 | `XO_MIRROR_GH_PREFIX=https://ghproxy.net/` 重跑 |
| 面板打不开 | 端口没放通 / 云安全组 | 检查 `ufw status`、云厂商安全组、`ss -ltnp \| grep x-ui` |
| 面板打开 404 | `webBasePath` 不是 `/` | 访问 `http://IP:PORT<basePath>`，或 `x-ui setting -show` 看 |
| 面板能开但节点连不上 | 端口未放通 / 节点配置错 | `xray run -test -c /usr/local/x-ui/bin/config.json` 校验；`journalctl -u x-ui -n 50` |
| Reality 握手失败 | 时间偏移 > 2 分钟 | `timedatectl` 确认 NTP 同步；客户端与服务端时区无关但时间要对 |
| Reality 握手失败 | SNI 目标不支持 TLS1.3/H2 | 换 `--reality-sni www.microsoft.com` / `dl.google.com` / `www.apple.com` |
| HY2 连不上 | 客户端未允许自签证书 | sing-box 里 `tls.insecure=true`；或换真证书 |
| 订阅被客户端拒绝 | 用了 http 且客户端强制 https | 用 443/域名 + 反代，或客户端允许明文 |
| 订阅里节点地址是 127.0.0.1 | 没设 subURI / 反代没传 X-Forwarded-Host | 设 subURI（本方案默认已设） |
| 8080 打开是 404 | token 路径不对 | 看 `/etc/xui-onekey/summary.txt` |
| 8080 打开 502 | 面板 API token 失效 | `x-ui setting -getApiToken` 重新取，更新 `portal.json` 后 `systemctl restart xui-portal` |
| 客户订阅流量不显示 | 没走 `/sub/<id>` 而是直接拿节点链接 | 只有订阅 URL 才带 `subscription-userinfo` 头 |
| 客户把订阅分享出去 | subId 泄漏 | 面板改该客户 subId；开 HWID 限制或 `limitIp` |
| 升级后 8080 挂了 | token 被轮换 / 设置被重置 | 重跑 `install.sh`（幂等，会重新对齐配置） |

---

## 4. 二次开发的扩展点

### 加一个协议

1. 在 `frontend/src/test/golden/fixtures/inbound-full/` 找对应模板（或从面板手工建一个，然后
   `GET /panel/api/inbounds/get/<id>` 把 JSON 抄下来）
2. 在 `scripts/provision-nodes.sh` 里加 `payload_xxx()` + 分支
3. 端口常量加到顶部，`install.sh stage_finish` 的防火墙清单同步

现成模板：`vless-tcp-reality.json` `vless-ws-tls.json` `vmess-tcp-tls.json` `trojan-ws-tls.json`
`hysteria-tls.json` `shadowsocks-tcp-2022.json` `wireguard-server.json` `masque-tls.json`

### 改成"一案一客户"

现在是一个客户看全部节点。要卖套餐（多客户各看一部分）时：

- 建多个 inbound（每客户一组端口）或一个 inbound 多 client
- 每个 client 独立 `email` + `subId`
- 8080 门户改成按客户 token 映射到 subId（`portal.json` 加 `clients: [{token, subId, name}]`）
- 更省事：直接给每个客户发订阅链接，不用 8080 门户

### 改成一主多从（一台面板管多台落地）

- 走 `/panel/api/nodes/*` 把落地机加成 node
- inbound 建在 node 上（`nodeId` 字段）
- 订阅时链接地址取 `node.address`（`resolveInboundAddress` 优先用 nodeAddr）

### 彻底去品牌（不出现在面板）

路线 C：fork 后改 `internal/web/dist`（前端品牌）+ `internal/sub/controller.go`（订阅页），
再用 `subThemeDir` 换成自己的模板。不建议动 Go 逻辑层。

---

## 5. 上线前 checklist

- [ ] 真机跑通一次 `install.sh`（Debian 12 + Ubuntu 22 各一次）
- [ ] 6 个节点在 `xray -test` 下配置合法
- [ ] v2rayNG（Reality）、sing-box（HY2）、Clash Verge（clash 订阅）各实测连通
- [ ] 8080 三大订阅 URL 都能拉出正确内容（`curl -A "clash-verge" .../sub/<id>` 看返回 YAML）
- [ ] 手机扫码 → 客户端跳转导入成功
- [ ] 云安全组放通：面板端口、8080、443/tcp+udp、8443、2087、8388
- [ ] `portal.json` 权限 600，`summary.txt` 权限 600
- [ ] 面板端口不是 2053/443，路径不是 `/`
- [ ] 试一次 `x-ui update`，确认 8080 与节点都没坏
- [ ] 试一次重复执行 `install.sh`，确认幂等不报错
