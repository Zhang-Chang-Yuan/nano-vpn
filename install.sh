#!/usr/bin/env bash
#
# nano-vpn 安装脚本（幂等，可重复执行）—— **只负责系统侧**
#
#   /opt/nano-vpn/                      应用本体（root:root，含 tools/sing-box）
#   /usr/local/bin/nanovpn              符号链接 → /opt/nano-vpn/bin/nanovpn
#   tools/sing-box                      授予 cap_net_admin,cap_net_raw（TUN 需要）
#
# 本脚本**不会写 $HOME 下任何东西**：
#   - 每个用户的配置在第一次运行 `nanovpn` 时，由 CLI 在自己的家目录初始化
#     （$XDG_CONFIG_HOME/nanovpn、$XDG_STATE_HOME/nanovpn、$XDG_CACHE_HOME/nanovpn），
#     因此不同用户天然拥有各自独立的配置；
#   - DMS 状态栏插件是用户级内容，用 `nanovpn install-dms` 安装（不需要 root）。
#
# 注意：本脚本不读取、不保存任何账号密码 / sudo 密码。

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SRC_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

PREFIX="${NANOVPN_PREFIX:-/opt/nano-vpn}"
CLI_LINK="/usr/local/bin/nanovpn"

SINGBOX_VERSION="1.14.2"
SINGBOX_TARBALL="sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
SINGBOX_PATH="SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${SINGBOX_TARBALL}"
# 默认先走 GitHub；网络不通时依次回退到公共加速镜像（可用 --singbox-url 指定单一地址）
SINGBOX_URL="${NANOVPN_SINGBOX_URL:-}"
SINGBOX_MIRRORS=(
    "https://github.com/$SINGBOX_PATH"
    "https://gh-proxy.com/https://github.com/$SINGBOX_PATH"
    "https://ghproxy.net/https://github.com/$SINGBOX_PATH"
)

DO_CAP=1
DO_LINK=1

usage() {
    cat <<EOF
用法：sudo $0 [选项]

  --prefix DIR   安装前缀（默认 $PREFIX，也可用环境变量 NANOVPN_PREFIX）
  --singbox-url URL  指定 sing-box 下载地址（默认 GitHub，失败自动回退镜像）
  --no-cap       不执行 setcap（TUN 需要时再运行 nanovpn tun-setup）
  --no-link      不创建 $CLI_LINK
  -h, --help     显示本帮助

安装结果：
  $PREFIX/{bin,lib,dms,docs,tools/sing-box,install.sh,uninstall.sh}
  $CLI_LINK → $PREFIX/bin/nanovpn

安装后（每个用户各自执行）：
  nanovpn login          # 首次运行会自动在用户目录初始化配置（XDG 规范）
  nanovpn install-dms    # 可选：安装 DMS 状态栏插件（用户级，不需要 root）
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --prefix)    PREFIX="${2:?--prefix 需要一个目录}"; shift 2 ;;
        --prefix=*)  PREFIX="${1#*=}"; shift ;;
        --singbox-url)   SINGBOX_URL="${2:?--singbox-url 需要一个 URL}"; shift 2 ;;
        --singbox-url=*) SINGBOX_URL="${1#*=}"; shift ;;
        --no-cap)    DO_CAP=0; shift ;;
        --no-link)   DO_LINK=0; shift ;;
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

