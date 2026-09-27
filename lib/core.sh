#!/usr/bin/env bash
# sing-box 进程管理、Clash API、status.json、出口 IP
set -euo pipefail

# ---------------------------------------------------------------- Clash API

nvp_clash_req() {
  # $1 path  $2 method  $3 data；secret 非空时带 Authorization
  local path="$1" method="${2:-GET}" data="${3:-}"
  local -a args=(-sS --max-time 10 -X "$method")
  local secret=""
  [[ -f "$NANOVPN_RUNTIME" ]] && secret="$(jq -r '.experimental.clash_api.secret // ""' "$NANOVPN_RUNTIME" 2>/dev/null || true)"
  [[ -n "$secret" && "$secret" != "null" ]] && args+=(-H "Authorization: Bearer $secret")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")
  curl "${args[@]}" "http://127.0.0.1:$(nvp_settings_get clash_port "$NANOVPN_DEFAULT_CLASH_PORT")$path" 2>/dev/null || true
}

# 启动成功判定：Clash API /version 可达
nvp_clash_ready() {
  local resp
  resp="$(nvp_clash_req /version)"
  [[ "$resp" == *'"version"'* ]]
}

nvp_selector_tag() {
  local t=""
  [[ -f "$NANOVPN_NODES" ]] && t="$(jq -r '.selector_tag // ""' "$NANOVPN_NODES" 2>/dev/null || true)"
  [[ -z "$t" ]] && t="$NANOVPN_DEFAULT_SELECTOR_TAG"
  printf '%s' "$t"
}

# ---------------------------------------------------------------- 进程管理

# 读 PID 文件并确认进程还活着且确实是我们的 sing-box（防 PID 复用）
nvp_core_pid() {
  [[ -f "$NANOVPN_PID_FILE" ]] || return 1
  local pid
  pid="$(<"$NANOVPN_PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local cmd
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [[ "$cmd" == *"sing-box"* ]] || return 1
  printf '%s' "$pid"
}

# setsid 可能 fork，用 /proc 扫描兜底找真正的 sing-box PID
nvp_scan_singbox_pid() {
  local d pid cmd
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [[ -r "$d/cmdline" ]] || continue
    cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" == *"sing-box run"* && "$cmd" == *"$NANOVPN_RUNTIME"* ]]; then
      printf '%s' "$pid"
      return 0
    fi
  done
  return 1
}

