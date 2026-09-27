#!/usr/bin/env bash
# nanovpn 公共函数：路径常量、日志、settings/credentials 读写
# 所有路径遵循 SPEC 第 5 节：配置在 ~/.config/nanovpn，状态在 ~/.local/state/nanovpn
set -euo pipefail

# 仓库根目录（兼容通过 ~/.local/bin/nanovpn 符号链接调用，需解析真实路径）
NANOVPN_HOME="${NANOVPN_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
NANOVPN_LIB="$NANOVPN_HOME/lib"
NANOVPN_TOOLS="$NANOVPN_HOME/tools"
NANOVPN_SING_BOX="$NANOVPN_TOOLS/sing-box"

# 用户数据目录
NANOVPN_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nanovpn"
NANOVPN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nanovpn"
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
NANOVPN_CACHE_DIR="$NANOVPN_STATE_DIR/cache"           # sing-box -D 工作目录（远程规则集）
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
  chmod 700 "$NANOVPN_CONFIG_DIR" "$NANOVPN_STATE_DIR"
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
