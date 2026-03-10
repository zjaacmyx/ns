#!/bin/bash

# ==========================================
# 辅助函数: 根据 CIDR 随机生成一个 IP
# ==========================================
randCIDR() {
    local cidr=$1
    local ip=${cidr%/*}
    local prefix=${cidr#*/}

    # 将 IP 转换为整数
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$ip"
    local ip_int=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
    
    # 计算网络号和可用主机数
    local mask=$(( 0xFFFFFFFF << (32 - prefix) ))
    local net_int=$(( ip_int & mask ))
    local hosts=$(( 2 ** (32 - prefix) ))

    # 使用 /dev/urandom 生成高质量随机偏移量 (排除网络号和广播地址)
    local rand_offset=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    rand_offset=$(( rand_offset % (hosts - 2) + 1 ))

    # 组合出最终的随机 IP 整数并转换回 IPv4 格式
    local rand_ip_int=$(( net_int + rand_offset ))
    echo "$(( (rand_ip_int >> 24) & 255 )).$(( (rand_ip_int >> 16) & 255 )).$(( (rand_ip_int >> 8) & 255 )).$(( rand_ip_int & 255 ))"
}

# 获取传入的域名参数
DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "错误: 未提供域名！"
    echo "用法: bash ns1.sh <你的域名> (例如: bash ns1.sh tscd.surf)"
    exit 1
fi

# 自动获取本机公网 IP (作为 ns1 DNS 解析服务器的 IP)
LocalIP=$(wget -qO- checkip.amazonaws.com | grep -o '[0-9\.]*')
if [ -z "$LocalIP" ]; then
    echo "错误: 无法获取本机 IP，请检查网络连接！"
    exit 1
fi

# 从指定 CIDR 随机生成 ns2 的 IP
IPAddrNS2=$(randCIDR "172.217.0.0/16")

# 邮局服务器的 IP (用于处理邮件和网站流量)
MailIP="8.208.90.25"

echo "=========================================="
echo "开始配置 DNS 权威服务器..."
echo "目标域名: ${DOMAIN}"
echo "本机 IP (仅作 NS1 解析): ${LocalIP}"
echo "随机生成的备用 IP (NS2): ${IPAddrNS2}"
echo "邮局/业务 IP (Web & Mail): ${MailIP}"
echo "=========================================="

# 安装依赖
DEBIAN_FRONTEND=noninteractive apt-get update -qqy
DEBIAN_FRONTEND=noninteractive apt-get install bind9 bind9utils net-tools dnsutils -qqy

# 1. 配置 options，隐藏指纹，禁用递归（权威服务器标配）
cat <<CONFIG > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";
    recursion no;
    allow-query { any; };
    # 隐藏 BIND 版本和服务器身份，防风控探测
    version "none";
    hostname "none";
    server-id "none";
    listen-on-v6 { any; };
};
CONFIG

# 2. 配置 local zone
mkdir -p /etc/bind/zones
zoneFile="/etc/bind/zones/db.${DOMAIN}"

grep -q "\"/etc/bind/zones/db.${DOMAIN}\";" /etc/bind/named.conf.local
if [ $? -ne 0 ]; then
    cat <<CONFIG >> /etc/bind/named.conf.local
zone "${DOMAIN}" {
    type master;
    file "${zoneFile}";
    # 允许从服务器同步数据 (由于 ns2 是随机的，这里按需配置)
    allow-transfer { ${IPAddrNS2}; };
};
CONFIG
fi

# 生成 Serial 号 (当前日期+01)
SERIAL=$(date +%Y%m%d01)

# 3. 编写 Zone 数据文件
cat <<DATA > "${zoneFile}"
\$TTL    86400
@       IN      SOA     ns1.${DOMAIN}. admin.${DOMAIN}. (
                              ${SERIAL}  ; Serial
                              10800      ; Refresh
                              3600       ; Retry
                              604800     ; Expire
                              3600 )     ; Negative Cache TTL

; --- 权威 NS 记录 ---
@       IN      NS      ns1.${DOMAIN}.
@       IN      NS      ns2.${DOMAIN}.

; --- NS 服务器自身的 IP ---
ns1     IN      A       ${LocalIP}
ns2     IN      A       ${IPAddrNS2}

; --- 核心 A 记录（主域名和泛解析指向邮局 IP） ---
@       IN      A       ${MailIP}
* IN      A       ${MailIP}
www     IN      A       ${MailIP}

; --- 邮件相关配置 (指向邮局 IP) ---
mail    IN      A       ${MailIP}
@       IN      MX  10  mail.${DOMAIN}.
* IN      MX  10  mail.${DOMAIN}.

; --- 安全策略 (SPF & DMARC) ---
@       IN      TXT     "v=spf1 a mx ip4:${MailIP} ~all"
_dmarc  IN      TXT     "v=DMARC1; p=quarantine; rua=mailto:admin@${DOMAIN}."
DATA

# 修正权限
chown -R bind:bind /etc/bind/zones
chmod -R 755 /etc/bind/zones

# 如果有防火墙，开放 53 端口
if command -v ufw > /dev/null; then
    ufw allow 53/tcp >/dev/null 2>&1
    ufw allow 53/udp >/dev/null 2>&1
fi

echo -e "\n正在检查 Zone 文件语法..."
named-checkzone "${DOMAIN}" "${zoneFile}"

# 重启服务并设置自启
systemctl enable named
systemctl restart named

echo "----------------------------------------"
echo "✅ Master NS 配置完成！"
echo "请前往域名注册商，将域名的 NS 服务器设置为："
echo "ns1.${DOMAIN}  ->  ${LocalIP} (本机)"
echo "ns2.${DOMAIN}  ->  ${IPAddrNS2} (随机生成的 Google IP 段)"
echo "----------------------------------------"