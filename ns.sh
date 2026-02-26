#!/bin/bash

# ─────────────────────────────────────────────
# 用法: bash ns1.sh <domain> [AKIAXXXX----secretXXXX] [region]
# 示例: bash ns1.sh mmit.baby AKIAXXXX----secretXXXX ap-east-1
# ─────────────────────────────────────────────

DOMAIN="${1:-}"
AWS_CREDS="${2:-}"
AWS_REGION="${3:-ap-east-1}"
WildRecord="8.208.90.25"

# 解析 KEY----SECRET 格式
AWS_KEY="${AWS_CREDS%%----*}"
AWS_SECRET="${AWS_CREDS##*----}"
# 如果没有 ---- 分隔符，清空两者
[ "$AWS_KEY" = "$AWS_CREDS" ] && AWS_KEY="" && AWS_SECRET=""

[ -n "$DOMAIN" ] || { echo "❌ 请提供域名参数"; exit 1; }

# ── 随机生成一个伪NS2 IP（Google段）──────────────────────────
randCIDR() {
  cidr="${1:-}"
  [ -n "$cidr" ] || return
  IFS=/ read -r ip prefix <<<"$cidr"
  IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  ipInt="$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))"
  if (( prefix == 0 )); then mask=0
  else mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF )); fi
  base=$(( ipInt & mask ))
  if (( prefix == 32 )); then size=1
  else size=$(( 1 << (32 - prefix) )); fi
  if (( size >= 3 )); then start=1; end=$(( size - 2 ))
  else start=0; end=$(( size - 1 )); fi
  span=$(( end - start + 1 ))
  offset=$(( (RANDOM % span) + 1 ))
  final=$(( base + offset ))
  printf "%d.%d.%d.%d" $(( (final >> 24) & 0xFF )) $(( (final >> 16) & 0xFF )) $(( (final >> 8) & 0xFF )) $(( final & 0xFF ))
}

# ── 获取本机公网 IP ──────────────────────────────────────────
echo "📡 获取本机公网 IP..."
IPAddrNS1=$(wget -qO- checkip.amazonaws.com | grep -o '[0-9.]*')
[ -n "$IPAddrNS1" ] || { echo "❌ 无法获取本机公网IP"; exit 1; }
IPAddrNS2=$(randCIDR "74.125.0.0/16")
echo "✅ 本机IP: ${IPAddrNS1}  伪NS2: ${IPAddrNS2}"

# ── 安装依赖 ─────────────────────────────────────────────────
echo "📦 安装依赖..."
DEBIAN_FRONTEND=noninteractive apt-get -qqy update
DEBIAN_FRONTEND=noninteractive apt-get -qqy install bind9 bind9utils net-tools dnsutils awscli curl -y

