#!/bin/bash
set -uo pipefail

# =====================================================
# OCR 一站式部署脚本 v3.0
# 仓库: https://github.com/qyidc/ocronekey
# 包含: Docker OCR + Nginx SSL + Worker 同步守护进程
# =====================================================

SCRIPT_VERSION="3.1.2"

# ---- tty fix: curl|bash 管道模式下重定向交互 ----
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec 3</dev/tty
fi
iread() {
    if [ -t 0 ]; then
        builtin read "$@"
    else
        builtin read "$@" <&3
    fi
}

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  OCR 一站式部署 v${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# ---- CLI 参数 ----
AUTO_YES=false
ARG_DOMAIN=""
ARG_EMAIL=""
ARG_APIKEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) ARG_DOMAIN="$2"; shift 2 ;;
        --email)  ARG_EMAIL="$2";  shift 2 ;;
        --apikey) ARG_APIKEY="$2"; shift 2 ;;
        -y|--yes) AUTO_YES=true;   shift ;;
        -v|--version) echo "OCR一站式部署 v${SCRIPT_VERSION}"; exit 0 ;;
        -h|--help)
            echo "用法: bash ocronkey.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --domain DOMAIN   非交互安装: 指定域名"
            echo "  --email EMAIL     非交互安装: 指定邮箱"
            echo "  --apikey KEY      非交互安装: 设置 API Key"
            echo "  -y, --yes         自动确认所有提示"
            echo "  -v, --version     显示版本号"
            echo "  -h, --help        显示帮助"
            exit 0
            ;;
        *) echo -e "${RED}未知参数: $1${NC}"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本。${NC}"
    exit 1
fi

# ---- 系统检测 ----
OS_ID=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
fi
case "$OS_ID" in
    ubuntu|debian) PKG_INSTALL="apt-get install -y"; PKG_UPDATE="apt-get update -qq" ;;
    centos|rhel|fedora|rocky|almalinux) PKG_INSTALL="yum install -y"; PKG_UPDATE="yum makecache" ;;
    *) PKG_INSTALL="apt-get install -y"; PKG_UPDATE="apt-get update -qq" ;;
esac

# ---- 工具函数 ----
check_command() { command -v "$1" &>/dev/null; }

get_public_ip() {
    curl -s -4 --max-time 5 ifconfig.me || curl -s -4 --max-time 5 icanhazip.com || curl -s -4 --max-time 5 ipinfo.io/ip || echo ""
}

