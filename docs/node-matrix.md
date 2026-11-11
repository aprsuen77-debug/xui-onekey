# 协议 / 端口 / 客户端 兼容矩阵

## 1. 端口规划

**规则**：TCP 与 UDP 是两套独立端口空间，同号不冲突。所以 `443/tcp`（Reality）和
`443/udp`（Hysteria2）可以共存 —— 这是现在最主流的组合。

| 端口 | 协议 | 说明 | 冲突风险 |
|---|---|---|---|
| 443/tcp | VLESS + Reality + Vision | 主力，无证书，抗封锁最强 | 与系统 Nginx/网站冲突 |
| 443/udp | Hysteria2 | 弱网加速，QUIC | 与 HTTP/3 网站冲突 |
| 8443/tcp | VLESS + WS + TLS | 可挂 CDN、可中转（xray 已标记 deprecated） | 低 |
| 2088/tcp | VLESS + XHTTP + TLS | **WS 的现代替代**，抗封锁更好 | 低 |
| 2087/tcp | Trojan + WS + TLS | 老客户端兜底 | 低 |
| 8388/tcp+udp | Shadowsocks 2022 | 轻量 | 低 |
| 8880/tcp | VMess + WS + TLS | 极老客户端兜底 | 低 |
| 2096/tcp | 3x-ui 订阅服务 | 只给本机反代，**不要对公网开** | 面板内部用 |
| 8080/tcp | xui-portal | 客户看到的唯一入口 | 常见 Web 端口，可能被占 |
| 随机 20000-60000 | 3x-ui 面板 | 不要用 2053/443 | — |

改端口：`scripts/provision-nodes.sh` 顶部 6 个常量 + `install.sh stage_finish` 的防火墙清单。

---

## 2. 协议 × 客户端矩阵

分档：✅ 原生支持 ｜ ⚠️ 需较新版本/需特定内核 ｜ ❌ 不支持

| 客户端 | 平台 | 内核 | VLESS+Reality | Hysteria2 | TUIC | SS2022 | Trojan | VMess |
|---|---|---|---|---|---|---|---|---|
| v2rayNG | Android | Xray | ✅ | ⚠️ 新版 | ❌ | ✅ | ✅ | ✅ |
| v2rayN | Windows | Xray | ✅ | ⚠️ 新版 | ❌ | ✅ | ✅ | ✅ |
| NekoBox / NekoRay | Android/Win | sing-box | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Clash Verge Rev | Win/macOS | mihomo | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Mihomo Party | Win/macOS | mihomo | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| FlClash | 全平台 | mihomo | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| sing-box 官方 | 全平台 | sing-box | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Shadowrocket | iOS | 自研 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Stash | iOS/macOS | Clash | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| Loon | iOS | 自研 | ⚠️ | ✅ | ❌ | ✅ | ✅ | ✅ |
| Quantumult X | iOS | 自研 | ⚠️ | ⚠️ 新版 | ❌ | ⚠️ | ✅ | ✅ |
| Streisand | iOS/macOS | Xray | ✅ | ⚠️ | ❌ | ✅ | ✅ | ✅ |
| V2Box | iOS/Android | Xray | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| Happ | 全平台 | Xray | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| V2RayTun | iOS/Android | Xray | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ |
| Karing | 全平台 | sing-box | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Hiddify | 全平台 | sing-box | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Incy | iOS/Android | 自研 | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| Foxray | iOS | Xray | ✅ | ⚠️ | ❌ | ✅ | ✅ | ✅ |

**XHTTP 支持度**（`network:"xhttp"`）：mihomo ≥1.18 / sing-box ≥1.10 / Xray ≥25 系支持；
v2rayNG 需 ≥1.9。老版本客户端会直接不认这条链接 —— 所以 WS 要留着兜底。

**结论**：只要提供 **Reality + Hysteria2 + SS2022** 三条，就已经覆盖 99% 的客户端；
再补 VLESS-WS 给 CDN 场景、Trojan 给老 iOS 客户端、VMess 给极老客户端。

> 判断依据是各客户端内置内核：Reality 只有 Xray 系内核与 mihomo ≥1.16 支持；
> Hysteria2/TUIC 需要 sing-box 系或 mihomo；SS2022 需要 2022 版本的实现（老客户端只有 aes-256-gcm）。
> 若客户反馈"导入后某个节点不可用"，先去查他的客户端内核版本，而不是改服务端。

---

## 3. 一键导入 deeplink（可直接拼到页面按钮上）

