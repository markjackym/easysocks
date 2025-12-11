#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# GOST(v3) SOCKS5 一键安装：可选认证(密码可空)、流量统计(默认开)、自定义端口、IPv4/IPv6 出站选择
# 用法：bash gost-socks5.sh {install|uninstall|status|traffic}
: "${GOST_TAG:=}"   # 例如：GOST_TAG=v3.2.6

BIN=/usr/local/bin/gost
DIR=/etc/gost
CFG=$DIR/gost.yml
SVC=/etc/systemd/system/gost.service

die(){ echo "[!] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行"; }
need_systemd(){ have systemctl || die "仅支持 systemd Linux"; }

pm_install(){
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
  elif have yum; then
    yum install -y "$@" >/dev/null
  elif have dnf; then
    dnf install -y "$@" >/dev/null
  else
    die "缺少包管理器(apt/yum/dnf)，无法安装依赖: $*"
  fi
}

ensure_deps(){
  local need=()
  have curl || need+=(curl)
  have tar  || need+=(tar)
  if ! have ip; then
    if have apt-get; then need+=(iproute2); else need+=(iproute); fi
  fi
  ((${#need[@]})) && pm_install "${need[@]}"
}

arch_asset(){
  case "$(uname -m)" in
    x86_64) grep -qm1 avx2 /proc/cpuinfo 2>/dev/null && echo amd64v3 || echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686) echo 386 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

latest_tag(){
  curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest \
    | awk -F'"' '/"tag_name":/ {print $4; exit}'
}

download(){
  local tag="$1" asset="$2" out="$3"
  local u base=(
    "https://github.com/go-gost/gost/releases/download"
    "https://ghproxy.com/https://github.com/go-gost/gost/releases/download"
    "https://mirror.ghproxy.com/https://github.com/go-gost/gost/releases/download"
  )
  for u in "${base[@]}"; do
    if curl -fL --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 1 \
      -o "$out" "$u/$tag/$asset" >/dev/null 2>&1; then
      tar -tzf "$out" >/dev/null 2>&1 && return 0 || true
    fi
    rm -f "$out"
  done
  return 1
}

install_bin(){
  local tag="${GOST_TAG:-$(latest_tag)}" arch ver asset tmp
  [[ -n "$tag" ]] || die "获取版本失败(GitHub API)"
  ver="${tag#v}"; arch="$(arch_asset)"

  while :; do
    asset="gost_${ver}_linux_${arch}.tar.gz"; tmp="/tmp/$asset"
    rm -f /tmp/gost "$tmp"
    if download "$tag" "$asset" "$tmp"; then
      break
    fi
    # amd64v3 资源缺失时自动回落
    if [[ "$arch" == "amd64v3" ]]; then
      arch="amd64"
      continue
    fi
    die "下载失败：检查网络/DNS/GitHub"
  done

  tar -xzf "$tmp" -C /tmp >/dev/null
  [[ -f /tmp/gost ]] || die "解压失败：未找到 gost"
  install -m 0755 /tmp/gost "$BIN"
  rm -f /tmp/gost "$tmp"
}

prompt(){ local m="$1" d="${2:-}" v=""; read -r -p "$m${d:+ (默认 $d)}: " v || true; echo "${v:-$d}"; }
prompt_secret(){ local m="$1" v=""; read -r -s -p "$m: " v || true; echo >&2; echo "$v"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1<=10#$1 && 10#$1<=65535)); }

def4(){ ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
def6(){ ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

fw_open(){
  local p="$1"
  if have firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port="$p/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif have ufw; then
    ufw allow "$p/tcp" >/dev/null 2>&1 || true
  fi
}
fw_close(){
  local p="$1"
  if have firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --remove-port="$p/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif have ufw; then
    ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
  fi
}

write_cfg(){
  local port="$1" user="$2" pass="$3" iface="$4" mon="$5" mport="$6"
  mkdir -p "$DIR"; chmod 700 "$DIR"
  {
    echo "services:"
    echo "- name: socks5"
    echo "  addr: \":$port\""
    [[ -n "$iface" ]] && { echo "  metadata:"; echo "    interface: \"$iface\""; }
    echo "  handler:"
    echo "    type: socks5"
    [[ -n "$user" ]] && { echo "    auth:"; echo "      username: \"$user\""; echo "      password: \"$pass\""; }
    echo "  listener:"
    echo "    type: tcp"
    [[ "$mon" == 1 ]] && { echo "metrics:"; echo "  addr: \"127.0.0.1:$mport\""; echo "  path: /metrics"; }
  } > "$CFG"
  chmod 600 "$CFG"
}

write_svc(){
  cat > "$SVC" <<EOF
[Unit]
Description=GOST SOCKS5 Proxy
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN -C $CFG
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable gost >/dev/null 2>&1 || true
  systemctl restart gost
}

cmd_install(){
  need_root; need_systemd; ensure_deps

  local port user pass mon mport out iface=""
  port="$(prompt "监听端口" 1080)"; valid_port "$port" || die "端口无效: $port"

  user="$(prompt "用户名(留空=无认证)" "")"
  if [[ -n "$user" ]]; then pass="$(prompt_secret "密码(可留空)")"; else pass=""; fi

  case "$(prompt "流量统计(Prometheus metrics) [Y/n]" Y | tr 'A-Z' 'a-z')" in
    n|no) mon=0; mport=18080 ;;
    *) mon=1; mport="$(prompt "Metrics 端口(仅本机访问)" 18080)"; valid_port "$mport" || die "metrics 端口无效: $mport" ;;
  esac

  out="$(prompt "出站选择: 0=自动 4=仅IPv4 6=仅IPv6" 0)"
  case "$out" in
    0) iface="" ;;
    4) iface="$(def4)"; [[ -n "$iface" ]] || die "未检测到默认 IPv4 出站地址" ;;
    6) iface="$(def6)"; [[ -n "$iface" ]] || die "未检测到默认 IPv6 出站地址" ;;
    *) die "无效选择: $out" ;;
  esac

  [[ -f "$SVC" ]] && cmd_uninstall || true
  install_bin
  write_cfg "$port" "$user" "$pass" "$iface" "$mon" "$mport"
  write_svc
  fw_open "$port"

  systemctl is-active --quiet gost || die "启动失败：journalctl -u gost -n 50 --no-pager"
  echo "[+] OK"
  echo "Port: $port"
  [[ -n "$user" ]] && echo "Auth: $user / ${pass:-<empty>}" || echo "Auth: none"
  [[ "$mon" == 1 ]] && echo "Metrics: http://127.0.0.1:$mport/metrics" || echo "Metrics: off"
  [[ -n "$iface" ]] && echo "Egress: $iface" || echo "Egress: auto"
}

