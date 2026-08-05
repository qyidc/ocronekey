#!/bin/bash
set -euo pipefail

# =====================================================
# OCR 服务一键部署脚本 v2.4.0
# 仓库: https://github.com/qyidc/ocronekey
# 用法:
#   菜单模式:   curl -fsSL url | bash
#   非交互模式: bash ocronkey.sh --domain ocr.example.com --email admin@example.com --apikey xxx -y
# =====================================================

VERSION="2.4.0"

# Fix: curl|bash 管道模式下，交互 read 从 /dev/tty 读取
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec 3</dev/tty
fi

# 交互式读取（自动选择正确的输入源）
iread() {
    if [ -t 0 ]; then
        builtin read "$@"
    else
        builtin read "$@" <&3
    fi
}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  OCR 服务一键部署 v${VERSION}${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# ----- 命令行参数解析 -----
AUTO_YES=false
ARG_DOMAIN=""
ARG_EMAIL=""
ARG_APIKEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   ARG_DOMAIN="$2"; shift 2 ;;
        --email)    ARG_EMAIL="$2";  shift 2 ;;
        --apikey)   ARG_APIKEY="$2"; shift 2 ;;
        -y|--yes)   AUTO_YES=true;   shift ;;
        -v|--version) echo "OCR一键部署脚本 v${VERSION}"; exit 0 ;;
        -h|--help)
            echo "用法: bash ocronkey.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --domain DOMAIN    指定域名 (非交互模式，直接安装)"
            echo "  --email EMAIL      指定邮箱 (非交互模式)"
            echo "  --apikey KEY       设置 API Key (可选)"
            echo "  -y, --yes          自动确认所有提示"
            echo "  -v, --version      显示版本号"
            echo "  -h, --help         显示帮助"
            exit 0
            ;;
        *) echo -e "${RED}未知参数: $1${NC}"; exit 1 ;;
    esac
done

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本。${NC}"
    exit 1
fi

# ----- 系统检测 -----
OS_ID=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
fi

case "$OS_ID" in
    ubuntu|debian)
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
        ;;
    centos|rhel|fedora|rocky|almalinux)
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache"
        ;;
    *)
        echo -e "${YELLOW}  未识别的系统 (${OS_ID:-unknown})，将尝试使用 apt-get。${NC}"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
        ;;
esac

# ======================== 工具函数 ========================
check_command() { command -v "$1" &>/dev/null; }

get_public_ip() {
    curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 ipinfo.io/ip || echo ""
}