confirm() {
    local prompt="$1"
    $AUTO_YES && return 0
    iread -p "$prompt " answer
    answer="${answer%$'\r'}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

get_nginx_dirs() {
    if [ -d "/etc/nginx/sites-available" ]; then
        SITES_AVAILABLE="/etc/nginx/sites-available"
        SITES_ENABLED="/etc/nginx/sites-enabled"
    else
        SITES_AVAILABLE="/etc/nginx/conf.d"
        SITES_ENABLED="/etc/nginx/conf.d"
    fi
}

detect_install() {
    get_nginx_dirs
    local conf
    conf=$(shopt -s nullglob; ls "$SITES_AVAILABLE"/ocr-*.conf 2>/dev/null | head -1 || true)
    [ -n "$conf" ] && basename "$conf" | sed 's/^ocr-//;s/\.conf$//'
}

get_apikey_from_conf() {
    local conf="$1"
    awk '/map.*api_auth_ok/,/^}/' "$conf" 2>/dev/null | grep -o '"[^"]*"' | tail -1 | tr -d '"'
}

is_sync_installed() {
    [ -f "/opt/ocr/ocr_worker.conf" ] && [ -f "/etc/systemd/system/ocr-worker.service" ]
}

sync_status() {
    if ! is_sync_installed; then echo "未配置"; return; fi
    systemctl is-active ocr-worker 2>/dev/null || echo "已停止"
}



# ======================== 1. 全新安装 ========================
install_full() {
    banner
    echo -e "${BLUE}开始全新安装...${NC}"
    echo ""

    EXISTING=$(detect_install)
    if [ -n "$EXISTING" ]; then
        echo -e "${YELLOW}  检测到已安装的 OCR 服务 (域名: $EXISTING)${NC}"
        if ! confirm "  是否覆盖重新安装? (y/n):"; then echo "已取消。"; return; fi
    fi

    # 域名
    if [ -n "$ARG_DOMAIN" ]; then
        DOMAIN="$ARG_DOMAIN"
        echo -e "${CYAN}  域名: $DOMAIN (命令行指定)${NC}"
    else
        iread -p "请输入域名 (例如: ocr.example.com): " DOMAIN
    fi
    DOMAIN="${DOMAIN%$'\r'}"
    [ -z "$DOMAIN" ] && { echo -e "${RED}域名不能为空${NC}"; return; }

    # 邮箱
    if [ -n "$ARG_EMAIL" ]; then
        EMAIL="$ARG_EMAIL"
        echo -e "${CYAN}  邮箱: $EMAIL (命令行指定)${NC}"
    else
        iread -p "请输入邮箱 (用于 Let's Encrypt): " EMAIL
    fi
    EMAIL="${EMAIL%$'\r'}"
    [ -z "$EMAIL" ] && { echo -e "${RED}邮箱不能为空${NC}"; return; }

    # API Key
    if [ -n "$ARG_APIKEY" ]; then
        APIKEY="$ARG_APIKEY"
        echo -e "${CYAN}  API Key: $APIKEY (命令行指定)${NC}"
    else
        iread -p "请输入 API Key (留空则无鉴权): " APIKEY
    fi
    APIKEY="${APIKEY%$'\r'}"
    [ -n "$APIKEY" ] && echo -e "${GREEN}  API Key 鉴权已启用。${NC}" || echo -e "${YELLOW}  未设置 API Key，无鉴权。${NC}"

    # === 预检 ===
    echo -e "${BLUE}[预检] 系统时间...${NC}"
    if ! timedatectl &>/dev/null; then
        case "$OS_ID" in
            centos|rhel|rocky|almalinux) $PKG_INSTALL chrony; systemctl start chronyd; systemctl enable chronyd ;;
            *) $PKG_INSTALL systemd-timesyncd 2>/dev/null || true ;;
        esac
    fi
    timedatectl set-ntp true 2>/dev/null || true
    echo -e "${GREEN}  已同步。${NC}"

    echo -e "${BLUE}[预检] SWAP...${NC}"
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$MEM_TOTAL" -lt 2048 ] && [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}  SWAP 已配置。${NC}"
    else
        echo -e "${GREEN}  已跳过。${NC}"
    fi

    echo -e "${BLUE}[预检] 域名解析...${NC}"
    PUBLIC_IP=$(get_public_ip)
    if [ -n "$PUBLIC_IP" ]; then
        DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
        [ -z "$DOMAIN_IP" ] && DOMAIN_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2}' | head -1)
        if [ -z "$DOMAIN_IP" ]; then
            echo -e "${RED}  域名未解析，请先添加 A 记录。${NC}"; return
        elif [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
            echo -e "${YELLOW}  解析到 $DOMAIN_IP (本机 $PUBLIC_IP)，CF 代理可能仍需开启。${NC}"
            confirm "  继续? (y/n):" || return
        else
            echo -e "${GREEN}  解析正确。${NC}"
        fi
    fi

    echo -e "${BLUE}[预检] 防火墙...${NC}"
    check_command ufw && { ufw allow 22/tcp 2>/dev/null; ufw allow 80/tcp 2>/dev/null; ufw allow 443/tcp 2>/dev/null; ufw --force enable 2>/dev/null; echo -e "${GREEN}  UFW 已开放 22/80/443。${NC}"; }
    check_command firewall-cmd && { systemctl start firewalld 2>/dev/null; firewall-cmd --add-service=http --permanent 2>/dev/null; firewall-cmd --add-service=https --permanent 2>/dev/null; firewall-cmd --reload 2>/dev/null; echo -e "${GREEN}  firewalld 已开放 80/443。${NC}"; }
    echo -e "${YELLOW}  请确保云服务商安全组已开放 80/443！${NC}"

    # === 安装 ===
    echo -e "${BLUE}[1/8] 基础工具...${NC}"
    $PKG_UPDATE
    for pkg in curl wget socat net-tools jq; do
        $PKG_INSTALL "$pkg" 2>/dev/null || true
    done
    case "$OS_ID" in
        centos|rhel|rocky|almalinux) $PKG_INSTALL bind-utils 2>/dev/null || true ;;
        *) $PKG_INSTALL bind9-dnsutils 2>/dev/null || true ;;
    esac

    echo -e "${BLUE}[2/8] Docker...${NC}"
    if ! check_command docker; then
        case "$OS_ID" in
            ubuntu|debian)
                $PKG_INSTALL ca-certificates
                install -m 0755 -d /etc/apt/keyrings
                local dr="$OS_ID"
                [ "$dr" = "debian" ] && dr="debian"
                curl -fsSL "https://download.docker.com/linux/${dr}/gpg" -o /etc/apt/keyrings/docker.asc
                chmod a+r /etc/apt/keyrings/docker.asc
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${dr} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                apt-get update
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            centos|rhel|rocky|almalinux)
                $PKG_INSTALL yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            *) echo -e "${RED}不支持的系统。${NC}"; return ;;
        esac
        systemctl start docker; systemctl enable docker
    fi
    echo -e "${GREEN}  Docker 就绪。${NC}"

    echo -e "${BLUE}[3/8] Nginx...${NC}"
    if ! check_command nginx; then
        [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]] && $PKG_INSTALL epel-release 2>/dev/null || true
        $PKG_INSTALL nginx
        systemctl start nginx; systemctl enable nginx
    fi
    echo -e "${GREEN}  Nginx 就绪。${NC}"

    get_nginx_dirs
    WEBROOT="/var/www/html"
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    chown -R www-data:www-data "$WEBROOT" 2>/dev/null || chown -R nginx:nginx "$WEBROOT" 2>/dev/null || true

    echo -e "${BLUE}[4/8] acme.sh...${NC}"
    export PATH="$HOME/.acme.sh:$PATH"
    if [ -f ~/.acme.sh/acme.sh ]; then
        ~/.acme.sh/acme.sh --upgrade
    else
        curl https://get.acme.sh | sh -s email="$EMAIL"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo -e "${BLUE}[5/8] 检查 Nginx 冲突...${NC}"
    if nginx -T 2>/dev/null | grep -q "server_name.*$DOMAIN"; then
        echo -e "${YELLOW}  存在同名配置。${NC}"
        confirm "  覆盖? (y/n):" || { echo "已取消。"; return; }
    fi

    echo -e "${BLUE}[6/8] SSL 证书...${NC}"
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$WEBROOT" --force || {
        echo -e "${RED}  证书申请失败。${NC}"; return
    }

    CERT_DIR="/etc/nginx/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CERT_DIR/key.pem" \
        --fullchain-file "$CERT_DIR/cert.pem" \
        --reloadcmd "systemctl reload nginx"

    # === OCR 容器（无 CPU/内存限制，保留健康检查） ===
    echo -e "${BLUE}[7/8] OCR 容器...${NC}"
    docker stop media-saber-paddle-ocr 2>/dev/null || true
    docker rm media-saber-paddle-ocr 2>/dev/null || true
    docker run -d \
        --name media-saber-paddle-ocr \
        --restart unless-stopped \
        --health-cmd="curl -f -m 5 http://localhost:9899/health || exit 1" \
        --health-interval=10s \
        --health-retries=1 \
        --health-timeout=5s \
        --health-start-period=60s \
        -p 127.0.0.1:9899:9899 \
        xylplm/media-saber-paddle-ocr:latest
    echo -e "${GREEN}  容器已启动（无资源限制，健康检查 + 挂死自动重启）。${NC}"

    # === Nginx 配置 ===
    echo -e "${BLUE}[8/8] Nginx 配置...${NC}"
    SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"

    cat > "$SITE_CONF" <<HEADER
