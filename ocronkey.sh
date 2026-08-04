#!/bin/bash
set -euo pipefail

# =====================================================
# OCR 服务一键部署脚本 v2.1.0
# 仓库: https://github.com/qyidc/ocronekey
# 包含: 依赖安装、域名解析检查、端口开放检测、SWAP自动配置、
#       NTP同步、acme.sh自动升级、证书申请、Nginx智能集成
# 用法:
#   交互模式:   bash ocronkey.sh
#   非交互模式: bash ocronkey.sh --domain ocr.example.com --email admin@example.com [-y]
# =====================================================

VERSION="2.1.0"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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
            echo "  --domain DOMAIN    指定域名 (非交互模式)"
            echo "  --email EMAIL      指定邮箱 (非交互模式)"
            echo "  --apikey KEY       设置 API Key 鉴权 (可选，不设置则无鉴权)"
            echo "  -y, --yes          自动确认所有提示"
            echo "  -v, --version      显示版本号"
            echo "  -h, --help         显示帮助"
            exit 0
            ;;
        *) echo -e "${RED}未知参数: $1${NC}"; exit 1 ;;
    esac
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  OCR 服务一键部署 v${VERSION}${NC}"
echo -e "${GREEN}========================================${NC}"

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

# ----- 函数定义 -----
check_command() { command -v "$1" &>/dev/null; }

get_public_ip() {
    curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 ipinfo.io/ip || echo ""
}

confirm() {
    local prompt="$1"
    if $AUTO_YES; then
        return 0
    fi
    read -p "$prompt " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ----- 1. 预检：系统时间 -----
echo -e "${BLUE}[预检] 检查系统时间...${NC}"
if ! timedatectl &>/dev/null; then
    if [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        $PKG_INSTALL chrony
        systemctl start chronyd
        systemctl enable chronyd
    else
        $PKG_INSTALL systemd-timesyncd 2>/dev/null || true
    fi
fi
timedatectl set-ntp true 2>/dev/null || true
echo -e "${GREEN}  系统时间已同步。${NC}"

# ----- 2. 预检：SWAP (若内存 < 2G) -----
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
if [ "$MEM_TOTAL" -lt 2048 ]; then
    echo -e "${YELLOW}[预检] 物理内存 ${MEM_TOTAL}MB，建议配置 SWAP。${NC}"
    if [ ! -f /swapfile ]; then
        echo "  创建 2GB SWAP..."
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        # 调整 swappiness
        sed -i '/vm.swappiness/d' /etc/sysctl.conf 2>/dev/null || true
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
        sysctl -p 2>/dev/null || true
        echo -e "${GREEN}  SWAP 配置完成。${NC}"
    else
        echo -e "${GREEN}  SWAP 已存在。${NC}"
    fi
fi

# ----- 3. 输入域名 & 邮箱 -----
if [ -n "$ARG_DOMAIN" ]; then
    DOMAIN="$ARG_DOMAIN"
    echo -e "${CYAN}  域名: $DOMAIN (命令行指定)${NC}"
else
    read -p "请输入域名 (例如: ocr.example.com): " DOMAIN
fi
if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空${NC}"; exit 1; fi

if [ -n "$ARG_EMAIL" ]; then
    EMAIL="$ARG_EMAIL"
    echo -e "${CYAN}  邮箱: $EMAIL (命令行指定)${NC}"
else
    read -p "请输入邮箱 (用于 Let's Encrypt): " EMAIL
fi
if [ -z "$EMAIL" ]; then echo -e "${RED}邮箱不能为空${NC}"; exit 1; fi

# API Key (可选)
if [ -n "$ARG_APIKEY" ]; then
    APIKEY="$ARG_APIKEY"
    echo -e "${CYAN}  API Key: $APIKEY (命令行指定)${NC}"
else
    read -p "请输入 API Key (留空跳过鉴权，直接回车): " APIKEY
fi
if [ -n "$APIKEY" ]; then
    echo -e "${GREEN}  API Key 鉴权已启用。${NC}"
else
    echo -e "${YELLOW}  未设置 API Key，服务无鉴权（任何人可访问）。${NC}"
fi

# ----- 4. 预检：域名解析 -----
echo -e "${BLUE}[预检] 检查域名解析...${NC}"
PUBLIC_IP=$(get_public_ip)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${YELLOW}  无法获取本机公网 IP，请手动确认域名已解析到本机。${NC}"
else
    DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
    if [ -z "$DOMAIN_IP" ]; then
        # 如果 dig 不可用，尝试用 nslookup
        DOMAIN_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2}' | head -1)
    fi
    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}  域名 $DOMAIN 未解析到任何 IP，请先添加 A 记录。${NC}"
        exit 1
    elif [ "$DOMAIN_IP" != "$PUBLIC_IP" ]; then
        echo -e "${YELLOW}  域名解析到 $DOMAIN_IP，但本机公网 IP 是 $PUBLIC_IP，请确认解析正确。${NC}"
        if ! confirm "  是否继续？(y/n):"; then exit 1; fi
    else
        echo -e "${GREEN}  域名解析正确 (IP: $PUBLIC_IP)${NC}"
    fi
