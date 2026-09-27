# 配置文件与安全边界

nano-vpn 的运行时数据**全部放在仓库之外**，分两个目录：

| 目录 | 内容 | 权限 |
|---|---|---|
| `~/.config/nanovpn/` | 配置：`settings`、`credentials` | `700`，文件 `0600` |
| `~/.local/state/nanovpn/` | 状态：`auth`、`subscription.json`、`nodes.json`、`runtime.json`、`panel.json`、`status.json`、`sing-box.pid`、`sing-box.log`、`cache/` | `700`，`auth` `0600` |

目录由 `nanovpn` 首次运行时创建（`install.sh` 也会预先建好空目录）。

## settings（KEY=VALUE 纯文本）

每行一个 `键=值`，`#` 开头为注释。缺省值由 `lib/common.sh` 在读取时兜底：

| 键 | 默认 | 说明 |
|---|---|---|
| `panel_api_base` | （空，发现后写入） | V2Board 面板 API base，如 `https://account.alibaba.alicdn.men/api/v1` |
| `mixed_port` | `7891` | 本地混合代理（SOCKS5+HTTP）端口 |
| `clash_port` | `9091` | Clash API 端口 |
| `mode` | `智能首选` | 订阅模式：`智能首选` / `全球直连` / `全局代理` |
| `tun` | `0` | `1` 表示连接时启用 TUN |
| `node` | （空=第一个节点） | 选中的节点 tag；**tag 含 emoji 与空格，必须单独一行整行存储**，不要拆分行或转义 |
| `log_level` | `warn` | sing-box 日志级别 |

## credentials（账号密码，明文 0600）

```
email=your@email.com
password=********
```

- 由 `nanovpn login` 写入，`0600`；`nanovpn logout` 删除。
- **明文存放**：本项目刻意不引入系统钥匙环（libsecret/Keychain）依赖——
  bash CLI + QML 插件的技术栈下，钥匙环可用性参差（最小安装常没有）。
  代价请见下方威胁模型。

## state 各文件

| 文件 | 内容 | 敏感度 |
|---|---|---|
| `auth` | 面板登录返回的 JWT（`data.auth_data`），`0600` | **高**：持有即可调用面板 API |
| `subscription.json` | 订阅正文（sing-box 完整配置），另存 `subscribe_url` | **高**：`subscribe_url` 自带 token，泄露 = 订阅被盗用 |
| `nodes.json` | 从订阅解析出的节点列表（tag/类型/服务器/端口/延迟）；`--test` 后按延迟从低到高排序 | 中：暴露所用节点 |
| `runtime.json` | 实际喂给 sing-box 的配置（由订阅 JSON 经 jq 变换） | 中 |
| `panel.json` | 最近一次账号信息（套餐/流量/到期/签到）缓存 | 中：含邮箱 |
| `status.json` | 连接状态（state/node/mode/ip/uptime…），DMS 轮询用 | 低 |
| `sing-box.pid` / `sing-box.log` | 内核 PID / 日志尾部 | 低-中：日志可能含节点域名与错误详情，**不含账号密码** |
| `cache/` | sing-box 工作目录（fakeip/rdrc 缓存、rule_set 的 srs 下载） | 低 |

`subscription.json` 只做短时缓存（10 分钟）：`subscribe_url` 不可缓存，
每次连接前都重新向面板获取（出口 IP 会轮换）。

## 威胁模型（如实说明）

- ✅ 文件权限 `0600` / 目录 `700`：**同机器的其他用户**读不到。
- ⚠️ **同一用户身份运行的任何程序**（包括恶意软件）都能读明文密码与 JWT。
  这是所有"本地存凭据"方案的共同边界；钥匙环只能提高门槛，不能消除。
- ⚠️ 备份、云同步（Nextcloud/Dropbox/`rsync` 到家目录）、磁盘镜像、
  把 `~/.config` 或 `~/.local/state` 提交进 git —— 都会带走凭据与订阅 token。
- ⚠️ 订阅 URL 的 token 等同于账号的流量配额：泄露后他人可直接用你的订阅。
- ✅ 登录载荷走 HTTPS；脚本与文档中**不存在**任何写死的账号、密码或 sudo 密码。
- ✅ 注销手段：`nanovpn logout` 删 credentials 与 auth；`uninstall.sh` 删整个两个目录。

## 卸载后的残留

`uninstall.sh` 会删除 `~/.config/nanovpn/`、`~/.local/state/nanovpn/`、
插件目录与 `~/.local/bin/nanovpn` 符号链接；保留 `settings.json.bak`
（DMS 配置备份，确认无恙后手动删除）与 `tools/sing-box`（随仓库保留，
撤销 TUN 能力：`sudo setcap -r <仓库>/tools/sing-box`）。
