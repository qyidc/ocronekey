#!/bin/bash
# =====================================================
# OCR 服务错误监控脚本
# 用途: 检测 503/504 时自动记录 Nginx日志 + Docker资源
# 用法: bash monitor_ocr.sh                         (一次性检测)
#       bash monitor_ocr.sh --domain ocr1.otwx.top   (指定域名)
#       bash monitor_ocr.sh --daemon                  (后台持续监控，每30秒)
# 日志: /var/log/ocr_monitor/
# =====================================================

set -euo pipefail

NGINX_ERR_LOG="/var/log/nginx/error.log"
NGINX_ACC_LOG="/var/log/nginx/access.log"
OCR_LOG_DIR="/var/log/ocr_monitor"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$OCR_LOG_DIR"

# 自动检测域名
detect_domain() {
    local conf
    conf=$(ls /etc/nginx/sites-available/ocr-*.conf 2>/dev/null | head -1)
    [ -z "$conf" ] && conf=$(ls /etc/nginx/conf.d/ocr-*.conf 2>/dev/null | head -1)
    if [ -n "$conf" ]; then
        grep -oP 'server_name\s+\K[^;]+' "$conf" | head -1 | tr -d ' '
    else
        echo ""
    fi
}

DOMAIN="${2:-$(detect_domain)}"

check_and_snapshot() {
    local url
    if [ -n "$DOMAIN" ]; then
        url="https://${DOMAIN}/health"
    else
        url="https://localhost/health"
    fi

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$url" 2>/dev/null || echo "000")
    local curl_code=$?

    # 检测异常：503/504/000(连接失败)/curl 超时(28)
    if [ "$status" = "503" ] || [ "$status" = "504" ] || [ "$status" = "000" ] || [ "$curl_code" = "28" ]; then
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        local file="$OCR_LOG_DIR/snapshot_$(date +%Y%m%d_%H%M%S).log"

        {
            echo "========================================"
            echo "  异常检测 — $ts"
            echo "  请求地址: $url"
            echo "  HTTP 状态码: $status (curl exit: $curl_code)"
            echo "========================================"
            echo ""

            echo ">>> [1/5] Nginx 最近 30 行错误日志"
            echo "----------------------------------------"
            tail -30 "$NGINX_ERR_LOG" 2>/dev/null || echo "(无法读取)"
            echo ""

            echo ">>> [2/5] Nginx Access 日志 — 最近 20 行"
            echo "----------------------------------------"
            tail -20 "$NGINX_ACC_LOG" 2>/dev/null || echo "(无法读取)"
            echo ""

            echo ">>> [3/5] Docker 容器状态"
            echo "----------------------------------------"
            docker ps -a --filter "name=media-saber-paddle-ocr" 2>/dev/null || echo "(容器未运行)"
            echo ""

            echo ">>> [4/5] Docker 容器资源占用"
            echo "----------------------------------------"
            docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null || echo "(无法获取 docker stats)"
            echo ""

            echo "--- 容器最近日志 (最后 30 行) ---"
            docker logs --tail 30 media-saber-paddle-ocr 2>/dev/null || echo "(无法获取容器日志)"
            echo ""

            echo ">>> [5/5] 系统资源快照"
            echo "----------------------------------------"
            echo "--- 内存 ---"
            free -h
            echo ""
            echo "--- CPU 负载 ---"
            uptime
            echo ""
            echo "--- 磁盘 ---"
            df -h / | tail -1

        } > "$file"

        echo -e "${RED}[$ts] 检测到 $status 错误！快照已保存: $file${NC}"

        # 保留最近 50 个快照
        local count
        count=$(ls -1 "$OCR_LOG_DIR"/snapshot_*.log 2>/dev/null | wc -l)
        if [ "$count" -gt 50 ]; then
            ls -1t "$OCR_LOG_DIR"/snapshot_*.log | tail -n +51 | xargs rm -f
        fi

        return 1
    fi
    return 0
}

# ---------- 参数解析 ----------
case "${1:-}" in
    --daemon)
        echo -e "${GREEN}OCR 监控已启动 (每30秒检测 $([ -n "$DOMAIN" ] && echo "$DOMAIN" || echo "localhost"), 日志: $OCR_LOG_DIR)${NC}"
        echo "按 Ctrl+C 停止"
        while true; do
            check_and_snapshot || true
            sleep 30
        done
        ;;
    --domain)
        # --domain ocr1.otwx.top 只设置域名并单次检测
        echo -e "${YELLOW}单次检测中 ($DOMAIN)...${NC}"
        if check_and_snapshot; then
            echo -e "${GREEN}服务正常 (HTTP 200)${NC}"
        fi
        ;;
    *)
        echo -e "${YELLOW}单次检测中 ($([ -n "$DOMAIN" ] && echo "$DOMAIN" || echo "localhost"))...${NC}"
        if check_and_snapshot; then
            echo -e "${GREEN}服务正常 (HTTP 200)${NC}"
        fi
        ;;
esac
