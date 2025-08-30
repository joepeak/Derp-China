# 用法
## 云主机
购买国内的 VPS 就行，建议在 618、双 11 过节的时候买良心云，打折力度大。

## 域名
这个 Dockerfile 要求 Derp 服务器必须使用域名，请提前准备好自己的域名。备案可以不用做，建议在后期开不常见端口。

## HTTPs 证书(caddy 会自动处理，这一步可以省略)
建议通过 `Certbot` 等工具进行自动化 SSL 证书申请，可以参考 @frank-lam 的[使用 Certbot 为网站签发永久免费的 HTTPS 证书](https://www.frankfeekr.cn/2021/03/28/let-is-encrypt-cerbot-for-https/index.html)。

## 创建 tailscale 一次性认证 key
这个 key 是用来通过命令行将容器连接到你的 tailscale 里去的，前往 https://login.tailscale.com/admin/settings/keys 点击 "Generate auth key..." 创建，然后把 key 记录下来。

<img width="500" alt="image" src="https://github.com/S4kur4/Derp-China/assets/17521941/093b6608-9100-47b5-87d9-ac59f629d1b6">

## 修改配置
重命名 `.env.example` 为 `.env`, 修改 `.env` 文件里的参数，把 `TAILSCALE_DERP_HOSTNAME` 和 `DERP_DOMAIN` 改成你自己的域名，然后把刚刚记录下的 key 填进 `TAILSCALE_AUTH_KEY`。

## 启动
```
docker-compose up -d --build
```
第一次因为要 build 镜像，速度应该不会很快，但也不至于太慢。
容器启动后检查一下 Derp 服务是否在回环地址正常工作：

```
curl http://127.0.0.1:444
```
正常情况下会返回下面的内容：

```html
<html><body>
<h1>DERP</h1>
<p>
  This is a <a href="https://tailscale.com/">Tailscale</a> DERP server.
</p>
```
## 安装配置 Nginx 为反向代理(忽略这一步,因为容器会启动 caddy, 并已经配置正确)
这里不一定用 Nginx，换别的 caddy 什么的也行。只要配置个反代转发到 `http://127.0.0.1:444` 就行。公网端口建议开不常见端口，例如 442、444 等。

我的 Nginx 配置给你参考：

```
# setup a upstream point to Derp server
upstream @derp {
    server 127.0.0.1:444;
    keepalive 300;
}

# for socket.io (http upgrade)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# https server
server {
    listen 442 ssl http2;
    server_name derp.xxxx.xx;
    if ($host !~ ^derp\.xxxx\.xxx$) {
        return 444;
    }
    # setup certificate
    ssl_certificate /etc/nginx/certs/xxxx.xx.key;
    ssl_certificate_key /etc/nginx/certs/xxxx.xx.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

     # add hsts header
    add_header Strict-Transport-Security "max-age=63072000" always;
    keepalive_timeout 65;

    location / {
        proxy_http_version 1.1;

        # set header for proxy protocol
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # setup for image upload
        client_max_body_size 8192m;
        client_body_buffer_size 128k;
        proxy_redirect off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        proxy_send_timeout 300s;
        proxy_buffer_size 4k;
        proxy_buffers 4 32k;
        proxy_busy_buffers_size 64k;
        proxy_temp_file_write_size 64k;
        proxy_pass http://@derp;
    }
}
```
## 向 tailscale 添加 Derp
到 https://login.tailscale.com/admin/acls/file 添加你的 Derp 服务器，同样给出我的参考配置：

```
"derpMap": {
                "Regions": {
                        "901": {
                                "RegionID":   901,
                                "RegionCode": "myderp",
                                "RegionName": "myderp",
                                "Nodes": [
                                        {
                                                "Name":     "901a",
                                                "RegionID": 901,
                                                "HostName": "derp.xxxx.xx",
                        "STUNPort": 3478,
                                                "DERPPort": 443,
                                        },
                                ],
                        },
                },
        }
```
这里就结束了，最后使用 tailscale 命令行通过 `tailscale ping` 和 `tailscale status` 检查验证一下。
# 致谢
我是基于 @tijjjy 的 https://github.com/tijjjy/Tailscale-DERP-Docker 修改的，他在博客 [Self Host Tailscale Derp Server](https://tijjjy.me/2023-01-22/Self-Host-Tailscale-Derp-Server) 给大家详细 walkthrough 了，建议阅读，非常容易理解。