info() { printf '%s[install]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

TMP_DIR=""
cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------- 前置检查

if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
        info "安装到 $PREFIX 需要管理员权限，改用 sudo 继续 …"
        exec sudo -- bash "$SCRIPT_PATH" "$@"
    fi
    die "需要 root 才能安装到 $PREFIX。请运行：sudo $SCRIPT_PATH $*"
fi

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

# ---------------------------------------------------------------- ① 安装应用文件

info "安装应用到 $PREFIX …"
install -d -m 0755 "$PREFIX" "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/dms" "$PREFIX/docs" "$PREFIX/tools"

if [[ "$SRC_DIR" == "$PREFIX" ]]; then
    ok "源目录就是安装前缀，跳过文件拷贝（从源码仓库执行才能升级）"
else
    rm -rf "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/dms" "$PREFIX/docs"
    cp -a "$SRC_DIR/bin" "$PREFIX/bin"
    cp -a "$SRC_DIR/lib" "$PREFIX/lib"
    cp -a "$SRC_DIR/dms" "$PREFIX/dms"
    [[ -d "$SRC_DIR/docs" ]] && cp -a "$SRC_DIR/docs" "$PREFIX/docs"
    for f in README.md LICENSE LICENSE-NOTE.md; do
        [[ -f "$SRC_DIR/$f" ]] && install -m 0644 "$SRC_DIR/$f" "$PREFIX/$f"
    done
    install -m 0755 "$SRC_DIR/install.sh" "$PREFIX/install.sh"
    install -m 0755 "$SRC_DIR/uninstall.sh" "$PREFIX/uninstall.sh"
    chmod 0755 "$PREFIX/bin/nanovpn" "$PREFIX/lib/nodes.py"
    chmod 0644 "$PREFIX"/lib/*.sh
    ok "应用文件已安装（bin/ lib/ dms/ docs/ + install.sh uninstall.sh）"
fi
# 前缀归 root：内核带 cap_net_admin，必须不可被普通用户改写
chown -R root:root "$PREFIX" 2>/dev/null || true
chmod 0755 "$PREFIX"

# ---------------------------------------------------------------- ② sing-box 内核

SINGBOX="$PREFIX/tools/sing-box"
if [[ -x "$SINGBOX" ]] && "$SINGBOX" version 2>/dev/null | grep -q "sing-box version ${SINGBOX_VERSION}"; then
    ok "sing-box v${SINGBOX_VERSION} 已存在，跳过下载"
else
    info "下载 sing-box v${SINGBOX_VERSION}（linux-amd64）…"
    TMP_DIR="$(mktemp -d)"
    urls=()
    if [[ -n "$SINGBOX_URL" ]]; then urls=("$SINGBOX_URL"); else urls=("${SINGBOX_MIRRORS[@]}"); fi
    got=0
    for url in "${urls[@]}"; do
        info "  下载地址：$url"
        if curl -fL --retry 1 --retry-delay 2 --connect-timeout 10 --max-time 1200 \
                -o "$TMP_DIR/$SINGBOX_TARBALL" "$url"; then
            got=1; break
        fi
        warn "  该地址不可用，换下一个"
    done
    (( got )) || die "所有下载地址都失败（可用 --singbox-url 指定可用地址）"
    tar -tzf "$TMP_DIR/$SINGBOX_TARBALL" >/dev/null 2>&1 \
        || die "压缩包校验失败：$TMP_DIR/$SINGBOX_TARBALL"
    tar -xzf "$TMP_DIR/$SINGBOX_TARBALL" -C "$TMP_DIR" \
        || die "解压失败：$TMP_DIR/$SINGBOX_TARBALL"
    extracted="$(find "$TMP_DIR" -type f -name sing-box | head -n1)"
    [[ -n "$extracted" ]] || die "压缩包内未找到 sing-box 可执行文件"
    install -m 0755 -o root -g root "$extracted" "$SINGBOX" || die "安装到 $SINGBOX 失败"
    rm -rf "$TMP_DIR"; TMP_DIR=""
    ok "sing-box v${SINGBOX_VERSION} 已安装到 $SINGBOX"
fi
chown root:root "$SINGBOX" 2>/dev/null || true
"$SINGBOX" version >/dev/null 2>&1 || die "$SINGBOX 无法执行"
info "内核版本：$("$SINGBOX" version 2>/dev/null | head -n1)"

# ---------------------------------------------------------------- ③ TUN capability

if (( DO_CAP )); then
    setcap_bin=""
    for c in "$(command -v setcap 2>/dev/null || true)" /usr/sbin/setcap /sbin/setcap /usr/bin/setcap; do
        [[ -n "$c" && -x "$c" ]] && { setcap_bin="$c"; break; }
    done
    if [[ -n "$setcap_bin" ]]; then
        if "$setcap_bin" cap_net_admin,cap_net_raw+eip "$SINGBOX"; then
            ok "已授予 cap_net_admin,cap_net_raw：$SINGBOX"
        else
            warn "setcap 失败；TUN 模式需手动运行：sudo setcap cap_net_admin,cap_net_raw+eip $SINGBOX"
        fi
    else
        warn "找不到 setcap，跳过 TUN 授权（需要时运行 nanovpn tun-setup）"
    fi
else
    info "--no-cap：跳过 setcap（TUN 需要时运行 nanovpn tun-setup）"
fi

# ---------------------------------------------------------------- ④ 命令链接

if (( DO_LINK )); then
    install -d -m 0755 "$(dirname "$CLI_LINK")"
    ln -sfn "$PREFIX/bin/nanovpn" "$CLI_LINK" || die "创建符号链接失败：$CLI_LINK"
    ok "命令已链接：$CLI_LINK → $PREFIX/bin/nanovpn"
    case ":$PATH:" in
        *":$(dirname "$CLI_LINK"):"*) : ;;
        *) warn "$(dirname "$CLI_LINK") 不在当前 PATH 中，可能需要重新登录" ;;
    esac
else
    info "--no-link：跳过 $CLI_LINK（可直接用 $PREFIX/bin/nanovpn）"
fi

# ---------------------------------------------------------------- 收尾

cat <<EOF

${C_BOLD}系统侧安装完成（未触碰任何用户目录）。${C_RESET}

  应用：$PREFIX
  内核：$SINGBOX（cap_net_admin,cap_net_raw）
  命令：$CLI_LINK → $PREFIX/bin/nanovpn

每个用户在自己的会话里执行（配置在首次运行时自动初始化到各自家目录）：

  1) nanovpn login          # 交互式输入邮箱密码（仅本地 0600 保存）
  2) nanovpn connect        # 连接（默认智能首选 + 设置里的节点）
  3) nanovpn connect --tun  # TUN 全局接管（能力已授权，无需再 tun-setup）
  4) nanovpn install-dms    # 可选：安装 DMS 状态栏插件（用户级，不需要 root）

  配置：~/.config/nanovpn（XDG_CONFIG_HOME）
  状态：~/.local/state/nanovpn（XDG_STATE_HOME）
  缓存：~/.cache/nanovpn（XDG_CACHE_HOME）
EOF
