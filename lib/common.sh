#!/usr/bin/env bash
# nanovpn 公共函数：路径常量、日志、settings/credentials 读写
# 应用安装在 /opt/nano-vpn（可用 NANOVPN_HOME 覆盖，也兼容仓库内直接运行）；
# 用户数据遵循 XDG，且**每个用户各自独立**，由 CLI 首次运行时初始化：
#   配置 ~/.config/nanovpn、状态 ~/.local/state/nanovpn、可再生缓存 ~/.cache/nanovpn
# 命令经 /usr/local/bin/nanovpn 软链接暴露；用户目录里只有 DMS 插件是软链接
# （指向 /opt/nano-vpn/dms，DMS 只从用户配置目录发现插件），配置/状态/缓存都是真实文件
set -euo pipefail

# 应用安装根目录（默认 /opt/nano-vpn；经 /usr/local/bin/nanovpn 软链接调用时
# 用 readlink -f 解析真实路径，仓库内直接跑同样成立）
NANOVPN_HOME="${NANOVPN_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
NANOVPN_LIB="$NANOVPN_HOME/lib"
NANOVPN_TOOLS="$NANOVPN_HOME/tools"
# sing-box 内核：安装后即 /opt/nano-vpn/tools/sing-box；可用 NANOVPN_SING_BOX 覆盖
NANOVPN_SING_BOX="${NANOVPN_SING_BOX:-$NANOVPN_TOOLS/sing-box}"

