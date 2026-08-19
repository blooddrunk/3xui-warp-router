# 3xui-warp-router

让 **3x-ui / Xray** 对 Google、Gemini、YouTube 等流量进行可控的 Cloudflare WARP 分流，同时尽量不碰系统全局路由。

> 面向已经使用 [3x-ui](https://github.com/MHSanaei/3x-ui) 的 VPS 用户。脚本复用 3x-ui 原生 WARP WireGuard outbound，不安装 `warp-cli`、`redsocks`，也不会通过 `iptables OUTPUT` 劫持系统流量。

当前版本：**v0.3.2**

## 它解决什么问题？

有些 VPS 的原生出口 IP 会被 Google 错误识别到不正确的地区，进而影响 Gemini、Google Search、AI Studio 或其他 Google 服务。

传统方案常见做法是：

```text
应用 -> iptables -> redsocks -> 本地 WARP SOCKS5 -> Cloudflare
```

`3xui-warp-router` 选择让 Xray 自己决定 outbound：

```text
客户端
  |
  v
3x-ui / Xray inbound
  |
  +-- Google / Gemini ----> Xray `warp` outbound ----> Cloudflare WARP
  |
  +-- YouTube -----------> direct（默认，可改为 WARP）
  |
  +-- 其他流量 ----------> 保留你原来的 Xray 路由
```

## 特点

- 使用 **3x-ui 原生 Cloudflare WARP WireGuard outbound**
- 不安装 `warp-cli`
- 不安装 `redsocks`
- 不修改 `iptables` / `nftables`
- 不修改 `/etc/gai.conf`
- 不创建 Google IPv6 黑洞路由
- 使用域名 / geosite 做 Xray 级精确分流
- 尽量保留已有 inbound、DNS、outbound 和 routing rules
- 修改前自动备份完整 Xray 配置
- 修改后自动 route test + WARP outbound test
- 验证失败时默认自动回滚
- 支持 3x-ui 原生 WARP 换 IP / 自动轮换
- 幂等：重复运行不会不断追加相同 managed rules
- 支持持久保存 API 配置，服务器重启后无需重新 export
- **v0.3.0：首次注册优先使用 3x-ui 自带 Xray 的 `wg` 子命令，不再把系统 `wg` 作为硬依赖**
- **v0.3.0：新增只读 `diagnose` 健康诊断命令**
- **v0.3.1：检查 client inbound 是否启用 sniffing，避免 domain/geosite route test 通过但真实 IP 流量无法按域名分流**
- **v0.3.2：使用 Xray `ruleTag` 标记 managed rules，不再把内部哨兵值写入实际 `domain` 列表；同时兼容清理 v0.3.1 生成的旧规则**

## 前置条件

推荐：

- Linux VPS
- 已安装并运行较新的 3x-ui
- Bash
- `curl`
- `jq`
- `base64`
- `od`

Debian / Ubuntu：

```bash
sudo apt update
sudo apt install -y curl jq coreutils
```

### 首次注册 WARP 还需要 `wireguard-tools` 吗？

**通常不需要。**

v0.3.0 起，首次注册流程依次尝试：

```text
3x-ui 自带 Xray 的 `xray wg`
        ↓ 不可用
系统 `wg genkey` / `wg pubkey`
        ↓ 仍不可用
给出明确的安装提示
```

脚本会自动寻找常见的 3x-ui Xray binary，例如：

```text
/usr/local/x-ui/bin/xray
/usr/local/x-ui/bin/xray-linux-amd64
/usr/local/x-ui/bin/xray-linux-arm64
```

也可以通过环境变量显式指定：

```bash
export XRAY_BIN='/path/to/xray'
```

只有 Xray 自带的 `wg` 子命令也不可用时，才需要 fallback：

```bash
sudo apt install -y wireguard-tools
```

> 安装 `wireguard-tools` 不会让整个 VPS 自动走 WireGuard；它仅用于生成首次注册 WARP 所需的密钥。

## 1. 获取 3x-ui API Token

打开 3x-ui：

```text
Settings -> Security -> API Token
```

创建 API Token。

脚本使用 Bearer Token 调用 3x-ui API，**不是面板登录密码**。

## 2. 安装 / 更新脚本

```bash
curl -fsSLo /usr/local/bin/3xui-warp-router \
  https://raw.githubusercontent.com/blooddrunk/3xui-warp-router/main/3xui-warp-router.sh

chmod 700 /usr/local/bin/3xui-warp-router
```

确认版本：

```bash
3xui-warp-router --version
```

当前应显示：

```text
0.3.0
```

也可以 clone：

```bash
git clone https://github.com/blooddrunk/3xui-warp-router.git
cd 3xui-warp-router
chmod +x 3xui-warp-router.sh
```

## 3. 一次性配置 3x-ui API

推荐：

```bash
3xui-warp-router configure \
  --api-base 'https://panel.example.com:2053/panel/api'
```

脚本会无回显询问 API Token，验证成功后保存到：

```text
~/.config/3xui-warp-router/config
~/.config/3xui-warp-router/token
```

Token 文件权限为 `0600`。

如果有 Web Base Path，例如：

```text
https://panel.example.com:2053/secret/
```

使用：

```bash
3xui-warp-router configure \
  --api-base 'https://panel.example.com:2053/secret/panel/api'
```

如果不希望保存 Token，也可以临时：

```bash
export XUI_API_BASE='https://panel.example.com:2053/panel/api'
export XUI_API_TOKEN='YOUR_API_TOKEN'
```

## 4. 推荐首次安装

Google / Gemini 走 WARP，YouTube 保持直连：

```bash
3xui-warp-router install \
  --profile google-web \
  --youtube direct
```

首次执行会：

1. 读取当前 Xray 配置。
2. 创建本地安全备份。
3. 检查是否已有 `warp` WireGuard outbound。
4. 如果没有 WARP 账号，优先使用 3x-ui 自带 Xray 生成 WireGuard keypair。
5. 如果 Xray `wg` 不可用，再尝试系统 `wg`。
6. 通过 3x-ui WARP API 注册账号并生成 native WireGuard outbound。
7. 检测 geosite 数据。
8. 合并本脚本管理的 routing rules。
9. 检查非 `api` client inbound 的 sniffing 状态；未启用时给出 WARNING。
10. 让 3x-ui/Xray 校验并保存配置。
11. 执行 route test 与真实 WARP outbound test。
12. 验证失败时默认回滚。

安装成功后建议立即：

```bash
3xui-warp-router diagnose
```

## `diagnose`：一次看清当前状态

v0.3.0 新增：

```bash
3xui-warp-router diagnose
```

这是一个**只读命令**：

- 不修改 routing
- 不重新注册 WARP
- 不换 WARP IP
- 不重启 Xray
- 不输出 API Token / WARP private key

它会一次检查：

- 3x-ui API 是否可访问、Token 是否有效
- Xray 配置是否为有效 JSON
- Xray route test API 是否响应
- 非 `api` client inbound 是否启用了 sniffing
- `warp` WireGuard outbound 是否存在
- WARP endpoint / `noKernelTun` 状态
- WARP outbound 实际连通性
- WARP egress IPv4 / IPv6
- WARP egress country
- Cloudflare trace 的 `warp` 状态
- Google 当前 route
- Gemini 当前 route
- YouTube 当前 route
- 3x-ui WARP 自动轮换间隔
- 本脚本 managed rule 数量
- 最终可读诊断结论

健康示例：

```text
========================================
3xui-warp-router diagnosis v0.3.2
========================================

[OK  ] 3x-ui API                reachable and authenticated
[OK  ] Xray config              valid JSON
[OK  ] Inbound sniffing         enabled on 1 client inbound(s)
[OK  ] Xray route API           responsive
[OK  ] WARP outbound            present (wireguard)
[INFO] WARP endpoint            engage.cloudflareclient.com:2408
[OK  ] WARP userspace           noKernelTun=true
[OK  ] WARP connectivity        success, delay=47
[INFO] WARP egress IPv4         104.x.x.x
[INFO] WARP egress country      US
[INFO] Cloudflare WARP          on
[OK  ] Direct outbound          direct
[OK  ] Google route             www.google.com -> warp
[OK  ] Gemini route             gemini.google.com -> warp
[OK  ] YouTube route            www.youtube.com -> direct
[INFO] WARP auto-rotation       disabled
[INFO] Managed rules            warp=1, direct=1

Conclusion:
  OK - Xray, WARP, managed routing, and rotation checks are healthy.
```

如果 Cloudflare trace 明确返回：

```text
warp=off
```

或者出口国家是：

```text
CN
```

`diagnose` 会给出 `FAIL` 并返回非 0 exit code。

如果当前 profile 本身**不要求** Google Search 走 WARP，例如更窄的 `gemini` profile，Google route 会作为信息展示，而不会被错误判成失败。

## Profile

### `google-web` — 推荐

```bash
3xui-warp-router install --profile google-web --youtube direct
```

优先：

```text
geosite:youtube -> direct
geosite:google  -> warp
```

geosite 不可用时退回显式 Google 域名列表。

### `gemini`

```bash
3xui-warp-router install --profile gemini --youtube direct
```

只覆盖 Gemini / AI Studio / Google AI API / 登录和必要静态依赖，减少其他 Google 流量经过 WARP。

### `google-all`

```bash
3xui-warp-router install --profile google-all --youtube warp
```

Google + YouTube 都走 WARP。

### `custom`

```text
# domains.txt
full:gemini.google.com
domain:aistudio.google.com
domain:generativelanguage.googleapis.com
geosite:google
```

```bash
3xui-warp-router apply \
  --profile custom \
  --custom-file ./domains.txt \
  --youtube direct
```

## 命令速查

```bash
# 保存 API 地址 / Token
3xui-warp-router configure --api-base 'https://panel.example.com:2053/panel/api'

# 首次准备 WARP + 应用分流
3xui-warp-router install --profile google-web --youtube direct

# 只准备 WARP outbound
3xui-warp-router bootstrap

# 更新规则
3xui-warp-router apply --profile gemini --youtube direct

# 查看简要状态
3xui-warp-router status

# 完整只读诊断
3xui-warp-router diagnose

# 严格测试当前 managed rules + WARP
3xui-warp-router test

# 手动换一次 WARP IP，并在换完后测试
3xui-warp-router rotate

# 查看自动换 IP 状态
3xui-warp-router rotation

# 每 7 天自动换一次
3xui-warp-router rotation --rotate-days 7

# 关闭自动换 IP
3xui-warp-router rotation --rotate-days 0

# 删除本脚本管理的路由规则
3xui-warp-router remove

# 回滚最近配置
3xui-warp-router rollback

# 查看备份
3xui-warp-router backups
```

## 服务器重启后会怎样？

`3xui-warp-router` 不是常驻 daemon，也不需要开机重复执行。

`install` 成功后，WARP outbound 和 routing rules 已经保存进 3x-ui/Xray：

```text
服务器重启
   ↓
3x-ui / Xray 启动
   ↓
读取保存的 warp outbound + routing rules
   ↓
分流继续生效
```

如果运行过 `configure`，管理脚本重启后也无需重新 export API Token。

## WARP 自动换 IP

3x-ui 默认：

```text
warpUpdateInterval = 0
```

即**默认关闭自动轮换**。

查看：

```bash
3xui-warp-router rotation
```

例如开启 7 天：

```bash
3xui-warp-router rotation --rotate-days 7
```

关闭：

```bash
3xui-warp-router rotation --rotate-days 0
```

对于 Google/Gemini 地区识别问题，建议先保持一个稳定可用的 WARP 出口，不要为了“随机”而高频轮换。

如果发现当前出口失效：

```bash
3xui-warp-router rotate
3xui-warp-router diagnose
```

## `status`、`test` 和 `diagnose` 的区别

```text
status
  快速看配置结构、managed rules、WARP endpoint、轮换状态

test
  严格验证当前 managed route + WARP outbound
  失败返回非 0；client inbound 未启用 sniffing 时显示 warning

diagnose
  更完整、可读、只读的故障诊断
  同时显示 egress IP / country / route / rotation / health
```

## 常用参数

| 参数 | 含义 |
|---|---|
| `--api-base URL` | 3x-ui API base |
| `--token-file FILE` | 从权限受控文件读取 API Token |
| `--config FILE` | 自定义持久配置文件 |
| `--no-config` | 本次不读取持久配置 |
| `--profile NAME` | `google-web` / `gemini` / `google-all` / `custom` |
| `--youtube MODE` | `direct` / `warp` |
| `--custom-file FILE` | 自定义 Xray domain tokens |
| `--priority MODE` | `prepend` / `append` |
| `--direct-tag TAG` | 显式指定 freedom outbound tag |
| `--rotate-days N` | WARP 自动轮换天数；0 关闭 |
| `--state-dir DIR` | 自定义状态/备份目录 |
| `--insecure` | 忽略面板 TLS 证书验证 |
| `--no-auto-rollback` | apply 失败后不自动回滚 |

## 环境变量

```text
XUI_API_BASE
XUI_API_TOKEN
XUI_API_TOKEN_FILE
XUI_WARP_CONFIG_FILE
XUI_WARP_PROFILE
XUI_YOUTUBE_MODE
XUI_WARP_PRIORITY
XUI_DIRECT_TAG
XUI_WARP_STATE_DIR
XUI_WARP_INSECURE
XRAY_BIN
```

## 安全说明

默认备份位置：

```text
~/.local/state/3xui-warp-router/backups/
```

备份可能包含：

- WARP WireGuard private key
- 其他 outbound 凭据
- Xray 配置中的敏感信息

脚本使用：

```text
状态目录 0700
备份文件 0600
API Token 文件 0600
```

不要把真实 API Token、WARP private key、完整 Xray 配置或 backup 目录提交到 GitHub / issue。

## 为什么不用静态 Google IP 段？

Google 服务和 Google Cloud 地址空间会变化、复用。使用大范围 Google IP 段很容易把托管在 GCP 上的第三方站点也送入 WARP。

因此本项目优先使用 **Xray domain/geosite routing**。

## 为什么不用 `warp-cli + redsocks + iptables`？

3x-ui/Xray 已经有自己的 routing system，再加系统透明劫持意味着同时维护两套路由：

```text
Xray routing
+
Linux iptables/redirection routing
```

本项目只保留：

```text
Xray routing -> warp / direct / 你的其他 outbound
```

更容易理解、排错和回滚。

## WARP 能保证美国出口吗？

不能。

Cloudflare WARP 不是可指定国家的传统 VPN。出口由 Cloudflare 网络决定。

本项目能做的是：

- 精确把指定 Xray 流量送到 WARP
- 检查 WARP 是否真实可达
- 显示探测到的 egress IP / country / warp 状态
- 明确识别 `country=CN` / `warp=off`
- 通过 3x-ui rotate WARP registration/IP

但不能保证每次都得到某个指定国家。

## 常见故障

### `routeTest` 通过，但真实客户端没有按域名走 WARP

`routeTest` 是对 Xray router 的合成域名查询，不会模拟客户端先把域名解析成 IP、再从 inbound 送入 Xray 的过程。对于这类流量，client inbound 需要启用 sniffing，才能从 TLS/HTTP 等协议中恢复域名并匹配 domain/geosite 规则。

安装、`test` 和 `diagnose` 都会检查非 `api` inbound 的 `sniffing.enabled`。例如：

```text
[3xui-warp-router] WARNING: inbound in-28193-tcp has sniffing disabled.
[3xui-warp-router] WARNING: Domain-based WARP routing may not work when clients send resolved IP addresses.
```

这是 warning 而不是自动修改：不同 inbound、协议和客户端的行为可能不同，脚本不会擅自改写已有 inbound 配置。请在 3x-ui 中确认对应 inbound 的 sniffing 设置，再运行 `3xui-warp-router test`。

### `Missing required command: wg`

这是 v0.2.0 及更早版本的首次注册限制。

先更新到 v0.3.2：

```bash
curl -fsSLo /usr/local/bin/3xui-warp-router \
  https://raw.githubusercontent.com/blooddrunk/3xui-warp-router/main/3xui-warp-router.sh
chmod 700 /usr/local/bin/3xui-warp-router
```

新版会优先使用 3x-ui 自带 Xray 的 `wg` 子命令。

如果新版仍提示无法生成 keypair，再安装：

```bash
apt update
apt install -y wireguard-tools
```

### Google / Gemini 仍然地区异常

先运行：

```bash
3xui-warp-router diagnose
```

重点看：

```text
WARP connectivity
WARP egress IPv4
WARP egress country
Cloudflare WARP
Google route
Gemini route
Conclusion
```

如果 route 正确、WARP 正常，但 Google 仍然不可用，可以：

```bash
3xui-warp-router rotate
3xui-warp-router diagnose
```

### 修改后 Xray 异常

```bash
3xui-warp-router rollback
```

## 设计原则

1. 不直接编辑 `x-ui.db`。
2. 不覆盖不属于本脚本的 routing rules。
3. 修改前先备份。
4. 保存交给 3x-ui / Xray 校验。
5. 修改后做真实验证。
6. 失败默认自动回滚。
7. `remove` 只删除自己创建的 rules。
8. WARP 生命周期交给 3x-ui 管理。
9. `diagnose` 保持只读。
10. 尽量复用 3x-ui/Xray 已经提供的能力，减少系统级依赖。

## Disclaimer

本项目与 Cloudflare、Google、3x-ui 项目无官方关联。

Cloudflare WARP、Google/Gemini 以及 3x-ui 的行为都可能随版本、地区、网络环境和服务政策变化。请先在可以恢复的 VPS 环境测试，并妥善保管 API Token、WireGuard private key 和 Xray 配置备份。
