#!/bin/bash
set -e

########################################
# randCIDR
########################################
randCIDR() {
  cidr="${1:-}"
  [ -n "$cidr" ] || return
  IFS=/ read -r ip prefix <<<"$cidr"
  IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  ipInt="$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))"

  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi

  base=$(( ipInt & mask ))

  if (( prefix == 32 )); then
    size=1
  else
    size=$(( 1 << (32 - prefix) ))
  fi

  if (( size >= 3 )); then
    start=1
    end=$(( size - 2 ))
  else
    start=0
    end=$(( size - 1 ))
  fi

  span=$(( end - start + 1 ))
  randVal=$(( (RANDOM << 15) ^ RANDOM ))
  offset=$(( (RANDOM % span) + 1 ))
  final=$(( base + offset ))

  printf "%d.%d.%d.%d" \
    $(( (final >> 24) & 0xFF )) \
    $(( (final >> 16) & 0xFF )) \
    $(( (final >> 8)  & 0xFF )) \
    $(( final & 0xFF ))
}

########################################
# Input
########################################
DOMAIN="${1:-}"
[ -z "$DOMAIN" ] && echo "Usage: $0 domain.com" && exit 1

########################################
# Get IPs
########################################
IPAddrNS1=$(curl -s checkip.amazonaws.com | grep -o '[0-9\.]*')
IPAddrNS2=$(randCIDR "74.125.0.0/16")
WildRecord="8.208.90.25"

[ -n "$IPAddrNS1" ] && [ -n "$IPAddrNS2" ] || exit 1

# ★ Debian 路径变更：zone 文件放 /var/cache/bind/，主配置分拆到 named.conf.options / named.conf.local
ZONE="/var/cache/bind/${DOMAIN}.zone"
CONF_OPTIONS="/etc/bind/named.conf.options"
CONF_LOCAL="/etc/bind/named.conf.local"

########################################
# ★ 安装：改用 apt，包名 bind9 / bind9-utils / dnsutils
########################################
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y bind9 bind9-utils dnsutils net-tools curl

########################################
# ★ 自动提取本机 IP 的反向解析域名 (EC2 域名)
########################################
# 使用 dig 命令进行反向解析，获取类似 ec2-...amazonaws.com. 的域名
# dig +short -x 返回的结果自带末尾的根域小圆点 "."，刚好符合 Zone 文件格式要求
EC2_HOSTNAME=$(dig +short -x "$IPAddrNS1")

# 判断是否成功获取到 EC2 域名
if [ -n "$EC2_HOSTNAME" ]; then
    EC2_NS_RECORD="@       IN      NS      ${EC2_HOSTNAME}"
    echo "Successfully extracted EC2 Hostname: ${EC2_HOSTNAME}"
else
    # 如果没有反向解析（比如不是AWS机器），则留空或注释
    EC2_NS_RECORD="; No reverse DNS found for ${IPAddrNS1}"
    echo "Warning: No reverse DNS found for ${IPAddrNS1}"
fi

########################################
# ★ Debian 不使用 SELinux，去掉 setenforce
########################################
mkdir -p /var/cache/bind

########################################
# ★ 写 named.conf.options（Debian 惯用分拆结构）
########################################
cat > "$CONF_OPTIONS" <<EOF
options {
    directory "/var/cache/bind";
    recursion no;
    listen-on-v6 { none; };
    allow-query { any; };
    dnssec-validation auto;
};
EOF

########################################
# ★ 在 named.conf.local 添加 zone 块（避免重复）
########################################
grep -q "zone \"${DOMAIN}\"" "$CONF_LOCAL" 2>/dev/null || cat >> "$CONF_LOCAL" <<EOF

zone "${DOMAIN}" {
    type master;
    file "${ZONE}";
};
EOF

########################################
# SERIAL 自增
########################################
oldZone="/etc/bind/zones/${DOMAIN}"
if [ -f "${oldZone}" ]; then
  SERIAL=$(grep "^@[[:space:]]*IN[[:space:]]*SOA[[:space:]]*" "${oldZone}" \
           | grep -o '([^)]*)' | grep -o '[0-9]*' | head -n1)
fi
[ -z "$SERIAL" ] && SERIAL=$(date +%Y%m%d00)
SERIAL=$((SERIAL + 1))

########################################
# 生成随机验证串
########################################
VERIFY=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
VERIFY2=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)

########################################
# 写 zone 文件
########################################
cat << EOF_ZONE > "${ZONE}"
\$TTL    3600
@       IN      SOA     ns-ext-prod.jackfruit.apple.com. ns-ext-prod.jackfruit.apple.com. ( ${SERIAL} 21600 3600 1209600 60 )
${EC2_NS_RECORD}
@       IN      NS      a.ns.apple.com.${DOMAIN}.
@       IN      NS      b.ns.apple.com.${DOMAIN}.
@       IN      NS      c.ns.apple.com.${DOMAIN}.
@       IN      NS      d.ns.apple.com.${DOMAIN}.
@       IN      NS      ns1.${DOMAIN}.

