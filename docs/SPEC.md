# nano-vpn 实施规格（唯一事实来源）

本文件由主 Agent 通过对 `Nano_v8a.apk`（Flutter AOT）的逆向 + 真实账号实测整理，
所有子 Agent 的实现必须严格遵循本规格，不要自行"发明"协议细节。

## 0. 项目定位

脚本化的代理客户端（替代原 Flutter 仓库 nano-client）：bash CLI + sing-box 内核 + DMS(Niri) 状态栏插件。
命令名 `nanovpn`（避免与系统 `nano` 编辑器冲突），仓库名 `nano-vpn`。

设计原则：**能直接用订阅配置就不自己造轮子**。订阅服务器用 sing-box UA 拉下来的就是一份
完整可用的 sing-box 配置（含 TUN inbound、mixed inbound、DNS、分流规则、Clash API），
脚本只做三件事：选节点、开关 TUN、管进程。

## 1. 面板协议（V2Board 定制版，逆向自 Nano APK）

三处与标准 V2Board 不同，**必须遵守**：

1. **User-Agent 白名单**：面板 API 要求 UA 包含 `dart`（不区分大小写），
   否则返回 HTTP 200 但 body 为空。统一用 `Dart/3.11.5 (dart:io)`。
2. **Authorization 头裸放 JWT**：登录返回的 `data.auth_data` 原样放入，
   **不能加 `Bearer ` 前缀**，加了会被判未登录。
3. **`subscribe_url` 不可缓存**：出口 IP 会轮换，每次连接前都要重新调
   `getSubscribe` 拿新地址。订阅正文本身可短时缓存（10 分钟）。

统一响应信封：`{"status":"success","message":"...","data":{...}}`，
失败时 `status` 为 `fail`，`message` 为中文提示。

### 1.1 面板地址发现

配置源（按顺序尝试，任一个返回 JSON 且含 `url` 字段即可）：

- `https://nanoapi.oss-ap-northeast-1.aliyuncs.com/u.json`
- `https://47.76.194.59/u.json`
- `https://54.37.159.199/u_nano.json`

返回示例：`{"url":"https://account.alibaba.alicdn.men/api/v1", ...}`。
当前实测面板 API base = `https://account.alibaba.alicdn.men/api/v1`。

### 1.2 端点（均已实测）

| 方法 | 路径（拼在 api base 后） | 请求体 | 关键返回 |
|---|---|---|---|
| POST | `passport/auth/login` | `{"email":"..","password":".."}` 明文 JSON | `data.auth_data`(JWT), `data.token`(32位hex), `data.is_admin` |
| GET | `user/info` | 无 | 账号信息 |
| GET | `user/getSubscribe` | 无 | `data.subscribe_url`；另有 `token,email,uuid,expired_at`(秒), `transfer_enable`(字节), `u`(上传), `d`(下载), `plan{id,name,speed_limit,content}` |
| POST | `user/checkin` | 空 body（`{}` 亦可） | 成功：`message` 含奖励说明；已签到：HTTP 400 + `{"status":"fail","message":"今天已经签到过了"}` |
| GET | `user/checkinStatus` | 无 | `data:{can_checkin, checkin_days, last_checkin_at, next_reward_gb, next_reward_traffic}` |

注意：`user/checkin` 只接受 POST，GET 返回 405 HTML 错误页（不要试图解析它）。

### 1.3 订阅拉取

`GET subscribe_url`，按 UA 做内容协商：

- UA `sing-box/1.14.0` → **完整 sing-box JSON 配置**（22+ 节点，首选）
- 空 UA → base64 编码的分享链接列表（只有 9 个 vless 节点，降级用）
- UA `Dart/...` → 500，不要用

## 2. 订阅返回的 sing-box 配置结构（实测 2026-09-27）