# ════════════════════════════════════════════════════════════
# PTR 设置（AWS EC2 环境自动处理）
# ════════════════════════════════════════════════════════════
setup_ptr() {
  echo ""
  echo "🔧 开始设置 PTR 反解..."

  # 检测是否在 AWS EC2 上（兼容 IMDSv1 和 IMDSv2）
  # 先尝试 IMDSv2（需要 token）
  IMDS_TOKEN=$(curl -s --max-time 2 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)

  if [ -n "$IMDS_TOKEN" ] && ! echo "$IMDS_TOKEN" | grep -qi "html\|xml\|error"; then
    IS_AWS=$(curl -s --max-time 2 \
      -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  else
    # 回退 IMDSv1
    IS_AWS=$(curl -s --max-time 2 \
      http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  fi

  # 验证格式必须是 i-xxxxxxxx
  if [ -z "$IS_AWS" ] || ! echo "$IS_AWS" | grep -qE '^i-[0-9a-f]+$'; then
    echo "⚠️  未检测到有效 EC2 实例ID，跳过 PTR 设置"
    return
  fi

  INSTANCE_ID="$IS_AWS"
  echo "✅ 检测到 EC2 实例: ${INSTANCE_ID}"

  # 配置 AWS 凭证
  if [ -n "$AWS_KEY" ] && [ -n "$AWS_SECRET" ]; then
    mkdir -p ~/.aws
    cat > ~/.aws/credentials <<EOF
[default]
aws_access_key_id = ${AWS_KEY}
aws_secret_access_key = ${AWS_SECRET}
EOF
    cat > ~/.aws/config <<EOF
[default]
region = ${AWS_REGION}
output = text
EOF
    echo "✅ AWS 凭证已写入 (Key: ${AWS_KEY:0:8}...)"
  else
    echo "ℹ️  未传入 AWS Key，尝试使用 IAM Role 或已有凭证..."
  fi

  # 获取当前实例绑定的 EIP AllocationId
  echo "🔍 查询 EIP AllocationId..."
  ALLOC_ID=$(aws ec2 describe-addresses \
    --region "${AWS_REGION}" \
    --filters "Name=instance-id,Values=${INSTANCE_ID}" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null)

  if [ -z "$ALLOC_ID" ] || [ "$ALLOC_ID" == "None" ]; then
    echo "⚠️  当前实例没有绑定 EIP，尝试申请新 EIP..."

    ALLOC_INFO=$(aws ec2 allocate-address \
      --domain vpc \
      --region "${AWS_REGION}" \
      --output text \
      --query '[AllocationId, PublicIp]' 2>/dev/null)

    ALLOC_ID=$(echo "$ALLOC_INFO" | awk '{print $1}')
    NEW_IP=$(echo "$ALLOC_INFO"  | awk '{print $2}')

    if [ -z "$ALLOC_ID" ] || [ "$ALLOC_ID" == "None" ]; then
      echo "❌ 申请 EIP 失败，跳过 PTR 设置"
      return
    fi

    echo "✅ 申请新 EIP: ${NEW_IP}  AllocationId: ${ALLOC_ID}"
    aws ec2 associate-address \
      --instance-id "${INSTANCE_ID}" \
      --allocation-id "${ALLOC_ID}" \
      --region "${AWS_REGION}" >/dev/null

    IPAddrNS1="${NEW_IP}"
    echo "✅ 新 EIP 已绑定，本机IP更新为: ${IPAddrNS1}"
  else
    echo "✅ 找到 AllocationId: ${ALLOC_ID}"
  fi

  # 设置 PTR 记录
  echo "📝 设置 PTR 反解: ${IPAddrNS1} → ${DOMAIN}"
  PTR_RESULT=$(aws ec2 modify-address-attribute \
    --region "${AWS_REGION}" \
    --allocation-id "${ALLOC_ID}" \
    --domain-name "${DOMAIN}" 2>&1)

  if echo "$PTR_RESULT" | grep -qi "error\|fail\|invalid"; then
    echo "❌ PTR 设置失败: ${PTR_RESULT}"
  else
    echo "✅ PTR 设置成功: ${IPAddrNS1} → ${DOMAIN}"
  fi
}

setup_ptr

# ════════════════════════════════════════════════════════════
# BIND9 Zone 配置
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 配置 BIND9..."

mkdir -p /etc/bind/zones

cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    recursion no;
    listen-on-v6 { none; };
    allow-query { any; };
    dnssec-validation auto;
};
EOF

grep -q "\"${DOMAIN}\"" /etc/bind/named.conf.local 2>/dev/null || \
cat >> /etc/bind/named.conf.local <<EOF

zone "${DOMAIN}" {
    type master;
    file "/etc/bind/zones/${DOMAIN}";
};
EOF

zoneFile="/etc/bind/zones/${DOMAIN}"
if [ -f "${zoneFile}" ]; then
  SERIAL=$(grep "^@[[:space:]]*IN[[:space:]]*SOA" "${zoneFile}" | grep -o '([^)]*)' | grep -o '[0-9]*' | head -n1)
else
  SERIAL=$(date +%Y%m%d00)
fi
SERIAL=$(( SERIAL + 1 ))

cat > "${zoneFile}" <<EOF
\$TTL    300
@       IN  SOA     ns1.${DOMAIN}. hostmaster.${DOMAIN}. ( ${SERIAL} 21600 3600 1209600 60 )

;; Name Servers
@       IN  NS      ns1.${DOMAIN}.
@       IN  NS      ns2.${DOMAIN}.
ns1     IN  A       ${IPAddrNS1}
ns2     IN  A       ${IPAddrNS2}

;; A Records
@       IN  A       ${IPAddrNS1}
*       IN  A       ${WildRecord}

;; Mail（MX不能指向CNAME，直接用Google MX）
@       IN  MX  1   aspmx.l.google.com.
@       IN  MX  5   alt1.aspmx.l.google.com.
@       IN  MX  5   alt2.aspmx.l.google.com.

;; SPF / DMARC
@       IN  TXT     "v=spf1 ip4:${IPAddrNS1} include:_spf.google.com ~all"
_dmarc  IN  TXT     "v=DMARC1; p=quarantine; rua=mailto:postmaster@${DOMAIN}"

;; PTR 验证辅助（正向）
@       IN  TXT     "ptr-verify=${DOMAIN}"
EOF

chmod -R 777 /etc/bind/zones

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  域名:     ${DOMAIN}"
echo "  NS1 IP:   ${IPAddrNS1}"
echo "  NS2 IP:   ${IPAddrNS2}  (伪)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

named-checkzone "${DOMAIN}" "${zoneFile}" && echo "✅ Zone 文件检查通过" || echo "❌ Zone 文件有误"

systemctl restart bind9 && echo "✅ BIND9 已重启" || echo "❌ BIND9 重启失败"

echo ""
echo "🎉 完成！接下来在域名注册商处："
echo "   1. 将 NS 改为 ns1.${DOMAIN} / ns2.${DOMAIN}"
echo "   2. 添加 Glue Record: ns1.${DOMAIN} → ${IPAddrNS1}"