# OCR 服务 - $DOMAIN
# 脚本版本: v${SCRIPT_VERSION} | 生成于 $(date)

HEADER

    if [ -n "$APIKEY" ]; then
        cat >> "$SITE_CONF" <<AUTHMAP

map \$http_x_api_key \$api_auth_ok {
    default     0;
    "$APIKEY"   1;
}
AUTHMAP
    fi

    cat >> "$SITE_CONF" <<UPSTREAM

upstream ocr_backend {
    server 127.0.0.1:9899 max_conns=1;
}

server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_DIR/cert.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }
UPSTREAM

    if [ -n "$APIKEY" ]; then
        cat >> "$SITE_CONF" << 'AUTHPROXY'
    location = /health {
        proxy_pass http://ocr_backend/health;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        if ($api_auth_ok = 0) {
            return 401 '{"error":"Invalid or missing API Key"}';
        }
        proxy_pass http://ocr_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
}
AUTHPROXY
    else
        cat >> "$SITE_CONF" << 'NOPROXY'
    location / {
        proxy_pass http://ocr_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
}
NOPROXY
    fi

    [ "$SITES_AVAILABLE" != "$SITES_ENABLED" ] && ln -sf "$SITE_CONF" "$SITES_ENABLED/ocr-$DOMAIN.conf"

    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}  Nginx 配置应用成功。${NC}"
    else
        echo -e "${RED}  Nginx 配置错误，检查 $SITE_CONF${NC}"; return
    fi

    # 输出
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  Base URL:        ${CYAN}https://$DOMAIN${NC}"
    echo -e "  健康检查:         ${CYAN}https://$DOMAIN/health${NC}"
    echo -e "  通用识别(文件):    ${CYAN}https://$DOMAIN/general/file${NC}"
    echo -e "  通用识别(Base64): ${CYAN}https://$DOMAIN/general/base64${NC}"
    echo -e "  验证码识别:        ${CYAN}https://$DOMAIN/captcha/base64${NC}"
    if [ -n "$APIKEY" ]; then
        echo ""
        echo -e "  ${GREEN}API Key: $APIKEY${NC}"
        echo -e "  ${YELLOW}请求头: X-API-Key: $APIKEY${NC}"
    fi
    echo ""
    echo -e "${YELLOW}  Cloudflare 用户: DNS 设为仅 DNS(灰云)，SSL/TLS 设为「完全」。${NC}"
    echo ""
}

