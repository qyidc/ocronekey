#!/bin/bash
# =====================================================
# OCR 服务错误监控脚本
# 用途: 检测 503/504 时自动记录 Nginx日志 + Docker资源
# 用法: bash monitor_ocr.sh           (一次性检测)
#       bash monitor_ocr.sh --daemon   (后台持续监控，每隔30秒)
# 日志: /var/log/ocr_monitor/
# =====================================================

set -euo pipefail

NGINX_ERR_LOG="/var/log/nginx/error.log"
OCR_LOG_DIR="/var/log/ocr_monitor"
SNAPSHOT_FILE="$OCR_LOG_DIR/snapshot_$(date +%Y%m%d_%H%M%S).log"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

mkdir -p "$OCR_LOG_DIR"

check_and_snapshot() {
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://localhost/health 2>/dev/null || echo "000")

    if [ "$status" = "503" ] || [ "$status" = "504" ] || [ "$status" = "000" ]; then
        local ts
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        local file="$OCR_LOG_DIR/snapshot_$(date +%Y%m%d_%H%M%S).log"

        {
            echo "========================================"
            echo "  异常检测 — $ts"
            echo "  HTTP 状态码: $status"
            echo "========================================"
            echo ""

            echo ">>> [1/4] Nginx 最近 20 行错误日志"
            echo "----------------------------------------"
            tail -20 "$NGINX_ERR_LOG" 2>/dev/null || echo "(无法读取)"
            echo ""

            echo ">>> [2/4] Docker 容器状态"
            echo "----------------------------------------"
            docker ps --filter "name=media-saber-paddle-ocr" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(容器未运行)"
            echo ""

            echo ">>> [3/4] Docker 容器资源占用 (docker stats --no-stream)"
            echo "----------------------------------------"
            docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}" 2>/dev/null || echo "(无法获取)"
            echo ""

            echo ">>> [4/4] 系统资源快照"
            echo "----------------------------------------"
            echo "--- 内存 ---"
            free -h
            echo ""
            echo "--- CPU 负载 ---"
            uptime
            echo ""
            echo "--- 磁盘 ---"
            df -h / | tail -1
            echo ""

        } > "$file"

        echo -e "${RED}[$ts] 检测到 $status 错误！快照已保存: $file${NC}"

        # 保留最近 50 个快照，删除旧的
        local count
        count=$(ls -1 "$OCR_LOG_DIR"/snapshot_*.log 2>/dev/null | wc -l)
        if [ "$count" -gt 50 ]; then
            ls -1t "$OCR_LOG_DIR"/snapshot_*.log | tail -n +51 | xargs rm -f
        fi

        return 1
    fi
    return 0
}

if [ "${1:-}" = "--daemon" ]; then
    echo -e "${GREEN}OCR 监控已启动 (每30秒检测一次，日志: $OCR_LOG_DIR)${NC}"
    echo "按 Ctrl+C 停止"
    while true; do
        check_and_snapshot || true
        sleep 30
    done
else
    echo -e "${YELLOW}单次检测中...${NC}"
    if check_and_snapshot; then
        echo -e "${GREEN}服务正常 (HTTP 200)${NC}"
    fi
fi
