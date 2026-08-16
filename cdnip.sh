#!/bin/bash
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
: ${CF_THREADS:="100"} ${CF_DN_COUNT:="10"} ${CF_DN_TIME:="10"} ${CF_TL:="300"}
: ${CF_IPV:="4"}
: ${CF_SPEED_URL:="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"}
: ${CF_TG_TOKEN:=""} ${CF_TG_ID:=""}

# ── 日志（带轮转）/ TG ──
log() {
    echo "$(date '+%m-%d %H:%M:%S') $1" | tee -a "$LOG"
    local n; n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    [ "$n" -gt 1000 ] && { tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
}
tg() {
    [ -z "$CF_TG_TOKEN" ] || [ -z "$CF_TG_ID" ] || [ -z "$1" ] && return
    curl -sm8 -X POST "https://api.telegram.org/bot${CF_TG_TOKEN}/sendMessage" \
        -d "chat_id=${CF_TG_ID}" --data-urlencode "text=$1" >/dev/null 2>&1
}

# ── JSON 解析工具（jq 优先，python3 次之）──
JSON_TOOL=""
detect_json() {
    command -v jq >/dev/null 2>&1 && { JSON_TOOL="jq"; return 0; }
    command -v python3 >/dev/null 2>&1 && { JSON_TOOL="python3"; return 0; }
    return 1
}

# ── 下载 cfst（多架构，多源）──
fetch_cfst() {
    [ -x "$CFST" ] && return
    log "下载 cfst 测速器..."
    case $(uname -m) in
        aarch64|arm64)        A=arm64 ;;
        armv7l|armv7)         A=armv7 ;;
        armv6l|armv6)         A=armv6 ;;
        armv5l|armv5)         A=armv5 ;;
        x86_64|amd64)         A=amd64 ;;
        i386|i486|i586|i686)  A=386 ;;
        mips64)               A=mips64 ;;
        mips64el)             A=mips64le ;;
        mipsel)               A=mipsle ;;
        mips)                 A=mips ;;
        *) log "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    local T="/tmp/cfst.tgz" ok=0
    for u in \
        "https://ghproxy.net/https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${A}.tar.gz" \
        "https://mirror.ghproxy.com/https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${A}.tar.gz" \
        "https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${A}.tar.gz" ; do
        curl -fsSLm 60 "$u" -o "$T" && [ -s "$T" ] && gzip -t "$T" 2>/dev/null && { ok=1; break; }
    done
    [ "$ok" = "1" ] || { log "cfst 下载失败"; exit 1; }
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
    local TARGET="$1" SRC="$2" ok=0
    log "下载 IP 列表 $SRC..."
    for u in \
        "https://ghproxy.net/https://raw.githubusercontent.com/jane2003/cfip/master/$SRC" \
        "https://mirror.ghproxy.com/https://raw.githubusercontent.com/jane2003/cfip/master/$SRC" \
        "https://raw.githubusercontent.com/jane2003/cfip/master/$SRC" ; do
        curl -fsSLm 30 "$u" -o "$TARGET" && [ -s "$TARGET" ] && { ok=1; break; }
    done
    [ "$ok" = "1" ] || { log "IP 列表下载失败: $SRC"; exit 1; }
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

# ── 取 DNS 记录 id（jq/python3，只取第一条）──
get_rid() {
    local records="$1" name="$2"
    [ -z "$records" ] && { echo ""; return 0; }
    if [ "$JSON_TOOL" = "jq" ]; then
        echo "$records" | jq -r --arg n "$name" '.result[]? | select(.name==$n) | .id' 2>/dev/null | head -1
    else
        echo "$records" | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((r['id'] for r in d.get('result',[]) if r['name']=='$name'),''))" 2>/dev/null
    fi
}

# ── 判断 CF API 响应 success ──
check_ok() {
    local resp="$1"
    if [ "$JSON_TOOL" = "jq" ]; then
        echo "$resp" | jq -e '.success == true' >/dev/null 2>&1
    else
        echo "$resp" | python3 -c "import sys,json;exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null
    fi
}

# ── CF API 更新 DNS ──
update_dns() {
    [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ] || [ -z "$CF_ZONE" ] && {
        log "未配置 CF 凭据，跳过 DNS 更新（先编辑 $CFG）"; return; }
    detect_json || { log "缺少 jq/python3，无法解析 DNS 记录，请安装其一"; return 1; }
    local TYPE="A"
    [ "$CF_IPV" = "6" ] && TYPE="AAAA"
    log "拉取现有 ${TYPE} 记录..."
    local RECORDS MSG=""
    RECORDS=$(curl -fsSm10 -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=${TYPE}&per_page=100") || {
        log "拉取 DNS 记录失败（CF API 不可达？检查 hosts 或凭据）"; return 1; }

    local TMP="/tmp/cf_loop.txt"
    tail -n +2 "$RESULT" > "$TMP"
    local N=1 IP D RID RESP
    # 子域名指针 N 与 IP 指针解耦：子域名缺失只换子域名，不浪费最快 IP
    exec 3< "$TMP"
    N=1
    while [ "$N" -le "$CF_COUNT" ]; do
        D="${N}.${CF_DOMAIN}"
        RID=$(get_rid "$RECORDS" "$D")
        if [ -z "$RID" ]; then
            N=$((N+1)); continue
        fi
        IP=""
        while [ -z "$IP" ] && IFS=',' read -r IP _ <&3; do :; done
        [ -n "$IP" ] || break
        log "更新 $D → $IP"
        RESP=$(curl -fsSm10 -X PATCH \
            -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records/$RID" \
            -d "{\"type\":\"$TYPE\",\"name\":\"$D\",\"content\":\"$IP\",\"ttl\":1}") || {
            MSG="${MSG}${D} 更新失败（API 错误）\n"; N=$((N+1)); continue; }
        if check_ok "$RESP"; then
            MSG="${MSG}${D} → ${IP}\n"
        else
            MSG="${MSG}${D} 更新失败\n"
        fi
        N=$((N+1))
    done
    exec 3<&-
    rm -f "$TMP"
    log "=== 完成 ==="
    [ -n "$MSG" ] && tg "$(printf '%b' "$MSG")"
}

# ── 主流程 ──
mkdir -p "$WD"
fetch_cfst
fetch_iplist "$IPLIST" "ip.txt"
[ "$CF_IPV" = "6" ] && fetch_iplist "$IPLIST6" "ipv6.txt"
run_speedtest
update_dns
exit 0