confirm() {
    local prompt="$1"
    if $AUTO_YES; then return 0; fi
    iread -p "$prompt " answer
    answer="${answer%$'\r'}"  # 修复 Windows CRLF
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

# 检测是否存在已安装的 OCR 配置，返回域名
detect_install() {
    get_nginx_dirs
    local conf
    conf=$(ls "$SITES_AVAILABLE"/ocr-*.conf 2>/dev/null | head -1)
    if [ -n "$conf" ]; then
        basename "$conf" | sed 's/^ocr-//;s/\.conf$//'
    fi
}

# 从 Nginx 配置中提取 API Key
get_apikey_from_conf() {
    local conf="$1"
    # 只在 map 块内提取，避免匹配到 401 错误消息中的引号
    awk '/map.*api_auth_ok/,/^}/' "$conf" 2>/dev/null | grep -o '"[^"]*"' | tail -1 | tr -d '"'
}

# ======================== 1. 全新安装 ========================
install_full() {
    banner
    echo -e "${BLUE}开始全新安装...${NC}"
    echo ""

    # 已安装检查
    EXISTING=$(detect_install)
    if [ -n "$EXISTING" ]; then
        echo -e "${YELLOW}⚠ 检测到已安装的 OCR 服务 (域名: $EXISTING)${NC}"
        if ! confirm "  是否覆盖重新安装? (y/n):"; then
            echo "已取消。"
            return
        fi
    fi

    # 输入域名 & 邮箱
    if [ -n "$ARG_DOMAIN" ]; then
        DOMAIN="$ARG_DOMAIN"
        echo -e "${CYAN}  域名: $DOMAIN (命令行指定)${NC}"
    else
        iread -p "请输入域名 (例如: ocr.example.com): " DOMAIN
    fi
    DOMAIN="${DOMAIN%$'\r'}"
    if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空${NC}"; return; fi

    if [ -n "$ARG_EMAIL" ]; then
        EMAIL="$ARG_EMAIL"
        echo -e "${CYAN}  邮箱: $EMAIL (命令行指定)${NC}"
    else
        iread -p "请输入邮箱 (用于 Let's Encrypt): " EMAIL
    fi
    EMAIL="${EMAIL%$'\r'}"
    if [ -z "$EMAIL" ]; then echo -e "${RED}邮箱不能为空${NC}"; return; fi

    if [ -n "$ARG_APIKEY" ]; then
        APIKEY="$ARG_APIKEY"
        echo -e "${CYAN}  API Key: $APIKEY (命令行指定)${NC}"
    else
        iread -p "请输入 API Key (留空则无鉴权): " APIKEY
    fi
    APIKEY="${APIKEY%$'\r'}"
    if [ -n "$APIKEY" ]; then
        echo -e "${GREEN}  API Key 鉴权已启用。${NC}"
    else
        echo -e "${YELLOW}  未设置 API Key，服务无鉴权。${NC}"
    fi

    # 预检：系统时间
    echo -e "${BLUE}[预检] 检查系统时间...${NC}"
    if ! timedatectl &>/dev/null; then
        if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
            $PKG_INSTALL chrony
            systemctl start chronyd; systemctl enable chronyd
        else
            $PKG_INSTALL systemd-timesyncd 2>/dev/null || true
        fi
    fi
    timedatectl set-ntp true 2>/dev/null || true
    echo -e "${GREEN}  系统时间已同步。${NC}"

    # 预检：SWAP
    MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$MEM_TOTAL" -lt 2048 ]; then
        echo -e "${YELLOW}[预检] 物理内存 ${MEM_TOTAL}MB，配置 SWAP...${NC}"
        if [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
            grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            sed -i '/vm.swappiness/d' /etc/sysctl.conf 2>/dev/null || true
            echo 'vm.swappiness=10' >> /etc/sysctl.conf; sysctl -p 2>/dev/null || true
            echo -e "${GREEN}  SWAP 配置完成。${NC}"
        fi
    fi

    # 预检：域名解析
    echo -e "${BLUE}[预检] 检查域名解析...${NC}"
    PUBLIC_IP=$(get_public_ip)
    if [ -n "$PUBLIC_IP" ]; then
        DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
        [ -z "$DOMAIN_IP" ] && DOMAIN_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2}' | head -1)
        if [ -z "$DOMAIN_IP" ]; then
            echo -e "${RED}  域名 $DOMAIN 未解析，请先添加 A 记录。${NC}"; return
        elif [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
            echo -e "${YELLOW}  域名解析到 $DOMAIN_IP，本机 IP 是 $PUBLIC_IP。${NC}"
            if ! confirm "  是否继续? (y/n):"; then return; fi
        else
            echo -e "${GREEN}  域名解析正确 (IP: $PUBLIC_IP)${NC}"
        fi
    fi

    # 防火墙
    echo -e "${BLUE}[预检] 配置防火墙...${NC}"
    if check_command ufw; then
        ufw allow 22/tcp 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        ufw --force enable 2>/dev/null || true
        echo -e "${GREEN}  UFW 已开放 22,80,443。${NC}"
    elif check_command firewall-cmd; then
        systemctl start firewalld 2>/dev/null || true
        firewall-cmd --add-service=http --permanent 2>/dev/null || true
        firewall-cmd --add-service=https --permanent 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}  firewalld 已开放 80,443。${NC}"
    fi
    echo -e "${YELLOW}  请确保云服务商安全组已开放 80/443 端口！${NC}"

    # 安装基础工具
    echo -e "${BLUE}[1/8] 安装基础工具...${NC}"
    $PKG_UPDATE
    for pkg in curl wget socat bind9-dnsutils net-tools; do
        if [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
            [ "$pkg" = "bind9-dnsutils" ] && pkg="bind-utils"
        fi
        $PKG_INSTALL "$pkg" 2>/dev/null || true
    done

    # 安装 Docker
    echo -e "${BLUE}[2/8] 安装 Docker...${NC}"
    if check_command docker; then
        echo -e "${GREEN}  Docker 已安装。${NC}"
    else
        case "$OS_ID" in
            ubuntu|debian)
                $PKG_INSTALL ca-certificates
                install -m 0755 -d /etc/apt/keyrings
                local docker_repo="ubuntu"
                [ "$OS_ID" = "debian" ] && docker_repo="debian"
                curl -fsSL "https://download.docker.com/linux/${docker_repo}/gpg" -o /etc/apt/keyrings/docker.asc
                chmod a+r /etc/apt/keyrings/docker.asc
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_repo} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                apt-get update
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            centos|rhel|rocky|almalinux)
                $PKG_INSTALL yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            *) echo -e "${RED}不支持的系统，请手动安装 Docker。${NC}"; return ;;
        esac
        systemctl start docker; systemctl enable docker
        echo -e "${GREEN}  Docker 安装完成。${NC}"
    fi

    # 安装 Nginx
    echo -e "${BLUE}[3/8] 安装 Nginx...${NC}"
    if check_command nginx; then
        echo -e "${GREEN}  Nginx 已安装。${NC}"
    else
        [[ "$OS_ID" =~ ^(centos|rhel|rocky|almalinux)$ ]] && $PKG_INSTALL epel-release 2>/dev/null || true
        $PKG_INSTALL nginx
        systemctl start nginx; systemctl enable nginx
        echo -e "${GREEN}  Nginx 安装完成。${NC}"
    fi

    get_nginx_dirs
    WEBROOT="/var/www/html"
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    chown -R www-data:www-data "$WEBROOT" 2>/dev/null || chown -R nginx:nginx "$WEBROOT" 2>/dev/null || true

    # 安装 acme.sh
    echo -e "${BLUE}[4/8] 安装/升级 acme.sh...${NC}"
    export PATH="$HOME/.acme.sh:$PATH"
    if [ -f ~/.acme.sh/acme.sh ]; then
        echo -e "  升级 acme.sh..."
        ~/.acme.sh/acme.sh --upgrade
    else
        curl https://get.acme.sh | sh -s email="$EMAIL"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # 检查 Nginx 冲突
    echo -e "${BLUE}[5/8] 检查 Nginx 配置冲突...${NC}"
    if nginx -T 2>/dev/null | grep -q "server_name.*$DOMAIN"; then
        echo -e "${YELLOW}  Nginx 中已存在 server_name $DOMAIN 的配置。${NC}"
        if ! confirm "  是否覆盖? (y/n):"; then echo "已取消。"; return; fi
    fi

    # 申请 SSL 证书
    echo -e "${BLUE}[6/8] 申请 SSL 证书...${NC}"
    if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$WEBROOT" --force; then
        echo -e "${GREEN}  证书申请成功。${NC}"
    else
        echo -e "${RED}  证书申请失败，请检查域名解析和防火墙。${NC}"; return
    fi

    CERT_DIR="/etc/nginx/ssl/$DOMAIN"
    mkdir -p "$CERT_DIR"
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$CERT_DIR/key.pem" \
        --fullchain-file "$CERT_DIR/cert.pem" \
        --reloadcmd "systemctl reload nginx"

    # 启动 OCR 容器
    echo -e "${BLUE}[7/8] 启动 OCR 容器...${NC}"
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
        --health-start-period=60s \
        -p 127.0.0.1:9899:9899 \
        xylplm/media-saber-paddle-ocr:latest
    echo -e "${GREEN}  容器已启动 (监听 127.0.0.1:9899，资源限制 CPU≤80%/内存≤768MB，挂死自动重启)。${NC}"

    # 生成 Nginx 配置
    echo -e "${BLUE}[8/8] 配置 Nginx 反向代理...${NC}"
    SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"

    cat > "$SITE_CONF" <<HEADER
