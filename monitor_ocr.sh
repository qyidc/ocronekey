#!/bin/bash
# =====================================================
# OCR 服务错误监控脚本
# 用法: bash monitor_ocr.sh              单次检测
#       bash monitor_ocr.sh --daemon     后台持续监控
#       bash monitor_ocr.sh --domain ocr1.otwx.top --daemon
# 日志: /var/log/ocr_monitor/
# =====================================================

NGINX_ERR_LOG="/var/log/nginx/error.log"
NGINX_ACC_LOG="/var/log/nginx/access.log"
OCR_LOG_DIR="/var/log/ocr_monitor"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$OCR_LOG_DIR"

URL="https://localhost/health"

# ---------- 解析参数 ----------
for arg in "$@"; do
    case "$arg" in
        --domain) ;;  # 后面会读下一个
        --daemon) DAEMON=1 ;;
        -*) ;;
        *) DOMAIN="$arg" ;;
    esac
done

if [ -n "${DOMAIN:-}" ]; then
    URL="https://${DOMAIN}/health"
else
    # 自动从 Nginx 配置提取域名
    CONF=$(ls /etc/nginx/sites-available/ocr-*.conf 2>/dev/null | head -1)
    [ -z "$CONF" ] && CONF=$(ls /etc/nginx/conf.d/ocr-*.conf 2>/dev/null | head -1)
    if [ -n "$CONF" ]; then
        D=$(grep -o 'server_name [^;]*' "$CONF" 2>/dev/null | head -1 | sed 's/server_name //;s/ //g')
        [ -n "$D" ] && URL="https://${D}/health"
    fi
fi

echo -e "${GREEN}检测地址: $URL${NC}"

# ---------- 一次检测 ----------
do_check() {
    local status curl_code

    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL" 2>/dev/null || echo "000")
    curl_code=$?

    if [ "$status" = "503" ] || [ "$status" = "504" ] || [ "$status" = "000" ] || [ "$curl_code" = "28" ]; then
        local ts file
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        file="$OCR_LOG_DIR/snapshot_$(date +%Y%m%d_%H%M%S).log"

        (
            echo "========================================"
            echo "  异常检测 — $ts"
            echo "  请求地址: $URL"
            echo "  HTTP 状态码: $status (curl exit: $curl_code)"
            echo "========================================"
            echo ""
            echo ">>> [1/5] Nginx 错误日志 (最近30行)"
            echo "----------------------------------------"
            tail -30 "$NGINX_ERR_LOG" 2>/dev/null || echo "(无法读取)"
            echo ""
            echo ">>> [2/5] Nginx Access 日志 (最近20行)"
            echo "----------------------------------------"
            tail -20 "$NGINX_ACC_LOG" 2>/dev/null || echo "(无法读取)"
            echo ""
            echo ">>> [3/5] 容器状态"
            echo "----------------------------------------"
            docker ps -a --filter "name=media-saber-paddle-ocr" 2>/dev/null || echo "(容器未运行)"
            echo ""
            echo ">>> [4/5] 容器资源 + 容器日志"
            echo "----------------------------------------"
            docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null || echo "(无法获取)"
            echo ""
            echo "--- 容器日志 (最后30行) ---"
            docker logs --tail 30 media-saber-paddle-ocr 2>/dev/null || echo "(无)"
            echo ""
            echo ">>> [5/5] 系统资源"
            echo "----------------------------------------"
            free -h; echo; uptime; echo; df -h / | tail -1
        ) > "$file"

        echo -e "${RED}[$ts] 检测到 $status 错误！快照: $file${NC}"

        # 只保留最近 50 个
        ls -1t "$OCR_LOG_DIR"/snapshot_*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null
        return 1
    fi
    echo -e "${GREEN}[$(date '+%H:%M:%S')] 正常 ($status)${NC}"
    return 0
}

# ---------- 入口 ----------
if [ "${DAEMON:-0}" = "1" ]; then
    echo -e "${GREEN}持续监控已启动 (每30秒) — Ctrl+C 停止${NC}"
    echo ""
    while true; do
        do_check || true
        sleep 30
    done
else
    do_check || true
fi