# ======================== 2. 配置 Worker 同步 ========================
config_sync() {
    banner
    DOMAIN=$(detect_install)
    [ -z "$DOMAIN" ] && { echo -e "${RED}请先安装 OCR 服务（选项 1）。${NC}"; return; }

    echo -e "${BLUE}配置 Worker 同步 — VPS 轮询 Worker API (push 模式)${NC}"
    echo ""

    # 参数收集
    iread -p "Worker 域名 (如 https://doc.otwx.top): " BASE_URL
    BASE_URL="${BASE_URL%$'\r'}"
    [ -z "$BASE_URL" ] && { echo -e "${RED}Worker 域名不能为空${NC}"; return; }
    # 去掉尾部斜杠
    BASE_URL="${BASE_URL%/}"

    iread -p "Worker Secret (与 Worker 端一致): " WORKER_SECRET
    WORKER_SECRET="${WORKER_SECRET%$'\r'}"
    [ -z "$WORKER_SECRET" ] && { echo -e "${RED}Secret 不能为空${NC}"; return; }

    iread -p "轮询间隔 (秒, 默认 5): " POLL_INTERVAL
    POLL_INTERVAL="${POLL_INTERVAL%$'\r'}"
    [ -z "$POLL_INTERVAL" ] && POLL_INTERVAL=5

    echo ""

    # 验证连接
    echo -e "${BLUE}测试 Worker 连接...${NC}"
    TEST_RESP=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "X-Worker-Secret: $WORKER_SECRET" \
        "$BASE_URL/api/ocr-tasks/next" 2>&1)
    if [ "$TEST_RESP" = "200" ] || [ "$TEST_RESP" = "204" ] || [ "$TEST_RESP" = "404" ]; then
        # 200=有任务, 204/404=无任务, 都是正常连接
        echo -e "${GREEN}  Worker 连接成功 (HTTP $TEST_RESP)。${NC}"
    else
        echo -e "${RED}  Worker 连接失败 (HTTP $TEST_RESP)，请检查 URL 和 Secret。${NC}"
        return
    fi

    # 生成配置目录
    mkdir -p /opt/ocr /tmp/ocr-worker

    # 写配置文件
    cat > /opt/ocr/ocr_worker.conf <<CONF
BASE_URL="$BASE_URL"
WORKER_SECRET="$WORKER_SECRET"
POLL_INTERVAL=$POLL_INTERVAL
CONF
    chmod 600 /opt/ocr/ocr_worker.conf

    # 生成 Worker 脚本
    cat > /opt/ocr/ocr_worker.sh << 'WORKEREOF'
#!/bin/bash
# OCR 同步守护进程 — 轮询 Worker API → 本地 OCR → 回传结果
# 由 ocronkey.sh v3.1 生成

set -euo pipefail
source /opt/ocr/ocr_worker.conf

PADDLE_URL="http://127.0.0.1:9899"
TEMP_DIR="/tmp/ocr-worker"
LOG_FILE="/var/log/ocr_worker.log"

mkdir -p "$TEMP_DIR"
exec >>"$LOG_FILE" 2>&1

echolog() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

echolog "=== OCR Worker v3.1 启动 ==="
echolog "Worker: $BASE_URL"
echolog "轮询间隔: ${POLL_INTERVAL}s"

