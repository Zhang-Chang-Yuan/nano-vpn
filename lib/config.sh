#!/usr/bin/env bash
# 订阅 JSON → runtime.json（jq 变换，SPEC 第 3 节）
set -euo pipefail

# 生成运行时配置；$1 = 选中节点 tag（可以是具体节点，也可以是 ♻️ 自动选择）
nvp_build_runtime() {
  local node_tag="$1"
  local src="$NANOVPN_SUBSCRIPTION"
  [[ -f "$src" ]] || nvp_die "订阅文件不存在：$src（先运行 nanovpn nodes）"

  # 降级模式：订阅是 base64 分享链接，先用 nodes.py 转成标准 sing-box 配置
  if ! jq -e 'has("outbounds")' "$src" >/dev/null 2>&1; then
    local norm="$NANOVPN_STATE_DIR/subscription.normalized.json"
    python3 "$NANOVPN_LIB/nodes.py" "$src" --emit-config > "$norm"
    src="$norm"
  fi

  local tun mixed_port clash_port mode log_level selector
  tun="$(nvp_settings_get tun 0)"
  mixed_port="$(nvp_settings_get mixed_port "$NANOVPN_DEFAULT_MIXED_PORT")"
  clash_port="$(nvp_settings_get clash_port "$NANOVPN_DEFAULT_CLASH_PORT")"
  mode="$(nvp_settings_get mode "$NANOVPN_DEFAULT_MODE")"
  log_level="$(nvp_settings_get log_level warn)"
  # 选择器 tag 从 nodes.json 拿（固定为 🚀 节点选择）
  selector="$(nvp_selector_tag)"
  # 端口必须是数字，否则 jq --argjson 会炸
  [[ "$mixed_port" =~ ^[0-9]+$ ]] || nvp_die "mixed_port 非法：$mixed_port"
  [[ "$clash_port" =~ ^[0-9]+$ ]] || nvp_die "clash_port 非法：$clash_port"

  local tmp
  tmp="$(mktemp)"
  jq \
    --arg node "$node_tag" \
    --arg selector "$selector" \
    --argjson tun "$tun" \
    --argjson mixed_port "$mixed_port" \
    --argjson clash_port "$clash_port" \
    --arg mode "$mode" \
    --arg log_level "$log_level" \
    '
    # TUN 关闭时删掉 tun-in（没授权 capability 也起不来）
    (if ($tun == 1) then . else .inbounds |= map(select(.tag != "tun-in")) end)
    # mixed inbound 端口用设置里的值
    | .inbounds |= map(if .type == "mixed" then .listen_port = $mixed_port else . end)
    # selector 初始选中项：sing-box 1.14 的字段名是 default（不是 outbound）；
    # 指向 ♻️ 自动选择（urltest）同样合法，selector.outbounds 列表里含它。
    # 若选中项不在列表里（订阅变更后 settings 里的 node 过期），回退到第一项，
    # 否则 sing-box 启动会 FATAL: default outbound not found
    | .outbounds |= map(if .tag == $selector
        then .default = (if (.outbounds | index($node)) then $node
                         else (.outbounds[0] // $node) end)
        else . end)
    # Clash API 端口与默认模式
    | .experimental.clash_api.external_controller = "127.0.0.1:\($clash_port)"
    | .experimental.clash_api.default_mode = $mode
    # 其余（dns/route/rule_set/certificate/log）原样保留，只压日志级别
    | .log.level = $log_level
    ' "$src" > "$tmp" || { rm -f "$tmp"; nvp_die "生成 runtime.json 失败（订阅 JSON 非法？）"; }
  mv "$tmp" "$NANOVPN_RUNTIME"
}
