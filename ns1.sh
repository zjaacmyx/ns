#!/bin/bash
set -e

########################################
# randCIDR (SAME as first script)
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
# Get IPs (SAME as first script)
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
# SERIAL auto increment (SAME logic)
########################################
zoneFile="/etc/bind/zones/${DOMAIN}"
[ -f "${zoneFile}" ] && SERIAL=`cat "${zoneFile}" |grep "^@[[:space:]]*IN[[:space:]]*SOA[[:space:]]*" |grep -o '(.*)' |grep -o '[0-9]*' |head -n1` || SERIAL=`date +%Y%m%d00`
SERIAL=$((SERIAL+1))
#SERIAL=$((SERIAL))
########################################
# Write zone (EXACT records from first script)
########################################   #mail    IN      CNAME   smtp.google.com.  #@       IN      TXT     "v=spf1 redirect=_spf.mail.${DOMAIN}"  # ${IPAddrNS2}
VERIFY=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
VERIFY2=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
cat << EOF_ZONE > "${ZONE}"
\$TTL    3600
@       IN      SOA     ns-ext-prod.jackfruit.apple.com. ns-ext-prod.jackfruit.apple.com. ( ${SERIAL} 21600 3600 1209600 60 )
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
mx01.mail     IN      A       ${IPAddrNS1}
mx02.mail     IN      A       ${IPAddrNS1}
@       IN      MX  10  mx01.mail.${DOMAIN}.
@       IN      MX  10  mx02.mail.${DOMAIN}.
@       IN      A       ${IPAddrNS1}
*       IN      A       ${IPAddrNS1}
mail    IN      CNAME   mail.we.apple-dns.net.


_dmarc  IN      TXT     "v=DMARC1; p=quarantine; sp=quarantine; rua=mailto:d@rua.agari.com; ruf=mailto:d@ruf.agari.com"
@       IN      TXT     "google-site-verification=${VERIFY}"
@       IN      TXT     "google-site-verification=${VERIFY2}"
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
*       IN      TXT     "google-site-verification=${VERIFY}"
*       IN      TXT     "google-site-verification=${VERIFY2}"
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

#*       IN      TXT     "v=spf1 redirect=_spf.google.com"
#*       IN      TXT     "v=spf1 redirect=_spf.${DOMAIN}"
########################################
# Permissions (same wide-open as first script)
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
echo -e "Domain: ${DOMAIN}"
echo -e "IPAddrNS1: ${IPAddrNS1}"
echo -e "IPAddrNS2: ${IPAddrNS2}"
