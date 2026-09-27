#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nanovpn 订阅解析器。

用法：nodes.py <订阅正文文件> [--emit-config]

默认输出节点 JSON 到 stdout：
  {"nodes":[{"tag","type","server","port","latency_ms"},...],
   "modes":[...],"selector_tag":"🚀 节点选择","urltest_tag":"♻️ 自动选择"}

支持两种输入格式：
  1. sing-box JSON 配置（首选）：直接读 outbounds；
  2. base64 分享链接列表（降级）：解析 vless/trojan/vmess/ss/hysteria2/tuic。

--emit-config：把降级格式转换成完整 sing-box 配置 JSON（供 config.sh 生成 runtime.json）。
"""

import base64
import json
import sys
import urllib.parse

# 这些 outbound 类型不算"节点"
NON_NODE_TYPES = {"selector", "urltest", "direct", "block", "dns"}
DEFAULT_SELECTOR_TAG = "🚀 节点选择"
DEFAULT_URLTEST_TAG = "♻️ 自动选择"
# 降级格式没有模式信息，用订阅约定的三件套
FALLBACK_MODES = ["智能首选", "全球直连", "全局代理"]


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace").strip()


def b64decode(s):
    """标准/urlsafe base64 解码，自动补 padding；失败返回 None。"""
    s = "".join(s.split()).replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    try:
        return base64.b64decode(s, validate=False).decode("utf-8", "replace")
    except Exception:
        return None


# ---------------------------------------------------------------- sing-box JSON

def parse_singbox_json(cfg):
    """从 sing-box 配置提取节点列表 / modes / selector tag。"""
    nodes = []
    selector_tag = ""
    urltest_tag = ""
    for ob in cfg.get("outbounds") or []:
        if not isinstance(ob, dict):
            continue
        t = ob.get("type", "")
        tag = ob.get("tag", "")
        if t == "selector":
            # 选择器 tag 固定为"🚀 节点选择"；找不到就退而求其次取第一个 selector
            if "节点选择" in tag or not selector_tag:
                selector_tag = tag
            continue
        if t == "urltest":
            if not urltest_tag:
                urltest_tag = tag
            continue
        if t in NON_NODE_TYPES:
            continue
        nodes.append({
            "tag": tag,
            "type": t,
            "server": ob.get("server", ""),
            "port": ob.get("server_port", 0),
            "latency_ms": None,
        })
    # modes：route rules 的 clash_mode 去重 + clash_api.default_mode（默认模式放最前）
    modes = []
    route = cfg.get("route") or {}
    for rule in route.get("rules") or []:
        cm = rule.get("clash_mode")
        if cm and cm not in modes:
            modes.append(cm)
    clash = (cfg.get("experimental") or {}).get("clash_api") or {}
    default_mode = clash.get("default_mode")
    if default_mode and default_mode not in modes:
        modes.insert(0, default_mode)
    return nodes, (selector_tag or DEFAULT_SELECTOR_TAG), (urltest_tag or DEFAULT_URLTEST_TAG), modes


# ---------------------------------------------------------------- 分享链接

def split_url(url):
    """scheme://userinfo@host:port?query#fragment → 各部分"""
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    try:
        port = parts.port or 0
    except ValueError:
        port = 0
    userinfo = ""
    if parts.username is not None:
        userinfo = urllib.parse.unquote(parts.username)
        if parts.password is not None:
            userinfo += ":" + urllib.parse.unquote(parts.password)
    query = urllib.parse.parse_qs(parts.query)
    tag = urllib.parse.unquote(parts.fragment)
    return host, port, userinfo, query, tag


def server_name(query, host):
    for key in ("sni", "peer", "host", "serverName"):
        v = (query.get(key) or [""])[0]
        if v:
            return v
    return host


