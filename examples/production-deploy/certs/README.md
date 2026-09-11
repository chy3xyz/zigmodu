# 自签证书（仅本地联调）

`docker compose up` 会把本目录挂到 nginx 的 `/etc/nginx/certs`。生成一次即可：

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout privkey.pem -out fullchain.pem \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

生产用真实证书（certbot / 企业 CA / 云 LB 托管），并把私钥放进 Secret 管理，
不要提交进仓库（本目录下的 `*.pem` 已被 `.gitignore` 忽略）。
