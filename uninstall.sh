#!/usr/bin/env bash
#
# nano-vpn 卸载脚本
#
# 步骤：
#   1. 停止 sing-box 内核（nanovpn disconnect，失败继续；PID 文件兜底）
#   2. 从 ~/.config/DankMaterialShell/settings.json 的 rightWidgets 移除 "nanoVpn"
#   3. 删除插件目录 ~/.config/DankMaterialShell/plugins/NanoVpn/
#   4. 删除符号链接 ~/.local/bin/nanovpn
#   5. 删除运行时目录 ~/.config/nanovpn 与 ~/.local/state/nanovpn
#
# 不会删除仓库内任何文件（包括 tools/sing-box），也不会动 TUN capability。
# 交互确认，-y / --yes 跳过。

set -euo pipefail

# ---------------------------------------------------------------- 参数

ASSUME_YES=0
usage() {
    cat <<'EOF'
用法：uninstall.sh [-y|--yes]

  -y, --yes   跳过交互确认，直接卸载
  -h, --help  显示本帮助
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '未知参数：%s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- 路径常量

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/nanovpn"

DMS_CONFIG_DIR="$HOME/.config/DankMaterialShell"
DMS_PLUGIN_DIR="$DMS_CONFIG_DIR/plugins/NanoVpn"
DMS_SETTINGS="$DMS_CONFIG_DIR/settings.json"

CONFIG_DIR="$HOME/.config/nanovpn"
STATE_DIR="$HOME/.local/state/nanovpn"

WIDGET_ID="nanoVpn"
ANCHOR_WIDGET="controlCenterButton"   # 仅作说明，移除时不需要

# ---------------------------------------------------------------- 日志助手

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

info() { printf '%s[uninstall]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# ---------------------------------------------------------------- 交互确认

if (( ASSUME_YES == 0 )); then
    if [[ ! -t 0 ]]; then
        err "非交互终端，请使用 -y 确认卸载"
        exit 2
    fi
    cat <<EOF
${C_BOLD}将执行以下操作：${C_RESET}
  - 停止 sing-box 内核（如正在运行）
  - 从 $DMS_SETTINGS 移除 "$WIDGET_ID" 组件（会先备份 .bak）
  - 删除插件目录 $DMS_PLUGIN_DIR
  - 删除符号链接 $LINK
  - 删除配置目录 $CONFIG_DIR（含账号密码）
  - 删除状态目录 $STATE_DIR（含 JWT、订阅、日志）
${C_BOLD}不会删除：${C_RESET}仓库文件（含 tools/sing-box）、TUN capability、settings.json.bak
EOF
    read -r -p "确认卸载？输入 yes 继续，其它任意键取消: " answer
    [[ "$answer" == "yes" ]] || { info "已取消"; exit 0; }
fi

# ---------------------------------------------------------------- 1. 停止内核

NANOVPN="$LINK"
[[ -x "$NANOVPN" ]] || NANOVPN="$REPO_DIR/bin/nanovpn"

if [[ -x "$NANOVPN" ]]; then
    if "$NANOVPN" disconnect >/dev/null 2>&1; then
        ok "内核已停止（nanovpn disconnect）"
    else
        warn "nanovpn disconnect 失败（可能本就未连接），继续"
    fi
else
    warn "找不到 nanovpn 命令，尝试用 PID 文件停止内核"
fi

PID_FILE="$STATE_DIR/sing-box.pid"
if [[ -f "$PID_FILE" ]]; then
    pid="$(tr -dc '0-9' < "$PID_FILE" | head -c 10 || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        info "结束 sing-box 进程 PID $pid"
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.3
        done
        kill -0 "$pid" 2>/dev/null && { kill -9 "$pid" 2>/dev/null || true; }
        ok "sing-box 进程已结束"
    fi
    rm -f "$PID_FILE"
fi

# ---------------------------------------------------------------- 2. 移除状态栏组件

# 退出码：0=已移除  2=原本不存在  3=无法处理  1=读写错误（不致命， warn 后继续）
if [[ -f "$DMS_SETTINGS" ]]; then
    info "从 settings.json 移除 $WIDGET_ID 组件 …"
    if python3 - "$DMS_SETTINGS" "$WIDGET_ID" <<'PY'
import json, os, shutil, stat, sys, tempfile

path, widget = sys.argv[1], sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"解析 {path} 失败：{e}", flush=True)
    sys.exit(1)

bar_configs = data.get("barConfigs")
if not isinstance(bar_configs, list):
    print("settings.json 中没有 barConfigs，跳过", flush=True)
    sys.exit(3)

removed = False
for bar in bar_configs:
    if not isinstance(bar, dict):
        continue
    widgets = bar.get("rightWidgets")
    if isinstance(widgets, list) and widget in widgets:
        widgets[:] = [w for w in widgets if w != widget]
        removed = True

if not removed:
    print(f"\"{widget}\" 不在任何 rightWidgets 中，跳过", flush=True)
    sys.exit(2)

bak = path + ".bak"
try:
    shutil.copyfile(path, bak)
except Exception as e:
    print(f"备份 {bak} 失败：{e}", flush=True)
    sys.exit(1)

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

print(f"已从 {path} 移除 \"{widget}\"（原文件备份为 {bak}）", flush=True)
sys.exit(0)
PY
    then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
        0) ok "状态栏组件已移除，DMS 会自动重载" ;;
        2) ok "状态栏组件原本就不存在" ;;
        3) warn "settings.json 结构异常，未做改动" ;;
        *) warn "settings.json 更新失败（退出码 $rc），请手动移除 $WIDGET_ID 组件" ;;
    esac
else
    warn "未找到 $DMS_SETTINGS，跳过组件移除"
fi

# ---------------------------------------------------------------- 3. 插件目录

if [[ -d "$DMS_PLUGIN_DIR" ]]; then
    rm -rf "$DMS_PLUGIN_DIR"
    ok "已删除插件目录 $DMS_PLUGIN_DIR"
else
    ok "插件目录不存在，跳过"
fi

# ---------------------------------------------------------------- 4. 命令符号链接

if [[ -L "$LINK" ]]; then
    rm -f "$LINK"
    ok "已删除符号链接 $LINK"
elif [[ -e "$LINK" ]]; then
    warn "$LINK 不是符号链接（可能是真实文件），未删除，请手动确认"
else
    ok "符号链接不存在，跳过"
fi

# ---------------------------------------------------------------- 5. 运行时目录

for dir in "$CONFIG_DIR" "$STATE_DIR"; do
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        ok "已删除 $dir"
    else
        ok "$dir 不存在，跳过"
    fi
done

# ---------------------------------------------------------------- 收尾提示

cat <<EOF

${C_BOLD}卸载完成。${C_RESET}

保留内容：
  - 仓库本身（$REPO_DIR），确认不用后可手动：rm -rf $REPO_DIR
  - tools/sing-box 内核（随仓库一起保留）
  - settings.json.bak 备份（确认无误后可手动删除）
  - sing-box 的 TUN capability（撤销命令：sudo setcap -r $REPO_DIR/tools/sing-box）

EOF
