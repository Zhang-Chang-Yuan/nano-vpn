#!/usr/bin/env bash
# 面板 API（curl+jq）：登录/订阅/签到/账号信息 + 节点刷新与延迟测试
# 三个坑（SPEC 第 1 节）：
#   1. UA 必须含 "dart"，否则 200 空 body；
#   2. Authorization 裸放 JWT，不能加 Bearer 前缀；
#   3. subscribe_url 不可缓存（出口 IP 轮换），每次重新 getSubscribe；订阅正文可缓存 10 分钟。
set -euo pipefail

# ---------------------------------------------------------------- API base 发现

# 面板地址发现：任一配置源返回 JSON 且含 url 字段即可
nvp_api_discover_base() {
  local url base
  for url in \
    "https://nanoapi.oss-ap-northeast-1.aliyuncs.com/u.json" \
    "https://47.76.194.59/u.json" \
    "https://54.37.159.199/u_nano.json"; do
    base="$(curl -sS --max-time 10 -H "User-Agent: $NANOVPN_UA_DART" "$url" 2>/dev/null \
            | jq -r '.url // empty' 2>/dev/null || true)"
    if [[ -n "$base" ]]; then
      printf '%s' "$base"
      return 0
    fi
  done
  # 兜底：实测面板地址
  printf '%s' "https://account.alibaba.alicdn.men/api/v1"
}

nvp_api_base() {
  local base
  base="$(nvp_settings_get panel_api_base)"
  if [[ -z "$base" ]]; then
    base="$(nvp_api_discover_base)"
    nvp_settings_set panel_api_base "$base"
  fi
  printf '%s' "$base"
}

# ---------------------------------------------------------------- 底层请求

# 裸请求：输出 "<http_code>\n<body>"；网络层失败时 code=000
nvp_api_request() {
  local method="$1" url="$2" body="$3" use_auth="$4"
  local -a args=(-sS --max-time 20 -X "$method"
                 -H "User-Agent: $NANOVPN_UA_DART"
                 -H "Accept: application/json")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  if [[ "$use_auth" == "1" && -s "$NANOVPN_AUTH" ]]; then
    # Authorization 裸放 JWT（无 Bearer 前缀），否则面板判未登录
    args+=(-H "Authorization: $(<"$NANOVPN_AUTH")")
  fi
  local raw
  raw="$(curl -w $'\n%{http_code}' "${args[@]}" "$url" 2>/dev/null)" || raw=$'\n000'
  printf '%s' "$raw"
}

# 带 401 自动重登重试的请求：输出 "<http_code>\n<body>"
nvp_api_call() {
  local method="$1" path="$2" body="${3:-}" need_auth="${4:-1}"
  local base raw code resp
  base="$(nvp_api_base)"
  raw="$(nvp_api_request "$method" "$base/$path" "$body" "$need_auth")"
  code="${raw##*$'\n'}"
  resp="${raw%$'\n'*}"
  # 401 / 未登录：用保存的凭据重登并重试一次。
  # 坑：面板会把中文 message 转义成 \uXXXX（如 \u672a\u767b\u5f55=未登录），
  # 必须先经 jq 解码再匹配，裸字符串匹配永远命中不了。
  if [[ "$need_auth" == "1" ]]; then
    local decoded=""
    decoded="$(printf '%s' "$resp" | jq -r '.message // ""' 2>/dev/null || true)"
    if [[ "$code" == "401" || "$decoded" == *"未登录"* || "$decoded" == *"过期"* ]]; then
      nvp_log_warn "会话失效，尝试用保存的凭据重新登录"
      if nvp_login_silent; then
        raw="$(nvp_api_request "$method" "$base/$path" "$body" "$need_auth")"
        code="${raw##*$'\n'}"
        resp="${raw%$'\n'*}"
      fi
    fi
  fi
  printf '%s\n%s' "$code" "$resp"
}

