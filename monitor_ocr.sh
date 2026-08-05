#!/bin/bash
# =====================================================
# OCR 服务错误监控脚本 v2
# 方案: 记录 access.log 已读行号，只检查新增行中的 503/504
# 用法: bash monitor_ocr.sh              单次扫描
#       bash monitor_ocr.sh --daemon     后台持续监控，每15秒
# 日志: /var/log/ocr_monitor/
# =====================================================

NGINX_ERR_LOG="/var/log/nginx/error.log"
NGINX_ACC_LOG="/var/log/nginx/access.log"
OCR_LOG_DIR="/var/log/ocr_monitor"
LAST_POS="$OCR_LOG_DIR/.acc_pos"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$OCR_LOG_DIR"

# ---------- 扫描 access.log 新增行 + error.log 尾部 ----------
scan_errors() {
    local cur last hits errs found
    found=0

    # ---- access.log: 增量扫描 ----
    cur=$(wc -l < "$NGINX_ACC_LOG" 2>/dev/null || echo 0)
    last=$(cat "$LAST_POS" 2>/dev/null || echo 0)
    # 如果日志被轮转（cur < last），重置
    [ "$cur" -lt "$last" ] && last=0

    if [ "$cur" -gt "$last" ]; then
        hits=$(tail -n +"$((last + 1))" "$NGINX_ACC_LOG" 2>/dev/null | grep -E '" (503|504) ')
        [ -n "$hits" ] && found=1
    else
        hits=""
    fi
    echo "$cur" > "$LAST_POS"

    # ---- error.log: 尾部扫描 upstream timeout / refused ----
    errs=$(tail -200 "$NGINX_ERR_LOG" 2>/dev/null | grep -E 'upstream.*timed out|connect.*refused|no live upstreams' || true)
    [ -n "$errs" ] && found=1

    # ---- 容器是否活着 ----
    if ! docker ps -q --filter "name=media-saber-paddle-ocr" 2>/dev/null | grep -q .; then
        found=1
    fi

    if [ "$found" = "1" ]; then
        local ts file
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        file="$OCR_LOG_DIR/snapshot_$(date +%Y%m%d_%H%M%S).log"

        {
            echo "========================================"
            echo "  异常检测 — $ts"
            echo "========================================"
            echo ""
            echo ">>> Access 日志 — 新增 503/504 请求"
            echo "----------------------------------------"
            if [ -n "$hits" ]; then
                echo "$hits"
            else
                echo "(无新增 503/504)"
            fi
            echo ""
            echo ">>> Error 日志 — upstream timed out / refused"
            echo "----------------------------------------"
            if [ -n "$errs" ]; then
                echo "$errs"
            else
                echo "(无)"
            fi
            echo ""
            echo ">>> 容器状态"
            echo "----------------------------------------"
            docker ps -a --filter "name=media-saber-paddle-ocr" 2>/dev/null
            echo ""
            echo ">>> 容器资源"
            echo "----------------------------------------"
            docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null || echo "(无法获取)"
            echo ""
            echo ">>> 容器日志 (最后40行)"
            echo "----------------------------------------"
            docker logs --tail 40 media-saber-paddle-ocr 2>/dev/null || echo "(无)"
            echo ""
            echo ">>> 系统资源"
            echo "----------------------------------------"
            free -h; echo; uptime; echo; df -h / | tail -1
        } > "$file"

        echo -e "${RED}[$ts] 发现异常！快照: $file${NC}"
        [ -n "$hits" ] && echo -e "${CYAN}  503/504 数量: $(echo "$hits" | grep -c .)${NC}"

        # 保留最近 50 个
        ls -1t "$OCR_LOG_DIR"/snapshot_*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null
        return 1
    fi
    return 0
}

# ---------- 入口 ----------
if [ "${1:-}" = "--daemon" ]; then
    echo -e "${GREEN}持续监控已启动 (每15秒扫描 Nginx 日志)${NC}"
    echo -e "${CYAN}日志目录: $OCR_LOG_DIR${NC}"
    echo "Ctrl+C 停止"
    echo ""
    while true; do
        scan_errors || true
        sleep 15
    done
else
    scan_errors || true
fi
