#!/usr/bin/env bash
#
# nano-vpn 安装脚本（幂等，可重复执行）
#
# 步骤：
#   ① 检查依赖（curl / jq / python3 / tar）
#   ② 下载 sing-box v1.14.2 linux-amd64 到 tools/sing-box（版本一致则跳过）
#   ③ 链接 ~/.local/bin/nanovpn -> 仓库 bin/nanovpn
#   ④ 拷贝 dms/ 到 ~/.config/DankMaterialShell/plugins/NanoVpn/
#   ⑤ dms ipc call plugin-scan reload nanoVpn      （失败不致命）
#   ⑥ dms ipc call plugins enable nanoVpn          （失败不致命）
#   ⑦ 把 "nanoVpn" 插入 ~/.config/DankMaterialShell/settings.json 的
#      barConfigs[0].rightWidgets（插到 controlCenterButton 前；原子写入 + 备份）
#   ⑧ 提示运行 `nanovpn login`
#
# 注意：本脚本不读取、不保存任何账号密码 / sudo 密码。

set -euo pipefail

# ---------------------------------------------------------------- 路径常量

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_DIR="$SCRIPT_DIR"
TOOLS_DIR="$REPO_DIR/tools"
SINGBOX="$TOOLS_DIR/sing-box"
CLI_ENTRY="$REPO_DIR/bin/nanovpn"

SINGBOX_VERSION="1.14.2"
SINGBOX_TARBALL="sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${SINGBOX_TARBALL}"

BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/nanovpn"

DMS_CONFIG_DIR="$HOME/.config/DankMaterialShell"
DMS_PLUGINS_DIR="$DMS_CONFIG_DIR/plugins"
DMS_PLUGIN_DIR="$DMS_PLUGINS_DIR/NanoVpn"
DMS_SETTINGS="$DMS_CONFIG_DIR/settings.json"

CONFIG_DIR="$HOME/.config/nanovpn"
STATE_DIR="$HOME/.local/state/nanovpn"

WIDGET_ID="nanoVpn"
ANCHOR_WIDGET="controlCenterButton"

# ---------------------------------------------------------------- 日志助手

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info() { printf '%s[install]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

TMP_DIR=""
cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------- ① 依赖检查

info "检查依赖 …"
missing=()
for cmd in curl jq python3 tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    err "缺少依赖：${missing[*]}"
    echo >&2
    if command -v apt-get >/dev/null 2>&1; then
        echo "  sudo apt-get update && sudo apt-get install -y curl jq python3 tar" >&2
    elif command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf install -y curl jq python3 tar" >&2
    elif command -v pacman >/dev/null 2>&1; then
        echo "  sudo pacman -S --needed curl jq python tar" >&2
    else
        echo "  请自行安装：curl jq python3 tar" >&2
    fi
    echo >&2
    die "依赖不满足，安装终止"
fi
ok "依赖齐全（curl / jq / python3 / tar）"

# ---------------------------------------------------------------- ② sing-box 内核

mkdir -p "$TOOLS_DIR"

if [[ -x "$SINGBOX" ]] && "$SINGBOX" version 2>/dev/null | grep -q "sing-box version ${SINGBOX_VERSION}"; then
    ok "sing-box v${SINGBOX_VERSION} 已存在，跳过下载"
else
    info "下载 sing-box v${SINGBOX_VERSION}（linux-amd64）…"
    TMP_DIR="$(mktemp -d)"
    curl -fL --retry 3 --connect-timeout 15 \
        -o "$TMP_DIR/$SINGBOX_TARBALL" "$SINGBOX_URL" \
        || die "下载失败：$SINGBOX_URL"
    tar -xzf "$TMP_DIR/$SINGBOX_TARBALL" -C "$TMP_DIR" \
        || die "解压失败：$TMP_DIR/$SINGBOX_TARBALL"
    extracted="$(find "$TMP_DIR" -type f -name sing-box | head -n1)"
    [[ -n "$extracted" ]] || die "压缩包内未找到 sing-box 可执行文件"
    install -m 0755 "$extracted" "$SINGBOX" || die "安装到 $SINGBOX 失败"
    rm -rf "$TMP_DIR"; TMP_DIR=""
    ok "sing-box v${SINGBOX_VERSION} 已安装到 $SINGBOX"
fi

"$SINGBOX" version >/dev/null 2>&1 || die "$SINGBOX 无法执行"
info "内核版本：$("$SINGBOX" version 2>/dev/null | head -n1)"

# ---------------------------------------------------------------- ③ 命令链接

mkdir -p "$BIN_DIR"
# -n：目标已是符号链接时整体替换，不会链到目录里面去
ln -sfn "$CLI_ENTRY" "$LINK" || die "创建符号链接失败：$LINK"
if [[ -x "$CLI_ENTRY" ]]; then
    ok "命令已链接：$LINK -> $CLI_ENTRY"
else
    warn "仓库内暂未找到 $CLI_ENTRY（CLI 尚未就绪？），链接已创建但暂不可用"
fi
case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *) warn "~/.local/bin 不在 PATH 中，可能需要重新登录或手动 export PATH=\$HOME/.local/bin:\$PATH" ;;
esac

# ---------------------------------------------------------------- ④ DMS 插件

mkdir -p "$DMS_PLUGINS_DIR"
if [[ -f "$REPO_DIR/dms/plugin.json" ]]; then
    rm -rf "$DMS_PLUGIN_DIR"
    cp -a "$REPO_DIR/dms" "$DMS_PLUGIN_DIR" || die "拷贝插件到 $DMS_PLUGIN_DIR 失败"
    ok "DMS 插件已安装：$DMS_PLUGIN_DIR"