# 只要 body；非 2xx 直接报错退出（QML/人类路径通用）
nvp_api_json() {
  local method="$1" path="$2" body="${3:-}"
  local raw code resp msg
  raw="$(nvp_api_call "$method" "$path" "$body" 1)"
  code="${raw%%$'\n'*}"
  resp="${raw#*$'\n'}"
  if [[ "$code" != 2* ]]; then
    msg="$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null || true)"
    nvp_die "${path} 请求失败 (HTTP ${code:-无响应})${msg:+：$msg}"
  fi
  printf '%s' "$resp"
}

# ---------------------------------------------------------------- 登录

# 真正登录：data.auth_data 是裸 JWT，原样落盘（0600）
nvp_do_login() {
  local email="$1" password="$2"
  nvp_ensure_dirs
  local base body raw code resp msg token
  base="$(nvp_api_base)"
  body="$(jq -nc --arg e "$email" --arg p "$password" '{email:$e,password:$p}')"
  raw="$(nvp_api_request POST "$base/passport/auth/login" "$body" 0)"
  code="${raw##*$'\n'}"
  resp="${raw%$'\n'*}"
  if [[ "$code" != 2* ]]; then
    msg="$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null || true)"
    nvp_log_error "登录失败 (HTTP ${code:-无响应})${msg:+：$msg}"
    return 1
  fi
  token="$(printf '%s' "$resp" | jq -r '.data.auth_data // empty' 2>/dev/null || true)"
  if [[ -z "$token" || "$token" == "null" ]]; then
    nvp_log_error "登录响应中缺少 auth_data"
    return 1
  fi
  printf '%s' "$token" > "$NANOVPN_AUTH"
  chmod 600 "$NANOVPN_AUTH"
  return 0
}

# 静默重登（401 重试路径用，不退出）
nvp_login_silent() {
  [[ -s "$NANOVPN_CREDENTIALS" ]] || return 1
  local email password
  email="$(nvp_cred_get email || true)"
  password="$(nvp_cred_get password || true)"
  [[ -n "$email" && -n "$password" ]] || return 1
  nvp_do_login "$email" "$password" 2>/dev/null
}

# 确保已登录：有 auth 最好；否则有 credentials 就自动登；否则报错
nvp_require_auth() {
  [[ -s "$NANOVPN_AUTH" ]] && return 0
  if [[ -s "$NANOVPN_CREDENTIALS" ]]; then
    local email password
    email="$(nvp_cred_get email || true)"
    password="$(nvp_cred_get password || true)"
    if [[ -n "$email" && -n "$password" ]]; then
      nvp_log_warn "未登录，使用保存的凭据自动登录"
      nvp_do_login "$email" "$password" || nvp_die "自动登录失败，请运行 nanovpn login"
      return 0
    fi
  fi
  nvp_die "尚未登录，请先运行：nanovpn login"
}

# ---------------------------------------------------------------- 订阅

# subscribe_url 每次重新获取（出口 IP 会轮换，不可缓存）
nvp_get_subscribe_url() {
  local resp url
  resp="$(nvp_api_json GET user/getSubscribe)"
  url="$(printf '%s' "$resp" | jq -r '.data.subscribe_url // empty' 2>/dev/null || true)"
  [[ -n "$url" && "$url" != "null" ]] || nvp_die "getSubscribe 响应中没有 subscribe_url"
  printf '%s' "$url"
}

# 拉订阅正文；正文本身可缓存 10 分钟，但 URL 每次都重新拿
nvp_fetch_subscription() {
  nvp_ensure_dirs
  nvp_require_auth
  local max_age=600
  if [[ -f "$NANOVPN_SUBSCRIPTION" ]]; then
    local mtime age
    mtime="$(stat -c %Y "$NANOVPN_SUBSCRIPTION")"
    age=$(( $(date +%s) - mtime ))
    if (( age >= 0 && age < max_age )); then return 0; fi
  fi
  local url tmp
  url="$(nvp_get_subscribe_url)"
  tmp="$(mktemp)"
  # UA sing-box/* → 完整 sing-box JSON；空 UA → base64 分享链接；Dart UA → 500
  if ! curl -sS --max-time 30 -H "User-Agent: $NANOVPN_UA_SINGBOX" "$url" -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    nvp_die "拉取订阅失败：$url"
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; nvp_die "订阅内容为空（检查 UA 白名单）"; }
  mv "$tmp" "$NANOVPN_SUBSCRIPTION"
}

