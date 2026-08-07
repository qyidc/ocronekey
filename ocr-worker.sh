#!/bin/bash
# ─── PaddleOCR 异步任务轮询脚本 ────────────────────────
# 运行方式: nohup bash ocr-worker.sh > ocr-worker.log 2>&1 &
# 或注册为 systemd 服务

set -euo pipefail

# ─── 配置 ──────────────────────────────────────────────
BASE_URL="https://doc.otwx.top"
WORKER_SECRET="ocr-worker-secret-change-me"   # 必须与 Worker 端一致
PADDLE_URL="http://localhost:9899"
TEMP_DIR="/tmp/ocr-worker"
LOG_PREFIX="[OCR-Worker]"

mkdir -p "$TEMP_DIR"

# ─── 主循环 ────────────────────────────────────────────

echo "$LOG_PREFIX 启动，轮询 $BASE_URL/api/ocr-tasks/next"

while true; do
  # 1. 拉取下一个待处理任务
  TASK_JSON=$(curl -sf -H "X-Worker-Secret: $WORKER_SECRET" \
    "$BASE_URL/api/ocr-tasks/next" 2>/dev/null) || {
    echo "$LOG_PREFIX 网络异常，5s 后重试..."
    sleep 5
    continue
  }

  TASK_ID=$(echo "$TASK_JSON" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
  
  if [ -z "$TASK_ID" ]; then
    # 无任务，等待
    sleep 3
    continue
  fi

  R2_KEY=$(echo "$TASK_JSON" | grep -o '"r2Key":"[^"]*"' | cut -d'"' -f4)
  DOC_ID=$(echo "$TASK_JSON" | grep -o '"documentId":[0-9]*' | head -1 | grep -o '[0-9]*')
  PAGE_NUM=$(echo "$TASK_JSON" | grep -o '"pageNum":[0-9]*' | head -1 | grep -o '[0-9]*')

  echo "$LOG_PREFIX 处理: task=$TASK_ID doc=$DOC_ID page=$PAGE_NUM"

  IMG_FILE="$TEMP_DIR/task_${TASK_ID}.jpg"

  # 2. 下载图片
  if ! curl -sf -H "X-Worker-Secret: $WORKER_SECRET" \
    "$BASE_URL/api/ocr-tasks/$TASK_ID/image" -o "$IMG_FILE" 2>/dev/null; then
    echo "$LOG_PREFIX 下载图片失败: task=$TASK_ID"
    curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
      -H "Content-Type: application/json" \
      -d "{\"error\":\"下载图片失败\"}" \
      "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
    rm -f "$IMG_FILE"
    continue
  fi

  # 3. 本地 OCR 识别
  BASE64_IMG=$(base64 -w 0 "$IMG_FILE" 2>/dev/null)
  rm -f "$IMG_FILE"

  if [ -z "$BASE64_IMG" ]; then
    echo "$LOG_PREFIX base64 编码失败: task=$TASK_ID"
    curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
      -H "Content-Type: application/json" \
      -d "{\"error\":\"base64 编码失败\"}" \
      "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
    continue
  fi

  OCR_RESP=$(curl -sf -X POST "$PADDLE_URL/general/base64" \
    -H "Content-Type: application/json" \
    -d "{\"base64_img\":\"$BASE64_IMG\"}" 2>/dev/null) || {
    echo "$LOG_PREFIX PaddleOCR 调用失败: task=$TASK_ID"
    curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
      -H "Content-Type: application/json" \
      -d "{\"error\":\"PaddleOCR 服务不可用\"}" \
      "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
    continue
  }

  # 4. 提取识别文本
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
    # 转义 JSON 特殊字符
    ESCAPED_TEXT=$(echo "$OCR_TEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
    curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
      -H "Content-Type: application/json" \
      -d "{\"text\":$ESCAPED_TEXT,\"chars\":${#OCR_TEXT}}" \
      "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
    echo "$LOG_PREFIX 完成: task=$TASK_ID, chars=${#OCR_TEXT}"
  else
    curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
      -H "Content-Type: application/json" \
      -d "{\"error\":\"无识别结果\"}" \
      "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
    echo "$LOG_PREFIX 无文字: task=$TASK_ID"
  fi

done