```json
{
  "log": {...},
  "certificate": {"store":"system","certificate":["-----BEGIN CERTIFICATE-----..."]},
  "dns": {"servers":[google_dns(https,detour 节点选择), ali_dns(https 223.6.6.6), fakeip], "rules":[...]},
  "inbounds": [
    {"tag":"tun-in","type":"tun","address":["172.19.0.0/30","fdfe:dcba:9876::0/126"],"stack":"system","auto_route":true,"strict_route":true,"platform":{"http_proxy":{"enabled":true,"server":"127.0.0.1","server_port":7891}}},
    {"tag":"mixed-in","type":"mixed","listen":"127.0.0.1","listen_port":7891}
  ],
  "outbounds": [
    {"type":"selector","tag":"🚀 节点选择","outbounds":["♻️ 自动选择", ...22个节点tag], "interrupt_exist_connections":true},
    {"type":"urltest","tag":"♻️ 自动选择","outbounds":[...], "url":"http://www.apple.com/library/test/success.html","interval":"5m"},
    {"type":"direct","tag":"direct"},
    {"tag":"❇️猎户座-A","type":"tuic","server":"bgpa...","server_port":18662,"uuid":"..","password":"..","congestion_control":"bbr","udp_relay_mode":"native","tls":{...}},
    ... 共 13 个 tuic + 9 个 vless（vless 多为 ws/CDN，如 cos-cdn-a.alicdn.win:443）
  ],
  "route": {
    "default_domain_resolver":{"server":"ali_dns"},
    "auto_detect_interface":true,
    "rules":[
      {"inbound":["tun-in","mixed-in"],"action":"sniff"},
      {"type":"logical","mode":"or","rules":[{"protocol":"dns"},{"port":53}],"action":"hijack-dns"},
      {"domain_suffix":["pandalive.co.kr"],"outbound":"direct"},
      {"domain_suffix":["services.googleapis.cn","xn--ngstr-lra8j.com"],"outbound":"节点选择"},
      {"ip_is_private":true,"outbound":"direct"},
      {"clash_mode":"全球直连","outbound":"direct"},
      {"clash_mode":"全局代理","outbound":"🚀 节点选择"},
      {"rule_set":["geoip-cn","geosite-cn"],"outbound":"direct"}
    ],
    "rule_set":[
      {"type":"remote","tag":"geoip-cn","format":"binary","url":"https://47.243.235.13/phantom/geoip-cn.srs","download_detour":"direct"},
      {"type":"remote","tag":"geosite-cn","format":"binary","url":"https://47.243.235.13/phantom/geosite-cn.srs","download_detour":"direct"}
    ]
  },
  "experimental": {
    "cache_file":{"enabled":true,"store_fakeip":true,"store_rdrc":true},
    "clash_api":{"default_mode":"智能首选","external_controller":"127.0.0.1:9091","secret":""}
  }
}
```

要点：

- 订阅模式（clash modes）= `智能首选` / `全球直连` / `全局代理`，运行时经 Clash API 切换。
- 选择器 tag 固定为 `🚀 节点选择`，urltest tag 为 `♻️ 自动选择`。
- **`certificate` 字段必须保留**：教育类 tuic 节点用自签 CA（server_name www.bing.com）。
- rule_set 是 remote srs，sing-box 运行时可自行下载（需要 `-D` 指定可写工作目录）。

## 3. 运行时配置生成（jq 变换订阅 JSON）

输入 `subscription.json`，输出 `runtime.json`：

1. `inbounds`：TUN 关闭时删掉 `tun-in`；`mixed-in.listen_port` 用设置里的 `mixed_port`（默认 7891）。
2. 选择器默认节点：给 tag == `🚀 节点选择` 的 outbound 加/改 `"outbound": "<选中节点tag>"`
   （sing-box ≥1.11 支持 selector 的 `outbound` 字段指定初始选中项）。
3. `experimental.clash_api.external_controller` 改为 `127.0.0.1:<clash_port>`（默认 9091）；
   `default_mode` 用设置里的 `mode`。
4. 其余（dns/route/rule_set/certificate/log）原样保留。`log.level` 可设 `warn`。
5. 其余（dns/route/rule_set/certificate/log）原样保留。`log.level` 可设 `warn`。

进程启动：`setsid tools/sing-box run -c runtime.json -D <state>/cache`，
stdout/stderr 追加到 `sing-box.log`，PID 写入 `sing-box.pid`。
启动成功判定：Clash API `GET http://127.0.0.1:<clash_port>/version` 可达（轮询最多 15s）。
失败时把日志尾部打到 stderr 并以非零退出。

