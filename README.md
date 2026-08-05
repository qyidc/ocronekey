# OCR 一站式部署脚本

基于 Docker + PaddleOCR + Nginx + Let's Encrypt SSL 的 OCR 识别服务一键部署方案。支持 **VPS 本地 OCR** 与 **Cloudflare Worker 同步（push 模式）**。

## 功能特性

- Docker 容器化部署 PaddleOCR 识别服务
- Nginx 反向代理 + `max_conns=1` 串行化（防止 1C1G VPS 并发挂死）
- 挂死自动恢复（Docker 健康检查 + 自动重启）
- Let's Encrypt 免费 SSL 证书自动申请与续期
- API Key 鉴权（可选）
- 可选：Worker 同步守护进程（VPS 轮询 Worker API → 本地 OCR → 回传结果）
- 交互式菜单管理
- 支持 Ubuntu / Debian / CentOS / Rocky / AlmaLinux

## 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/qyidc/ocronekey/main/ocronkey.sh | bash
```

菜单：

```
  OCR 一站式部署 v3.1

  1. 全新安装 OCR 服务
  2. 配置 Worker 同步     (VPS 轮询 Worker API)
  3. 同步服务管理         (启动/停止/重启)
  4. 查看配置信息
  5. 查看证书到期时间
  6. 证书续期
  7. 修改 API Key
  8. 查看同步日志
  9. 完全卸载
  0. 退出
```

### 非交互模式

```bash
curl -fsSL https://raw.githubusercontent.com/qyidc/ocronekey/main/ocronkey.sh | bash -s -- \
  --domain ocr.example.com --email admin@example.com --apikey my-secret -y
```

## 前置要求

| 要求 | 说明 |
|------|------|
| 系统 | Ubuntu / Debian / CentOS / Rocky / AlmaLinux |
| 用户 | root 权限 |
| 域名 | A 记录解析到 VPS IP |
| 端口 | 80、443 开放 |
| 内存 | >= 1GB |

## API 接口

| 接口 | 说明 |
|------|------|
| `GET /health` | 健康检查（无需 API Key） |
| `POST /general/file` | 通用识别（文件上传） |
| `POST /general/base64` | 通用识别（Base64） |
| `POST /captcha/base64` | 验证码识别 |

鉴权方式：

```bash
curl -H "X-API-Key: your-key" https://你的域名/general/base64
```

## Worker 同步架构（可选）

```
Worker ──→ PDF拆图 ──→ 写入任务队列
                            ↓ 轮询
VPS  ←── GET  /api/ocr-tasks/next      (取任务)
VPS  ←── GET  /api/ocr-tasks/{id}/image (下载图片)
VPS  ──→ POST /api/ocr-tasks/{id}/result (回传结果)
                            ↓
Worker ←── 获取结果 ──→ 返回用户
```

鉴权方式：所有三个 API 端点均使用 `X-Worker-Secret` 头认证，比 D1 API Token 更安全。

菜单选 **2. 配置 Worker 同步** 后输入 Worker 域名和 Secret，自动部署 systemd 守护进程。

### Worker 端需实现的端点

```
GET  /api/ocr-tasks/next                     → 200 + {id, documentId, pageNum}  或 204 (无任务)
GET  /api/ocr-tasks/{id}/image               → 200 + 图片二进制
POST /api/ocr-tasks/{id}/result              → 接收 {text: "识别文本"} 或 {error: "错误信息"}
```

所有端点需校验请求头 `X-Worker-Secret`。

## Cloudflare 注意事项

- DNS 设**仅 DNS（灰云）**
- SSL/TLS 设**「完全」（严格）**
- 免费套餐有 100s 代理超时限制，直连（灰云）不受限

## 项目文件

```
ocronekey/
├── ocronkey.sh       # 主脚本（部署 + 菜单 + 同步配置生成）
├── ocr-worker.sh     # Worker 端 VPS 脚本参考
├── deploy_fix.sh     # 修复脚本（重建容器 + Nginx upstream）
├── monitor_ocr.sh    # 错误监控（503/504 自动记录快照）
└── README.md
```

## 技术栈

- PaddleOCR（Docker：`xylplm/media-saber-paddle-ocr`）
- Nginx（反向代理 + SSL + upstream limit）
- acme.sh（Let's Encrypt 证书）
- systemd（同步守护进程）