# OCR 服务 - $DOMAIN
# 生成于 $(date)
# 脚本版本: v${VERSION}
HEADER

    if [ -n "$APIKEY" ]; then
        cat >> "$SITE_CONF" <<AUTHMAP

# API Key 鉴权
map \$http_x_api_key \$api_auth_ok {
    default     0;
    "$APIKEY"   1;
}
AUTHMAP
    fi

    cat >> "$SITE_CONF" <<BASESERVER

# 串行化后端请求 — 1C1G VPS 一次只处理一张图
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
BASESERVER

    if [ -n "$APIKEY" ]; then
        cat >> "$SITE_CONF" <<AUTHLOCATION

    # /health 不校验 API Key
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

        # 不限超时 — 页面再大也等
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
AUTHLOCATION
    else
        cat >> "$SITE_CONF" <<NOMALLLOCATION

    location / {
        proxy_pass http://ocr_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 不限超时 — 页面再大也等
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
NOMALLLOCATION
    fi
    echo "}" >> "$SITE_CONF"

    # 启用站点
    if [ "$SITES_AVAILABLE" != "$SITES_ENABLED" ]; then
        ln -sf "$SITE_CONF" "$SITES_ENABLED/ocr-$DOMAIN.conf"
    fi

    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}  Nginx 配置应用成功。${NC}"
    else
        echo -e "${RED}  Nginx 配置错误，请检查 $SITE_CONF${NC}"; return
    fi

    # 输出信息
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ 部署完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}📋 API 信息：${NC}"
    echo "  Base URL:        https://$DOMAIN"
    echo "  健康检查:         GET  https://$DOMAIN/health"
    echo "  通用识别(文件):    POST https://$DOMAIN/general/file"
    echo "  通用识别(Base64): POST https://$DOMAIN/general/base64"
    echo "  验证码识别:        POST https://$DOMAIN/captcha/base64"
    if [ -n "$APIKEY" ]; then
        echo ""
        echo -e "${GREEN}  API Key: $APIKEY${NC}"
        echo -e "${YELLOW}  请求头: X-API-Key: $APIKEY${NC}"
    else
        echo ""
        echo -e "${RED}  ⚠ 未设置 API Key，服务无鉴权保护！${NC}"
    fi
    echo ""
    echo -e "${BLUE}📁 证书目录:${NC} $CERT_DIR"
    echo -e "${BLUE}🐳 容器:${NC}"
    docker ps --filter "name=media-saber-paddle-ocr" --format "table {{.Names}}\t{{.Status}}"
    echo ""
    echo -e "${GREEN}========================================${NC}"
}