# XDG 目录：环境变量是绝对路径时才用（规范要求忽略相对路径），否则回退到 $HOME 下默认位置
nvp_xdg_dir() {
  local var="$1" fallback="$2" val="${!1:-}"
  if [[ -n "$val" && "$val" == /* ]]; then printf '%s' "$val"; else printf '%s/%s' "$HOME" "$fallback"; fi
}

# 用户数据目录
NANOVPN_CONFIG_DIR="$(nvp_xdg_dir XDG_CONFIG_HOME .config)/nanovpn"
NANOVPN_STATE_DIR="$(nvp_xdg_dir XDG_STATE_HOME .local/state)/nanovpn"
NANOVPN_SETTINGS="$NANOVPN_CONFIG_DIR/settings"        # KEY=VALUE
NANOVPN_CREDENTIALS="$NANOVPN_CONFIG_DIR/credentials"  # email/password，0600
NANOVPN_AUTH="$NANOVPN_STATE_DIR/auth"                 # 裸 JWT，0600
NANOVPN_SUBSCRIPTION="$NANOVPN_STATE_DIR/subscription.json"
NANOVPN_NODES="$NANOVPN_STATE_DIR/nodes.json"
NANOVPN_RUNTIME="$NANOVPN_STATE_DIR/runtime.json"
NANOVPN_PANEL="$NANOVPN_STATE_DIR/panel.json"
NANOVPN_STATUS="$NANOVPN_STATE_DIR/status.json"
NANOVPN_IP_CACHE="$NANOVPN_STATE_DIR/ip.json"          # 出口 IP，60s 缓存
NANOVPN_PID_FILE="$NANOVPN_STATE_DIR/sing-box.pid"
NANOVPN_LOG="$NANOVPN_STATE_DIR/sing-box.log"
NANOVPN_CACHE_DIR="$(nvp_xdg_dir XDG_CACHE_HOME .cache)/nanovpn"  # sing-box -D 工作目录（远程规则集/fakeip，可再生）
NANOVPN_LAST_ERROR="$NANOVPN_STATE_DIR/last_error"

# 面板 API 的 UA 白名单：UA 不含 "dart" 时返回 HTTP 200 但 body 为空
NANOVPN_UA_DART="Dart/3.11.5 (dart:io)"
# 拉订阅必须用 sing-box UA 才能拿到完整 sing-box JSON；Dart UA 会 500；空 UA 是 base64 降级格式
NANOVPN_UA_SINGBOX="sing-box/1.14.0"

# 默认设置（SPEC 第 5 节）
NANOVPN_DEFAULT_MIXED_PORT=7891
NANOVPN_DEFAULT_CLASH_PORT=9091
NANOVPN_DEFAULT_MODE="智能首选"
NANOVPN_DEFAULT_SELECTOR_TAG="🚀 节点选择"
NANOVPN_DEFAULT_URLTEST_TAG="♻️ 自动选择"

# ---------------------------------------------------------------- 日志

nvp_log_info()  { printf '%s\n' "$*"; }
nvp_log_warn()  { printf '警告：%s\n' "$*" >&2; }
nvp_log_error() { printf '错误：%s\n' "$*" >&2; }
nvp_die()       { nvp_log_error "$*"; exit 1; }

# ---------------------------------------------------------------- 目录

nvp_ensure_dirs() {
  mkdir -p "$NANOVPN_CONFIG_DIR" "$NANOVPN_STATE_DIR" "$NANOVPN_CACHE_DIR"
  chmod 700 "$NANOVPN_CONFIG_DIR" "$NANOVPN_STATE_DIR" "$NANOVPN_CACHE_DIR" 2>/dev/null || true
}

# 迁移：旧版安装器把命令软链接放在 ~/.local/bin/nanovpn。
# 现在命令统一在 /usr/local/bin（系统目录），用户目录里不该再有它 —— 只删指向本项目的软链接。
nvp_migrate_legacy_link() {
  local legacy="$HOME/.local/bin/nanovpn" raw=""
  [[ -L "$legacy" ]] || return 0
  raw="$(readlink "$legacy" 2>/dev/null || true)"
  case "$raw" in
    *nanovpn*|*nano-vpn*)
      rm -f "$legacy" && nvp_log_warn "已清理旧版遗留的软链接：$legacy（命令现在在 /usr/local/bin/nanovpn）"
      ;;
  esac
  return 0
}

# 首次运行初始化用户配置：建 XDG 目录 + 写一份带注释的默认 settings（已存在则不动）。
# 安装脚本不碰 $HOME，用户目录就是在这里、以当前用户身份生成的 —— 多用户互不影响。
nvp_init_user_config() {
  nvp_ensure_dirs
  nvp_migrate_legacy_link
  [[ -f "$NANOVPN_SETTINGS" ]] && return 0
  local tmp
  tmp="$(mktemp "$NANOVPN_CONFIG_DIR/.settings.XXXXXX")"
  cat > "$tmp" <<EOF
# nanovpn 用户配置 —— 首次运行 nanovpn 时自动生成，属于用户 $(id -un)，不同用户各自独立。
# 格式：每行 KEY=VALUE；# 开头为注释。删除本文件不影响登录态，下次运行会重新生成。

# 面板 API base（登录后自动发现并写入，一般不用手改）
#panel_api_base=

# 本地混合代理端口（SOCKS5 + HTTP 共用，默认 $NANOVPN_DEFAULT_MIXED_PORT）
mixed_port=$NANOVPN_DEFAULT_MIXED_PORT

# Clash API 端口（面板/延迟测试用，默认 $NANOVPN_DEFAULT_CLASH_PORT）
clash_port=$NANOVPN_DEFAULT_CLASH_PORT

# 分流模式：智能首选 / 全球直连 / 全局代理
mode=$NANOVPN_DEFAULT_MODE

# TUN 全局接管：1=启用 0=关闭（等价于 connect --tun / --no-tun）
tun=0

# sing-box 日志级别：trace / debug / info / warn / error
log_level=warn

# 上次使用的节点（由 connect 自动写入）
#node=
EOF
  chmod 600 "$tmp"
  mv "$tmp" "$NANOVPN_SETTINGS"
  if [[ -t 2 ]]; then
    printf '首次运行：已在 %s 初始化用户配置（XDG 规范，仅属于当前用户）\n' "$NANOVPN_CONFIG_DIR" >&2
  fi
}

# ---------------------------------------------------------------- sing-box 内核

# 确认 NANOVPN_SING_BOX 可用：不可执行时回退到 PATH 里的 sing-box
# （仓库内尚未安装内核、但系统已装 sing-box 的情况）；回退警告只发一次。
nvp_require_singbox() {
  if [[ -x "$NANOVPN_SING_BOX" ]]; then return 0; fi
  local sb_path
  sb_path="$(command -v sing-box 2>/dev/null || true)"
  if [[ -n "$sb_path" && -x "$sb_path" ]]; then
    if [[ -z "${NVP_SINGBOX_FALLBACK_WARNED:-}" ]]; then
      nvp_log_warn "未找到 $NANOVPN_SING_BOX，改用 PATH 中的 sing-box：$sb_path"
      NVP_SINGBOX_FALLBACK_WARNED=1
    fi
    NANOVPN_SING_BOX="$sb_path"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- settings（KEY=VALUE，节点 tag 含 emoji/空格，单独一行存）

# 读一个设置；值为空时返回默认值
nvp_settings_get() {
  local key="$1" default="${2:-}" val=""
  if [[ -f "$NANOVPN_SETTINGS" ]]; then
    val="$(sed -n "s/^${key}=//p" "$NANOVPN_SETTINGS" | head -n1)"
  fi
  if [[ -z "$val" ]]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# 写一个设置：先删旧行再追加，避免值里含特殊字符时 sed 替换出错
nvp_settings_set() {
  local key="$1" value="$2"
  nvp_ensure_dirs
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$NANOVPN_SETTINGS" ]]; then
    grep -v "^${key}=" "$NANOVPN_SETTINGS" > "$tmp" 2>/dev/null || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$NANOVPN_SETTINGS"
}

# ---------------------------------------------------------------- credentials（0600）

nvp_cred_get() {
  local key="$1"
  [[ -f "$NANOVPN_CREDENTIALS" ]] || return 1
  sed -n "s/^${key}=//p" "$NANOVPN_CREDENTIALS" | head -n1
}

# ---------------------------------------------------------------- 小工具

# 字节数人类可读（纯 bash 整数运算，避免依赖 awk）
nvp_fmt_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if   (( b >= 1073741824 )); then printf '%d.%02d GB' $((b/1073741824)) $(( (b%1073741824)*100/1073741824 ))
  elif (( b >= 1048576 ));    then printf '%d.%02d MB' $((b/1048576))    $(( (b%1048576)*100/1048576 ))
  elif (( b >= 1024 ));       then printf '%d.%02d KB' $((b/1024))       $(( (b%1024)*100/1024 ))
  else printf '%d B' "$b"; fi
}

# epoch 秒 → YYYY-MM-DD（GNU date）
nvp_fmt_date() {
  local ts="${1:-0}"
  [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )) || { printf '未知'; return; }
  date -d "@$ts" '+%Y-%m-%d'
}
