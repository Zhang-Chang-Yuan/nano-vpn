#!/usr/bin/env bash
#
# nano-vpn 卸载脚本 —— **只负责系统侧**
#
#   /usr/local/bin/nanovpn    删除符号链接（只删链接，普通文件不动）
#   /opt/nano-vpn/            删除安装前缀（含 sing-box 内核与其 capability）
#
# 本脚本**不会碰 $HOME 下任何东西**（多用户环境下不应由 root 代删某个用户的数据）。
# 用户级内容的清理请由各用户自己执行：
#   nanovpn uninstall-dms     # 移除 DMS 状态栏插件与状态栏组件
#   rm -rf ~/.config/nanovpn ~/.local/state/nanovpn ~/.cache/nanovpn   # 删配置/状态/缓存
#
# 交互确认，-y / --yes 跳过。

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

PREFIX="${NANOVPN_PREFIX:-/opt/nano-vpn}"
CLI_LINK="/usr/local/bin/nanovpn"

ASSUME_YES=0
KEEP_APP=0

usage() {
    cat <<EOF
用法：sudo $0 [-y|--yes] [选项]

  -y, --yes     跳过交互确认
  --prefix DIR  安装前缀（默认 $PREFIX）
  --keep-app    保留安装前缀，只删 $CLI_LINK
  -h, --help    显示本帮助
EOF
}

while (( $# > 0 )); do
    case "$1" in
        -y|--yes)    ASSUME_YES=1; shift ;;
        --prefix)    PREFIX="${2:?--prefix 需要一个目录}"; shift 2 ;;
        --prefix=*)  PREFIX="${1#*=}"; shift ;;
        --keep-app)  KEEP_APP=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) printf '未知参数：%s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$PREFIX" in
    /*) ;;
    *) printf '安装前缀必须是绝对路径：%s\n' "$PREFIX" >&2; exit 2 ;;
esac
if [[ "$PREFIX" == "/" || "$PREFIX" == "/opt" || "$PREFIX" == "/usr" || "$PREFIX" == "/usr/local" ]]; then
    printf '拒绝把安装前缀设为 %s（过于宽泛，可能误删系统目录）\n' "$PREFIX" >&2
    exit 2
fi

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
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- 前置检查

if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
        info "卸载 $PREFIX 需要管理员权限，改用 sudo 继续 …"
        exec sudo -- bash "$SCRIPT_PATH" "$@"
    fi
    die "需要 root 才能卸载 $PREFIX。请运行：sudo $SCRIPT_PATH $*"
fi

# ---------------------------------------------------------------- 运行中的内核

# 删除内核二进制前必须先停掉进程：否则它会继续活着、继续持有 cap_net_admin 与 TUN，
# 而磁盘上的文件已经没了，用户很难再定位和收拾它。
stop_running_kernel() {
    local pat="$PREFIX/tools/sing-box" pids
    pids="$(pgrep -f "$pat" 2>/dev/null || true)"
    [[ -z "$pids" ]] && return 0
    info "检测到仍在运行的内核（PID：$(printf '%s' "$pids" | tr '\n' ' ')），先停止 …"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6; do
        pgrep -f "$pat" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pids="$(pgrep -f "$pat" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        warn "进程未响应 TERM，强制结束"
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
    ok "内核已停止"
}

# ---------------------------------------------------------------- 交互确认

if (( ASSUME_YES == 0 )); then
    if [[ ! -t 0 ]]; then
        err "非交互终端，请使用 -y 确认卸载"
        exit 2
    fi
    cat <<EOF
${C_BOLD}将执行以下操作：${C_RESET}
  - 删除符号链接 $CLI_LINK（只删链接，普通文件不动）
EOF
    if (( KEEP_APP )); then
        echo "  - 保留安装前缀 $PREFIX（--keep-app）"
    else
        echo "  - 删除安装前缀 $PREFIX（含 sing-box 内核与其 capability）"
        echo "  - 若内核仍在运行，会先停止该进程"
    fi
    cat <<EOF
${C_BOLD}不会碰 \$HOME：${C_RESET}用户级内容请各自执行
  nanovpn uninstall-dms
  rm -rf ~/.config/nanovpn ~/.local/state/nanovpn ~/.cache/nanovpn
EOF
    read -r -p "确认卸载？输入 yes 继续，其它任意键取消: " answer
    [[ "$answer" == "yes" ]] || { info "已取消"; exit 0; }
fi

# ---------------------------------------------------------------- ① 安装前缀

if (( KEEP_APP )); then
    info "--keep-app：保留安装前缀 $PREFIX"
elif [[ -d "$PREFIX" ]]; then
    stop_running_kernel
    rm -rf "$PREFIX"
    ok "已删除安装前缀 $PREFIX（含内核与其 capability）"
else
    ok "$PREFIX 不存在，跳过"
fi

# ---------------------------------------------------------------- ② 命令链接

if [[ -L "$CLI_LINK" ]]; then
    rm -f "$CLI_LINK"
    ok "已删除符号链接 $CLI_LINK"
elif [[ -e "$CLI_LINK" ]]; then
    warn "$CLI_LINK 不是符号链接（可能是真实文件），未删除，请手动确认"
else
    ok "$CLI_LINK 不存在，跳过"
fi

# ---------------------------------------------------------------- 收尾

cat <<EOF

${C_BOLD}系统侧卸载完成。${C_RESET}

未触碰 \$HOME。各用户如需清理自己的数据：

  nanovpn uninstall-dms      # 移除 DMS 状态栏插件与组件（需在删除 /opt 之前执行）
  rm -rf ~/.config/nanovpn ~/.local/state/nanovpn ~/.cache/nanovpn

保留内容：源码仓库（应用是从它安装出去的拷贝）、DMS settings.json.bak。
EOF