# ======================== 2. 查看配置信息 ========================
show_config() {
    banner
    DOMAIN=$(detect_install)
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}未检测到已安装的 OCR 服务。${NC}"
        return
    fi
    get_nginx_dirs
    SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"

    echo -e "${BLUE}📋 OCR 服务配置信息${NC}"
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
        echo -e "  ${RED}API Key: 未设置 (无鉴权)${NC}"
    fi

    echo ""
    echo -e "${BLUE}📁 文件路径：${NC}"
    echo "  Nginx 配置: $SITE_CONF"
    echo "  证书目录:   /etc/nginx/ssl/$DOMAIN"

    echo ""
    echo -e "${BLUE}🐳 容器状态：${NC}"
    docker ps --filter "name=media-saber-paddle-ocr" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo -e "  ${RED}容器未运行${NC}"

    echo ""
    echo -e "${BLUE}🔧 测试命令：${NC}"
    echo "  curl https://$DOMAIN/health"
    if [ -n "$APIKEY" ]; then
        echo "  curl -H 'X-API-Key: $APIKEY' https://$DOMAIN/health"
    fi
    echo ""
}

# ======================== 3. 查看证书到期时间 ========================
check_cert_expiry() {
    banner
    DOMAIN=$(detect_install)
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}未检测到已安装的 OCR 服务。${NC}"
        return
    fi
    CERT_FILE="/etc/nginx/ssl/$DOMAIN/cert.pem"
    if [ ! -f "$CERT_FILE" ]; then
        echo -e "${RED}证书文件不存在: $CERT_FILE${NC}"
        return
    fi
    echo -e "${BLUE}🔒 SSL 证书信息 - $DOMAIN${NC}"
    echo ""
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null | while read line; do
        if [[ "$line" == notBefore* ]]; then
            echo -e "  生效时间: ${GREEN}$(echo "$line" | cut -d= -f2)${NC}"
        elif [[ "$line" == notAfter* ]]; then
            EXPIRY=$(echo "$line" | cut -d= -f2)
            EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
            NOW_TS=$(date +%s)
            if [ "$EXPIRY_TS" -gt 0 ]; then
                DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))
                if [ "$DAYS_LEFT" -lt 30 ]; then
                    echo -e "  到期时间: ${RED}$EXPIRY (还剩 ${DAYS_LEFT} 天!)${NC}"
                else
                    echo -e "  到期时间: ${GREEN}$EXPIRY (还剩 ${DAYS_LEFT} 天)${NC}"
                fi
            else
                echo "  到期时间: $EXPIRY"
            fi
        else
            echo "  $line"
        fi
    done
    echo ""
}