## 4. TUN 模式

TUN 已包含在订阅配置里（`auto_route:true`）。只需：

- `tools/sing-box` 需要 `cap_net_admin,cap_net_raw+eip`（`setcap`）。
- 授权命令：`pkexec setcap cap_net_admin,cap_net_raw+eip <abs path to tools/sing-box>`
  （pkexec 会弹 polkit 图形密码框；当前桌面 DMS 自带 polkit agent）。
- 授权前先 `getcap tools/sing-box` 检查，已有能力则跳过。
- 撤销：`sudo setcap -r tools/sing-box`（写进 README，不提供 CLI）。

## 5. 文件布局与运行时路径

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
├── dms/                   # DMS 插件源（install.sh 拷贝到 ~/.config/DankMaterialShell/plugins/NanoVpn/）
│   ├── plugin.json
│   ├── NanoVpnWidget.qml
│   ├── NanoVpnSettings.qml
│   └── translations/zh_CN.json
├── install.sh
├── uninstall.sh
└── README.md
```

运行时（**不放仓库内**）：

- 配置 `~/.config/nanovpn/`：`settings`（KEY=VALUE）、`credentials`（email/password，0600）
- 状态 `~/.local/state/nanovpn/`：`auth`(JWT,0600)、`subscription.json`、`nodes.json`、
  `runtime.json`、`panel.json`、`status.json`、`sing-box.pid`、`sing-box.log`、`cache/`

settings 键：`panel_api_base`、`mixed_port=7891`、`clash_port=9091`、`mode=智能首选`、
`tun=0|1`、`node=<tag>`（节点 tag 含 emoji/空格，单独一行存）、`log_level=warn`。

## 6. CLI 契约（bin/nanovpn）

人类可读输出走 stdout，错误/提示走 stderr。`--json` 输出机器可读 JSON（QML 用）。

```
nanovpn login [email] [password]      # 缺省交互式读入；保存 credentials(0600) 并登录
nanovpn logout                        # 删除 credentials 与 auth
nanovpn checkin                       # 签到；已签到则提示"今天已经签到过了"
nanovpn panel [--json]                # 账号信息：套餐/流量/到期/签到状态
nanovpn nodes [--json] [--test]       # 节点列表；--test 实测延迟并写回 nodes.json，按延迟从低到高排序
nanovpn connect [node] [--tun|--no-tun]   # 选节点(缺省用设置里的 node 或第一个)、起内核
nanovpn disconnect                    # 停内核
nanovpn toggle                        # 连/断切换
nanovpn status [--json]               # 状态
nanovpn mode <智能首选|全球直连|全局代理>  # Clash API 切换并记忆
nanovpn tun-setup                     # pkexec setcap 授权
nanovpn install                       # 下载内核到 tools/、装 DMS 插件、链接命令、加状态栏组件
nanovpn uninstall                     # 反向
```

### JSON 输出契约（QML 依赖，字段名固定）

`nanovpn status --json`：

```json
{"state":"connected|stopped|starting|error","node":"🇯🇵东京-E(通用)","mode":"智能首选",
 "tun":true,"ip":"1.2.3.4","ip_age_s":42,"mixed_port":7891,"clash_port":9091,
 "uptime_s":123,"error":""}
```

- `state=stopped` 时 `node/mode/tun` 仍返回设置里的值（供 UI 显示将连什么）。
- `ip`：connected 时经 `socks5h://127.0.0.1:<mixed_port>` 请求 `https://api.ipify.org`；
  结果带 60s 缓存（`ip_age_s`），过期才刷新，避免 QML 轮询打爆。

`nanovpn panel --json`：

```json
{"logged_in":true,"email":"your@email.com","plan":"",
 "used_bytes":123,"total_bytes":456,"used_ratio":0.27,
 "expire_at":1790000000,"expired":false,
 "can_checkin":true,"checkin_days":3,"next_reward_traffic":"3GB"}
```

`nanovpn nodes --json`：