nvp_core_stop() {
  local pid
  pid="$(nvp_core_pid || true)"
  [[ -z "$pid" ]] && { rm -f "$NANOVPN_PID_FILE"; return 0; }
  # 先 SIGTERM 优雅退出
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for ((i=0; i<25; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  # 还不退就 SIGKILL
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.3
  fi
  rm -f "$NANOVPN_PID_FILE"
}

nvp_core_start() {
  local node_tag="$1"
  [[ -x "$NANOVPN_SING_BOX" ]] || nvp_die "未找到可执行的 sing-box：$NANOVPN_SING_BOX（先运行 nanovpn install）"
  nvp_build_runtime "$node_tag"
  nvp_ensure_dirs
  nvp_core_stop || true
  : >> "$NANOVPN_LOG"
  # setsid 让内核脱离 CLI 会话，CLI 退出后继续跑；日志追加到 sing-box.log
  setsid "$NANOVPN_SING_BOX" run -c "$NANOVPN_RUNTIME" -D "$NANOVPN_CACHE_DIR" >> "$NANOVPN_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$NANOVPN_PID_FILE"
  # setsid 若 fork 过，$! 就不是真正的 sing-box，扫 /proc 兜底
  if ! grep -qa 'sing-box' "/proc/$pid/cmdline" 2>/dev/null; then
    pid="$(nvp_scan_singbox_pid || echo "$pid")"
    echo "$pid" > "$NANOVPN_PID_FILE"
  fi
  # 轮询 Clash API /version，最多 15s
  local i ok=0
  for ((i=0; i<30; i++)); do
    if nvp_clash_ready; then ok=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if (( ok != 1 )); then
    nvp_log_error "sing-box 启动失败（进程退出或 Clash API 15s 内不可达），日志尾部："
    # 去掉 ANSI 颜色码，避免终端里一片乱码
    tail -n 20 "$NANOVPN_LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' >&2 || true
    nvp_core_stop || true
    printf '%s' "启动失败：Clash API 15s 内不可达或进程退出" > "$NANOVPN_LAST_ERROR"
    return 1
  fi
  rm -f "$NANOVPN_LAST_ERROR"
  # experimental.cache_file 会在启动时用上次缓存的模式覆盖 default_mode；
  # 这里按 settings 里的 mode 纠正一次，保证运行时与设置一致
  local want_mode
  want_mode="$(nvp_settings_get mode "$NANOVPN_DEFAULT_MODE")"
  if [[ "$(nvp_clash_req /configs | jq -r '.mode // empty' 2>/dev/null || true)" != "$want_mode" ]]; then
    nvp_clash_req /configs PATCH "$(jq -nc --arg m "$want_mode" '{mode:$m}')" >/dev/null
  fi
}

# ---------------------------------------------------------------- 连接

# 连接核心逻辑（nodes --test 自动拉起也走这里）；成功返回 0
nvp_connect_core() {
  nvp_ensure_dirs
  nvp_require_auth
  nvp_nodes_refresh
  local node
  node="$(nvp_settings_get node)"
  if [[ -z "$node" ]]; then
    node="$(jq -r '.nodes[0].tag // empty' "$NANOVPN_NODES")"
    [[ -n "$node" ]] || nvp_die "订阅里没有可用节点"
  fi
  # 节点 tag 必须存在于选择器的 outbounds 列表里（含 ♻️ 自动选择）
  nvp_validate_node "$node"
  nvp_settings_set node "$node"
  nvp_core_start "$node"
}

# 校验节点 tag：具体节点或 urltest 都合法
nvp_validate_node() {
  local node="$1"
  [[ -f "$NANOVPN_NODES" ]] || nvp_die "节点列表不存在，请先运行 nanovpn nodes"
  if jq -e --arg n "$node" '([.nodes[].tag] + [.urltest_tag // empty]) | index($n) != null' \
      "$NANOVPN_NODES" >/dev/null 2>&1; then
    return 0
  fi
  nvp_die "节点不存在：$node（用 nanovpn nodes 查看可用节点）"
}

# ---------------------------------------------------------------- 出口 IP（60s 缓存）

nvp_current_ip() {
  local now cache ts ip mixed_port
  now="$(date +%s)"
  cache="$NANOVPN_IP_CACHE"
  if [[ -f "$cache" ]]; then
    ts="$(jq -r '.ts // 0' "$cache" 2>/dev/null || echo 0)"
    if (( now - ts < 60 )); then
      jq -r '.ip // ""' "$cache" 2>/dev/null || printf ''
      return 0
    fi
  fi
  mixed_port="$(nvp_settings_get mixed_port "$NANOVPN_DEFAULT_MIXED_PORT")"
  ip="$(curl -sS --max-time 8 -x "socks5h://127.0.0.1:$mixed_port" https://api.ipify.org 2>/dev/null || true)"
  ip="${ip//[[:space:]]/}"
  # 只有拿到合法 IP 才刷新缓存，避免失败时把好缓存冲掉
  if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" == *:* ]]; then
    jq -nc --arg ip "$ip" --argjson ts "$now" '{ip:$ip,ts:$ts}' > "$cache" 2>/dev/null || true
  fi
  printf '%s' "$ip"
}

# ---------------------------------------------------------------- 状态

# 进程活着但 Clash API 不通 = starting
nvp_core_state() {
  local pid
  pid="$(nvp_core_pid || true)"
  if [[ -z "$pid" ]]; then
    if [[ -f "$NANOVPN_LAST_ERROR" ]]; then echo error; else echo stopped; fi
    return 0
  fi
  if nvp_clash_ready; then echo connected; else echo starting; fi
}

# 写 status.json 并输出（--json 时只输出 JSON）
nvp_write_status() {
  nvp_ensure_dirs
  local state node mode tun mixed_port clash_port ip ip_age uptime error pid
  state="$(nvp_core_state)"
  tun="$(nvp_settings_get tun 0)"
  mixed_port="$(nvp_settings_get mixed_port "$NANOVPN_DEFAULT_MIXED_PORT")"
  clash_port="$(nvp_settings_get clash_port "$NANOVPN_DEFAULT_CLASH_PORT")"
  mode="$(nvp_settings_get mode "$NANOVPN_DEFAULT_MODE")"
  node="$(nvp_settings_get node)"
  if [[ "$state" == "connected" ]]; then
    # 从 Clash API 拿真实选中节点与模式
    local enc now
    enc="$(jq -rn --arg s "$(nvp_selector_tag)" '$s|@uri')"
    now="$(nvp_clash_req "/proxies/$enc" | jq -r '.now // empty' 2>/dev/null || true)"
    [[ -n "$now" ]] && node="$now"
    now="$(nvp_clash_req /configs | jq -r '.mode // empty' 2>/dev/null || true)"
    [[ -n "$now" ]] && mode="$now"
  fi
  ip=""; ip_age=0
  if [[ "$state" == "connected" ]]; then
    ip="$(nvp_current_ip)"
    if [[ -f "$NANOVPN_IP_CACHE" ]]; then
      local ts
      ts="$(jq -r '.ts // 0' "$NANOVPN_IP_CACHE" 2>/dev/null || echo 0)"
      ip_age=$(( $(date +%s) - ts ))
      (( ip_age < 0 )) && ip_age=0
    fi
  fi
  uptime=0
  pid="$(nvp_core_pid || true)"
  if [[ -n "$pid" && -f "$NANOVPN_PID_FILE" ]]; then
    uptime=$(( $(date +%s) - $(stat -c %Y "$NANOVPN_PID_FILE") ))
    (( uptime < 0 )) && uptime=0
  fi
  error=""
  [[ -f "$NANOVPN_LAST_ERROR" ]] && error="$(<"$NANOVPN_LAST_ERROR")"
  # state=stopped 时 node/mode/tun 仍返回设置里的值（供 UI 显示将连什么）
  local json
  json="$(jq -nc \
    --arg state "$state" --arg node "$node" --arg mode "$mode" \
    --argjson tun "$tun" --arg ip "$ip" --argjson ip_age_s "$ip_age" \
    --argjson mixed_port "$mixed_port" --argjson clash_port "$clash_port" \
    --argjson uptime_s "$uptime" --arg error "$error" \
    '{state:$state,node:$node,mode:$mode,tun:($tun==1),ip:$ip,
      ip_age_s:$ip_age_s,mixed_port:$mixed_port,clash_port:$clash_port,
      uptime_s:$uptime_s,error:$error}')"
  printf '%s\n' "$json" > "$NANOVPN_STATUS"
  NVP_STATUS_JSON="$json"
}

nvp_status_human() {
  local json="$1"
  local state node mode tun ip ip_age
  state="$(jq -r '.state' <<<"$json")"
  node="$(jq -r '.node' <<<"$json")"
  mode="$(jq -r '.mode' <<<"$json")"
  tun="$(jq -r '.tun' <<<"$json")"
  ip="$(jq -r '.ip' <<<"$json")"
  ip_age="$(jq -r '.ip_age_s' <<<"$json")"
  case "$state" in
    connected) printf '状态：已连接\n';;
    starting)  printf '状态：启动中\n';;
    error)     printf '状态：错误\n';;
    *)         printf '状态：未连接\n';;
  esac
  printf '节点：%s\n' "${node:-（未选择）}"
  printf '模式：%s\n' "$mode"
  if [[ "$tun" == "true" ]]; then printf 'TUN：开\n'; else printf 'TUN：关\n'; fi
  if [[ -n "$ip" ]]; then
    printf '出口 IP：%s（%ds 前刷新）\n' "$ip" "$ip_age"
  elif [[ "$state" == "connected" ]]; then
    printf '出口 IP：获取失败\n'
  fi
}

