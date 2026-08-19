# 3xui-warp-router

让 **3x-ui / Xray** 对 Google、Gemini、YouTube 等流量进行可控的 Cloudflare WARP 分流，同时尽量不碰系统全局路由。

> 面向已经使用 [3x-ui](https://github.com/MHSanaei/3x-ui) 的 VPS 用户。脚本复用 3x-ui 原生 WARP WireGuard outbound，不安装 `warp-cli`、`redsocks`，也不会通过 `iptables OUTPUT` 劫持系统流量。

## 它解决什么问题？

有些 VPS 的原生出口 IP 会被 Google 错误识别到不正确的地区，进而影响 Gemini、Google Search、AI Studio 或其他 Google 服务。

传统的一键 WARP 脚本常见做法是：

```text
应用 -> iptables -> redsocks -> 本地 WARP SOCKS5 -> Cloudflare
```

这类方案能工作，但通常还会带来静态 Google IP 表、IPv6 黑洞路由、`gai.conf` 修改、TCP/UDP 分流不一致等问题。

`3xui-warp-router` 换了一个更适合 3x-ui 的思路：

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
- 通过 **域名 / geosite** 做 Xray 级精确分流
- 尽量保留你已有的 inbound、DNS、outbound 和 routing 规则
- 修改前自动备份完整 Xray 配置
- 修改后自动执行 route test + WARP outbound connectivity test
- 验证失败时默认自动回滚
- 支持调用 3x-ui 原生 WARP 换 IP
- 支持 3x-ui 原生 WARP 定时轮换
- 幂等：重复运行不会不断追加相同的 managed rules

## 前置条件

推荐：

- Linux VPS
- 已安装并运行较新的 3x-ui
- 3x-ui 中可以使用 WARP outbound / WARP API
- Bash
- `curl`
- `jq`
- `base64`
- `od`

如果 3x-ui **还没有注册过 WARP**，首次运行还需要：

```bash
wg
```

Debian / Ubuntu：

```bash
sudo apt update
sudo apt install -y curl jq wireguard-tools
```

如果你已经在 3x-ui 中注册并配置好了 WARP，`wireguard-tools` 通常不再是必须项。

## 1. 获取 3x-ui API Token

打开 3x-ui：

```text
Settings -> Security -> API Token
```

创建一个 API Token。

脚本使用 Bearer Token 调用 3x-ui API，**不是你的面板密码**。

## 2. 安装脚本

仓库创建后，可以直接下载：

```bash
curl -fsSLo /usr/local/bin/3xui-warp-router \
  https://raw.githubusercontent.com/blooddrunk/3xui-warp-router/main/3xui-warp-router.sh

chmod 700 /usr/local/bin/3xui-warp-router
```

也可以 clone：

```bash
git clone https://github.com/blooddrunk/3xui-warp-router.git
cd 3xui-warp-router
chmod +x 3xui-warp-router.sh
```

## 3. 配置 3x-ui API（推荐一次性持久保存）

推荐先运行：

```bash
3xui-warp-router configure \
  --api-base 'https://panel.example.com:2053/panel/api'
```

脚本会无回显询问 API Token，先验证能否登录 3x-ui，然后保存：

```text
~/.config/3xui-warp-router/config
~/.config/3xui-warp-router/token
```

两个文件都会使用 `0600` 权限；Token 不会写入普通配置文件。以后重新 SSH、开新 shell、甚至服务器重启后，`status` / `test` / `rotate` 等命令都不需要重新 `export`。

如果你的 3x-ui 配置了 Web Base Path，例如：

```text
https://panel.example.com:2053/secret/
```

则：

```bash
3xui-warp-router configure \
  --api-base 'https://panel.example.com:2053/secret/panel/api'
```

### 临时环境变量方式

如果你不希望把 Token 保存到磁盘，也可以继续使用：

```bash
export XUI_API_BASE='https://panel.example.com:2053/panel/api'
export XUI_API_TOKEN='YOUR_API_TOKEN'
```

这种 `export` 只对当前 shell 有效；它消失不会影响已经写入 3x-ui 的 WARP outbound 和 routing rules，只会影响你以后再次调用管理脚本。

也可以只保存 Token 到自己指定的权限受控文件：

```bash
3xui-warp-router status \
  --api-base 'https://panel.example.com:2053/panel/api' \
  --token-file /root/.secrets/3xui-api-token
```

> 不建议把真实 API Token 写进 shell history、README、issue 或公开日志。

## 4. 推荐的首次运行

### Google / Gemini 走 WARP，YouTube 保持直连

```bash
3xui-warp-router install \
  --profile google-web \
  --youtube direct
```

如果你是从仓库目录直接运行：

```bash
./3xui-warp-router.sh install \
  --profile google-web \
  --youtube direct
```

首次执行时，脚本会：

1. 通过 3x-ui API 读取当前 Xray 配置。
2. 创建本地安全备份。
3. 检查是否已有 `warp` WireGuard outbound。
4. 如果没有，则通过 3x-ui 自己的 WARP 接口注册并构造 outbound。
5. 检测可用的 `geosite` 数据。
6. 合并本脚本管理的 routing rules。
7. 让 3x-ui 校验并保存配置。
8. 测试 Google / YouTube 的实际路由选择。
9. 测试 WARP outbound 是否真正可用。
10. 如果验证失败，默认恢复到修改前的配置。

## 重启后会发生什么？

`3xui-warp-router` **不是常驻 daemon**，也不需要开机再次执行。它只是通过 3x-ui API 写入 Xray/WARP 配置。

首次 `install` 成功后：

```text
服务器重启
   ↓
3x-ui / Xray 启动
   ↓
读取已经保存的 warp outbound + routing rules
   ↓
Google / Gemini 继续按原规则走 WARP
```

所以：

- 不需要 systemd 定时重跑本脚本；
- `export XUI_API_BASE/XUI_API_TOKEN` 是否还存在，不影响已经生效的路由；
- 如果使用了 `configure`，重启后连管理命令也不需要再次 export。

可以随时验证：

```bash
3xui-warp-router status
3xui-warp-router test
```

从 v0.2.0 开始，`test` 和 `rotate` 会读取**当前实际安装的 managed rules** 来决定测试 Google / Gemini / YouTube 的哪条路由，而不是假设你仍然使用默认的 `google-web + youtube direct`。这避免了重启后或更换 profile 后的误报。

## Profile

### `google-web` — 推荐

```bash
3xui-warp-router install --profile google-web --youtube direct
```

目标：Google 主体流量走 WARP，YouTube 保持 VPS 原生出口。

脚本会优先尝试：

```text
geosite:youtube -> direct
geosite:google  -> warp
```

如果当前 Xray geosite 数据不支持相关 category，则退回到显式域名列表。

### `gemini` — 更窄的规则

```bash
3xui-warp-router install --profile gemini --youtube direct
```

主要覆盖：

- Gemini
- Google AI Studio
- Google AI API / Generative Language API
- Google 登录
- 部分 Google API / static 依赖域名

适合希望尽量少让 Google 其他业务经过 WARP 的情况。

### `google-all`

```bash
3xui-warp-router install --profile google-all --youtube warp
```

Google + YouTube 都走 WARP。

### `custom`

创建域名规则文件：

```text
# domains.txt
full:gemini.google.com
domain:aistudio.google.com
domain:generativelanguage.googleapis.com
geosite:google
```

应用：

```bash
3xui-warp-router apply \
  --profile custom \
  --custom-file ./domains.txt \
  --youtube direct
```

文件每行一个 Xray domain token；空行和 `#` 注释会被忽略。

## 命令速查

### 一键准备 WARP + 应用规则

```bash
3xui-warp-router install --profile google-web --youtube direct
```

### 只准备 WARP outbound，不修改分流

```bash
3xui-warp-router bootstrap
```

### 更新分流规则

要求已经存在 `warp` outbound：

```bash
3xui-warp-router apply --profile gemini --youtube direct
```

### 查看状态

```bash
3xui-warp-router status
```

### 测试当前配置

```bash
3xui-warp-router test
```

脚本会检查 routing decision，并调用 3x-ui 的 outbound connectivity test。

### 更换 WARP IP

```bash
3xui-warp-router rotate
```

换 IP 后会再次执行测试。

### 设置 3x-ui 原生自动换 IP

3x-ui 自带 WARP 自动轮换能力，但**默认关闭**（interval = `0`）。本脚本不会在你没有显式要求时自动开启它。

推荐先查看当前状态：

```bash
3xui-warp-router rotation
```

例如每 7 天：

```bash
3xui-warp-router install \
  --profile google-web \
  --youtube direct \
  --rotate-days 7
```

关闭：

```bash
3xui-warp-router rotation --rotate-days 0
```

也可以不改 routing，单独设置：

```bash
3xui-warp-router rotation --rotate-days 7
```

`status` 现在也会显示当前 3x-ui WARP 自动轮换间隔。

> 不建议为了“看起来更随机”而高频换 IP。对于 Google 地区判定问题，找到一个稳定可用的出口后保持稳定通常更合理。

### 删除本脚本管理的路由规则

```bash
3xui-warp-router remove
```

`remove` 不会删除：

- 3x-ui WARP 账号
- `warp` outbound
- 其他用户自定义 routing rules

### 回滚

```bash
3xui-warp-router rollback
```

恢复最新一次本地 Xray 配置备份。

### 查看备份

```bash
3xui-warp-router backups
```

## 常用参数

| 参数 | 含义 |
|---|---|
| `--api-base URL` | 3x-ui API base，通常以 `/panel/api` 结尾 |
| `--token-file FILE` | 从权限受控文件读取 API Token |
| `--config FILE` | 指定持久配置文件 |
| `--no-config` | 本次运行忽略持久配置文件 |
| `--profile NAME` | `google-web` / `gemini` / `google-all` / `custom` |
| `--youtube MODE` | `direct` 或 `warp` |
| `--custom-file FILE` | 自定义 Xray domain token 文件 |
| `--priority MODE` | managed rules 放在现有规则前 (`prepend`) 或后 (`append`) |
| `--direct-tag TAG` | 手工指定已有 freedom outbound tag |
| `--rotate-days N` | 设置 3x-ui WARP 自动换 IP 的间隔天数 |
| `--state-dir DIR` | 自定义本地状态/备份目录 |
| `--insecure` | 忽略面板 HTTPS 证书验证；仅自签名环境使用 |
| `--no-auto-rollback` | 应用验证失败后不自动恢复 |

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
```

命令行参数优先用于改变相应的运行行为。

## 默认备份位置

```text
~/.local/state/3xui-warp-router/backups/
```

权限：

```text
目录 0700
文件 0600
```

### 重要安全提醒

Xray 配置备份可能包含：

- WARP WireGuard private key
- 其他 outbound 凭据
- 你的 Xray 配置中的敏感内容

因此：

- 不要把 backup 目录提交到 GitHub。
- 不要把真实 API Token 写入 issue、README 或日志。
- 不要把真实 Xray 配置贴到公共 issue，除非已经脱敏。

## 为什么不使用静态 Google IP 段？

Google 的服务和 Google Cloud 地址空间会变化，并且不同服务可能共用基础设施。

使用类似：

```text
34.0.0.0/9
35.0.0.0/...
```

这种大范围 IP 路由，很容易把托管在 Google Cloud 上但与 Google Search/Gemini 无关的第三方服务也送入 WARP。

这个项目因此优先使用 **Xray 域名/geosite routing**。

## 为什么不用 `warp-cli + redsocks + iptables`？

如果服务器本来就以 3x-ui/Xray 为主要代理入口，那么在系统层再次透明劫持会形成两套 routing system：

```text
Xray routing
+
Linux iptables/redirection routing
```

长期维护、诊断和回滚都会更复杂。

本项目选择让 Xray 自己决定 outbound：

```text
Xray routing -> warp / direct / 你的其他 outbound
```

因此规则更容易理解，也更适合通过 3x-ui 管理。

## YouTube 为什么默认直连？

部分用户遇到的是：

- VPS 原生 IP 对 YouTube 正常；
- 但 Google/Gemini 对同一 IP 的地区识别不正确。

这种情况下没有必要让 YouTube 一起走 WARP。

所以默认推荐：

```bash
--profile google-web --youtube direct
```

如果你的 YouTube 同样受到原 IP 影响，可以切换：

```bash
--youtube warp
```

## WARP 能保证获得美国 IP 吗？

不能。

Cloudflare WARP 并不是一个“选择国家的传统 VPN”。WARP 出口位置由 Cloudflare 网络决定。

本项目能做的是：

- 让指定 Xray 流量通过 WARP；
- 检查 WARP outbound 是否可达；
- 尽量读取 outbound probe 的 egress 信息；
- 如果明确得到 `country=CN` 或 `warp=off`，将测试视为失败；
- 允许通过 3x-ui 重新注册 / rotate WARP。

它不能保证每次 WARP 出口都满足 Gemini 或 Google 的地区政策。

## `--insecure` 什么时候使用？

只有你的 3x-ui 面板 HTTPS 使用自签名证书，并且你确定自己连接的是正确服务器时才使用：

```bash
3xui-warp-router status --insecure
```

正常的公开 TLS 证书不要加这个参数。

## 和现有 routing rules 会冲突吗？

默认：

```text
--priority prepend
```

本脚本管理的规则放在现有 user rules 前面，以确保 Google/Gemini 命中。

如果你的现有规则必须拥有更高优先级，可以使用：

```bash
--priority append
```

请记住 Xray routing 通常是 **first match wins**。

本脚本使用内部 marker 标记自己创建的规则，因此再次 `apply` 时会先移除旧 managed rules，再加入新规则，而不是重复追加。

## 故障排查

先运行：

```bash
3xui-warp-router status
3xui-warp-router test
```

常见检查项：

```bash
# 确认 API 地址
printf '%s\n' "$XUI_API_BASE"

# 确认依赖
command -v curl
command -v jq
command -v wg

# 查看本地备份
3xui-warp-router backups
```

如果刚刚修改后出现问题：

```bash
3xui-warp-router rollback
```

如果 WARP 本身可达，但 Google/Gemini 仍然不可用，可以尝试：

```bash
3xui-warp-router rotate
```

然后再次：

```bash
3xui-warp-router test
```

## 兼容性说明

这个脚本依赖较新的 3x-ui API 能力，包括：

- Bearer API Token
- Xray settings API
- Cloudflare WARP integration API
- route test
- outbound connectivity test
- geodata validation（不可用时相关检测可能需要调整）

3x-ui 是持续更新的项目。如果未来 API 行为发生变化，建议提交 issue，并附：

```bash
3xui-warp-router --version
```

以及**脱敏后的**错误输出。

## 设计原则

这个项目尽量遵循：

1. **不直接编辑 `x-ui.db`**。
2. **不覆盖不属于本脚本的 routing rules**。
3. **修改前先备份**。
4. **保存交给 3x-ui / Xray 做校验**。
5. **修改后做真实验证**。
6. **失败默认自动回滚**。
7. **remove 只删除自己创建的东西**。
8. **WARP 生命周期交给 3x-ui 管理**。

## Disclaimer

本项目与 Cloudflare、Google、3x-ui 项目无官方关联。

Cloudflare WARP、Google/Gemini 以及 3x-ui 的行为都可能随版本、地区、网络环境和服务政策发生变化。请先在你可以恢复的 VPS 环境中测试，并妥善保管 API Token、WireGuard private key 和 Xray 配置备份。
