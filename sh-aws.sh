#!/bin/bash

# 需要aws的VPS
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

  printf "%d.%d.%d.%d"     $(( (final >> 24) & 0xFF ))     $(( (final >> 16) & 0xFF ))     $(( (final >> 8)  & 0xFF ))     $(( final & 0xFF ))
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

ZONE="/var/named/${DOMAIN}.zone"
CONF="/etc/named.conf"

########################################
# Install bind (yum/dnf version)
########################################
if command -v dnf >/dev/null 2>&1; then
    PKG=dnf
elif command -v yum >/dev/null 2>&1; then
    PKG=yum
else
    echo "Only yum/dnf supported"
    exit 1
fi

$PKG -y install bind bind-utils net-tools dnsutils curl --allowerasing --skip-broken

########################################
# ★ 自动提取本机 IP 的反向解析域名 (EC2 域名)
# 必须放在安装完 bind-utils 之后，因为需要用到 dig 命令
########################################
EC2_HOSTNAME=$(dig +short -x "$IPAddrNS1")

if [ -n "$EC2_HOSTNAME" ]; then
    EC2_NS_RECORD="@       IN      NS      ${EC2_HOSTNAME}"
    echo "Successfully extracted EC2 Hostname: ${EC2_HOSTNAME}"
else
    EC2_NS_RECORD="; No reverse DNS found for ${IPAddrNS1}"
    echo "Warning: No reverse DNS found for ${IPAddrNS1}"
fi

########################################
# Prepare
########################################
setenforce 0 2>/dev/null || true
mkdir -p /var/named

########################################
# Write named.conf.options equivalent
########################################
cat > $CONF <<EOF
options {
    directory "/var/named";
    recursion no;
    listen-on-v6 { none; };
    allow-query { any; };
    dnssec-validation auto;
};
EOF

########################################
# Add zone block if not exists
########################################
grep -q "zone \"${DOMAIN}\"" $CONF || cat >> $CONF <<EOF

zone "${DOMAIN}" {
    type master;
    file "${ZONE}";
};
EOF

########################################
# SERIAL auto increment
# ★ 修复了之前遗留的 Debian 路径错误，改为当前的 ZONE 变量
########################################
if [ -f "${ZONE}" ]; then
  SERIAL=$(grep "^@[[:space:]]*IN[[:space:]]*SOA[[:space:]]*" "${ZONE}" | grep -o '([^)]*)' | grep -o '[0-9]*' | head -n1)
fi
[ -z "$SERIAL" ] && SERIAL=$(date +%Y%m%d00)
SERIAL=$((SERIAL+1))

########################################
# Write zone 
########################################
VERIFY=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
VERIFY2=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)

cat << EOF_ZONE > "${ZONE}"
\$TTL    3600
@       IN      SOA     ns-ext-prod.jackfruit.apple.com. ns-ext-prod.jackfruit.apple.com. ( ${SERIAL} 21600 3600 1209600 60 )
${EC2_NS_RECORD}
@       IN      NS      a.ns.apple.com.${DOMAIN}.
@       IN      NS      b.ns.apple.com.${DOMAIN}.
@       IN      NS      c.ns.apple.com.${DOMAIN}.
@       IN      NS      d.ns.apple.com.${DOMAIN}.
@       IN      NS      ns1.${DOMAIN}.

ns1     IN      A       ${IPAddrNS1}
a.ns.apple.com     IN      A       17.253.200.1
b.ns.apple.com     IN      A       17.253.207.1
c.ns.apple.com     IN      A       204.19.119.1
d.ns.apple.com     IN      A       204.26.57.1
mail     IN      A       ${IPAddrNS1}
@       IN      MX  5  mail.${DOMAIN}.
@       IN      MX  10  mail.${DOMAIN}.
@       IN      MX  20  mail.${DOMAIN}.
@       IN      MX  30  mail.${DOMAIN}.
@       IN      MX  40  mail.${DOMAIN}.
* IN      MX  5  mail.${DOMAIN}.
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
# Permissions
########################################
chmod -R 777 /var/named

########################################
# Check & restart
########################################
named-checkconf
named-checkzone "${DOMAIN}" "${ZONE}"

systemctl daemon-reexec
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