def transport_of(query, net, host):
    """按 type 参数生成 sing-box transport 段"""
    net = (net or "tcp").lower()
    if net == "ws":
        return {"type": "ws",
                "path": (query.get("path") or ["/"])[0],
                "headers": {"Host": (query.get("host") or [host])[0]}}
    if net == "grpc":
        name = (query.get("serviceName") or query.get("path") or [""])[0]
        return {"type": "grpc", "service_name": name}
    if net in ("http", "h2"):
        return {"type": "http",
                "host": [(query.get("host") or [host])[0]],
                "path": (query.get("path") or ["/"])[0]}
    return None


def parse_link(url):
    """一条分享链接 → sing-box outbound；失败返回 None。"""
    scheme = url.split("://", 1)[0].lower()
    if scheme not in ("vless", "trojan", "vmess", "ss", "shadowsocks", "hysteria2", "hy2", "tuic"):
        return None

    if scheme == "vmess":
        txt = b64decode(url[len("vmess://"):])
        if not txt:
            return None
        try:
            v = json.loads(txt)
        except Exception:
            return None
        host = v.get("add") or ""
        port = int(v.get("port") or 0)
        if not host:
            return None
        ob = {"type": "vmess",
              "tag": v.get("ps") or "%s:%s" % (host, port),
              "server": host, "server_port": port,
              "uuid": v.get("id", ""),
              "security": v.get("scy") or "auto",
              "alter_id": int(v.get("aid") or 0)}
        if v.get("tls"):
            ob["tls"] = {"enabled": True,
                         "server_name": v.get("sni") or v.get("host") or host}
        tr = transport_of({}, v.get("net"), host)
        if tr:
            if tr["type"] == "ws":
                tr["path"] = v.get("path") or "/"
                tr["headers"] = {"Host": v.get("host") or host}
            elif tr["type"] == "grpc":
                tr["service_name"] = v.get("path") or ""
            ob["transport"] = tr
        return ob

    host, port, userinfo, query, tag = split_url(url)

    if scheme == "vless":
        uuid = userinfo.split(":", 1)[0] if userinfo else ""
        if not uuid or not host:
            return None
        ob = {"type": "vless", "tag": tag or "%s:%s" % (host, port),
              "server": host, "server_port": int(port), "uuid": uuid}
        flow = (query.get("flow") or [""])[0]
        if flow:
            ob["flow"] = flow
        security = (query.get("security") or [""])[0].lower()
        if security != "none":
            tls = {"enabled": True, "server_name": server_name(query, host)}
            if security == "reality":
                tls["reality"] = {"enabled": True,
                                  "public_key": (query.get("pbk") or [""])[0],
                                  "short_id": (query.get("sid") or [""])[0]}
            ob["tls"] = tls
        tr = transport_of(query, (query.get("type") or [""])[0], host)
        if tr:
            ob["transport"] = tr
        return ob

    if scheme == "trojan":
        if not userinfo or not host:
            return None
        ob = {"type": "trojan", "tag": tag or "%s:%s" % (host, port),
              "server": host, "server_port": int(port), "password": userinfo,
              "tls": {"enabled": True, "server_name": server_name(query, host)}}
        tr = transport_of(query, (query.get("type") or [""])[0], host)
        if tr:
            ob["transport"] = tr
        return ob

    if scheme in ("ss", "shadowsocks"):
        # 形态一：ss://b64(method:password)@host:port#tag
        if userinfo:
            method, _, password = userinfo.partition(":")
        else:
            # 形态二：ss://b64(method:password@host:port)#tag
            dec = b64decode(url[len("ss://"):].split("#", 1)[0]) or ""
            cred, _, hostport = dec.rpartition("@")
            if not cred:
                return None
            method, _, password = cred.partition(":")
            hp = urllib.parse.urlsplit("//" + hostport)
            host = hp.hostname or ""
            try:
                port = hp.port or 0
            except ValueError:
                port = 0
        if not method or not host:
            return None
        return {"type": "shadowsocks", "tag": tag or "%s:%s" % (host, port),
                "server": host, "server_port": int(port),
                "method": method, "password": password}

    if scheme in ("hysteria2", "hy2"):
        if not host:
            return None
        ob = {"type": "hysteria2", "tag": tag or "%s:%s" % (host, port),
              "server": host, "server_port": int(port), "password": userinfo,
              "tls": {"enabled": True, "server_name": server_name(query, host)}}
        obfs = (query.get("obfs") or [""])[0]
        if obfs:
            ob["obfs"] = {"type": obfs,
                          "password": (query.get("obfs-password") or [""])[0]}
        return ob

    if scheme == "tuic":
        if not host:
            return None
        uuid, _, password = userinfo.partition(":")
        ob = {"type": "tuic", "tag": tag or "%s:%s" % (host, port),
              "server": host, "server_port": int(port),
              "uuid": uuid, "password": password,
              "tls": {"enabled": True, "server_name": server_name(query, host)}}
        cc = (query.get("congestion_control") or [""])[0]
        if cc:
            ob["congestion_control"] = cc
        return ob

    return None


