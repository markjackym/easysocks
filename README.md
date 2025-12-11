````md
# easysocks（gost SOCKS5 一键安装/卸载）

一个基于 **gost** 的高性能 SOCKS5 一键脚本：支持自定义端口、可选用户名密码、IPv4/IPv6 出站选择、systemd 常驻运行、自动放行防火墙端口。

---

## ✅ 一键执行（复制即用）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/markjackym/easysocks/main/install.sh)
````

> 如果你的系统没有 `curl`，也可以用 `wget`：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/markjackym/easysocks/main/install.sh)
```

---

## 功能特性

* SOCKS5 代理一键安装 / 卸载
* 端口自定义（默认 `1080`）
* 用户名/密码可选（留空则不启用认证）
* IPv4 / IPv6 / 双栈监听选择
* systemd 服务守护（自动重启、开机自启）
* 自动配置防火墙端口（firewalld / ufw）

---

## 使用说明

执行脚本后按菜单提示选择：

* `1` 安装 SOCKS5
* `2` 卸载 SOCKS5
* `3` 查看服务状态
* `0` 退出

安装完成后会输出服务器地址、端口与认证信息，按提示在客户端填入即可使用。

---

## 常用命令

查看运行状态：

```bash
systemctl status gost --no-pager -l
```

查看最近日志：

```bash
journalctl -u gost -n 50 --no-pager
```

重启服务：

```bash
systemctl restart gost
```

停止服务：

```bash
systemctl stop gost
```

---

## 卸载

运行脚本并选择菜单 `2` 即可卸载（会同时移除 systemd 服务与配置）。

---

## 免责声明

本项目仅用于学习与合法用途，请遵守当地法律法规。使用本脚本造成的任何后果由使用者自行承担。