fi

# ----- 5. 预检：防火墙/安全组 80,443 端口 -----
echo -e "${BLUE}[预检] 检查防火墙端口...${NC}"
if ss -tlnp | grep -q ":80 "; then
    echo -e "${GREEN}  80 端口已被监听。${NC}"
else
    echo -e "${YELLOW}  80 端口未监听，如果未安装 Nginx，后面会安装。${NC}"
fi
echo -e "${YELLOW}  请确保云服务商安全组已开放 80 和 443 端口！${NC}"

# 自动配置 UFW (如果启用)
if check_command ufw; then
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    echo -e "${GREEN}  UFW 已开放 22,80,443。${NC}"
# 检测 firewalld (CentOS)
elif check_command firewall-cmd; then
    systemctl start firewalld 2>/dev/null || true
    firewall-cmd --add-service=http --permanent 2>/dev/null || true
    firewall-cmd --add-service=https --permanent 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo -e "${GREEN}  firewalld 已开放 80,443。${NC}"
fi

# ----- 6. 安装基础工具 -----
echo -e "${BLUE}[1/8] 安装基础工具...${NC}"
$PKG_UPDATE
for pkg in curl wget socat bind9-dnsutils net-tools; do
    # CentOS 上包名不同
    if [ "$OS_ID" = "centos" ] || [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "rocky" ] || [ "$OS_ID" = "almalinux" ]; then
        case "$pkg" in
            bind9-dnsutils) pkg="bind-utils" ;;
            net-tools) ;;  # net-tools 在 centos 上名字相同
        esac
    fi
    if ! check_command "${pkg%%-*}" && ! check_command "$pkg"; then
        $PKG_INSTALL "$pkg" 2>/dev/null || true
    fi
done

# ----- 7. 安装 Docker (如未安装) -----
echo -e "${BLUE}[2/8] 安装 Docker...${NC}"
if check_command docker; then
    echo -e "${GREEN}  Docker 已安装。${NC}"
else
    case "$OS_ID" in
        ubuntu|debian)
            $PKG_INSTALL ca-certificates
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel|rocky|almalinux)
            $PKG_INSTALL yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            echo -e "${YELLOW}  不支持的系统，请手动安装 Docker。${NC}"
            echo -e "${RED}  curl -fsSL https://get.docker.com | sh${NC}"
            exit 1
            ;;
    esac
    systemctl start docker
    systemctl enable docker
    echo -e "${GREEN}  Docker 安装完成。${NC}"
fi

# ----- 8. 安装 Nginx (如未安装) -----
echo -e "${BLUE}[3/8] 安装 Nginx...${NC}"
if check_command nginx; then
    echo -e "${GREEN}  Nginx 已安装。${NC}"
else
    case "$OS_ID" in
        centos|rhel|rocky|almalinux)
            $PKG_INSTALL epel-release 2>/dev/null || true
            ;;
    esac
    $PKG_INSTALL nginx
    systemctl start nginx
    systemctl enable nginx
    echo -e "${GREEN}  Nginx 安装完成。${NC}"
fi

# 获取 Nginx 配置目录
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
if [ ! -d "$SITES_AVAILABLE" ]; then
    SITES_AVAILABLE="/etc/nginx/conf.d"
    SITES_ENABLED="/etc/nginx/conf.d"
fi

# ----- 9. 准备 webroot -----
WEBROOT="/var/www/html"
mkdir -p "$WEBROOT"
mkdir -p "$WEBROOT/.well-known/acme-challenge"
chown -R www-data:www-data "$WEBROOT" 2>/dev/null || chown -R nginx:nginx "$WEBROOT" 2>/dev/null || true

# ----- 10. 安装/升级 acme.sh -----
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

# ----- 11. 检查是否存在冲突的 Nginx server_name -----
echo -e "${BLUE}[5/8] 检查 Nginx 配置冲突...${NC}"
if nginx -T 2>/dev/null | grep -q "server_name.*$DOMAIN"; then
    echo -e "${YELLOW}  警告：Nginx 中已存在 server_name $DOMAIN 的配置。${NC}"
    if ! confirm "  是否覆盖？(y/n):"; then
        echo "已退出。"
        exit 0
    fi
fi

# ----- 12. 申请 SSL 证书 (webroot) -----
echo -e "${BLUE}[6/8] 申请 SSL 证书...${NC}"
echo "  验证路径: http://$DOMAIN/.well-known/acme-challenge/"
if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" -w "$WEBROOT" --force; then
    echo -e "${GREEN}  证书申请成功。${NC}"