def parse_links(text):
    outbounds = []
    for line in text.splitlines():
        line = line.strip()
        if "://" not in line:
            continue
        ob = parse_link(line)
        if ob and ob.get("server"):
            outbounds.append(ob)
    return outbounds


# ---------------------------------------------------------------- 降级：生成完整 sing-box 配置

def build_singbox_config(outbounds, modes, default_mode):
    tags = [ob["tag"] for ob in outbounds]
    rules = [
        {"inbound": ["mixed-in"], "action": "sniff"},
        {"ip_is_private": True, "outbound": "direct"},
    ]
    for m in modes:
        if m == default_mode:
            continue
        # 直连模式走 direct，其它模式走 selector
        rules.append({"clash_mode": m,
                      "outbound": "direct" if m == "全球直连" else DEFAULT_SELECTOR_TAG})
    return {
        "log": {"level": "warn"},
        "inbounds": [
            {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
             "listen_port": 7891},
        ],
        "outbounds": [
            # selector 的 outbounds 列表必须含 urltest tag，否则把默认选中项
            # 指向 ♻️ 自动选择 时会 FATAL: default outbound not found
            {"type": "selector", "tag": DEFAULT_SELECTOR_TAG,
             "outbounds": [DEFAULT_URLTEST_TAG] + tags,
             "interrupt_exist_connections": True},
            {"type": "urltest", "tag": DEFAULT_URLTEST_TAG, "outbounds": tags,
             "url": "http://www.apple.com/library/test/success.html",
             "interval": "5m"},
            {"type": "direct", "tag": "direct"},
        ] + outbounds,
        "route": {"rules": rules},
        "experimental": {
            "clash_api": {"default_mode": default_mode or (modes[0] if modes else "rule"),
                          "external_controller": "127.0.0.1:9091",
                          "secret": ""},
        },
    }


# ---------------------------------------------------------------- main

def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    path = argv[1]
    emit_config = "--emit-config" in argv

    text = read_text(path)
    cfg = None
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            cfg = obj
    except Exception:
        cfg = None

    if cfg is not None:
        nodes, selector_tag, urltest_tag, modes = parse_singbox_json(cfg)
        if emit_config:
            json.dump(cfg, sys.stdout, ensure_ascii=False)
        else:
            json.dump({"nodes": nodes, "modes": modes,
                       "selector_tag": selector_tag,
                       "urltest_tag": urltest_tag},
                      sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    # 降级：base64 分享链接列表
    decoded = b64decode(text) or text
    outbounds = parse_links(decoded)
    if not outbounds:
        sys.stderr.write("无法解析订阅内容（既不是 sing-box JSON，也不是分享链接列表）\n")
        return 1
    default_mode = FALLBACK_MODES[0]
    if emit_config:
        json.dump(build_singbox_config(outbounds, FALLBACK_MODES, default_mode),
                  sys.stdout, ensure_ascii=False)
    else:
        nodes = [{"tag": ob["tag"], "type": ob["type"], "server": ob["server"],
                  "port": ob["server_port"], "latency_ms": None}
                 for ob in outbounds]
        json.dump({"nodes": nodes, "modes": list(FALLBACK_MODES),
                   "selector_tag": DEFAULT_SELECTOR_TAG,
                   "urltest_tag": DEFAULT_URLTEST_TAG},
                  sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