```json
{"nodes":[{"tag":"❇️猎户座-A","type":"tuic","server":"bgpa...","port":18662,"latency_ms":180}],
 "selected":"🇯🇵东京-E(通用)","mode":"智能首选",
 "modes":["智能首选","全球直连","全局代理"]}
```

- `latency_ms` 无测得值为 `null`；`--test` 时并行实测延迟（内核在跑走 Clash API delay 接口，`--no-core` 退回 TCP 拨号近似值，域名先解析，3s 超时）。
- **排序**：`--test` 后（以及任何持有实测延迟的刷新）`.nodes` 按 `latency_ms` 升序排列——
  延迟最低在前，未测得的 `null` 排最后；全部未测时保持订阅原序。
  默认选中节点（设置里的 `node` 缺省时取 `.nodes[0]`）因此指向当前最快的已测节点。
- 节点 = outbounds 里 `type` 不属于 `selector/urltest/direct/block/dns` 的项。
- `modes` 从订阅 route rules 的 `clash_mode` 值去重 + `experimental.clash_api.default_mode`。

`nanovpn checkin`：stdout 打一行中文结果（成功/已签到/失败原因），退出码 0/1。
`nanovpn connect`：成功打 `已连接：<tag>（出口 IP x.x.x.x）`；失败非零退出 + stderr 原因。

## 7. DMS 插件契约（dms/）

- 安装目录 `~/.config/DankMaterialShell/plugins/NanoVpn/`，`plugin.json`：
  `id:"nanoVpn"`（bar 控件列表用它做主键）、`type:"widget"`、`capabilities:["dankbar-widget"]`、
  `component:"./NanoVpnWidget.qml"`、`settings:"./NanoVpnSettings.qml"`、
  `permissions:["settings_read","settings_write"]`、`requires:["nanovpn"]`。
- 控件：`PluginComponent` + `horizontalBarPill`（St yledRect 药丸：DankIcon `vpn_lock`，
  连接时 `Theme.primary`、断开 `Theme.surfaceVariantText`、连接中呼吸动画、错误 `Theme.error`）
  + 可选节点简称文本；`verticalBarPill` 同样提供（竖排状态栏）。
