# sing-box 一键搭建：VLESS+Reality + Hysteria2 + AnyTLS

一条命令在一台 VPS 上同时装好三个协议的节点，互为备用，专为小火箭（Shadowrocket）等客户端优化。

| 入站 | 端口 | 用途 |
| --- | --- | --- |
| VLESS + Reality（Vision） | TCP 443 | 主力：借真实大站证书伪装，无需域名，抗封锁最强 |
| Hysteria2 | UDP 443 | 弱网/晚高峰：高丢包也能跑满带宽 |
| AnyTLS | TCP 8443 | 备用新秀：TLS 伪装 + 填充抹平流量特征（需新版客户端，小火箭 2.2.65+） |

内核为 [sing-box](https://github.com/SagerNet/sing-box)（脚本已用 v1.14.4 实测校验配置通过）。

## 前置要求

- 一台境外 VPS（东京/新加坡/美西均可，1 核 1G 足够个人使用）
- 系统：Debian 11+ 或 Ubuntu 20.04+，root 登录
- 云厂商安全组放行：**TCP 443、UDP 443、TCP 8443**（脚本会处理系统内 ufw，但安全组要在商家后台手动放行）

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1668689224-tech/-vpn-one-click/main/install.sh)
```

没有仓库访问时也可以把 `install.sh` 下载到服务器本地再执行 `bash install.sh`。

安装过程全自动：装 sing-box 官方源版本 → 生成 UUID / Reality 密钥对 / 各协议密码 → 生成自签证书 → 写入配置并校验 → 开 BBR → 启动服务。完成后屏幕上会打印三条节点链接，同时保存在服务器的 `/etc/sing-box/client-info.txt`。

## 导入小火箭

1. 复制任意一条 `vless://` / `hysteria2://` / `anytls://` 链接；
2. 打开 Shadowrocket，它会提示从剪贴板导入；或点右上角 **+** 手动粘贴添加；
3. 选中节点，打开首页连接开关即可。三个节点建议都导入，哪个快用哪个。

其他客户端（sing-box、mihomo/Clash Meta、v2rayN、NekoBox 等）同样可以直接导入这些链接。

## 管理命令

```bash
bash install.sh show       # 再次打印节点链接（密钥、密码都在里面，别外传）
bash install.sh restart    # 重启 sing-box
bash install.sh uninstall  # 卸载并删除配置
journalctl -u sing-box -e  # 看服务日志
```

## 可选自定义

安装前用环境变量覆盖默认值：

```bash
REALITY_SNI=www.apple.com CERT_SNI=www.microsoft.com bash install.sh
```

- `REALITY_SNI`：Reality 借用的目标站，必须支持 TLS 1.3 且服务器能直连（默认 `www.microsoft.com`）；
- `CERT_SNI`：Hysteria2 / AnyTLS 自签证书与伪装域名（默认 `www.apple.com`）；
- `ANYTLS_PORT`：AnyTLS 端口（默认 8443）。Reality 与 Hysteria2 固定使用 443（TCP/UDP 互不冲突）。

## 注意事项 / 常见问题

- **重复运行安装会重新生成全部密钥和密码**，老链接随即失效，需要重新导入。
- **连不上先查三件事**：安全组 UDP 443 是否放行（Hysteria2 最常见死因）；服务是否在跑（`systemctl status sing-box`）；IP 是否被墙（换 IP 或换机器比换协议管用）。
- Hysteria2 与 AnyTLS 用的是自签证书，所以链接里带 `insecure=1`，这是预期行为；介意的话可换成自有域名 + 正式证书后去掉该参数。
- 某个协议被限速/阻断时，先切换到另一个协议顶上，这正是三协议共存的意义。
- 节点只建议自用；`client-info.txt` 等同于钥匙，不要截图发到公开场合。

## 卸载

```bash
bash install.sh uninstall
```
