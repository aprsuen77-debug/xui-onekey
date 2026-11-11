# xui-onekey —— 3x-ui 一键装机（面板 + 主流节点 + 8080 节点门户）

> 客户在服务器上执行一条命令 → 3x-ui 面板装好 → 6 个主流协议节点自动创建好 →
> 打开 `http://IP:8080/p/<token>/` 就是一个能扫码 / 一键跳转客户端的节点门户。

**核心取舍：不改 3x-ui 源码。**
所有节点创建走官方 REST API，品牌化走官方 `subThemeDir` 扩展点，8080 门户是独立小服务。
好处：`x-ui update` 随便升，上游 rebase 成本为 0；坏处：8080 页面的样式受限于我们的门户（就是本仓库的 `portal/`）。

真要在 3x-ui 进程内部加路由、改 logo、删品牌，参见 [docs/research.md](docs/research.md#路线-c真-fork改-go)。

---

## 0. 交互菜单（推荐给客户）

在服务器上直接跑脚本，会先出一个菜单：

```
  ┌────────────────────────────────────────────────┐
  │            routex  一键部署脚本                │
  └────────────────────────────────────────────────┘

   1) 只安装面板        routex 面板本体，不含节点
   2) 完整安装          面板 + 7 个主流节点 + 8080 节点门户
   3) 只重建节点        在已有面板上重排节点与订阅
   4) 只升级面板        换成最新的 routex 面板本体
   5) 卸载             移除面板与门户服务
   0) 退出

  请选择 [0-5，回车默认 2]:
```

- 交互菜单需要真正的终端：`bash <(curl -fsSL <bootstrap.sh 地址>)`，不要用 `curl | bash`（stdin 是管道，弹不出菜单）。
- 想跳过菜单直接跑：`bash install.sh --mode panel|full|nodes|upgrade|uninstall`，或环境变量 `XO_MODE=panel`。

## 0.5 自建分发源（不走 GitHub 也能装）

适合：先在内网/自有 VPS 上验证，或者客户机器访问 GitHub 困难。

服务端（一台能公网访问的机器）放三个文件到任意静态目录：

```
x-ui-linux-amd64      # routex 面板本体（75MB）
xui-onekey.tar.gz     # 本仓库源码包（含 bin/ 里的门户二进制）
bootstrap.sh          # 入口脚本
```

用 nginx / caddy / `python3 -m http.server` 对外提供即可，然后客户端：

```bash
# 1) 临时指定源（不改脚本）
XO_SRC_URL=http://你的服务器:8090/xui-onekey.tar.gz \
XO_ROUTEX_BIN_URL=http://你的服务器:8090/x-ui-linux-amd64 \
  bash <(curl -fsSL http://你的服务器:8090/bootstrap.sh)

# 2) 或者把 install-routex.sh 里的 ROUTEX_BASE 改成你的地址，客户端只需：
bash <(curl -fsSL http://你的服务器:8090/install-routex.sh)
```

`XO_SRC_URL` 有值时，`bootstrap.sh` 会自动把面板二进制也指向同一个源的 `x-ui-linux-amd64`，不需要再单独配。

## 1. 快速开始

### 方式 A：客户机器一条命令（交互菜单）

```bash
# 交互菜单（推荐，能选 1/2）
bash <(curl -fsSL https://raw.githubusercontent.com/yourname/xui-onekey/main/bootstrap.sh)

# 非交互（直接完整安装）
curl -fsSL https://raw.githubusercontent.com/yourname/xui-onekey/main/bootstrap.sh | bash -s -- --host 1.2.3.4
```

国内机器（GitHub 直连大概率超时）：

```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/yourname/xui-onekey/main/bootstrap.sh | \
  XO_MIRROR_GH_PREFIX=https://ghproxy.net/ bash -s -- --host 1.2.3.4
```

### 方式 B：git clone 后执行

```bash
git clone https://github.com/yourname/xui-onekey.git
cd xui-onekey
bash install.sh --host 1.2.3.4
```

### 带域名 + 真证书

```bash
bash install.sh --host node.example.com --acme-email you@example.com --remark-prefix "🇭🇰HK-"
```

### 只想要部分协议

```bash
bash install.sh --host 1.2.3.4 --protocols reality,hy2,ss
```

### 装完你会拿到

| 项目 | 地址 |
|---|---|
| 面板 | `http://IP:<随机端口><basePath>` |
| 节点门户 | `http://IP:8080/p/<随机token>/` |
| 通用订阅 | `http://IP:8080/sub/<subId>`（客户端按 UA 自动返回 raw / clash / sing-box） |
| Clash 订阅 | `http://IP:8080/clash/<subId>` |
| Sing-box 订阅 | `http://IP:8080/json/<subId>` |

全部结果落在 `/etc/xui-onekey/summary.txt`（600 权限）。

---

## 2. 目录结构

```
xui-onekey/
├── bootstrap.sh              # curl | bash 入口：拉仓库 → exec install.sh
├── install.sh                # 主流程：6 个阶段
├── scripts/
│   ├── lib.sh                # 公共函数（日志/端口/API/镜像）
│   └── provision-nodes.sh    # 用 REST API 建节点（可单独重跑，幂等）
├── portal/                   # 8080 门户（Go 单文件，零第三方依赖）
│   ├── main.go
│   ├── web/index.html        # 门户页模板（go:embed）
│   └── go.mod
├── theme/index.html          # 可选：3x-ui 订阅页换皮模板（subThemeDir）
├── ci/build.sh               # 交叉编译 4 个架构
├── bin/                      # 编译产物 xui-portal-linux-{amd64,arm64,armv7,386}
└── docs/
    ├── research.md           # 3x-ui v3 源码级研究结论（所有结论有出处）
    ├── flow.md               # 部署流程 + 时序 + 排障
    └── node-matrix.md        # 协议×端口×客户端兼容矩阵
```

---

## 3. 装机做了什么（6 阶段）

```
阶段0 预检      root/OS/arch/依赖/公网IP/时间同步/BBR/端口规划
阶段1 装面板    下载官方 install.sh（走镜像）→ 非交互安装 → 等 API 就绪 → 取 token
阶段2 证书      有域名+邮箱 → acme.sh 签真证书；否则 Reality + 自签证书
阶段3 订阅      固定 subPath=/s/，开 clash/json，设 subURI → 订阅统一走 8080
阶段4 节点      调 API 建 6 个 inbound（同 email + 同 uuid + 同 subId = 一个订阅含全部节点）
阶段5 门户      装 xui-portal（systemd），反代 /sub /json /clash，渲染节点页
阶段6 收尾      放通防火墙 → 生成 summary.txt → 终端打二维码
```

细节与坑：[docs/flow.md](docs/flow.md)

---

## 4. 默认节点编排

| 节点 | 协议 | 端口 | 用途 | 需要证书 |
|---|---|---|---|---|
| REALITY | VLESS + Reality + Vision | 443/tcp | 抗封锁主力，无证书 | ✗（Reality 自带） |
| HY2 | Hysteria2 | 443/udp | 弱网/移动网络加速，UDP 与 TCP 443 不冲突 | 自签即可 |
| XHTTP | VLESS + XHTTP + TLS | 2088/tcp | **WS 的现代替代**，抗封锁更好 | 自签或 ACME |
| VLESS-WS | VLESS + WS + TLS | 8443/tcp | 兼容老客户端 / 可挂 CDN | 自签或 ACME |
| TROJAN | Trojan + WS + TLS | 2087/tcp | 兼容老客户端 | 自签或 ACME |
| SS2022 | Shadowsocks 2022 | 8388/tcp+udp | 轻量、内核友好 | ✗ |
| VMESS-WS | VMess + WS + TLS | 8880/tcp | 仅老客户端兜底 | 自签或 ACME |

端口全在 `scripts/provision-nodes.sh` 顶部 6 行常量里，改完重跑即可。
协议×客户端矩阵：[docs/node-matrix.md](docs/node-matrix.md)

---

## 5. 已验证 / 待验证

**已在本机验证**

- **7 个节点配置用真实 Xray 26.11.9 校验并实跑**：`Configuration OK` + 全部端口同时监听
  （含 `443 tcp` 与 `443 udp` 同端口共存），详见 [docs/research.md](docs/research.md#8-实测验证2026-11xray-26119)
- 实测修掉两个致命问题：Hysteria2 的 `streamSettings.network` 必须是 `hysteria`（不是 `tcp`）；
  Reality target 不能用 microsoft 系（xray 明确警告易被封）
- `provision-nodes.sh` 用 mock 面板端到端跑通：7 个 payload 全部合法 JSON、幂等跳过/`--force` 更新分支正确
- `portal` 用 mock 面板 API 跑通：settings 字符串解析、流量/到期聚合、12 个客户端 deeplink
  （自定义 scheme 未被 html/template 过滤）、/healthz、根路径 302
- `theme/index.html` 用 html/template 渲染通过（无未注册模板函数）
- 4 个架构交叉编译通过（`ci/build.sh`）
- 全部 shell 脚本 `bash -n` 通过

**真机实测通过（2026-11-11，Debian 12 / 1C1G，IP 189.105.70.85）**

- `install.sh` 全流程跑通；连续重跑幂等无报错、不换密码、不重复建节点
- **7 个协议全部端到端可用**（用订阅链接里的真实参数 + xray 26.11.9 客户端直连）：

| 协议 | 结果 | 出口 |
|---|---|---|
| VLESS + Reality + Vision | 204 | 189.105.70.85 |
| Hysteria2 | 204 | 189.105.70.85 |
| VLESS + XHTTP | 204 | 189.105.70.85 |
| VLESS + WS | 204 | 189.105.70.85 |
| Trojan + WS | 204 | 189.105.70.85 |
| Shadowsocks 2022 | 204 | 189.105.70.85 |
| VMess + WS | 204 | 189.105.70.85 |

- 门户 `200`、7 个节点卡、流量统计正常、12 个客户端入口可点
- 真机暴露并修掉的 16 个 bug 见 [docs/research.md](docs/research.md#10-真机实测1891057085debian-121c1g发现的-16-个-bug)

**还需要在别的发行版上验证**

- Ubuntu 22 / Rocky 9（apt/dnf 路径差异）
- 有域名 + ACME 真证书的完整链路（当前只测了自签 + Reality）
- 手机真机扫码导入（桌面端已验证，手机端 deeplink 未逐一点过）

---

## 6. 必读的安全约束

1. **8080 门户 = 节点集市**。谁打开谁就能白嫖。本仓库默认 `/p/<随机 token>/`，`portal.json` 里 `open:false`。绝不要改成 `open:true` 放在公网。
2. **subId 就是凭据**。泄露后任何人可拉你的全部节点。3x-ui 面板里改客户 subId 即可一键作废旧订阅。
3. **面板端口不要用 2053/443/8080**，不要和节点端口重叠；本脚本默认随机 20000-60000。
4. 客户机器只有 IP 时走 Reality + 自签证书：HY2/Trojan 客户端要允许"不安全"，否则连不上。
5. 上线前把 `portal.json` 权限确认成 600（脚本已做），里面含 API token。

---

## 7. 常用运维

```bash
# 重跑建节点（幂等，只补缺失的）
bash /opt/xui-onekey/src/scripts/provision-nodes.sh --host 1.2.3.4

# 换个 SNI 重建 Reality
bash .../provision-nodes.sh --host 1.2.3.4 --reality-sni www.apple.com --force

# 看所有节点分享链接
cat /etc/xui-onekey/links.txt

# 门户日志
journalctl -u xui-portal -f

# 面板日志
journalctl -u x-ui -f

# 升级 3x-ui（不影响门户和节点）
x-ui update

# 改面板端口/路径
x-ui setting -port 23456
x-ui setting -webBasePath /mypanel

# 重发 API token（会作废旧的，记得同步 portal.json）
x-ui setting -getApiToken
```

卸载：

```bash
x-ui uninstall
systemctl disable --now xui-portal
rm -rf /opt/xui-onekey /etc/xui-onekey /etc/systemd/system/xui-portal.service
```