# ---------------------------------------------------------------- 模式切换

nvp_mode_set() {
  local mode="$1"
  case "$mode" in
    智能首选|全球直连|全局代理) ;;
    *) nvp_die "未知模式：$mode（可选：智能首选 / 全球直连 / 全局代理）";;
  esac
  nvp_settings_set mode "$mode"
  local pid
  pid="$(nvp_core_pid || true)"
  if [[ -z "$pid" ]]; then
    nvp_log_info "已记录模式：$mode（未连接，下次 connect 生效）"
    return 0
  fi
  # 先试 Clash API 热切换（注意参数顺序：path method data）
  nvp_clash_req /configs PATCH "$(jq -nc --arg m "$mode" '{mode:$m}')" >/dev/null
  if [[ "$(nvp_clash_req /configs | jq -r '.mode // empty' 2>/dev/null || true)" == "$mode" ]]; then
    nvp_log_info "模式已切换：$mode"
    return 0
  fi
  # 热切换失败：该模式不在运行时 mode-list（sing-box 只把路由规则里出现过的
  # clash_mode 和 default_mode 放进 mode-list，"智能首选" 作为 default_mode 时才行）。
  # 改 default_mode 重启；但 experimental.cache_file 会在启动时用缓存模式覆盖
  # default_mode，所以重启后必须再补一次 PATCH（此时该模式已进 mode-list）。
  nvp_log_warn "Clash API 不支持热切换到该模式，重建配置并重启内核"
  nvp_core_start "$(nvp_settings_get node)" || return 1
  nvp_clash_req /configs PATCH "$(jq -nc --arg m "$mode" '{mode:$m}')" >/dev/null
  nvp_log_info "模式已切换：$mode"
}