else
    echo -e "${RED}  证书申请失败，请检查域名解析和防火墙。${NC}"
    exit 1
fi

# 安装证书
CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/cert.pem" \
    --reloadcmd "systemctl reload nginx"

# ----- 13. 启动 OCR 容器 (映射端口 9899) -----
echo -e "${BLUE}[7/8] 启动 OCR 容器...${NC}"
docker stop media-saber-paddle-ocr 2>/dev/null || true
docker rm media-saber-paddle-ocr 2>/dev/null || true
docker run -d \
    --name media-saber-paddle-ocr \
    --restart unless-stopped \
    -p 127.0.0.1:9899:9899 \
    xylplm/media-saber-paddle-ocr:latest
echo -e "${GREEN}  容器已启动 (监听 127.0.0.1:9899)。${NC}"

# ----- 14. 生成 Nginx 站点配置 -----
echo -e "${BLUE}[8/8] 配置 Nginx 反向代理...${NC}"
SITE_CONF="$SITES_AVAILABLE/ocr-$DOMAIN.conf"

cat > "$SITE_CONF" <<EOF
# OCR 服务 - $DOMAIN
# 生成于 $(date)
# 脚本版本: v${VERSION}
EOF

# 如果设置了 API Key，添加 map 鉴权
if [ -n "$APIKEY" ]; then
    cat >> "$SITE_CONF" <<EOF

# API Key 鉴权
map \$http_x_api_key \$api_auth_ok {
    default     0;
    "$APIKEY"   1;
}
EOF
fi

cat >> "$SITE_CONF" <<EOF

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
EOF

if [ -n "$APIKEY" ]; then
    cat >> "$SITE_CONF" <<EOF

    # /health 不校验 API Key
    location = /health {
        proxy_pass http://127.0.0.1:9899/health;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        if (\$api_auth_ok = 0) {
            return 401 '{"error":"Invalid or missing API Key"}';
        }
        proxy_pass http://127.0.0.1:9899;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
EOF
else
    cat >> "$SITE_CONF" <<EOF

    location / {
        proxy_pass http://127.0.0.1:9899;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
EOF
fi

echo "}" >> "$SITE_CONF"

# 启用站点
if [ "$SITES_AVAILABLE" != "$SITES_ENABLED" ]; then
    ln -sf "$SITE_CONF" "$SITES_ENABLED/ocr-$DOMAIN.conf"
fi

# 测试并重载 Nginx
echo "  测试 Nginx 配置..."
if nginx -t; then
    systemctl reload nginx
    echo -e "${GREEN}  Nginx 配置应用成功。${NC}"
else
    echo -e "${RED}  Nginx 配置错误，请检查 $SITE_CONF${NC}"
    exit 1
fi

# ----- 15. 输出部署信息 -----
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ 部署完成！ (脚本版本 v${VERSION})${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}📋 API 配置参数：${NC}"
echo "  Base URL: https://$DOMAIN"
echo "  健康检查: https://$DOMAIN/health"
echo "  通用识别(文件): POST https://$DOMAIN/general/file"
echo "  通用识别(Base64): POST https://$DOMAIN/general/base64"
echo "  验证码识别: POST https://$DOMAIN/captcha/base64"
if [ -n "$APIKEY" ]; then
    echo ""
    echo -e "${GREEN}  API Key: $APIKEY${NC}"
    echo -e "${YELLOW}  调用时需在请求头添加: X-API-Key: $APIKEY${NC}"
else
    echo ""
    echo -e "${RED}  ⚠ 未设置 API Key，服务无鉴权保护！${NC}"
fi
echo ""
echo -e "${BLUE}📁 证书信息：${NC}"
echo "  证书目录: $CERT_DIR"
echo "  自动续期: acme.sh cron 已配置"
echo ""
echo -e "${BLUE}🐳 容器状态：${NC}"
docker ps --filter "name=media-saber-paddle-ocr" --format "table {{.Names}}\t{{.Status}}"
echo ""
echo -e "${BLUE}🔧 测试命令：${NC}"
echo "  curl https://$DOMAIN/health"
echo ""
echo -e "${YELLOW}💡 后续维护：${NC}"
echo "  1. 查看日志: docker logs media-saber-paddle-ocr"
echo "  2. 更新镜像: docker pull ... && docker restart ..."
echo "  3. 手动续期证书: ~/.acme.sh/acme.sh --renew -d $DOMAIN --force"
echo "  4. Nginx 配置文件: $SITE_CONF"
echo "  5. 脚本升级: bash ocronkey.sh --version 检查最新版本"
echo ""
echo -e "${GREEN}========================================${NC}"