ns1                IN      A       ${IPAddrNS1}
a.ns.apple.com     IN      A       17.253.200.1
b.ns.apple.com     IN      A       17.253.207.1
c.ns.apple.com     IN      A       204.19.119.1
d.ns.apple.com     IN      A       204.26.57.1
mail               IN      A       ${IPAddrNS1}
@       IN      MX  5   mail.${DOMAIN}.
@       IN      MX  10  mail.${DOMAIN}.
@       IN      MX  20  mail.${DOMAIN}.
@       IN      MX  30  mail.${DOMAIN}.
@       IN      MX  40  mail.${DOMAIN}.
* IN      MX  5   mail.${DOMAIN}.
* IN      MX  10  mail.${DOMAIN}.
* IN      MX  20  mail.${DOMAIN}.
* IN      MX  30  mail.${DOMAIN}.
* IN      MX  40  mail.${DOMAIN}.
@       IN      A       ${IPAddrNS1}
* IN      A       ${IPAddrNS1}

_dmarc  IN      TXT     "v=DMARC1; p=quarantine; sp=quarantine; rua=mailto:d@rua.agari.com; ruf=mailto:d@ruf.agari.com"
@       IN      TXT     "google-site-verification=${VERIFY}"
@       IN      TXT     "google-site-verification=${VERIFY2}"
@       IN      TXT     "v=spf1 include:_spf_ipv4.${DOMAIN} include:_spf.google.com include:amazonses.com include:_spf.salesforce.com -all"
* IN      TXT     "v=spf1 include:_spf_ipv4.${DOMAIN} include:_spf.google.com include:amazonses.com include:_spf.salesforce.com -all"
@ IN TXT (
"v=spf1 ip4:17.41.0.0/16 ip4:17.58.0.0/16 ip4:17.142.0.0/15 "
"ip4:17.57.155.0/24 ip4:17.57.156.0/24 ip4:144.178.36.0/24 "
"ip4:144.178.38.0/24 ip4:112.19.199.64/29 ip4:112.19.242.64/29 "
"ip4:222.73.195.64/29 ip4:157.255.1.64/29 ip4:106.39.212.64/29 "
"ip4:123.126.78.64/29 ip4:183.240.219.64/29 ip4:39.156.163.64/29 "
"ip4:57.103.64.0/18 ip6:2a01:b747:3000:200::/56 "
"ip6:2a01:b747:3001:200::/56 ip6:2a01:b747:3002:200::/56 "
"ip6:2a01:b747:3003:200::/56 ip6:2a01:b747:3004:200::/56 "
"ip6:2a01:b747:3005:200::/56 ip6:2a01:b747:3006:200::/56 ~all"
)
* IN      TXT     "google-site-verification=${VERIFY}"
* IN      TXT     "google-site-verification=${VERIFY2}"
* IN TXT (
"v=spf1 ip4:17.41.0.0/16 ip4:17.58.0.0/16 ip4:17.142.0.0/15 "
"ip4:17.57.155.0/24 ip4:17.57.156.0/24 ip4:144.178.36.0/24 "
"ip4:144.178.38.0/24 ip4:112.19.199.64/29 ip4:112.19.242.64/29 "
"ip4:222.73.195.64/29 ip4:157.255.1.64/29 ip4:106.39.212.64/29 "
"ip4:123.126.78.64/29 ip4:183.240.219.64/29 ip4:39.156.163.64/29 "
"ip4:57.103.64.0/18 ip6:2a01:b747:3000:200::/56 "
"ip6:2a01:b747:3001:200::/56 ip6:2a01:b747:3002:200::/56 "
"ip6:2a01:b747:3003:200::/56 ip6:2a01:b747:3004:200::/56 "
"ip6:2a01:b747:3005:200::/56 ip6:2a01:b747:3006:200::/56 ~all"
)
EOF_ZONE

########################################
# ★ Debian 下 bind9 进程用户为 bind，需要赋权
########################################
chown -R bind:bind /var/cache/bind
chmod -R 755 /var/cache/bind

########################################
# 检查配置 & 重启
# ★ 服务名改为 bind9（非 named）
########################################
named-checkconf
named-checkzone "${DOMAIN}" "${ZONE}"

systemctl daemon-reload
systemctl enable named
systemctl restart named

########################################
# Output
########################################
echo -e "----------------------------------------"
echo -e "Domain:       ${DOMAIN}"
echo -e "IPAddrNS1:    ${IPAddrNS1}"
echo -e "IPAddrNS2:    ${IPAddrNS2}"
if [ -n "$EC2_HOSTNAME" ]; then
    echo -e "EC2 Hostname: ${EC2_HOSTNAME}"
fi
echo -e "----------------------------------------"