`SUB` = 订阅 URL，`NAME` = 显示名。**官方验证过的 8 个**（来源：3x-ui
`frontend/src/pages/sub/subPageModel.ts` `buildSubApps()`）：

| 客户端 | deeplink |
|---|---|
| v2rayNG | `v2rayng://install-config?url=<URLENC(SUB)>` |
| V2Box | `v2box://install-sub?url=<URLENC(SUB)>&name=<URLENC(NAME)>` |
| Shadowrocket | `shadowrocket://add/sub://<BASE64(SUB?flag=shadowrocket)>?remark=<URLENC(NAME)>` |
| Sing-box | `sing-box://import-remote-profile?url=<URLENC(SUB)>#<URLENC(NAME)>` |
| Streisand | `streisand://import/<URLENC(SUB)>` |
| Happ | `happ://add/<SUB>`（不要 URL 编码） |
| V2RayTun | `v2raytun://import/<SUB>`（不要 URL 编码） |
| Incy | `incy://add/<SUB>`（不要 URL 编码） |

社区通用、实测可用的补充：

| 客户端 | deeplink |
|---|---|
| Clash / ClashX / FlClash | `clash://install-config?url=<URLENC(CLASH_SUB)>` |
| ClashX | `clashx://install-config?url=<URLENC(CLASH_SUB)>` |
| Hiddify | `hiddify://install-config/?url=<URLENC(SUB)>` |
| Karing | `karing://install-config?url=<URLENC(SUB)>&name=<URLENC(NAME)>` |
| NekoRay | `sn://subscription?url=<URLENC(SUB)>&name=<URLENC(NAME)>` |
| Happ 加密订阅 | `happ://crypto/<CRYPTO_SUB>` / `happ://crypto2/<CRYPTO_SUB>`（用 happ.su 的加密工具生成） |

**踩坑记录**

1. `v2rayng://install-sub?url=` 与 `v2rayng://install-config?url=` 两个都有人用，
   官方用的是 `install-config`（v2rayNG ≥1.8.28 也支持 `install-sub/?url=`）。
2. `Happ` / `V2RayTun` / `Incy` 的 URL 是**直接拼在路径里**的，不能 URL 编码，否则客户端解析失败。
3. `Shadowrocket` 的 `SUB?flag=shadowrocket` 是官方特意加的 UA 标记（让服务端返回 iOS 友好格式），
   别省掉；`btoa()` 对纯 ASCII URL 等价于 `base64.StdEncoding`。
4. deeplink 里的 `#` 之后必须用 `%20` 表示空格，**不能用 `+`**（fragment 不做 query 解码）。
5. 桌面端（Windows/macOS）的 Clash/V2rayN 一般不吃 deeplink，只能复制订阅链接手动粘贴 ——
   门户页要把"复制订阅"做成主按钮。

---

## 4. Reality 参数建议

| 参数 | 建议 | 原因 |
|---|---|---|
| `target` / `serverNames` | `www.microsoft.com:443`（默认）、`dl.google.com`、`www.apple.com`、`swdist.apple.com` | 必须支持 TLS 1.3 + HTTP/2，且在你客户所在网络可达 |
| `shortIds` | 随机 4-8 位 hex，可配多个 | 长度必须是偶数；多个 sid 便于轮换 |
| `flow` | `xtls-rprx-vision`（仅 TCP） | 与 Reality 组合才有效；WS 下必须为空 |
| `fingerprint` | `chrome`（或 `firefox`/`safari`/`ios`/`android`） | 客户端 uTLS 指纹，与服务端无关但要合法 |
| `spiderX` | `/` | 抓站路径，别设太诡异 |
| `maxTimediff` | 0（不限制） | 机器时间不准时限制会直接连不上 |

**注意**：Reality 的 `settings.publicKey` 必须与 `privateKey` 配对（`provision-nodes.sh` 用
`GET /panel/api/server/getNewX25519Cert` 一次性取一对）。手工改 privateKey 而忘了改 publicKey
= 客户端永远握手失败。

---

## 5. 自签证书场景下客户端设置

只有 IP、没签真证书时，以下客户端需要显式放行：

| 客户端 | 设置 |
|---|---|
| v2rayN / v2rayNG | 节点设置里勾 "允许不安全 / Allow Insecure" |
| sing-box | `"tls": {"insecure": true}`（3x-ui 生成的链接里带 `insecure=1`） |
| Clash / mihomo | `skip-cert-verify: true` |
| Shadowrocket | 打开 "允许不安全" 开关 |
| Happ / V2Box | 一般会自动跟随链接里的 `allowInsecure` |

Reality 节点**不需要**这一项（它不做证书校验，走 X25519 握手）。