# ======================== 4. 证书续期 ========================
renew_cert() {
    banner
    DOMAIN=$(detect_install)
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}未检测到已安装的 OCR 服务。${NC}"
        return
    fi
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo -e "${RED}acme.sh 未安装，无法续期。${NC}"
        return
    fi
    echo -e "${BLUE}正在为 $DOMAIN 续期 SSL 证书...${NC}"
    export PATH="$HOME/.acme.sh:$PATH"
    if ~/.acme.sh/acme.sh --renew -d "$DOMAIN" --force; then
        echo -e "${GREEN}  证书续期成功！${NC}"
        systemctl reload nginx
    else
        echo -e "${RED}  证书续期失败，请检查。${NC}"
    fi
    echo ""
}

# ======================== 5. 修改 API Key ========================
modify_apikey() {
    banner
    DOMAIN=$(detect_install)
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}未检测到已安装的 OCR 服务。${NC}"
        return
    fi
    get_nginx_dirs
    SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"

    echo -e "${BLUE}API Key 管理 - $DOMAIN${NC}"
    echo ""
    CURRENT_KEY=$(get_apikey_from_conf "$SITE_CONF")
    if [ -n "$CURRENT_KEY" ]; then
        echo -e "  当前 API Key: ${GREEN}$CURRENT_KEY${NC}"
    else
        echo -e "  当前: ${YELLOW}无鉴权${NC}"
    fi
    echo ""
    echo "  1. 输入自定义 API Key"
    echo "  2. 自动生成随机 API Key"
    echo "  3. 清除 API Key（取消鉴权）"
    echo "  0. 返回"
    iread -p "  请选择 [1-3]: " KEY_CHOICE
    KEY_CHOICE="${KEY_CHOICE%$'\r'}"  # 修复 Windows CRLF

    NEW_KEY=""
    case "$KEY_CHOICE" in
        1) iread -p "  请输入新的 API Key: " NEW_KEY
           NEW_KEY="${NEW_KEY%$'\r'}"  # 修复 Windows CRLF
           ;;
        2) NEW_KEY=$(openssl rand -hex 16); echo -e "  已生成: ${GREEN}$NEW_KEY${NC}" ;;
        3) NEW_KEY=""; echo -e "  将清除 API Key 鉴权。${NC}" ;;
        0) return ;;
        *) echo -e "${RED}无效选择。${NC}"; return ;;
    esac

    # 备份原配置
    cp "$SITE_CONF" "$SITE_CONF.bak.$(date +%s)"

    # 重建 Nginx 配置
    CERT_DIR="/etc/nginx/ssl/$DOMAIN"
    WEBROOT="/var/www/html"

    if [ -n "$NEW_KEY" ]; then
        # 有 API Key
        cat > "$SITE_CONF" <<NEWCONF
# OCR 服务 - $DOMAIN
# 更新于 $(date)
# 脚本版本: v${VERSION}

# API Key 鉴权
map \$http_x_api_key \$api_auth_ok {
    default     0;
    "$NEW_KEY"  1;
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

        # 不限超时 — 页面再大也等
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
}
NEWCONF
    else
        # 无 API Key
        cat > "$SITE_CONF" <<NEWCONF
# OCR 服务 - $DOMAIN
# 更新于 $(date)
# 脚本版本: v${VERSION}

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

        # 不限超时 — 页面再大也等
        proxy_read_timeout 0;
        proxy_send_timeout 0;
    }
}
NEWCONF
    fi

    if nginx -t; then
        systemctl reload nginx
        echo ""
        if [ -n "$NEW_KEY" ]; then
            echo -e "${GREEN}  API Key 已更新！${NC}"
            echo -e "  新 Key: ${GREEN}$NEW_KEY${NC}"
            echo -e "  请求头: ${YELLOW}X-API-Key: $NEW_KEY${NC}"
        else
            echo -e "${YELLOW}  API Key 已清除，服务无鉴权。${NC}"
        fi
    else
        echo -e "${RED}  Nginx 配置测试失败，已恢复备份。${NC}"
        local bak
        bak=$(ls -1t "$SITE_CONF.bak."* 2>/dev/null | head -1)
        [ -n "$bak" ] && cp "$bak" "$SITE_CONF"
    fi
    echo ""
}

