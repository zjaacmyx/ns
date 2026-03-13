#!/bin/bash
# 子域名
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
  offset=$(( (RANDOM % $span) + 1 ))
  final=$(( base + offset ))
  printf "%d.%d.%d.%d" $(( (final >> 24) & 0xFF )) $(( (final >> 16) & 0xFF )) $(( (final >> 8)  & 0xFF )) $(( final & 0xFF ))
}

DOMAIN="${1:-}"
IPAddrNS1=`wget -qO- checkip.amazonaws.com |grep -o '[0-9\.]*'`
IPAddrNS2=`randCIDR "172.217.0.0/16"`
WildRecord="8.208.90.25"

[ -n "$DOMAIN" ] && [ -n "$IPAddrNS1" ] && [ -n "$IPAddrNS2" ] || exit 1

DEBIAN_FRONTEND=noninteractive apt-get -qqy update
DEBIAN_FRONTEND=noninteractive apt-get -qqy install bind9 bind9utils net-tools dnsutils

mkdir -p /etc/bind/zones
echo -ne "options {\n	directory \"/var/cache/bind\";\n	recursion no;\n	listen-on-v6 { none; };\n	allow-query { any; };\n	dnssec-validation auto;\n};\n\n" >/etc/bind/named.conf.options
grep -q "\"/etc/bind/zones/${DOMAIN}\";" /etc/bind/named.conf.local
[ $? -ne 0 ] && echo -ne "zone \"${DOMAIN}\" {\n    type master;\n    file \"/etc/bind/zones/${DOMAIN}\";\n};\n\n" |tee -a /etc/bind/named.conf.local

zoneFile="/etc/bind/zones/${DOMAIN}"
[ -f "${zoneFile}" ] && SERIAL=`cat "${zoneFile}" |grep "^@[[:space:]]*IN[[:space:]]*SOA[[:space:]]*" |grep -o '(.*)' |grep -o '[0-9]*' |head -n1` || SERIAL=`date +%Y%m%d00`
SERIAL=$((SERIAL+1))

cat << EOF_ZONE > "${zoneFile}"
\$TTL    300
@       IN      SOA     ns1.google.com. dns-admin.google.com. ( ${SERIAL} 21600 1800 1800 60 )
@       IN      NS      ns1.${DOMAIN}.
@       IN      NS      ns2.${DOMAIN}.

ns1     IN      A       ${IPAddrNS1}
ns2     IN      A       ${IPAddrNS2}
@       IN      A       ${IPAddrNS1}
*       IN      A       ${WildRecord}
mail    IN      CNAME   smtp.google.com.

@       IN      MX  10  mail.${DOMAIN}.
@       IN      TXT     "v=spf1 redirect=_spf.google.com"
_dmarc  IN      TXT     "v=DMARC1; p=quarantine; rua=mailto:dns-admin.google.com."
@       IN      TXT     "v=spf1 redirect=_spf.${DOMAIN}"
EOF_ZONE

# chown -R bind:bind /etc/bind/zones
chmod -R 777 /etc/bind/zones
echo -ne "Domain: ${DOMAIN}\nIPAddrNS1: ${IPAddrNS1}\nIPAddrNS2: ${IPAddrNS2}\n\n"
named-checkzone "${DOMAIN}" "${zoneFile}"
systemctl restart bind9
