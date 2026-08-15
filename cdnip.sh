#!/bin/sh
# ==============================================================
#  CF 官方 IP 优选 —— 路由器端脚本
#  数据源: github.com/jane2003/cfip  (ip.txt / ipv6.txt)
#  流程: 下载官方IP段 → cfst 本地测速 → 选最快 → CF API 更新 DNS
#
#  用法:
#    bash cdnip.sh            # 手动跑一次（首次会生成配置并下载 cfst）
#    bash cdnip.sh --run      # cron 静默跑（每天）
#    cron: 0 7 * * * cd /root && bash cdnip.sh --run
# ==============================================================
set -e

# ── 基础路径 ──
WD="/root/cfipopw"
CFG="$WD/cf_config"
LOG="$WD/informlog"
IPLIST="$WD/ip.txt"
IPLIST6="$WD/ipv6.txt"
RESULT="$WD/result.csv"
CFST="$WD/cfst"

# ── 颜色 ──
R='\033[31m' G='\033[32m' Y='\033[33m' C='\033[36m' W='\033[0m'
[ "$1" = "--run" ] && R='' && G='' && Y='' && C='' && W=''

# ── 加载配置 ──
[ -f "$CFG" ] && . "$CFG"
: ${CF_EMAIL:=""} ${CF_KEY:=""} ${CF_ZONE:=""}
: ${CF_DOMAIN:="zbs969.dpdns.org"} ${CF_COUNT:="10"}
: ${CF_THREADS:="200"} ${CF_DN_COUNT:="10"} ${CF_DN_TIME:="3"} ${CF_TL:="300"}
: ${CF_IPV:="4"}
: ${CF_SPEED_URL:="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"}
: ${CF_TG_TOKEN:=""} ${CF_TG_ID:=""}

# ── 日志 / TG ──
log() { echo "$(date '+%m-%d %H:%M:%S') $1" | tee -a "$LOG"; }
tg() {
    [ -z "$CF_TG_TOKEN" ] || [ -z "$CF_TG_ID" ] || [ -z "$1" ] && return
    curl -sm8 -X POST "https://api.telegram.org/bot${CF_TG_TOKEN}/sendMessage" \
        -d "chat_id=${CF_TG_ID}" --data-urlencode "text=$1" >/dev/null 2>&1
}

# ── 下载 cfst（arm64，多源）──
fetch_cfst() {
    [ -x "$CFST" ] && return
    log "下载 cfst 测速器..."
    case $(uname -m) in
        aarch64|arm64) A=arm64 ;;
        x86_64|amd64) A=amd64 ;;
        *) A=arm64 ;;
    esac
    local T="/tmp/cfst.tgz"
    for u in \
        "https://ghproxy.net/https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${A}.tar.gz" \
        "https://mirror.ghproxy.com/https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${A}.tar.gz" \
        "https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${A}.tar.gz" ; do
        curl -sSLm 60 "$u" -o "$T" && [ -s "$T" ] && break
    done
    [ -s "$T" ] || { log "cfst 下载失败"; exit 1; }
    tar -xzf "$T" -C "$WD" 2>/dev/null
    BIN=$(find "$WD" -maxdepth 2 \( -name 'cfst' -o -name 'CloudflareST' \) -type f 2>/dev/null | head -1)
    [ -n "$BIN" ] && mv -f "$BIN" "$CFST"
    chmod +x "$CFST" 2>/dev/null
    rm -f "$T"
    find "$WD" -maxdepth 1 -type d -name 'cfst_linux_*' -exec rm -rf {} + 2>/dev/null
    [ -x "$CFST" ] || { log "cfst 解压失败"; exit 1; }
    log "cfst 就绪"
}

# ── 下载 IP 段列表（多源）──
fetch_iplist() {
    local TARGET="$1" SRC="$2"
    log "下载 IP 列表 $SRC..."
    for u in \
        "https://ghproxy.net/https://raw.githubusercontent.com/jane2003/cfip/master/$SRC" \
        "https://mirror.ghproxy.com/https://raw.githubusercontent.com/jane2003/cfip/master/$SRC" \
        "https://raw.githubusercontent.com/jane2003/cfip/master/$SRC" ; do
        curl -sSLm 30 "$u" -o "$TARGET" && [ -s "$TARGET" ] && break
    done
    [ -s "$TARGET" ] || { log "IP 列表下载失败: $SRC"; exit 1; }
    log "IP 列表就绪: $(wc -l < "$TARGET") 个 CIDR 段"
}

# ── cfst 测速 ──
run_speedtest() {
    log "开始测速（线程 ${CF_THREADS}，延迟上限 ${CF_TL}ms）..."
    local FILE="$IPLIST"
    [ "$CF_IPV" = "6" ] && FILE="$IPLIST6"
    $CFST -f "$FILE" -o "$RESULT" -n "$CF_THREADS" -t 1 \
        -dn "$CF_DN_COUNT" -dt "$CF_DN_TIME" -tl "$CF_TL" -tll 0 -sl 0 \
        -url "$CF_SPEED_URL" >/dev/null 2>&1 || true
    [ -s "$RESULT" ] || { log "测速失败，无结果"; exit 1; }
    log "测速完成: $(tail -n +2 "$RESULT" | wc -l) 个可用 IP"
}

# ── CF API 更新 DNS ──
update_dns() {
    [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ] || [ -z "$CF_ZONE" ] && {
        log "未配置 CF 凭据，跳过 DNS 更新（先编辑 $CFG）"; return; }
    log "拉取现有 DNS 记录..."
    local RECORDS MSG=""
    RECORDS=$(curl -sm10 -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&per_page=100")
    local TMP="/tmp/cf_loop.txt"
    tail -n +2 "$RESULT" > "$TMP"
    local N=1 IP D RID RESP
    while IFS=',' read -r IP _; do
        [ -z "$IP" ] && continue
        [ "$N" -gt "$CF_COUNT" ] && break
        D="${N}.${CF_DOMAIN}"
        RID=$(echo "$RECORDS" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(r['id']) for r in d.get('result',[]) if r['name']=='$D']" 2>/dev/null)
        [ -z "$RID" ] && { N=$((N+1)); continue; }
        log "更新 $D → $IP"
        RESP=$(curl -sm10 -X PATCH \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records/$RID" \
            -d "{\"type\":\"A\",\"name\":\"$D\",\"content\":\"$IP\",\"ttl\":1}")
        if echo "$RESP" | python3 -c "import sys,json;exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null; then
            MSG="${MSG}${D} → ${IP}\n"
        else
            MSG="${MSG}${D} 更新失败\n"
        fi
        N=$((N+1))
    done < "$TMP"
    rm -f "$TMP"
    log "=== 完成 ==="
    [ -n "$MSG" ] && tg "$(echo -e "$MSG")"
}

# ── 主流程 ──
mkdir -p "$WD"
fetch_cfst
fetch_iplist "$IPLIST" "ip.txt"
[ "$CF_IPV" = "6" ] && fetch_iplist "$IPLIST6" "ipv6.txt"
run_speedtest
update_dns
exit 0
