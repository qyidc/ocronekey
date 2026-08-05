# OCR 服务一键部署脚本

基于 Docker + PaddleOCR + Nginx + Let's Encrypt SSL 的 OCR 识别服务一键部署方案。

## 功能特性

- Docker 容器化部署 PaddleOCR 识别服务
- 自动安装 Docker、Nginx、acme.sh
- Let's Encrypt 免费 SSL 证书自动申请与续期
- Nginx 反向代理，HTTP 自动跳转 HTTPS
- 域名解析自动检测
- 小内存 VPS 自动配置 SWAP
- 防火墙端口自动开放（UFW / firewalld）
- 系统时间自动同步
- 支持 Ubuntu / Debian / CentOS / Rocky / AlmaLinux
- 支持非交互模式，适合自动化部署

## 一键安装

### 交互模式

```bash
curl -fsSL https://raw.githubusercontent.com/qyidc/ocronekey/main/ocronkey.sh | bash
```

运行后按提示输入域名和邮箱即可完成部署。

### 自动化模式（无人值守）

```bash
curl -fsSL https://raw.githubusercontent.com/qyidc/ocronekey/main/ocronkey.sh | bash -s -- --domain ocr.example.com --email admin@example.com --apikey my-secret-key -y
```

## 前置要求

| 要求 | 说明 |
|------|------|
| 系统 | Ubuntu 18.04+ / Debian 10+ / CentOS 7+ / Rocky Linux |
| 用户 | root 权限 |
| 域名 | 需提前将域名 A 记录解析到 VPS 公网 IP |
| 端口 | 安全组 / 防火墙需开放 80 和 443 端口 |
| 内存 | 建议 >= 2GB（低于 2G 会自动配置 SWAP） |

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--domain DOMAIN` | 指定域名（非交互模式） |
| `--email EMAIL` | 指定邮箱（非交互模式，用于 Let's Encrypt） |
| `--apikey KEY` | 设置 API Key（可选，非交互模式） |
| `-y, --yes` | 自动确认所有提示 |
| `-v, --version` | 显示版本号 |
| `-h, --help` | 显示帮助信息 |

## API 接口

部署完成后，OCR 服务提供以下接口：

| 接口 | 方法 | 说明 |
|------|------|------|
| `https://your-domain/health` | GET | 健康检查 |
| `https://your-domain/general/file` | POST | 通用文字识别（文件上传） |
| `https://your-domain/general/base64` | POST | 通用文字识别（Base64） |
| `https://your-domain/captcha/base64` | POST | 验证码识别（Base64） |

## 后续维护

```bash
# 查看容器运行状态
docker ps --filter "name=media-saber-paddle-ocr"

# 查看 OCR 服务日志
docker logs media-saber-paddle-ocr

# 更新 OCR 镜像
docker pull xylplm/media-saber-paddle-ocr:latest
docker restart media-saber-paddle-ocr

# 手动续期 SSL 证书
~/.acme.sh/acme.sh --renew -d your-domain.com --force

# 测试接口
curl https://your-domain/health
```

## 证书自动续期

acme.sh 安装时会自动配置 cron 定时任务，证书到期前自动续期，无需手动干预。

## 项目文件

```
ocronekey/
├── ocronkey.sh       # 主部署脚本（菜单化交互）
├── deploy_fix.sh     # 资源限制修复脚本（Docker CPU/内存 + Nginx 超时）
├── monitor_ocr.sh    # 错误监控脚本（503/504 自动记录日志）
└── README.md         # 项目说明
```

## 技术栈

- PaddleOCR（Docker 镜像：`xylplm/media-saber-paddle-ocr`）
- Nginx（反向代理 + SSL 终端）
- acme.sh（Let's Encrypt 证书管理）
- Docker
