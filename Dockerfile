FROM alpine:latest

# 设置环境变量
# 使用国内 Go 模块代理
ENV GOPROXY="https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct"
# 设置 Alpine 软件源为国内镜像
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装基础依赖
RUN apk add --no-cache curl iptables

# 安装 GO - 使用国内镜像和固定版本
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
    # 使用国内镜像站下载Go安装包（固定版本为1.21.0）
    curl -fsSL "https://golang.google.cn/dl/go1.24.6.linux-${GOARCH}.tar.gz" -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && \
    rm go.tar.gz

# 设置Go环境变量
ENV PATH="/usr/local/go/bin:$PATH"

# 安装 Tailscale DERPER
RUN go install tailscale.com/cmd/derper@latest

# 安装 Tailscale
RUN apk add --no-cache tailscale

# 复制初始化脚本
COPY init.sh /init.sh
RUN chmod +x /init.sh

# 暴露端口
# Derper Web 端口
EXPOSE 444/tcp
# STUN 端口
EXPOSE 3478/udp

# 设置入口点
ENTRYPOINT ["/init.sh"]
