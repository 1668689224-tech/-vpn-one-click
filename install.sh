#!/usr/bin/env bash
# =============================================================================
# sing-box 一键搭建脚本：VLESS+Reality + Hysteria2 + AnyTLS 三协议共存
# 适用：Debian 11+ / Ubuntu 20.04+（root 运行，systemd）
# 用法：
# bash install.sh # 安装（重复运行会重新生成全部密钥）
# bash install.sh show # 再次打印节点链接
# bash install.sh restart # 重启 sing-box
# bash install.sh uninstall # 卸载
# 可选环境变量：
# REALITY_SNI Reality 伪装域名（默认 www.microsoft.com，需支持 TLS1.3）
# CERT_SNI Hy2/AnyTLS 自签证书域名（默认 www.apple.com）
# ANYTLS_PORT AnyTLS 端口（默认 8443）
# =============================================================================
set -euo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
INFO_FILE="$CONFIG_DIR/client-info.txt"
CERT_DIR="$CONFIG_DIR/cert"
CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"

REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
CERT_SNI="${CERT_SNI:-www.apple.com}"
ANYTLS_PORT="${ANYTLS_PORT:-8443}"
REALITY_PORT=443
HY2_PORT=443

red() { printf '\033[31m%s\033[0m\n' "$*";}
green() { printf '\033[32m%s\033[0m\n' "$*";}
info() { printf '%s\n' "$*";}

need_root() {
[ "$(id -u)" = "0"] || { red "请用 root 运行：sudo bash $0"; exit 1;}
}

check_os() {
[ -f /etc/debian_version] || { red "仅支持 Debian / Ubuntu 系统"; exit 1;}
command -v systemctl >/dev/null || { red "未检测到 systemd"; exit 1;}
}

public_ip() {
local ip=""
ip="$(curl -fsS4 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')" || true
[ -z "$ip"] && ip="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null)" || true
[ -n "$ip"] || { red "无法自动获取公网 IP，请手动编辑 $INFO_FILE"; ip="YOUR_SERVER_IP";}
printf '%s' "$ip"
}

install_singbox() {
if command -v sing-box >/dev/null 2>&1; then
info "sing-box 已安装：$(sing-box version | head -n1)"
return
fi
info "正在安装 sing-box（官方源）…"
bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)"
}

gen_cert() {
mkdir -p "$CERT_DIR"
if [! -f "$CERT_FILE"]; then
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
-keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -nodes \
-subj "/CN=$CERT_SNI" >/dev/null 2>&1
chmod 600 "$KEY_FILE"
fi
}

enable_bbr() {
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
return
fi
info "开启 BBR…"
{
echo "net.core.default_qdisc=fq"
echo "net.ipv4.tcp_congestion_control=bbr"
} >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true
}

write_config() {
local uuid reality priv pub short_id hy2_pass anytls_pass
uuid="$(sing-box generate uuid)"
reality="$(sing-box generate reality-keypair)"
priv="$(printf '%s' "$reality" | awk '/PrivateKey/{print $2}')"
pub="$(printf '%s' "$reality" | awk '/PublicKey/{print $2}')"
short_id="$(openssl rand -hex 8)"
hy2_pass="$(openssl rand -base64 18 | tr -d '\n')"
anytls_pass="$(openssl rand -base64 18 | tr -d '\n')"

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
"log": { "level": "info", "timestamp": true},
"inbounds": [
{
"type": "vless",
"tag": "vless-reality-in",
"listen": "::",
"listen_port": $REALITY_PORT,
"users": [ { "uuid": "$uuid", "flow": "xtls-rprx-vision"}],
"tls": {
"enabled": true,
"server_name": "$REALITY_SNI",
"reality": {
"enabled": true,
"handshake": { "server": "$REALITY_SNI", "server_port": 443},
"private_key": "$priv",
"short_id": [ "$short_id"]
}
}
},
{
"type": "hysteria2",
"tag": "hy2-in",
"listen": "::",
"listen_port": $HY2_PORT,
"users": [ { "password": "$hy2_pass"}],
"tls": {
"enabled": true,
"server_name": "$CERT_SNI",
"certificate_path": "$CERT_FILE",
"key_path": "$KEY_FILE"
},
"masquerade": { "type": "proxy", "url": "https://$CERT_SNI", "rewrite_host": true}
},
{
"type": "anytls",
"tag": "anytls-in",
"listen": "::",
"listen_port": $ANYTLS_PORT,
"users": [ { "name": "user", "password": "$anytls_pass"}],
"tls": {
"enabled": true,
"certificate_path": "$CERT_FILE",
"key_path": "$KEY_FILE"
}
}
],
"outbounds": [ { "type": "direct", "tag": "direct"}]
}
EOF
sing-box check -c "$CONFIG_FILE"

local ip; ip="$(public_ip)"
cat > "$INFO_FILE" <<EOF
服务器 IP: $ip

VLESS + Reality（TCP $REALITY_PORT）— 主力
vless://$uuid@$ip:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$pub&sid=$short_id&type=tcp#VLESS-Reality

Hysteria2（UDP $HY2_PORT）— 弱网/晚高峰
hysteria2://$hy2_pass@$ip:$HY2_PORT?insecure=1&sni=$CERT_SNI#Hysteria2

AnyTLS（TCP $ANYTLS_PORT）— 备用（需新版客户端）
anytls://$anytls_pass@$ip:$ANYTLS_PORT?insecure=1&sni=$CERT_SNI#AnyTLS
EOF
chmod 600 "$INFO_FILE"
}

open_firewall() {
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
ufw allow ${REALITY_PORT}/tcp >/dev/null || true
ufw allow ${HY2_PORT}/udp >/dev/null || true
ufw allow ${ANYTLS_PORT}/tcp >/dev/null || true
fi
info "提醒：若云厂商有安全组，请放行 TCP $REALITY_PORT、UDP $HY2_PORT、TCP $ANYTLS_PORT"
}

do_install() {
need_root; check_os
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl >/dev/null
install_singbox
gen_cert
enable_bbr
write_config
open_firewall
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 1
systemctl is-active --quiet sing-box && green "sing-box 运行中" || { red "sing-box 启动失败，看日志：journalctl -u sing-box -e"; exit 1;}
green "==================== 安装完成 ===================="
cat "$INFO_FILE"
info "以上信息保存在 $INFO_FILE，随时可运行 bash $0 show 再次查看"
}

do_uninstall() {
need_root
systemctl disable --now sing-box 2>/dev/null || true
apt-get purge -y sing-box || true
rm -rf "$CONFIG_DIR"
green "已卸载 sing-box 并删除 $CONFIG_DIR"
}

case "${1:-install}" in
install) do_install;;
show) [ -f "$INFO_FILE"] && cat "$INFO_FILE" || { red "未找到 $INFO_FILE，请先安装"; exit 1;};;
restart) need_root; systemctl restart sing-box; green "已重启";;
uninstall) do_uninstall;;
*) red "用法：bash $0 [install|show|restart|uninstall]"; exit 1;;
esac