# ======================== 6. 完全卸载 ========================
full_uninstall() {
    banner
    DOMAIN=$(detect_install)
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}未检测到已安装的 OCR 服务。${NC}"
        return
    fi
    echo -e "${RED}⚠ 即将卸载 OCR 服务 - $DOMAIN${NC}"
    echo ""
    echo -e "  将执行以下操作："
    echo "  1. 停止并删除 OCR Docker 容器"
    echo "  2. 删除 Nginx 站点配置"
    echo "  3. 删除 SSL 证书文件"
    echo "  4. 删除 acme.sh 域名配置"
    echo "  5. (可选) 删除 Docker 镜像"
    echo ""
    if ! confirm "  确认卸载? (y/n):"; then echo "已取消。"; return; fi

    echo ""
    echo -e "${BLUE}[1/5] 停止并删除容器...${NC}"
    docker stop media-saber-paddle-ocr 2>/dev/null || true
    docker rm media-saber-paddle-ocr 2>/dev/null || true
    echo -e "${GREEN}  容器已删除。${NC}"

    echo -e "${BLUE}[2/5] 删除 Nginx 配置...${NC}"
    get_nginx_dirs
    rm -f "$SITES_AVAILABLE/ocr-$DOMAIN.conf"
    rm -f "$SITES_ENABLED/ocr-$DOMAIN.conf"
    systemctl reload nginx 2>/dev/null || true
    echo -e "${GREEN}  Nginx 配置已删除。${NC}"

    echo -e "${BLUE}[3/5] 删除 SSL 证书...${NC}"
    rm -rf "/etc/nginx/ssl/$DOMAIN"
    echo -e "${GREEN}  证书已删除。${NC}"

    echo -e "${BLUE}[4/5] 删除 acme.sh 域名配置...${NC}"
    if [ -f ~/.acme.sh/acme.sh ]; then
        export PATH="$HOME/.acme.sh:$PATH"
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null || true
    fi
    rm -rf ~/.acme.sh/"$DOMAIN"* 2>/dev/null || true
    echo -e "${GREEN}  acme.sh 配置已清理。${NC}"

    echo -e "${BLUE}[5/5] 清理 Docker 镜像...${NC}"
    if confirm "  是否删除 OCR Docker 镜像? (y/n):"; then
        docker rmi xylplm/media-saber-paddle-ocr:latest 2>/dev/null || true
        echo -e "${GREEN}  镜像已删除。${NC}"
    else
        echo "  已跳过。"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ 卸载完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}注意: Docker 和 Nginx 本身未被卸载，如需完全移除请手动操作。${NC}"
    echo ""
}

# ======================== 主菜单 ========================
main_menu() {
    while true; do
        banner
        DOMAIN=$(detect_install)
        if [ -n "$DOMAIN" ]; then
            echo -e "  状态: ${GREEN}已安装${NC} (域名: $DOMAIN)"
        else
            echo -e "  状态: ${YELLOW}未安装${NC}"
        fi
        echo ""
        echo "  1. 全新安装"
        echo "  2. 查看配置信息"
        echo "  3. 查看证书到期时间"
        echo "  4. 证书续期"
        echo "  5. 修改 API Key"
        echo "  6. 完全卸载"
        echo "  7. 退出脚本"
        echo ""
        iread -p "  请选择 [1-7]: " CHOICE
        CHOICE="${CHOICE%$'\r'}"  # 修复 Windows CRLF

        case "$CHOICE" in
            1) install_full ;;
            2) show_config ;;
            3) check_cert_expiry ;;
            4) renew_cert ;;
            5) modify_apikey ;;
            6) full_uninstall ;;
            7) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择，请输入 1-7。${NC}"; sleep 1 ;;
        esac

        echo ""
        if [ "$CHOICE" != "7" ]; then
            iread -p "按回车返回菜单..."
        fi
    done
}

# ======================== 入口 ========================
if [ -n "$ARG_DOMAIN" ]; then
    # 非交互模式：直接安装
    install_full
else
    # 交互模式：显示菜单
    main_menu
fi