while true; do
    # 1. 拉取下一个待处理任务
    TASK_JSON=$(curl -sf -H "X-Worker-Secret: $WORKER_SECRET" \
        "$BASE_URL/api/ocr-tasks/next" 2>/dev/null) || {
        echolog "WARN: 网络异常, 5s 后重试"
        sleep 5
        continue
    }

    TASK_ID=$(echo "$TASK_JSON" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

    if [ -z "$TASK_ID" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    DOC_ID=$(echo "$TASK_JSON" | grep -o '"documentId":[0-9]*' | head -1 | grep -o '[0-9]*')
    PAGE_NUM=$(echo "$TASK_JSON" | grep -o '"pageNum":[0-9]*' | head -1 | grep -o '[0-9]*')

    echolog "处理: task=$TASK_ID doc=$DOC_ID page=$PAGE_NUM"

    # 2. 下载图片到文件（避免大 base64 占满内存）
    IMG_FILE="$TEMP_DIR/task_${TASK_ID}.jpg"
    if ! curl -sf -H "X-Worker-Secret: $WORKER_SECRET" \
        --max-time 30 \
        "$BASE_URL/api/ocr-tasks/$TASK_ID/image" -o "$IMG_FILE" 2>/dev/null; then
        echolog "  ERROR: 下载图片失败"
        curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"error":"下载图片失败"}' \
            "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
        rm -f "$IMG_FILE"
        continue
    fi

    # 3. base64 编码
    BASE64_IMG=$(base64 -w 0 "$IMG_FILE" 2>/dev/null || base64 "$IMG_FILE" 2>/dev/null)
    rm -f "$IMG_FILE"

    if [ -z "$BASE64_IMG" ]; then
        echolog "  ERROR: base64 编码失败"
        curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"error":"base64 编码失败"}' \
            "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
        continue
    fi

    # 4. 本地 OCR 识别（不限时）
    echolog "  开始 OCR..."
    OCR_RESP=$(curl -s --max-time 300 \
        -X POST "$PADDLE_URL/general/base64" \
        -H "Content-Type: application/json" \
        -d "{\"image\":\"$BASE64_IMG\"}" 2>/dev/null) || {
        echolog "  ERROR: PaddleOCR 不可用"
        curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"error":"PaddleOCR 服务不可用"}' \
            "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
        continue
    }

    # 5. 提取识别文本（解析 rec_texts 字段）
    OCR_TEXT=$(echo "$OCR_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    texts = []
    for r in data.get('results', []):
        texts.extend(r.get('rec_texts', []))
    print('\n'.join(texts))
except Exception:
    pass
" 2>/dev/null)

    if [ -n "$OCR_TEXT" ]; then
        # 用 python3 安全转义 JSON
        ESCAPED_TEXT=$(echo "$OCR_TEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
        curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
            -H "Content-Type: application/json" \
            -d "{\"text\":$ESCAPED_TEXT}" \
            "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
        echolog "  完成: task=$TASK_ID, chars=${#OCR_TEXT}"
    else
        echolog "  无文字: task=$TASK_ID"
        curl -sf -X POST -H "X-Worker-Secret: $WORKER_SECRET" \
            -H "Content-Type: application/json" \
            -d '{"error":"无识别结果"}' \
            "$BASE_URL/api/ocr-tasks/$TASK_ID/result" > /dev/null 2>&1
    fi
done
WORKEREOF
    chmod +x /opt/ocr/ocr_worker.sh

    # 创建 systemd 服务
    cat > /etc/systemd/system/ocr-worker.service <<SERVICEEOF
[Unit]
Description=OCR Sync Worker (Worker API)
After=network.target docker.service

[Service]
Type=simple
ExecStart=/bin/bash /opt/ocr/ocr_worker.sh
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/ocr_worker.log
StandardError=append:/var/log/ocr_worker.log

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable ocr-worker
    systemctl start ocr-worker

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  同步配置完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  Worker URL:  ${BASE_URL}"
    echo -e "  配置文件:     /opt/ocr/ocr_worker.conf"
    echo -e "  Worker 脚本:  /opt/ocr/ocr_worker.sh"
    echo -e "  日志文件:     /var/log/ocr_worker.log"
    echo -e "  轮询间隔:     ${POLL_INTERVAL}s"
    echo -e "  状态:         $(systemctl is-active ocr-worker 2>/dev/null)"
    echo ""
    echo -e "${BLUE}Worker 端需要在 Cloudflare Worker 中实现三个端点:${NC}"
    echo "  GET  ${BASE_URL}/api/ocr-tasks/next        → 返回下一个待处理任务"
    echo "  GET  ${BASE_URL}/api/ocr-tasks/{id}/image  → 返回图片二进制"
    echo "  POST ${BASE_URL}/api/ocr-tasks/{id}/result → 接收识别结果 {text} 或 {error}"
    echo ""
}

# ======================== 3. 同步服务管理 ========================
sync_control() {
    banner
    if ! is_sync_installed; then
        echo -e "${RED}同步服务未配置，请先执行选项 2。${NC}"
        return
    fi
    echo -e "${BLUE}同步服务管理${NC}"
    echo ""
    echo -e "  状态: $(systemctl is-active ocr-worker 2>/dev/null)"
    echo ""
    echo "  1. 启动同步"
    echo "  2. 停止同步"
    echo "  3. 重启同步"
    echo "  0. 返回"
    iread -p "  请选择 [1-3]: " SC
    SC="${SC%$'\r'}"

    case "$SC" in
        1) systemctl start ocr-worker; echo -e "${GREEN}  已启动。${NC}" ;;
        2) systemctl stop ocr-worker;  echo -e "${YELLOW}  已停止。${NC}" ;;
        3) systemctl restart ocr-worker; echo -e "${GREEN}  已重启。${NC}" ;;
        0) return ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
}

