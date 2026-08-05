#!/bin/bash
# =====================================================
# OCR 服务修复脚本 v2 — 应对 1C1G VPS OCR 挂死问题
# 用法: bash deploy_fix.sh
# =====================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}[1/3] 重建 Docker 容器...${NC}"

docker stop media-saber-paddle-ocr 2>/dev/null || true
docker rm media-saber-paddle-ocr 2>/dev/null || true

docker run -d \
    --name media-saber-paddle-ocr \
    --restart unless-stopped \
    --cpus="0.8" \
    --memory="768m" \
    --memory-swap="768m" \
    --health-cmd="curl -f -m 5 http://localhost:9899/health || exit 1" \
    --health-interval=10s \
    --health-retries=1 \
    --health-timeout=5s \
    -p 127.0.0.1:9899:9899 \
    xylplm/media-saber-paddle-ocr:latest

echo -e "${GREEN}  容器已重建。${NC}"

echo -e "${YELLOW}[2/3] 添加 max_conns=1 (一次只处理一张图)...${NC}"

SITE_CONF=$(ls /etc/nginx/sites-available/ocr-*.conf 2>/dev/null || ls /etc/nginx/conf.d/ocr-*.conf 2>/dev/null)

if [ -z "$SITE_CONF" ]; then
    echo -e "${YELLOW}  未找到 OCR 站点配置，跳过。${NC}"
    exit 0
fi

# 如果不存在 upstream 块，在第一个 server 之前插入
if ! grep -q "upstream ocr_backend" "$SITE_CONF"; then
    sed -i '/^server {/i\
# 串行化后端请求 — 1C1G VPS 一次只处理一张图\
upstream ocr_backend {\
    server 127.0.0.1:9899 max_conns=1;\
}\
' "$SITE_CONF"
fi

# 替换所有 proxy_pass 为使用 upstream
sed -i 's|proxy_pass http://127.0.0.1:9899/health;|proxy_pass http://ocr_backend/health;|g' "$SITE_CONF"
sed -i 's|proxy_pass http://127.0.0.1:9899;|proxy_pass http://ocr_backend;|g' "$SITE_CONF"

echo -e "${YELLOW}[3/3] 修复 proxy 超时配置...${NC}"
sed -i '/proxy_connect_timeout/d' "$SITE_CONF"
sed -i '/proxy_next_upstream/d' "$SITE_CONF"
sed -i '/proxy_next_upstream_tries/d' "$SITE_CONF"

if grep -q "proxy_read_timeout" "$SITE_CONF"; then
    sed -i 's/proxy_read_timeout .*/proxy_read_timeout 0;/' "$SITE_CONF"
else
    sed -i '/proxy_pass http:\/\/ocr_backend;/a\        proxy_read_timeout 0;' "$SITE_CONF"
fi

if grep -q "proxy_send_timeout" "$SITE_CONF"; then
    sed -i 's/proxy_send_timeout .*/proxy_send_timeout 0;/' "$SITE_CONF"
else
    sed -i '/proxy_read_timeout 0/a\        proxy_send_timeout 0;' "$SITE_CONF"
fi

nginx -t && systemctl reload nginx

echo -e "${GREEN}  配置已更新并重载。${NC}"
echo ""
echo -e "${GREEN}修复完成！${NC}"
