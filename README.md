# nano-vpn

脚本化的 **V2Board 代理客户端**：bash CLI（`nanovpn`）+ sing-box 内核 + DMS(Niri) 状态栏插件。
从原 Flutter 版客户端重构而来——同样的面板协议，去掉 GUI 框架，全部功能一行命令完成。

登录 / 签到 / 节点列表 / 连接 / TUN 全局接管 / Clash 模式切换全部命令行完成，
桌面端通过 DankMaterialShell 的状态栏药丸与弹层操作。

> 协议细节来自对 `Nano_v8a.apk`（Flutter AOT）的逆向与真实账号实测，
> 三处与"标准 V2Board"不同的坑见文末[协议实现说明](#协议实现说明)。

## 特性

| 能力 | 说明 |
|---|---|
| 账号密码登录 | 对接 V2Board 面板，凭据本地 `0600` 明文保存（边界见[安全说明](#配置与安全)） |
| 签到 | 支持"已签到"识别 |
| 节点列表 | 解析订阅（sing-box JSON，20+ 节点），`--test` 经 Clash API 并行实测延迟并按从低到高排序 |
| 一键连接 | 选节点 + 起内核，本地混合代理 `127.0.0.1:7891` |
| TUN 全局接管 | 订阅自带 `tun-in`（`auto_route`），授权后无需任何程序支持代理 |
| 三种订阅模式 | 智能首选 / 全球直连 / 全局代理，Clash API 运行时切换 |
| DMS 状态栏插件 | 药丸显示状态，弹层完成连接/断开/切节点/签到/看流量 |

## 快速开始

```bash
git clone <repo-url> nano-vpn && cd nano-vpn

sudo ./install.sh   # 系统侧安装：应用 → /opt/nano-vpn，命令 → /usr/local/bin/nanovpn，装内核 + TUN 授权
nanovpn login       # 首次运行自动把「你的」配置初始化到自己的家目录（XDG 规范）
nanovpn connect     # 连接（默认智能首选 + 设置里的节点）
nanovpn install-dms # 可选：DMS 状态栏插件（用户级，不需要 root）
```

### 安装布局

**系统侧**（`sudo ./install.sh` 负责，安装器绝不写任何用户目录）：

| 位置 | 内容 | 属主 / 权限 |
|---|---|---|
| `/opt/nano-vpn/` | 应用本体：`bin/`、`lib/`、`dms/`、`docs/`、`tools/sing-box`、`install.sh`、`uninstall.sh` | `root:root`（内核带 `cap_net_admin`，不可被普通用户改写） |
| `/usr/local/bin/nanovpn` | 指向 `/opt/nano-vpn/bin/nanovpn` 的软链接（系统目录，已在 `PATH` 中） | `root:root` |

**用户侧**（每个用户各自一份，`nanovpn` 首次运行时自动初始化，因此多用户互不影响）：

| 位置 | 内容 | 属主 / 权限 |
|---|---|---|
| `~/.config/nanovpn/` | 用户配置：`settings`（首次运行自动生成，带注释）、`credentials` | 当前用户，目录 `700`，凭据 `0600` |
| `~/.local/state/nanovpn/` | 用户状态：`auth`、订阅、节点、运行时配置、日志 | 当前用户，`700`，`auth` `0600` |
| `~/.cache/nanovpn/` | 可再生缓存：sing-box 工作目录（rule_set 下载、fakeip/rdrc 缓存） | 当前用户，`700` |
| `~/.config/DankMaterialShell/plugins/NanoVpn` | DMS 插件（`nanovpn install-dms` 建的**软链接** → `/opt/nano-vpn/dms`） | 当前用户 |

- **安装器完全不碰 `$HOME`**：`sudo ./install.sh` 只写 `/opt` 与 `/usr/local/bin`，
  所以装完机器上任何用户都能直接用；各自第一次运行 `nanovpn` 时才在自己的家目录
  生成配置，天然一用户一份（`settings`、凭据、订阅、状态全隔离）。
- 用户数据严格遵循 **XDG Base Directory** 规范：配置 `XDG_CONFIG_HOME`、状态 `XDG_STATE_HOME`、
  可再生缓存 `XDG_CACHE_HOME`（未设时分别用 `~/.config` / `~/.local/state` / `~/.cache`）。
- 用户目录里唯一的软链接是 **DMS 插件目录**（DMS 只从用户配置目录发现插件，插件源码留在
  `/opt/nano-vpn/dms`，升级应用后插件自动跟着更新）。配置、状态、缓存都是真实文件，
  不是指向别处的软链接。
- 历史版本遗留的 `~/.local/bin/nanovpn` 软链接会在 `nanovpn` 首次运行时被清理
  （只删指向本项目的软链接，普通文件不动）。

`install.sh` 做的事：检查依赖（curl/jq/python3/tar）→ 应用文件安装到 `/opt/nano-vpn`
→ 下载 sing-box v1.14.2 到 `/opt/nano-vpn/tools/sing-box` → `setcap` 授予 TUN 能力
（失败只警告，仍可用 `nanovpn tun-setup` 兜底）→ 链接 `/usr/local/bin/nanovpn`。
就这些，不涉及任何用户目录。

> ⚠️ TUN capability 挂在文件 **inode** 上：`install.sh` 每次安装/升级后都会重新
> `setcap`；手工拷贝内核二进制会丢能力，需重跑 `nanovpn tun-setup`。

升级：`git pull` 拉源码后重跑 `sudo ./install.sh`（幂等；用户配置、凭据与登录态保留，
DMS 插件是软链接所以也自动是新版）。

### 卸载

**用户级先清、系统级后清**（插件是指向 `/opt` 的软链接，要赶在 `/opt` 被删之前）：

```bash
nanovpn disconnect          # 1. 停内核（没连接可跳过）
nanovpn uninstall-dms       # 2. 移除 DMS 插件软链接与状态栏组件（用户级，不需要 root）
rm -rf ~/.config/nanovpn ~/.local/state/nanovpn ~/.cache/nanovpn   # 3. 删配置/状态/缓存（想留登录态可跳过）
cd <仓库> && sudo ./uninstall.sh   # 4. 删 /opt/nano-vpn 与 /usr/local/bin/nanovpn（交互确认，-y 跳过）
```

- `sudo ./uninstall.sh` 只删系统侧，**不动任何用户数据**；若内核还在运行，它会**先停掉**
  （否则二进制删了、进程还活着并继续持有 TUN/capability，变成不好收拾的幽灵进程）。
- `--keep-app`：保留 `/opt/nano-vpn`，只删命令链接。
- 卸完还留着：源码仓库、DMS 配置备份 `settings.json.bak`，以及第 3 步你选择保留的用户数据。

## DMS 状态栏

- **药丸**（`vpn_lock` 图标）：已连接 `Theme.primary` / 断开
  `Theme.surfaceVariantText` / 连接中呼吸动画 / 错误 `Theme.error`；可选显示节点简称。
- **弹层**（点击药丸）：
  - 「Nano VPN」标题行可点击：`Qt.openUrlExternally` 用默认浏览器打开官网
    https://16.76.177.124/ （悬停时变 `Theme.primary` + 下划线 + 手型光标；弹层不关闭、不断开连接）；
    标题固定在弹层最顶部，内置 `headerText` / `detailsText` 均置空不渲染，无残留空白；
  - 标题正下方是状态行：连接状态（未连接/连接中/已连接 <tag>）+ 出口 IP/错误原因，
    自绘 `StyledText` 复刻内置 popoutDetails 样式（可换行，随 `statusLine` 实时刷新）；
  - 大连接/断开按钮；
  - 三个模式 chip：智能首选 / 全球直连 / 全局代理；
  - TUN 开关（未授权时 toast 提示运行 `nanovpn tun-setup`）；
  - 节点列表（tag/类型/延迟，按延迟从低到高排序；点击即连；置顶"自动选择"）；
  - 底部：刷新节点 / 测试延迟 / 签到 / 登录·登出（四个按钮同一行等宽等高，按登录态切换标签；
    未登录时**默认不显示**登录表单，点"登录"才在弹层内展开邮箱+密码输入框，两项都非空后
    提交按钮才可点；登录成功表单收起）；
  - 账号信息：账号、流量（进度条）/总量、到期时间、连续签到天数；
  - 点"登出"会先 `nanovpn disconnect` 停内核（失败不阻断），再 `nanovpn logout` 删凭据与
    auth，随后刷新状态：按钮回到"登录"、表单收起、账号信息消失；
  - 弹层不显示关闭按钮，点击弹层外任意处即关闭。
- 数据经 `Proc.runCommand` 调 `nanovpn status --json` 等，status 3s 轮询；
  命令找不到时 toast 提示运行 `nanovpn install`。
- 插件设置（设置 → Plugins → NanoVpn）：是否显示节点名、轮询间隔、`nanovpn` 路径。
- 插件不在插件列表里？`nanovpn install-dms`（用户级，不需要 root）装一次即可。

## 命令

```
nanovpn login [email] [password]      # 缺省交互式读入；保存 credentials(0600) 并登录
nanovpn logout                        # 删除 credentials 与 auth
nanovpn checkin                       # 签到；已签到则提示"今天已经签到过了"
nanovpn panel [--json]                # 账号信息：套餐/流量/到期/签到状态
nanovpn nodes [--json] [--test]       # 节点列表；--test 经 Clash API 实测延迟并写回 nodes.json，按延迟从低到高排序
nanovpn connect [node] [--tun|--no-tun]   # 选节点(缺省用设置里的 node 或第一个)、起内核
nanovpn disconnect                    # 停内核
nanovpn toggle                        # 连/断切换
nanovpn status [--json]               # 状态
nanovpn mode <智能首选|全球直连|全局代理>  # Clash API 切换并记忆
nanovpn tun-setup                     # setcap 授权 TUN 能力（root 直接授权，否则 pkexec 弹窗）
nanovpn install-dms                   # 安装/刷新 DMS 状态栏插件（用户级：软链接 + 加状态栏组件）
nanovpn uninstall-dms                 # 移除 DMS 状态栏插件与状态栏组件（用户级）
nanovpn install                       # 系统侧安装：调 /opt/nano-vpn/install.sh（需要 root 时用 sudo 重入）
nanovpn uninstall                     # 系统侧卸载：调 /opt/nano-vpn/uninstall.sh（只删 /opt 与命令链接）
```

`install` / `uninstall` 只动系统目录，不会碰你的家目录；用户侧的东西（配置、DMS 插件）
由首次运行与 `install-dms` / `uninstall-dms` 负责。

人类可读输出走 stdout，错误走 stderr；`--json` 输出机器可读 JSON（QML 用）。

## 三种订阅模式

| 模式 | 行为 |
|---|---|
| **智能首选**（默认） | 按订阅 route 规则分流：国内域名/IP 直连，其余走"🚀 节点选择"；urltest 组"♻️ 自动选择"每 5 分钟自动挑最快节点 |
| **全球直连** | 全部流量直连（`clash_mode` 命中 `direct`）——临时不想走代理时用 |
| **全局代理** | 除局域网/私网 IP 外全部走节点选择 |

模式经 Clash API 运行时切换并记忆到 `settings`，重启内核后仍生效。

## TUN 模式

订阅配置自带 TUN inbound（`auto_route: true`），网络层接管全部流量，
**不需要**系统代理，也不受 Flatpak 沙箱限制。代价是内核需要网络能力：

```bash
nanovpn tun-setup
# = setcap cap_net_admin,cap_net_raw+eip /opt/nano-vpn/tools/sing-box
# 已经是 root 就直接授权；否则走 pkexec（polkit 弹窗输密码，只授权二进制，
# 不整体以 root 运行内核）；pkexec 不可用时回退到 sudo setcap。
# install.sh 以 root 运行时已经授权过一次，正常情况下这里会直接跳过。
```

- 授权前会先 `getcap` 检查，已有能力则跳过；内核版本更新后需重新授权一次。
- 撤销授权：

  ```bash
  sudo setcap -r /opt/nano-vpn/tools/sing-box
  ```

## 配置与安全

应用本体在 `/opt/nano-vpn`（root 所有），用户运行时数据全部在用户目录（XDG 规范），
由 `nanovpn` 首次运行时自动初始化：

```
/opt/nano-vpn/        # 应用本体 + tools/sing-box（root:root，含 cap_net_admin）
~/.config/nanovpn/    # XDG_CONFIG_HOME，首次运行自动生成
├── settings        # KEY=VALUE：panel_api_base / mixed_port=7891 / clash_port=9091
│                   #   mode=智能首选 / tun=0|1 / node=<tag> / log_level=warn
└── credentials     # email / password，明文，0600
~/.local/state/nanovpn/   # XDG_STATE_HOME
├── auth            # 面板 JWT，0600
├── subscription.json / nodes.json / runtime.json / panel.json / status.json
├── sing-box.pid / sing-box.log
~/.cache/nanovpn/          # XDG_CACHE_HOME：sing-box 工作目录（rule_set 下载 / fakeip 缓存）
```

**威胁模型（请如实理解边界）：**

- ✅ `0600` 文件 + `700` 目录：同机器其他用户读不到。
- ⚠️ **同一用户身份的任意程序**可读明文密码与 JWT——这是本地存凭据方案的共同边界，
  本项目刻意不依赖系统钥匙环（libsecret/Keychain），换取 bash CLI 的零依赖。
- ⚠️ 备份 / 云同步 / 提交 git 会带走凭据与订阅 token；`subscribe_url` 的 token
  等同于流量配额，泄露后他人可直接使用你的订阅。
- ✅ 脚本与文档中不存在任何写死的账号、密码或 sudo 密码。

各文件格式细节见 [`docs/CONFIG.md`](docs/CONFIG.md)。

## 项目结构

```
nano-vpn/                  # 源码仓库（可放在任意位置，例如 ~/Workspace/nano-vpn）
├── bin/nanovpn            # CLI 入口（bash）
├── lib/
│   ├── common.sh          # 路径常量、日志、settings 读写
│   ├── api.sh             # 面板 API（curl+jq）
│   ├── nodes.py           # 订阅解析（sing-box JSON / base64 链接）→ 节点 JSON
│   ├── config.sh          # 订阅 JSON → runtime.json（jq）
│   └── core.sh            # sing-box 进程管理、Clash API、status.json
├── dms/                   # DMS 插件源（plugin.json / NanoVpnWidget.qml /
│                          #   NanoVpnSettings.qml / translations/zh_CN.json）
├── install.sh / uninstall.sh   # 安装器：应用装到 /opt/nano-vpn（见「安装布局」）
├── docs/SPEC.md           # 实施规格（协议细节的唯一事实来源）
├── docs/CONFIG.md         # 配置文件格式与安全边界
├── LICENSE / LICENSE-NOTE.md
└── README.md
```

安装后运行时的实际布局：

```
/opt/nano-vpn/             # ← install.sh 拷贝的 bin/ lib/ dms/ docs/ + install.sh uninstall.sh
│   └── tools/sing-box     # 由 install.sh 下载（仓库内的 tools/ 被 .gitignore 忽略）
/usr/local/bin/nanovpn     # → /opt/nano-vpn/bin/nanovpn
~/.config/nanovpn/         # 每个用户首次运行 nanovpn 时自动生成
~/.config/DankMaterialShell/plugins/NanoVpn   # → /opt/nano-vpn/dms（nanovpn install-dms）
```

## 常见问题

**Q：Flatpak 应用 / 不认代理的程序走不了代理？**
开 TUN 就不存在这个问题：`nanovpn tun-setup` 授权一次，之后
`nanovpn connect --tun`（或把 `settings` 里 `tun=1`）即在网络层全局接管，
沙箱应用、`ping`、不认代理的程序全部覆盖，也不需要系统代理。
若只用混合代理，程序指向 `socks5h://127.0.0.1:7891` 即可（`nanovpn connect --no-tun`）。

**Q：拉订阅为什么必须用 sing-box 的 UA？**
面板按 UA 做内容协商：UA `sing-box/...` 返回完整 sing-box JSON 配置（22+ 节点），
空 UA 只返回 base64 分享链接（仅 9 个 vless 节点），UA `Dart/...` 直接 500。
所以 `subscription.json` 缓存过期后重拉也必须用 sing-box UA。

**Q：节点列表不全 / 显示过期？**
先删订阅缓存再连：

```bash
rm ~/.local/state/nanovpn/subscription.json
nanovpn connect
```

`subscribe_url` 每次连接前都会重新获取（出口 IP 会轮换，不可缓存），
删掉本地缓存可强制走全新拉取。

**Q：药丸/弹层没出现？**
先确认插件装过：`nanovpn install-dms`（用户级，会把插件软链接到
`~/.config/DankMaterialShell/plugins/NanoVpn` 并把组件加进状态栏）。
`dms ipc call plugin-scan reload nanoVpn` 失败时（如 DMS 未运行），
手动到 设置 → Plugins 启用 NanoVpn，并在状态栏右侧组件里确认。

**Q：内核起不来？**
看 `~/.local/state/nanovpn/sing-box.log` 尾部；最常见是 TUN 未授权
（`nanovpn connect --tun` 前先 `nanovpn tun-setup`）或端口被占用
（改 `settings` 里的 `mixed_port` / `clash_port`）。

**Q：缺 curl/jq/python3？**
`install.sh` 会按发行版给出安装命令（apt/dnf/pacman）后退出。

## 协议实现说明

面板协议来自对 Android 客户端 `Nano_v8a.apk` 的逆向与真实账号实测，三处与
"标准 V2Board"不同，自行实现时务必注意：

1. **User-Agent 白名单**：面板 API 要求 UA 包含 `dart`（不区分大小写），
   否则返回 HTTP 200 但 body 为空。统一用 `Dart/3.11.5 (dart:io)`。
2. **Authorization 头裸放 JWT**：登录返回的 `data.auth_data` 原样放入，
   **不能加 `Bearer ` 前缀**，加了会被判未登录。
3. **`subscribe_url` 不可缓存**：出口 IP 会轮换，每次连接前都要重新调
   `getSubscribe` 拿新地址；订阅正文本身可短时缓存（10 分钟）。

登录载荷为明文 JSON，面板不做加密。完整端点表与响应信封见
[`docs/SPEC.md`](docs/SPEC.md) 第 1 节。

## 许可证

**GPL-3.0-or-later**，见 [`LICENSE`](LICENSE)。

之所以与 sing-box 采用同一许可证：安装产物会捆绑 sing-box 内核
（`install.sh` 下载到 `/opt/nano-vpn/tools/` 并以独立进程运行），为避免任何许可歧义，
整体采用同一许可证。若计划以宽松许可发布**不含内核**的本体，请先阅读
[`LICENSE-NOTE.md`](LICENSE-NOTE.md)。
