# EasySocks（easysocks）

基于 **GOST(v3)** 的高性能 SOCKS5 代理一键部署脚本（systemd），支持：可选认证（密码可空）、流量统计（默认开）、自定义端口（默认 1080）、IPv4/IPv6 出站选择。

---

## 一键安装（复制即用）

> 需要 root（或 sudo）

```bash
curl -fsSL https://raw.githubusercontent.com/markjackym/easysocks/main/install.sh | sudo bash

