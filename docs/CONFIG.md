# 配置文件与安全边界

应用本体装在 `/opt/nano-vpn`（`root:root`，含带 `cap_net_admin` 的 `tools/sing-box`），
命令通过 `/usr/local/bin/nanovpn` 软链接暴露。**安装器（`sudo install.sh`）只写系统目录，
完全不碰 `$HOME`**：用户运行时数据全部由 CLI 首次运行时在自己的家目录初始化，
按 XDG Base Directory 规范分三个目录（`XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME`
生效时优先，相对路径按规范忽略）：

| 目录 | 内容 | 权限 |
|---|---|---|
| `~/.config/nanovpn/` | 配置：`settings`（首次运行自动生成）、`credentials` | `700`，文件 `0600` |
| `~/.local/state/nanovpn/` | 状态：`auth`、`subscription.json`、`nodes.json`、`runtime.json`、`panel.json`、`status.json`、`sing-box.pid`、`sing-box.log` | `700`，文件默认 `0600` |
| `~/.cache/nanovpn/` | 可再生缓存：sing-box 工作目录（`-D`，rule_set 的 srs 下载、fakeip/rdrc 缓存） | `700` |

CLI 以 `umask 077` 运行，所以它新建的文件都是 `0600`（含 `runtime.json`、`subscription.json`
这些带凭据/订阅 token 的文件）；遇到历史遗留的宽松权限，下次运行会自动收紧。

**多用户**：三个目录都属于当前用户，每个用户第一次运行 `nanovpn` 时各自生成一份，
互不可见、互不影响；root 只装 `/opt`，不会替任何用户建配置。

用户目录里唯一的软链接是 DMS 插件目录
`~/.config/DankMaterialShell/plugins/NanoVpn → /opt/nano-vpn/dms`
（DMS 只从该目录发现插件，插件源码留在 `/opt`，升级后自动是新版），
由用户级命令 `nanovpn install-dms` 建立；配置、状态、缓存都是真实文件。
命令链接在系统目录 `/usr/local/bin`，不在 `$HOME`。

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
| `~/.cache/nanovpn/` | sing-box 工作目录（`-D`：fakeip/rdrc 缓存、rule_set 的 srs 下载），可随时删除 | 低 |

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
- ✅ 注销手段：`nanovpn logout` 删 credentials 与 auth；删配置/状态/缓存目录见下节。

## 卸载

用户级先清、系统级后清（插件是指向 `/opt` 的软链接，必须在删 `/opt` 之前处理）：

```bash
nanovpn disconnect        # 1. 停内核（没连接可跳过）
nanovpn uninstall-dms     # 2. 删插件软链接 + settings.json 里的 nanoVpn 组件
rm -rf ~/.config/nanovpn ~/.local/state/nanovpn ~/.cache/nanovpn   # 3. 配置/状态/缓存（想留登录态可跳过）
sudo ./uninstall.sh       # 4. 删 /opt/nano-vpn 与 /usr/local/bin/nanovpn
```

- 第 1 步不能省：卸载器虽然会在删 `/opt` 前主动停掉仍在运行的 `tools/sing-box`
  （否则进程会继续持有 TUN 与 capability 变成幽灵进程），但先自己 `disconnect` 更干净。
- 第 2 步只删插件与状态栏组件，**保留登录态**；它输出里会给出上面那条 `rm -rf`（含展开后的真实路径）。
- 第 3 步是唯一删凭据与登录态的地方，root 不会代你做。
- 第 4 步只删系统侧，**不碰任何用户目录**；`--keep-app` 可只删命令链接、保留 `/opt/nano-vpn`。

卸载后残留：源码仓库（应用是从它安装出去的拷贝）、`settings.json.bak`（DMS 配置备份，
确认无恙后手动删）、以及第 3 步你选择保留的用户数据。
