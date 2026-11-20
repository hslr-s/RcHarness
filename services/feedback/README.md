# RcHarness 反馈服务

Worker 接收 `POST /api/feedback`，请求体为 `{ "title": "…", "body": "…" }`。成功时以 `201` 返回 `number` 和 `html_url`。Cloudflare 按来源 IP 和边缘位置限制请求频率。代码只向 `tokenzz-vip/RcHarness` 创建 Issue。

1. 创建 GitHub App，关闭 Webhook，授予仓库级 `Issues: Read and write` 权限，并仅安装到 `tokenzz-vip/RcHarness`。记下 Client ID 和 Installation ID，并生成 PEM 私钥。[GitHub App 认证](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
2. 从本目录用 Wrangler 部署 Worker，并在 Cloudflare 中设置 `GITHUB_APP_CLIENT_ID`、`GITHUB_INSTALLATION_ID` 和 `GITHUB_APP_PRIVATE_KEY`。私钥保存在 Worker Secrets 中。[Cloudflare Workers Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)

   ```sh
   npx wrangler deploy
   npx wrangler secret put GITHUB_APP_CLIENT_ID
   npx wrangler secret put GITHUB_INSTALLATION_ID
   npx wrangler secret put GITHUB_APP_PRIVATE_KEY < /path/to/app.private-key.pem
   ```

3. 构建时将 `RC_HARNESS_FEEDBACK_URL` 设成 Worker 的完整 HTTPS 地址，例如 `https://rcharness-feedback.<subdomain>.workers.dev/api/feedback`。`scripts/build_app.sh` 会在签名前把地址写入应用。未提供地址的构建会使用 GitHub 预填页面。