# ======================== 4. 查看配置信息 ========================
show_config() {
    banner
    DOMAIN=$(detect_install)
    [ -z "$DOMAIN" ] && { echo -e "${RED}未检测到已安装的 OCR 服务。${NC}"; return; }

    get_nginx_dirs
    SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"

    echo -e "${BLUE}  OCR 服务配置信息${NC}"
    echo ""
    echo -e "  域名:           ${GREEN}$DOMAIN${NC}"
    echo "  Base URL:       https://$DOMAIN"
    echo "  健康检查:        GET  https://$DOMAIN/health"
    echo "  通用识别(文件):   POST https://$DOMAIN/general/file"
    echo "  通用识别(Base64): POST https://$DOMAIN/general/base64"
    echo "  验证码识别:       POST https://$DOMAIN/captcha/base64"

    APIKEY=$(get_apikey_from_conf "$SITE_CONF")
    if [ -n "$APIKEY" ]; then
        echo ""
        echo -e "  ${GREEN}API Key: $APIKEY${NC}"
        echo -e "  请求头: ${YELLOW}X-API-Key: $APIKEY${NC}"
    else
        echo ""
        echo -e "  ${RED}API Key: 未设置${NC}"
    fi

    echo ""
    echo -e "${BLUE}  文件路径${NC}"
    echo "  Nginx:     $SITE_CONF"
    echo "  证书:       /etc/nginx/ssl/$DOMAIN"

    echo ""
    echo -e "${BLUE}  容器状态${NC}"
    docker ps --filter "name=media-saber-paddle-ocr" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo -e "  ${RED}容器未运行${NC}"

    if is_sync_installed; then
        echo ""
        echo -e "${BLUE}  同步状态${NC}"
        echo "  Worker:      $(systemctl is-active ocr-worker 2>/dev/null)"
        echo "  日志文件:     /var/log/ocr_worker.log"
        echo "  配置文件:     /opt/ocr/ocr_worker.conf"
    fi
    echo ""
}

# ======================== 5. 证书到期时间 ========================
check_cert_expiry() {
    banner
    DOMAIN=$(detect_install)
    [ -z "$DOMAIN" ] && { echo -e "${RED}未检测到 OCR 服务。${NC}"; return; }

    CERT_FILE="/etc/nginx/ssl/$DOMAIN/cert.pem"
    [ ! -f "$CERT_FILE" ] && { echo -e "${RED}证书不存在: $CERT_FILE${NC}"; return; }

    echo -e "${BLUE}SSL 证书 — $DOMAIN${NC}"
    echo ""
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null | while read line; do
        if [[ "$line" == notBefore* ]]; then
            echo -e "  生效: ${GREEN}$(echo "$line" | cut -d= -f2)${NC}"
        elif [[ "$line" == notAfter* ]]; then
            EXPIRY=$(echo "$line" | cut -d= -f2)
            EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
            NOW_TS=$(date +%s)
            if [ "$EXPIRY_TS" -gt 0 ]; then
                DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))
                if [ "$DAYS_LEFT" -lt 30 ]; then
                    echo -e "  到期: ${RED}$EXPIRY (还剩 ${DAYS_LEFT} 天!)${NC}"
                else
                    echo -e "  到期: ${GREEN}$EXPIRY (还剩 ${DAYS_LEFT} 天)${NC}"
                fi
            else
                echo "  到期: $EXPIRY"
            fi
        else
            echo "  $line"
        fi
    done
    echo ""
}