else
    warn "dms/plugin.json 不存在，跳过插件拷贝"
fi

# ---------------------------------------------------------------- 运行时目录

mkdir -p "$CONFIG_DIR" "$STATE_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- ⑤⑥ DMS IPC（失败不致命）

dms_ipc() {
    # $1=target $2=function $3=arg；统一容错：命令不存在 / DMS 未运行 / 插件未识别 都不致命
    local target="$1" fn="$2" arg="$3" out rc
    if ! command -v dms >/dev/null 2>&1; then
        warn "找不到 dms 命令，跳过：dms ipc call $target $fn $arg"
        return 1
    fi
    set +e
    out="$(dms ipc call "$target" "$fn" "$arg" 2>&1)"
    rc=$?
    set -e
    if (( rc != 0 )); then
        warn "dms ipc call $target $fn $arg 失败（退出码 $rc）：${out:-无输出}"
        return 1
    fi
    # dms ipc 的部分失败也以退出码 0 返回，错误信息只在输出里
    if printf '%s' "$out" | grep -Eqi 'error|not_found|not found|unknown|failed|失败'; then
        warn "dms ipc call $target $fn $arg 未成功：${out}"
        return 1
    fi
    ok "dms ipc call $target $fn $arg：${out:-已执行}"
    return 0
}

dms_ipc plugin-scan reload "$WIDGET_ID" || true
dms_ipc plugins enable "$WIDGET_ID" || true

# ---------------------------------------------------------------- ⑦ 状态栏组件写入

# 用 python3 原子改写 settings.json：
#   - "nanoVpn" 已存在则跳过（幂等）
#   - 插到 barConfigs[0].rightWidgets 的 "controlCenterButton" 前，没有则追加
#   - 先备份 settings.json.bak，再写同目录临时文件后 rename（原子）
#   - DMS 运行时 watchChanges 会自动重载，无需重启
# 退出码：0=已插入  2=已存在跳过  3=无法处理（缺文件/结构不符）  1=读写错误
info "更新 DMS 状态栏组件 …"
if python3 - "$DMS_SETTINGS" "$WIDGET_ID" "$ANCHOR_WIDGET" <<'PY'
import json, os, shutil, stat, sys, tempfile

path, widget, anchor = sys.argv[1], sys.argv[2], sys.argv[3]

if not os.path.isfile(path):
    print(f"未找到 {path}（DMS 尚未生成配置？），跳过状态栏组件插入", flush=True)
    sys.exit(3)

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"解析 {path} 失败：{e}", flush=True)
    sys.exit(1)

bar_configs = data.get("barConfigs")
if not isinstance(bar_configs, list) or not bar_configs or not isinstance(bar_configs[0], dict):
    print("settings.json 中没有可用的 barConfigs[0]，跳过", flush=True)
    sys.exit(3)

widgets = bar_configs[0].get("rightWidgets")
if widgets is None:
    widgets = []
    bar_configs[0]["rightWidgets"] = widgets
if not isinstance(widgets, list):
    print("barConfigs[0].rightWidgets 不是数组，跳过", flush=True)
    sys.exit(3)

if widget in widgets:
    print(f"\"{widget}\" 已在 rightWidgets 中，跳过", flush=True)
    sys.exit(2)

idx = widgets.index(anchor) if anchor in widgets else len(widgets)
widgets.insert(idx, widget)

# 备份原文件
bak = path + ".bak"
try:
    shutil.copyfile(path, bak)
except Exception as e:
    print(f"备份 {bak} 失败：{e}", flush=True)
    sys.exit(1)

# 原子写入：同目录临时文件 + rename，保留原权限
tmp = None
try:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    fd, tmp = tempfile.mkstemp(prefix=".settings.json.", suffix=".tmp",
                               dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    tmp = None
except Exception as e:
    print(f"写入 {path} 失败：{e}", flush=True)
    sys.exit(1)

print(f"已将 \"{widget}\" 插入 {path} 的 rightWidgets（原文件备份为 {bak}）", flush=True)
sys.exit(0)
PY
then
    rc=0
else
    rc=$?
fi

case "$rc" in
    0) ok "状态栏组件已添加，DMS 会自动重载（若未生效可重启 DMS）" ;;
    2) ok "状态栏组件已存在，跳过" ;;
    3) warn "未能自动改写 settings.json，请手动在 设置 → 状态栏 → 右侧组件 中添加 NanoVpn" ;;
    *) die "settings.json 更新失败（退出码 $rc）" ;;
esac

# ---------------------------------------------------------------- ⑧ 收尾提示

cat <<EOF

${C_BOLD}安装完成。下一步：${C_RESET}

  1) 登录（密码仅本地保存，权限 0600）：
       nanovpn login
  2) 连接（默认用订阅配置里的 mixed 代理，端口 7891）：
       nanovpn connect
  3) （推荐）TUN 全局接管——先授权内核，再连接：
       nanovpn tun-setup      # pkexec 弹窗输密码，给内核加 cap_net_admin,cap_net_raw
       nanovpn connect --tun

  DMS 状态栏：右侧组件已出现 NanoVpn 药丸，点击可打开弹层
  （连接/断开、切换模式、选节点、签到、查看流量）。
  若药丸未出现：设置 → Plugins 里手动启用 NanoVpn。

  协议细节来自对 Nano APK 的逆向，见 docs/SPEC.md 与 README.md。
EOF