- 弹层 `popoutContent`（`PopoutComponent`）：
  - 标题行（自绘，替代内置 `headerText`）：内置标题是不可交互的 `StyledText`，且内置状态行
    `popoutDetails` 排在内容 Column 之前（会把状态行顶到标题上方），故 `headerText` /
    `detailsText` 均置为 `""`（`visible` 依赖文本长度 → 高度 0，不留空白、无重复状态行），
    改在内容 Column 顶部自绘 `Item`（`id: titleRow`，`width: parent.width`、`height: 40`，
    与内置标题栏等高）：
    `StyledText` 文本 `I18n.trFor("nanoVpn", "Nano VPN")`、`Theme.fontSizeLarge + 4`、
    `Font.Bold`、未悬停 `Theme.surfaceText` / 悬停 `Theme.primary` + `font.underline`；
    `MouseArea`（`anchors.fill`、`hoverEnabled: true`、`cursorShape: Qt.PointingHandCursor`）
    `onClicked: Qt.openUrlExternally(root.officialUrl)`，`officialUrl` 是 root 上的
    `readonly property string`（`https://16.76.177.124/`，唯一出处）；点击只开浏览器，
    不关闭弹层、不改变连接状态，与登录态无关
  - 状态行（自绘，紧随 titleRow 正下方）：复刻内置 popoutDetails 样式（`leftPadding` /
    `bottomPadding: Theme.spacingS`、`font.pixelSize: Theme.fontSizeMedium`、
    `color: Theme.surfaceVariantText`、`wrapMode: Text.WordWrap`），
    `text: root.statusLine`（已连接 <tag> · 出口 IP / 未连接 / 连接中 / 错误原因），
    与内容 Column 其余项之间有 spacingM 间距（可接受，不加负间距 hack）
  - 大连接/断开按钮（DankButton 或自绘 StyledRect+MouseArea）
  - 模式切换（三个 chip：智能首选/全球直连/全局代理）
  - TUN 开关（DankToggle；开时若未授权，toast 提示运行 `nanovpn tun-setup`）
  - 节点列表（可滚动，显示 tag/类型/延迟，按延迟从低到高排序，点击 `nanovpn connect <tag>`；置顶"自动选择"）
  - 底部按钮行：刷新节点 / 测试延迟 / 签到 / 登录·登出（四者平行：`Row` + 显式宽度
    `(parent.width - 3 * Theme.spacingS) / 4`、`spacing: Theme.spacingS`、`buttonHeight: 32`、
    `horizontalPadding: Theme.spacingS`，保证 4w + 3*spacing == parent.width 单行不换行；
    标签按 `panel --json` 的 `logged_in` 切换：未登录显示"登录"并展开弹层内登录表单，
    已登录显示"登出"并执行登出链路；按钮本身不显示账号）
  - 登录表单（仅未登录且点过"登录"按钮时显示，`visible: !root.loggedIn && root.loginFormOpen`，
    `loginFormOpen` 默认 `false`）：邮箱 + 密码（DankTextField，密码掩码可切换），提交按钮
    `enabled: emailField.text.trim().length > 0 && passwordField.text.length > 0`（置灰即
    opacity 0.4），提交走 `nanovpn login <email> <password>`，凭据由 CLI 落盘 0600，插件不存储；
    登录成功 `loginFormOpen = false` 收起表单，失败保持展开、邮箱保留、密码清空
  - 登出链路 `doLogout()`：先 `nanovpn disconnect` 停内核（断开失败不阻断，删凭据不需要内核），
    再 `nanovpn logout` 删凭据与 auth，toast "Logged out and disconnected"（已退出登录并断开连接），
    最后 `fetchPanel()/fetchStatus()/fetchNodes()`：按钮标签回"登录"、表单收起、账号信息区消失
  - 账号信息（仅已登录时显示，顺序固定）：账号 → 流量（`used/total` 文本 + `used_ratio`
    进度条）→ 到期时间 + 连续签到天数（来自 `nanovpn panel --json`）
  - 弹层 `showCloseButton: false`：不显示右上角 ❌，点击弹层外任意处即关闭
- 数据获取：`Proc.runCommand(id, ["nanovpn", ...], cb)`；status 3s 轮询，panel/nodes 在弹层打开时拉。
  命令找不到时 toast 提示运行 `nanovpn install`。
- 操作反馈：`ToastService.showInfo/showError/showWarning(title, msg)`。
- 主题：只用 `Theme.*`（primary/surfaceContainerHigh/surfaceText/outline/spacing*/cornerRadius/fontSize*），
  与 DMS 默认主题一致，不写死颜色。
- `NanoVpnSettings.qml`：`PluginSettings{pluginId:"nanoVpn"}` + ToggleSetting(showNodeLabel)、
  SelectionSetting(pollInterval)、StringSetting(nanoPath，默认 `nanovpn`)。
- `translations/zh_CN.json`：所有用户可见字符串包 `I18n.trFor("nanoVpn", ...)` 并提供中文翻译。

## 8. 验收标准（主 Agent 按此测试）

1. `nanovpn login` 用真实账号登录成功（账号密码由主 Agent 在验收环境中提供，不写入仓库，
   面板 https://account.alibaba.alicdn.men/api/v1）。
2. `nanovpn checkin` 正确区分"签到成功/今天已经签到过了"。
3. `nanovpn nodes` 列出 ≥20 个节点。
4. `nanovpn connect` 后 `curl -x socks5h://127.0.0.1:7891 https://api.ipify.org` 返回境外 IP；
   `nanovpn status --json` 的 state=connected。
5. TUN：`nanovpn tun-setup`（sudo 密码 admin）后 `nanovpn connect --tun`，
   不带代理环境变量 `curl https://api.ipify.org` 也走代理。
6. DMS：插件被 scan/enable，`nanoVpn` 加入 bar rightWidgets，药丸与弹层正常，
   点击连接/断开/切节点/签到均生效。
7. 全部通过后推送 GitHub 新仓库，删除原 `Zhang-Chang-Yuan/nano-client` 仓库。