# ======================== 6. 证书续期 ========================
renew_cert() {
    banner
    DOMAIN=$(detect_install)
    [ -z "$DOMAIN" ] && { echo -e "${RED}未检测到 OCR 服务。${NC}"; return; }
    [ ! -f ~/.acme.sh/acme.sh ] && { echo -e "${RED}acme.sh 未安装。${NC}"; return; }

    echo -e "${BLUE}续期 $DOMAIN ...${NC}"
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --renew -d "$DOMAIN" --force && echo -e "${GREEN}  续期成功！${NC}" && systemctl reload nginx || echo -e "${RED}  续期失败。${NC}"
    echo ""
}

# ======================== 7. 修改 API Key ========================
modify_apikey() {
    banner
    DOMAIN=$(detect_install)
    [ -z "$DOMAIN" ] && { echo -e "${RED}未检测到 OCR 服务。${NC}"; return; }

    get_nginx_dirs
    SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"
    CERT_DIR="/etc/nginx/ssl/$DOMAIN"
    WEBROOT="/var/www/html"

    echo -e "${BLUE}API Key 管理 — $DOMAIN${NC}"
    echo ""

    CURRENT_KEY=$(get_apikey_from_conf "$SITE_CONF")
    [ -n "$CURRENT_KEY" ] && echo -e "  当前: ${GREEN}$CURRENT_KEY${NC}" || echo -e "  当前: ${YELLOW}无鉴权${NC}"

    echo ""
    echo "  1. 输入自定义 Key"
    echo "  2. 自动生成随机 Key"
    echo "  3. 清除 Key (取消鉴权)"
    echo "  0. 返回"
    iread -p "  请选择 [1-3]: " KC
    KC="${KC%$'\r'}"

    case "$KC" in
        1) iread -p "  新 Key: " NEW_KEY; NEW_KEY="${NEW_KEY%$'\r'}" ;;
        2) NEW_KEY=$(openssl rand -hex 16); echo -e "  已生成: ${GREEN}$NEW_KEY${NC}" ;;
        3) NEW_KEY="" ;;
        0) return ;;
        *) echo -e "${RED}无效选择。${NC}"; return ;;
    esac

    # 备份
    cp "$SITE_CONF" "$SITE_CONF.bak.$(date +%s)"

    # 重写配置（含 upstream + max_conns）
    if [ -n "$NEW_KEY" ]; then
        cat > "$SITE_CONF" <<KEYCONF
# OCR 服务 - $DOMAIN
# 更新于 $(date) | 脚本版本 v${SCRIPT_VERSION}

map \$http_x_api_key \$api_auth_ok {
    default     0;
    "$NEW_KEY"  1;
}

upstream ocr_backend {
    server 127.0.0.1:9899 max_conns=1;
}

server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_DIR/cert.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }

    location = /health {
        proxy_pass http://ocr_backend/health;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        if (\$api_auth_ok = 0) {
            return 401 '{"error":"Invalid or missing API Key"}';
        }
        proxy_pass http://ocr_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
}
KEYCONF
    else
        cat > "$SITE_CONF" <<NOKEYCONF
# OCR 服务 - $DOMAIN
# 更新于 $(date) | 脚本版本 v${SCRIPT_VERSION}

upstream ocr_backend {
    server 127.0.0.1:9899 max_conns=1;
}

server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT_DIR/cert.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }

    location / {
        proxy_pass http://ocr_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
}
NOKEYCONF
    fi

    if nginx -t; then
        systemctl reload nginx
        echo ""
        if [ -n "$NEW_KEY" ]; then
            echo -e "  ${GREEN}API Key 已更新！${NC}"
            echo -e "  Key: ${GREEN}$NEW_KEY${NC}"
        else
            echo -e "  ${YELLOW}API Key 已清除。${NC}"
        fi
    else
        echo -e "${RED}  配置测试失败，已恢复备份。${NC}"
        local bak
        bak=$(ls -1t "$SITE_CONF.bak."* 2>/dev/null | head -1)
        [ -n "$bak" ] && cp "$bak" "$SITE_CONF"
    fi
    echo ""
}

# ======================== 8. 查看同步日志 ========================
show_sync_logs() {
    banner
    if ! is_sync_installed; then
        echo -e "${RED}同步服务未配置，请先执行选项 2。${NC}"
        return
    fi
    echo -e "${BLUE}同步日志 (最后 50 行)${NC}"
    echo "========================================"
    tail -50 /var/log/ocr_worker.log 2>/dev/null || echo "  日志文件为空或不存在。"
    echo "========================================"
    echo ""
    echo "  持续查看: tail -f /var/log/ocr_worker.log"
    echo ""
}

