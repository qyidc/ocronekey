#!/bin/bash
# =====================================================
# OCR 服务错误监控脚本 v2
# 方案: 记录日志已读行号，只检查增量
# 用法: bash monitor_ocr.sh                单次扫描(从上次位置)
#       bash monitor_ocr.sh --reset        重置位置,从头扫描
#       bash monitor_ocr.sh --daemon       后台持续监控，每15秒
# 日志: /var/log/ocr_monitor/
# =====================================================

NGINX_ERR_LOG="/var/log/nginx/error.log"
NGINX_ACC_LOG="/var/log/nginx/access.log"
OCR_LOG_DIR="/var/log/ocr_monitor"
ACC_POS="$OCR_LOG_DIR/.acc_pos"
ERR_POS="$OCR_LOG_DIR/.err_pos"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$OCR_LOG_DIR"

scan_errors() {
    local cur_acc last_acc cur_err last_err hits errs found
    found=0

    # ---- access.log: 增量扫描 503/504 ----
    cur_acc=$(wc -l < "$NGINX_ACC_LOG" 2>/dev/null || echo 0)
    last_acc=$(cat "$ACC_POS" 2>/dev/null || echo 0)
    [ "$cur_acc" -lt "$last_acc" ] && last_acc=0

    if [ "$cur_acc" -gt "$last_acc" ]; then
        hits=$(tail -n +"$((last_acc + 1))" "$NGINX_ACC_LOG" 2>/dev/null | grep -E '" (503|504) ')
        [ -n "$hits" ] && found=1
    else
        hits=""
    fi
    echo "$cur_acc" > "$ACC_POS"

    # ---- error.log: 增量扫描 upstream timed out / refused ----
    cur_err=$(wc -l < "$NGINX_ERR_LOG" 2>/dev/null || echo 0)
    last_err=$(cat "$ERR_POS" 2>/dev/null || echo 0)
    [ "$cur_err" -lt "$last_err" ] && last_err=0

    if [ "$cur_err" -gt "$last_err" ]; then
        errs=$(tail -n +"$((last_err + 1))" "$NGINX_ERR_LOG" 2>/dev/null | grep -E 'upstream.*timed out|connect.*refused|no live upstreams' || true)
        [ -n "$errs" ] && found=1
    else
        errs=""
    fi
    echo "$cur_err" > "$ERR_POS"

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
            echo ">>> Access 日志 — 新增 503/504"
            echo "----------------------------------------"
            if [ -n "$hits" ]; then
                echo "$hits"
            else
                echo "(无新增)"
            fi
            echo ""
            echo ">>> Error 日志 — 新增 upstream timeout/refused"
            echo "----------------------------------------"
            if [ -n "$errs" ]; then
                echo "$errs"
            else
                echo "(无新增)"
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
        [ -n "$hits" ] && echo -e "${CYAN}  access.log 503/504: $(echo "$hits" | wc -l) 行${NC}"
        [ -n "$errs" ] && echo -e "${CYAN}  error.log upstream: $(echo "$errs" | wc -l) 行${NC}"

        ls -1t "$OCR_LOG_DIR"/snapshot_*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null
        return 1
    fi
    return 0
}

# ---------- 入口 ----------
case "${1:-}" in
    --reset)
        rm -f "$ACC_POS" "$ERR_POS"
        echo -e "${GREEN}位置已重置。${NC}"
        echo -e "${YELLOW}扫描中...${NC}"
        scan_errors || true
        ;;
    --daemon)
        echo -e "${GREEN}持续监控已启动 (每15秒扫描增量日志)${NC}"
        echo -e "${CYAN}日志目录: $OCR_LOG_DIR${NC}"
        echo "Ctrl+C 停止"
        echo ""
        while true; do
            scan_errors || true
            sleep 15
        done
        ;;
    *)
        echo -e "${YELLOW}增量扫描中...${NC}"
        if scan_errors; then
            echo -e "${GREEN}最近无新增异常。${NC}"
            echo "  提示: 首次运行用 --reset 从当前日志末尾开始追踪"
        fi
        ;;
esac