cmd_uninstall(){
  need_root; need_systemd
  local port=""
  [[ -f "$CFG" ]] && port="$(awk -F'"' '/addr:/{print $2; exit}' "$CFG" | sed 's/^://')"
  systemctl stop gost >/dev/null 2>&1 || true
  systemctl disable gost >/dev/null 2>&1 || true
  rm -f "$SVC"; systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$CFG"; rmdir "$DIR" >/dev/null 2>&1 || true
  rm -f "$BIN" || true
  [[ -n "$port" ]] && fw_close "$port" || true
  echo "[+] 已卸载"
}

cmd_status(){
  need_systemd
  systemctl status gost --no-pager -l || true
  [[ -f "$CFG" ]] && { echo; echo "---- $CFG (password masked) ----"; sed -E 's/(password:\s*).*/\1"***"/' "$CFG" || true; }
}

cmd_traffic(){
  [[ -f "$CFG" ]] || die "未安装"
  local mport body in out
  mport="$(awk -F'"' '/metrics:/{f=1} f&&/addr:/{print $2; exit}' "$CFG" 2>/dev/null | awk -F: '{print $NF}')"
  [[ -n "$mport" ]] || die "未开启 metrics"
  body="$(curl -fsS "http://127.0.0.1:$mport/metrics" 2>/dev/null)" || die "无法访问 metrics(端口 $mport)"
  in="$(awk '/gost_service_transfer_input_bytes_total\{[^}]*service="socks5"/{print $2}' <<<"$body" | tail -n1)"
  out="$(awk '/gost_service_transfer_output_bytes_total\{[^}]*service="socks5"/{print $2}' <<<"$body" | tail -n1)"
  [[ -n "$in" && -n "$out" ]] || die "未找到 socks5 指标(可能无流量)"
  echo "IN : $in bytes"
  echo "OUT: $out bytes"
}

case "${1:-install}" in
  install) cmd_install ;;
  uninstall|remove) cmd_uninstall ;;
  status) cmd_status ;;
  traffic|stats) cmd_traffic ;;
  *) die "用法：$0 {install|uninstall|status|traffic}" ;;
esac

