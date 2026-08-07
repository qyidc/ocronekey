#!/bin/bash
# ─── PaddleOCR 异步任务处理脚本 v4.0 ──────────────────
# 事件驱动模式: Worker 触发 → 批量处理 → 休眠
# VPS 通过 ocronkey.sh 安装后自动部署，本文件为参考
#
# 架构:
#   Worker ──POST /worker/wake──▶ VPS (Nginx → 127.0.0.1:9898)
#   VPS   ←──GET  /api/ocr-tasks/next── Worker
#   VPS   ←──GET  /api/ocr-tasks/{id}/image── Worker (R2)
#   VPS   ──POST /api/ocr-tasks/{id}/result──▶ Worker

set -uo pipefail

# ─── 配置 ──────────────────────────────────────────────
BASE_URL="https://doc.otwx.top"
WORKER_SECRET="ocr-worker-secret-change-me"   # 必须与 Worker 端一致
PADDLE_URL="http://localhost:9899"
TEMP_DIR="/tmp/ocr-worker"
LOG_FILE="/var/log/ocr_worker.log"

mkdir -p "$TEMP_DIR"
exec >>"$LOG_FILE" 2>&1

echolog() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

IMG_DIR="$TEMP_DIR/images"
mkdir -p "$IMG_DIR"

# ─── 批量处理所有待处理任务 ─────────────────────────
process_batch() {
    local count=0

    while true; do
        TASK_JSON=$(curl -sf -H "X-Worker-Secret: $WORKER_SECRET" \
            "$BASE_URL/api/ocr-tasks/next" 2>/dev/null) || {
            echolog "WARN: 网络异常, 暂停本轮"
            break
        }

        TASK_ID=$(echo "$TASK_JSON" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
        [ -z "$TASK_ID" ] && break

        count=$((count + 1))
        DOC_ID=$(echo "$TASK_JSON" | grep -o '"documentId":[0-9]*' | head -1 | grep -o '[0-9]*')
        PAGE_NUM=$(echo "$TASK_JSON" | grep -o '"pageNum":[0-9]*' | head -1 | grep -o '[0-9]*')

        echolog "处理: task=$TASK_ID doc=$DOC_ID page=$PAGE_NUM"

        IMG_FILE="$IMG_DIR/task_${TASK_ID}.jpg"

        # 下载图片
        if ! curl -sf -H "X-Worker-Secret: $WORKER_SECRET" \
            "$BASE_URL/api/ocr-tasks/$TASK_ID/image" -o "$IMG_FILE" 2>/dev/null; then
            echolog "  ERROR: 下载失败"
            curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
                -H "Content-Type: application/json" \
                -d '{"error":"下载图片失败"}' \
                "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
            rm -f "$IMG_FILE"
            continue
        fi

        # 本地 OCR (base64)
        BASE64_IMG=$(base64 -w 0 "$IMG_FILE" 2>/dev/null)
        rm -f "$IMG_FILE"

        if [ -z "$BASE64_IMG" ]; then
            curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
                -d '{"error":"编码失败"}' \
                "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
            continue
        fi

        OCR_RESP=$(curl -sf -X POST "$PADDLE_URL/general/base64" \
            -H "Content-Type: application/json" \
            -d "{\"base64_img\":\"$BASE64_IMG\"}" 2>/dev/null) || {
            curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
                -d '{"error":"PaddleOCR 服务不可用"}' \
                "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
            continue
        }

        OCR_TEXT=$(echo "$OCR_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    texts = []
    for r in data.get('results', []):
        texts.extend(r.get('rec_texts', []))
    print('\n'.join(texts))
except: pass
" 2>/dev/null)

        if [ -n "$OCR_TEXT" ]; then
            ESCAPED=$(echo "$OCR_TEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
            curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
                -H "Content-Type: application/json" \
                -d "{\"text\":$ESCAPED,\"chars\":${#OCR_TEXT}}" \
                "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
            echolog "  完成: task=$TASK_ID, chars=${#OCR_TEXT}"
        else
            curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
                -d '{"error":"empty_page","text":""}' \
                "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
            echolog "  空白页: task=$TASK_ID"
        fi
    done

    echolog "本轮完成: ${count} 个任务"
}

# ─── 主循环: 事件驱动 ────────────────────────────────
echolog "=== OCR Worker v4.0 启动 (事件驱动模式) ==="
echolog "Worker: $BASE_URL"

# 启动时先处理积压
echolog "检查积压任务..."
process_batch

while true; do
    echolog "休眠中，等待 Worker 触发..."
    socat TCP-LISTEN:9898,bind=127.0.0.1,reuseaddr \
        EXEC:'printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"' 2>/dev/null || true
    echolog "=== 收到触发信号 ==="
    process_batch
done
