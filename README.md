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
| 节点列表 | 解析订阅（sing-box JSON，20+ 节点），`--test` 经 Clash API 并行实测延迟 |
| 一键连接 | 选节点 + 起内核，本地混合代理 `127.0.0.1:7891` |
| TUN 全局接管 | 订阅自带 `tun-in`（`auto_route`），授权后无需任何程序支持代理 |
| 三种订阅模式 | 智能首选 / 全球直连 / 全局代理，Clash API 运行时切换 |
| DMS 状态栏插件 | 药丸显示状态，弹层完成连接/断开/切节点/签到/看流量 |

## 快速开始

```bash
git clone <repo-url> nano-vpn && cd nano-vpn

./install.sh        # 装内核、链命令、拷 DMS 插件、加状态栏组件（幂等）
nanovpn login       # 交互式输入邮箱密码
nanovpn connect     # 连接（默认智能首选 + 设置里的节点）
```

想装到 `/opt`（和其他软件放一起）：

```bash
sudo git clone <repo-url> /opt/nano-vpn
sudo chown -R $USER:$USER /opt/nano-vpn   # 之后 git pull 免 sudo
cd /opt/nano-vpn && ./install.sh
# 升级：cd /opt/nano-vpn && git pull && ./install.sh
```

> ⚠️ `tools/sing-box` 上的 TUN capability 挂在文件 inode 上：**拷贝**部署会丢权限，
> 需重跑 `nanovpn tun-setup`；同分区 `mv` / `git clone` 不受影响。

`install.sh` 做的事：检查依赖（curl/jq/python3）→ 下载 sing-box v1.14.2 到
`tools/sing-box` → 链接 `~/.local/bin/nanovpn` → 拷贝 `dms/` 到
`~/.config/DankMaterialShell/plugins/NanoVpn/` → `dms ipc` 重载并启用插件 →
把 `nanoVpn` 加进状态栏右侧组件 → 提示登录。

卸载：`./uninstall.sh`（交互确认，`-y` 跳过）。

## DMS 状态栏

- **药丸**（`vpn_lock` 图标）：已连接 `Theme.primary` / 断开
  `Theme.surfaceVariantText` / 连接中呼吸动画 / 错误 `Theme.error`；可选显示节点简称。
- **弹层**（点击药丸）：
  - 头部：连接状态 + 出口 IP；
  - 大连接/断开按钮；
  - 三个模式 chip：智能首选 / 全球直连 / 全局代理；
  - TUN 开关（未授权时 toast 提示运行 `nanovpn tun-setup`）；
  - 节点列表（tag/类型/延迟，点击即连；置顶"自动选择"）；
  - 底部：刷新节点 / 签到 / 测试延迟 / 登录；
  - 账号信息行：流量 used/total、到期时间、连续签到天数。
- 数据经 `Proc.runCommand` 调 `nanovpn status --json` 等，status 3s 轮询；
  命令找不到时 toast 提示运行 `nanovpn install`。
- 插件设置（设置 → Plugins → NanoVpn）：是否显示节点名、轮询间隔、`nanovpn` 路径。

## 命令

```
nanovpn login [email] [password]      # 缺省交互式读入；保存 credentials(0600) 并登录
nanovpn logout                        # 删除 credentials 与 auth
nanovpn checkin                       # 签到；已签到则提示"今天已经签到过了"
nanovpn panel [--json]                # 账号信息：套餐/流量/到期/签到状态
nanovpn nodes [--json] [--test]       # 节点列表；--test 经 Clash API 实测延迟并写回 nodes.json
nanovpn connect [node] [--tun|--no-tun]   # 选节点(缺省用设置里的 node 或第一个)、起内核
nanovpn disconnect                    # 停内核
nanovpn toggle                        # 连/断切换
nanovpn status [--json]               # 状态
nanovpn mode <智能首选|全球直连|全局代理>  # Clash API 切换并记忆
nanovpn tun-setup                     # pkexec setcap 授权
nanovpn install                       # 下载内核到 tools/、装 DMS 插件、链接命令、加状态栏组件
nanovpn uninstall                     # 反向
```

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
# = pkexec setcap cap_net_admin,cap_net_raw+eip <仓库>/tools/sing-box
# （polkit 弹窗输密码，只授权二进制，不整体以 root 运行）
```

- 授权前会先 `getcap` 检查，已有能力则跳过；内核版本更新后需重新授权一次。
- 撤销授权：

  ```bash
  sudo setcap -r <仓库>/tools/sing-box
  ```

## 配置与安全

运行时数据全部在仓库之外：

```
~/.config/nanovpn/
├── settings        # KEY=VALUE：panel_api_base / mixed_port=7891 / clash_port=9091
│                   #   mode=智能首选 / tun=0|1 / node=<tag> / log_level=warn
└── credentials     # email / password，明文，0600
~/.local/state/nanovpn/
├── auth            # 面板 JWT，0600
├── subscription.json / nodes.json / runtime.json / panel.json / status.json
├── sing-box.pid / sing-box.log / cache/
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
nano-vpn/
├── bin/nanovpn            # CLI 入口（bash）
├── lib/
│   ├── common.sh          # 路径常量、日志、settings 读写
│   ├── api.sh             # 面板 API（curl+jq）
│   ├── nodes.py           # 订阅解析（sing-box JSON / base64 链接）→ 节点 JSON
│   ├── config.sh          # 订阅 JSON → runtime.json（jq）
│   └── core.sh            # sing-box 进程管理、Clash API、status.json
├── tools/sing-box         # 由 install.sh 下载（gitignore）
├── dms/                   # DMS 插件源（plugin.json / NanoVpnWidget.qml /
│                          #   NanoVpnSettings.qml / translations/zh_CN.json）
├── install.sh / uninstall.sh
├── docs/SPEC.md           # 实施规格（协议细节的唯一事实来源）
├── docs/CONFIG.md         # 配置文件格式与安全边界
├── LICENSE / LICENSE-NOTE.md
└── README.md
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
（`install.sh` 下载到 `tools/` 并以独立进程运行），为避免任何许可歧义，
整体采用同一许可证。若计划以宽松许可发布**不含内核**的本体，请先阅读
[`LICENSE-NOTE.md`](LICENSE-NOTE.md)。