# ======================== 9. 完全卸载 ========================
full_uninstall() {
    banner
    DOMAIN=$(detect_install)
    [ -z "$DOMAIN" ] && { echo -e "${RED}未检测到 OCR 服务。${NC}"; return; }

    echo -e "${RED}  将卸载 OCR 服务 — $DOMAIN${NC}"
    echo ""
    echo "  1. 停止并删除 Docker 容器"
    echo "  2. 删除 Nginx 站点配置"
    echo "  3. 删除 SSL 证书"
    echo "  4. 删除 acme.sh 域名配置"
    if is_sync_installed; then
        echo "  5. 停止并删除同步服务"
    fi
    echo "  6. (可选) 删除 Docker 镜像"
    echo ""
    confirm "  确认卸载? (y/n):" || { echo "已取消。"; return; }

    # 1. 容器
    echo -e "${BLUE}[1] 容器...${NC}"
    docker stop media-saber-paddle-ocr 2>/dev/null || true
    docker rm media-saber-paddle-ocr 2>/dev/null || true
    echo -e "${GREEN}  已删除。${NC}"

    # 2. Nginx
    echo -e "${BLUE}[2] Nginx 配置...${NC}"
    get_nginx_dirs
    rm -f "$SITES_AVAILABLE/ocr-$DOMAIN.conf"
    rm -f "$SITES_ENABLED/ocr-$DOMAIN.conf"
    systemctl reload nginx 2>/dev/null || true
    echo -e "${GREEN}  已清理。${NC}"

    # 3. 证书
    echo -e "${BLUE}[3] SSL 证书...${NC}"
    rm -rf "/etc/nginx/ssl/$DOMAIN"
    echo -e "${GREEN}  已删除。${NC}"

    # 4. acme.sh
    echo -e "${BLUE}[4] acme.sh...${NC}"
    if [ -f ~/.acme.sh/acme.sh ]; then
        export PATH="$HOME/.acme.sh:$PATH"
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null || true
    fi
    rm -rf ~/.acme.sh/"$DOMAIN"* 2>/dev/null || true
    echo -e "${GREEN}  已清理。${NC}"

    # 5. 同步服务
    if is_sync_installed; then
        echo -e "${BLUE}[5] 同步服务...${NC}"
        systemctl stop ocr-worker 2>/dev/null || true
        systemctl disable ocr-worker 2>/dev/null || true
        rm -f /etc/systemd/system/ocr-worker.service
        rm -f /opt/ocr/ocr_worker.sh /opt/ocr/ocr_worker.conf
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}  已清理。${NC}"
    fi

    # 6. 镜像
    echo -e "${BLUE}[6] Docker 镜像...${NC}"
    confirm "  删除 OCR 镜像? (y/n):" && {
        docker rmi xylplm/media-saber-paddle-ocr:latest 2>/dev/null || true
        echo -e "${GREEN}  已删除。${NC}"
    } || echo "  已跳过。"

    echo ""
    echo -e "${GREEN}  卸载完成。Docker/Nginx 本体未卸载。${NC}"
    echo ""
}

# ======================== 主菜单 ========================
main_menu() {
    while true; do
        banner
        DOMAIN=$(detect_install)
        if [ -n "$DOMAIN" ]; then
            SYNC_STAT=$(sync_status)
            echo -e "  状态: ${GREEN}已安装${NC} (域名: $DOMAIN) | 同步: ${SYNC_STAT}"
        else
            echo -e "  状态: ${YELLOW}未安装${NC}"
        fi
        echo ""
        echo "  1. 全新安装 OCR 服务"
        echo "  2. 配置 Worker 同步     (VPS 轮询 Worker API)"
        echo "  3. 同步服务管理         (启动/停止/重启)"
        echo "  4. 查看配置信息"
        echo "  5. 查看证书到期时间"
        echo "  6. 证书续期"
        echo "  7. 修改 API Key"
        echo "  8. 查看同步日志"
        echo "  9. 完全卸载"
        echo "  0. 退出"
        echo ""
        iread -p "  请选择 [0-9]: " CHOICE
        CHOICE="${CHOICE%$'\r'}"

        case "$CHOICE" in
            1) install_full ;;
            2) config_sync ;;
            3) sync_control ;;
            4) show_config ;;
            5) check_cert_expiry ;;
            6) renew_cert ;;
            7) modify_apikey ;;
            8) show_sync_logs ;;
            9) full_uninstall ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择 [0-9]。${NC}"; sleep 1 ;;
        esac

        echo ""
        [ "$CHOICE" != "0" ] && iread -p "按回车返回菜单..."
    done
}

# ======================== 入口 ========================
if [ -n "$ARG_DOMAIN" ]; then
    install_full
else
    main_menu
fi
