# OCR 一站式部署脚本

基于 Docker + PaddleOCR + Nginx + Let's Encrypt SSL 的 OCR 识别服务一键部署方案。支持 **VPS 本地 OCR** 与 **Cloudflare Worker + D1 + R2 同步**。

## 功能特性

- Docker 容器化部署 PaddleOCR 识别服务
- Nginx 反向代理 + `max_conns=1` 串行化（防止 1C1G VPS 并发挂死）
- 挂死自动恢复（Docker 健康检查 + 自动重启）
- Let's Encrypt 免费 SSL 证书自动申请与续期
- API Key 鉴权（可选）
- 可选：Cloudflare Worker 同步（D1 任务队列 + R2 图片 + VPS 自动拉取 OCR）
- 交互式菜单管理
- 支持 Ubuntu / Debian / CentOS / Rocky / AlmaLinux

## 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/qyidc/ocronekey/main/ocronkey.sh | bash
```

菜单：

```
  OCR 一站式部署 v3.0
  状态: 已安装 (域名: ocr.example.com) | 同步: 运行中

  1. 全新安装 OCR 服务
  2. 配置 Worker 同步     (D1 + R2 对接)
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
| 内存 | >= 1GB（推荐 2GB+） |

## API 接口

| 接口 | 说明 |
|------|------|
| `GET /health` | 健康检查 |
| `POST /general/file` | 通用识别（文件上传） |
| `POST /general/base64` | 通用识别（Base64） |
| `POST /captcha/base64` | 验证码识别 |

## Worker 同步架构（可选）

```
Worker ──→ PDF拆成图 ──→ 上传 R2 ──→ INSERT D1 (pending)
                                            ↓ 轮询
VPS  ←── SELECT D1 pending ←── 从 R2 拉图 ──→ OCR ──→ UPDATE D1 (done)
                                            ↓ 轮询
Worker ←── SELECT D1 done ←── 返回结果
```

菜单选 **2. 配置 Worker 同步** 后按提示输入 CF 凭据即可自动部署守护进程。

Worker 端写入示例：

```sql
INSERT INTO ocr_tasks (id, image_url, status) VALUES ('task-001', 'https://r2.example.com/page1.png', 'pending');
```

## Cloudflare 注意事项

- DNS 设**仅 DNS（灰云）**
- SSL/TLS 设**「完全」**

## 项目文件

```
ocronekey/
├── ocronkey.sh       # 主脚本（部署 + 菜单 + 同步配置）
├── deploy_fix.sh     # 修复脚本（重建容器 + Nginx upstream）
├── monitor_ocr.sh    # 错误监控（503/504 自动记录快照）
└── README.md
```

## 技术栈

- PaddleOCR（Docker：`xylplm/media-saber-paddle-ocr`）
- Nginx（反向代理 + SSL）
- acme.sh（Let's Encrypt 证书）
- Cloudflare D1 / R2（Worker 同步）
