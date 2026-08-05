#!/bin/bash
# =====================================================
# OCR 服务修复脚本 — 应对 1C1G VPS 连续识别问题
# 用法: bash deploy_fix.sh
# =====================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}[1/2] 重建 Docker 容器 (CPU<=80%/内存<=768MB)...${NC}"

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

echo -e "${YELLOW}[2/2] 更新 Nginx 代理超时 (设为0=永不超时)...${NC}"

SITE_CONF=$(ls /etc/nginx/sites-available/ocr-*.conf 2>/dev/null || ls /etc/nginx/conf.d/ocr-*.conf 2>/dev/null)

if [ -z "$SITE_CONF" ]; then
    echo -e "${YELLOW}  未找到 OCR 站点配置文件，跳过 Nginx 修复。${NC}"
    exit 0
fi

# 移除旧的 timeout 和 next_upstream 配置
sed -i '/proxy_connect_timeout/d' "$SITE_CONF"
sed -i '/proxy_next_upstream/d' "$SITE_CONF"
sed -i '/proxy_next_upstream_tries/d' "$SITE_CONF"

# 替换或添加 proxy_read_timeout 0 / proxy_send_timeout 0
if grep -q "proxy_read_timeout" "$SITE_CONF"; then
    sed -i 's/proxy_read_timeout .*/proxy_read_timeout 0;/' "$SITE_CONF"
else
    sed -i '/proxy_pass http:\/\/127.0.0.1:9899/a\        proxy_read_timeout 0;' "$SITE_CONF"
fi

if grep -q "proxy_send_timeout" "$SITE_CONF"; then
    sed -i 's/proxy_send_timeout .*/proxy_send_timeout 0;/' "$SITE_CONF"
else
    sed -i '/proxy_read_timeout 0/a\        proxy_send_timeout 0;' "$SITE_CONF"
fi

nginx -t && systemctl reload nginx

echo -e "${GREEN}  Nginx 配置已更新并重载。${NC}"
echo ""
echo -e "${GREEN}修复完成！${NC}"
