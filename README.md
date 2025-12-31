# 自建 Tailscale DERP 中继服务器部署指南

## 📖 目录
1.  [原理概述](#原理概述)
2.  [前置准备](#前置准备)
3.  [文件结构与配置](#文件结构与配置)
4.  [部署步骤](#部署步骤)
5.  [验证与测试](#验证与测试)
6.  [故障排除](#故障排除)
7.  [维护建议](#维护建议)

## 🔍 原理概述

### 什么是 DERP？
DERP (Detour Encrypted Routing Protocol) 是 Tailscale 的专用中继协议，当 NAT 穿透（STUN）失败时，用于在 Tailscale 节点之间中继加密流量。

### 架构设计
```
公网客户端 (443端口) → Caddy (TLS终结/反向代理) → Derper 服务 (444端口，验证客户端)
                              ↓
                         STUN服务 (3478/udp)
```
- **Caddy**：处理 TLS 证书、反向代理，将 443 端口流量转发到 Derper
- **Derper**：核心 DERP 服务，提供中继功能
- **STUN**：辅助 NAT 穿透的服务

### 安全模型
- **`--verify-clients=true`**：只允许同一 Tailscale 网络的设备连接
- **端到端加密**：所有流量在客户端间已加密，中继无法解密
- **容器隔离**：使用 Docker 网络隔离服务

## 📦 前置准备

### 1. 服务器要求
- **云服务器**：1核1G以上，建议位于国内
- **开放端口**：
  - TCP 443 (HTTPS，必需)
  - TCP 80 (HTTP，用于证书申请，可选)
  - UDP 3478 (STUN，必需)
- **域名**：准备一个域名并解析到服务器 IP

### 2. Tailscale 准备
1.  访问 [Tailscale Admin Console](https://login.tailscale.com/admin)
2.  生成认证密钥：**Settings → Keys → Generate auth key**
    - 选择 "Reusable" 和 "Ephemeral"
    - 保存生成的 `tskey-xxx` 密钥

## 📁 文件结构与配置

### 项目目录结构
```
Derp-China/
├── docker-compose.yml          # Docker编排配置
├── .env                        # 环境变量配置
├── Caddyfile                   # Caddy反向代理配置
├── init.sh                     # Derper启动脚本
├── config/                     # Tailscale状态目录
├── caddy_data/                 # Caddy证书数据
└── caddy_config/               # Caddy配置数据
```

### 1. `.env` 环境变量文件
```bash
# 域名配置
TAILSCALE_DERP_HOSTNAME=derp.yourdomain.com
DERP_DOMAIN=derp.yourdomain.com

# Derper服务配置
TAILSCALE_DERP_ADDR=:444
TAILSCALE_DERP_VERIFY_CLIENTS=true
TAILSCALE_DERP_STUN_PORT=3478

# Tailscale认证（使用生成的密钥）
TAILSCALE_AUTH_KEY=tskey-auth-xxxxxx
```

### 2. `docker-compose.yml` 编排配置
```yaml
version: '3.8'

services:
  tailscale-derp:
    build: .
    container_name: tailscale-derp
    image: derpinchina:latest
    hostname: ${TAILSCALE_DERP_HOSTNAME}
    volumes:
      - /lib/modules:/lib/modules:ro
      - $PWD/config:/var/lib/tailscale
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      - TAILSCALE_DERP_HOSTNAME=${TAILSCALE_DERP_HOSTNAME}
      - TAILSCALE_DERP_ADDR=${TAILSCALE_DERP_ADDR}
      - TAILSCALE_DERP_VERIFY_CLIENTS=${TAILSCALE_DERP_VERIFY_CLIENTS}
      - TAILSCALE_DERP_STUN_PORT=${TAILSCALE_DERP_STUN_PORT}
      - TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
    ports:
      - 127.0.0.1:444:444/tcp        # 仅内部访问
      - 3478:3478/udp                # STUN公网访问
    restart: always
    devices:
      - /dev/net/tun:/dev/net/tun
    networks:
      - derp-network
    healthcheck:
      test: ["sh", "-c", "wget --no-verbose --tries=1 --spider http://localhost:444/derp/latency-check || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"      # HTTP（证书申请）
      - "443:443"    # HTTPS（主服务）
    volumes:
      - $PWD/Caddyfile:/etc/caddy/Caddyfile
      - $PWD/caddy_data:/data
      - $PWD/caddy_config:/config
    networks:
      - derp-network
    environment:
      - DERP_DOMAIN=${DERP_DOMAIN}
    depends_on:
      tailscale-derp:
        condition: service_healthy

networks:
  derp-network:
    driver: bridge
```

### 3. `Caddyfile` 反向代理配置
```caddyfile
# 将 example.com 替换为您的实际域名
{$DERP_DOMAIN} {
    # 反向代理到 tailscale-derp 服务的 444 端口
    reverse_proxy tailscale-derp:444 {
        # 保持主机头
        header_up Host {host}
        header_up X-Real-IP {remote}
    }

    # WebSocket 连接处理（DERP协议使用）
    @ws {
        path /derp*
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @ws tailscale-derp:444
}
```

### 4. `init.sh` 启动脚本
```bash
#!/usr/bin/env sh

# Start tailscaled and connect to tailnet
/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state &> /var/lib/tailscale/tailscaled_initial.log &
/usr/bin/tailscale up --accept-routes=true --accept-dns=true --auth-key $TAILSCALE_AUTH_KEY &> /var/lib/tailscale/tailscale_onboard.log &

# 等待 Tailscale 网络就绪
echo "Waiting for Tailscale network to be ready..."
for i in $(seq 1 30); do
    if tailscale status 2>&1 | grep -q "100\."; then
        echo "Tailscale network is ready."
        break
    fi
    sleep 2
    echo "Still waiting... ($i/30)"
done

# Start Tailscale derp server
/root/go/bin/derper --hostname=$TAILSCALE_DERP_HOSTNAME --a=$TAILSCALE_DERP_ADDR --stun-port=$TAILSCALE_DERP_STUN_PORT --verify-clients=$TAILSCALE_DERP_VERIFY_CLIENTS
```

### 5. `Dockerfile` 构建文件
```dockerfile
FROM alpine:latest

# 设置国内镜像源
ENV GOPROXY="https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct"
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装基础依赖
RUN apk add --no-cache curl iptables

# 安装 Go (兼容多架构)
RUN APKARCH="$(apk --print-arch)" && \
    case "${APKARCH}" in \
        x86_64) GOARCH=amd64 ;; \
        aarch64) GOARCH=arm64 ;; \
        armv7*|armhf) GOARCH=armv6l ;; \
        x86) GOARCH=386 ;; \
        ppc64le) GOARCH=ppc64le ;; \
        s390x) GOARCH=s390x ;; \
        *) echo "Unsupported architecture: ${APKARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://golang.google.cn/dl/go1.21.0.linux-${GOARCH}.tar.gz" -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm go.tar.gz

# 设置 Go 环境
ENV PATH="/usr/local/go/bin:$PATH"

# 安装 Tailscale DERPER
RUN go install tailscale.com/cmd/derper@latest

# 安装 Tailscale 客户端
RUN apk add --no-cache tailscale

# 复制启动脚本
COPY init.sh /init.sh
RUN chmod +x /init.sh

# 暴露端口
EXPOSE 444/tcp   # Derper 管理端口
EXPOSE 3478/udp  # STUN 端口

# 启动入口
ENTRYPOINT ["/init.sh"]
```

## 🚀 部署步骤

### 1. 初始化项目目录
```bash
mkdir Derp-China && cd Derp-China
mkdir config caddy_data caddy_config
```

### 2. 创建配置文件
按上述内容创建以下文件：
- `.env` (修改为自己的域名和密钥)
- `docker-compose.yml`
- `Caddyfile`
- `init.sh`
- `Dockerfile`

### 3. 构建并启动服务
```bash
# 构建 Derper 镜像
docker-compose build

# 启动所有服务
docker-compose up -d

# 查看启动状态
docker-compose ps
docker-compose logs -f
```

### 4. 配置 Tailscale ACL
在 Tailscale Admin Console 的 **Access Controls** 页面添加：

```json
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "cn-gz",
        "RegionName": "Guangzhou (China)",
        "Nodes": [
          {
            "Name": "1",
            "RegionID": 900,
            "HostName": "derp.yourdomain.com",
            "DERPPort": 443
          }
        ]
      }
    }
  }
}
```

### 5. 客户端应用配置
```bash
# 强制客户端更新 ACL
sudo tailscale up --force-reauth
```

## ✅ 验证与测试

### 1. 服务状态检查
```bash
# 检查容器健康状态
docker-compose ps

# 查看 Derper 日志
docker logs -f tailscale-derp

# 查看 Caddy 日志
docker logs -f caddy
```

### 2. 网络连通性测试
```bash
# 测试 DERP 健康端点
curl -v https://derp.yourdomain.com/derp/latency-check

# 在客户端执行网络检查
tailscale netcheck --verbose

# 预期输出应包含：
# Nearest DERP: Guangzhou (China)
# DERP latency: - cn-gz: xxms (derp900, Guangzhou (China))
```

### 3. 端到端连接测试
```bash
# 获取服务器 Tailscale IP
tailscale status

# 从客户端 ping 服务器
tailscale ping --verbose 100.x.x.x

# 观察是否通过 DERP 中继
# 预期输出: via DERP(cn-gz)
```

## 🔧 故障排除

### 常见问题及解决方案

| 问题现象 | 可能原因 | 解决方案 |
|---------|---------|---------|
| `Weird upgrade: "{>upgrade}"` | 云服务商扫描或恶意探测 | 确保 `--verify-clients=true` 生效 |
| `connect: connection refused` | 容器间网络不通或启动顺序问题 | 检查健康检查和依赖配置 |
| `peer nodekey not authorized` | 验证失败，客户端不在同一Tailnet | 确保客户端和服务器在同一Tailscale网络 |
| 证书申请失败 | 域名解析或端口问题 | 检查80/443端口是否开放，域名解析是否正确 |
| 高延迟或连接不稳定 | 网络质量或服务器性能 | 考虑升级服务器配置或选择更好的网络区域 |

### 诊断命令集
```bash
# 1. 网络诊断
docker exec caddy nc -zv tailscale-derp 444
docker inspect tailscale-derp | grep IPAddress

# 2. 进程检查
docker exec tailscale-derp ps aux | grep derper
docker exec tailscale-derp tailscale status

# 3. 端口监听检查
docker exec tailscale-derp netstat -tlnp | grep :444

# 4. 日志分析
docker-compose logs --tail=50 tailscale-derp
docker-compose logs --tail=50 caddy

# 5. 客户端诊断
tailscale debug derp
tailscale ping --verbose derp.yourdomain.com
```

## 🛠️ 维护建议

### 日常维护
1.  **日志监控**：定期检查服务日志
2.  **证书更新**：Caddy 自动管理 Let's Encrypt 证书
3.  **备份配置**：定期备份 `.env`、`docker-compose.yml` 等配置文件

### 性能优化
```bash
# 调整网络缓冲区（可选）
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400

# 持久化配置
echo "net.core.rmem_max=26214400" >> /etc/sysctl.conf
echo "net.core.wmem_max=26214400" >> /etc/sysctl.conf
```

### 更新与升级
```bash
# 更新 Derper 版本
docker-compose build --no-cache
docker-compose up -d

# 更新 Caddy
docker-compose pull caddy
docker-compose up -d
```

### 安全建议
1.  **定期更新**：保持 Docker 镜像和基础系统更新
2.  **访问控制**：使用 `--verify-clients=true` 限制访问
3.  **网络隔离**：确保防火墙只开放必要端口
4.  **监控告警**：设置容器异常重启告警

## 📚 附录

### 端口说明
- **443/tcp**：Caddy HTTPS 服务（对外）
- **80/tcp**：Caddy HTTP 服务（证书申请）
- **444/tcp**：Derper 管理端口（仅内部）
- **3478/udp**：STUN 服务（NAT穿透）

### 资源参考
- [Tailscale 官方文档](https://tailscale.com/kb/)
- [DERP 协议说明](https://tailscale.com/blog/how-tailscale-works/#encrypted-tcp-relays-derp)
- [Caddy 反向代理配置](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)

---

**部署完成！** 你现在拥有一个完全自控的 Tailscale DERP 中继服务器，可以显著提升国内设备间的连接速度和稳定性。