# ---------------------------------------------------------------- 节点列表刷新

# 拉订阅 + 解析 → nodes.json（含 selected/mode/modes/selector_tag/urltest_tag）
nvp_nodes_refresh() {
  nvp_fetch_subscription
  local raw selected mode tmp
  raw="$(python3 "$NANOVPN_LIB/nodes.py" "$NANOVPN_SUBSCRIPTION")"
  # 按 tag 保留上次测得的延迟，避免 nodes --json 把 --test 的结果冲掉
  if [[ -f "$NANOVPN_NODES" ]]; then
    tmp="$(mktemp)"
    if printf '%s' "$raw" | jq --slurpfile old "$NANOVPN_NODES" '
          ($old[0].nodes // []) as $oldnodes
          | .nodes |= map(. as $n
              | . + {latency_ms: (([$oldnodes[] | select(.tag == $n.tag)]
                                   | .[0].latency_ms) // null)})' > "$tmp" 2>/dev/null; then
      raw="$(cat "$tmp")"
    fi
    rm -f "$tmp"
  fi
  selected="$(nvp_settings_get node)"
  mode="$(nvp_settings_get mode "$NANOVPN_DEFAULT_MODE")"
  printf '%s' "$raw" | jq \
    --arg sel "$selected" \
    --arg mode "$mode" \
    '. + {selected: (if ($sel == "" or ([.nodes[].tag] | index($sel) | not))
                     then (.nodes[0].tag // "") else $sel end),
           mode: $mode}' > "$NANOVPN_NODES"
  # 有实测延迟就按从低到高排（刷新不丢延迟，顺序也随之恢复）
  nvp_nodes_sort_by_latency
}

# ---------------------------------------------------------------- 延迟测试

# 按实测延迟升序排 nodes.json 的 .nodes：延迟最低在前，未测到的 null 排最后；
# 全部未测时保持订阅原序（避免无谓的顺序变动）。
# 排序落在 nodes.json 上，CLI 显示与 DMS 插件（按 nodes 数组顺序渲染）同时生效。
nvp_nodes_sort_by_latency() {
  local file="${1:-$NANOVPN_NODES}" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp)"
  if jq 'if any(.nodes[]?; .latency_ms != null)
         then .nodes |= sort_by(if .latency_ms == null then 999999999 else .latency_ms end)
         else . end' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

# 内核运行中：走 Clash API 的 delay 接口（tuic 是 QUIC/UDP，TCP 拨号测不了）
# tag 含 emoji/中文必须 URL 编码；并行测（xargs -P 12），22 个节点 ~10s 内完成
nvp_nodes_test_clash() {
  # 内核没运行：按当前设置自动拉起，测完保持运行
  if [[ -z "$(nvp_core_pid || true)" ]]; then
    nvp_log_warn "内核未运行，先自动连接以进行延迟测试"
    nvp_connect_core
  fi
  [[ -f "$NANOVPN_NODES" ]] || nvp_die "节点列表不存在"
  local n
  n="$(jq '.nodes | length' "$NANOVPN_NODES")"
  (( n > 0 )) || return 0

  local tmpdir runner
  tmpdir="$(mktemp -d)"
  runner="$tmpdir/run.sh"
  cat > "$runner" <<'EOF'
#!/usr/bin/env bash
# 单节点延迟测试 runner（xargs 并行调用）
line="$1"
idx="${line%%$'\t'*}"
tag="${line#*$'\t'}"
port="${NVP_CLASH_PORT:-9091}"
# tag 含 emoji/中文，必须 URL 编码
enc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$tag")"
url="http://127.0.0.1:${port}/proxies/${enc}/delay?timeout=5000&url=http%3A%2F%2Fwww.apple.com%2Flibrary%2Ftest%2Fsuccess.html"
resp="$(curl -sS --max-time 10 "$url" 2>/dev/null || true)"
delay="$(printf '%s' "$resp" | jq -r '.delay // empty' 2>/dev/null || true)"
if [[ "$delay" =~ ^[0-9]+$ ]]; then
  printf '%s' "$delay" > "${NVP_OUTDIR}/${idx}"
else
  printf 'null' > "${NVP_OUTDIR}/${idx}"
fi
EOF
  chmod +x "$runner"
  jq -r '.nodes | to_entries[] | "\(.key)\t\(.value.tag)"' "$NANOVPN_NODES" > "$tmpdir/list"
  NVP_CLASH_PORT="$(nvp_settings_get clash_port "$NANOVPN_DEFAULT_CLASH_PORT")" \
  NVP_OUTDIR="$tmpdir" \
    xargs -P 12 -a "$tmpdir/list" -I{} "$runner" {}

  # 结果写回 nodes.json 的 latency_ms，并按延迟从低到高排序（最低在前，未测到的排最后）
  local filter="." i lat tmp
  for ((i=0; i<n; i++)); do
    lat="$(cat "$tmpdir/$i" 2>/dev/null || echo null)"
    [[ "$lat" =~ ^[0-9]+$ ]] || lat="null"
    filter+=" | .nodes[$i].latency_ms = $lat"
  done
  rm -rf "$tmpdir"
  tmp="$(mktemp)"
  jq "$filter" "$NANOVPN_NODES" > "$tmp" && mv "$tmp" "$NANOVPN_NODES"
  nvp_nodes_sort_by_latency
}

# 降级：TCP 拨号近似值（--no-core 时用；tuic 等 UDP 协议测不出，结果仅供参考）
nvp_nodes_test_tcp() {
  [[ -f "$NANOVPN_NODES" ]] || nvp_die "节点列表不存在"
  local n
  n="$(jq '.nodes | length' "$NANOVPN_NODES")"
  (( n > 0 )) || return 0
  nvp_log_warn "未连接内核，TCP 拨号测速为近似值（tuic/hysteria2 等 UDP 协议测不出）"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local i
  for ((i=0; i<n; i++)); do
    (
      server="$(jq -r ".nodes[$i].server" "$NANOVPN_NODES")"
      port="$(jq -r ".nodes[$i].port" "$NANOVPN_NODES")"
      lat="null"
      # 域名先 getent 解析，延迟不含 DNS 耗时
      ip="$(getent ahostsv4 "$server" 2>/dev/null | head -n1)"
      ip="${ip%% *}"
      if [[ -n "$ip" && "$port" =~ ^[0-9]+$ ]]; then
        start="$(date +%s%3N)"
        if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
          end="$(date +%s%3N)"
          lat="$((end - start))"
        fi
      fi
      printf '%s' "$lat" > "$tmpdir/$i"
    ) &
    while (( $(jobs -rp | wc -l) >= 12 )); do wait -n 2>/dev/null || true; done
  done
  wait
  local filter="." lat tmp
  for ((i=0; i<n; i++)); do
    lat="$(cat "$tmpdir/$i" 2>/dev/null || echo null)"
    [[ "$lat" =~ ^[0-9]+$ ]] || lat="null"
    filter+=" | .nodes[$i].latency_ms = $lat"
  done
  rm -rf "$tmpdir"
  tmp="$(mktemp)"
  jq "$filter" "$NANOVPN_NODES" > "$tmp" && mv "$tmp" "$NANOVPN_NODES"
  # 同样按延迟从低到高排序（TCP 近似值路径）
  nvp_nodes_sort_by_latency
}
