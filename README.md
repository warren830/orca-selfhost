# orca-selfhost

自建 [Orca](https://github.com/stablyai/orca) 手机 relay：手机和桌面不再经过官方的 `relay.onorca.dev`，而是连到你自己 AWS 账号里的 relay。

- **不需要域名、不需要备案、不需要自己签证书**：入口就是 CloudFront 默认域名 `dxxxx.cloudfront.net`，自带公网信任证书。
- **机器零公网暴露**：EC2 在私有子网、没有公网 IP、子网没有出网路由；只有 CloudFront 能通过 VPC Origin 访问它，管理走 SSM。
- **单用户登录**：用一个很小的 auth 服务替代 Orca 官方私有的 Orca Cloud 登录服务，浏览器里输一次密码即可。

```
手机 / Mac ──HTTPS/WSS──▶ CloudFront (dxxxx.cloudfront.net)
                             │  /v1/admin/*            → 边缘直接 404（CloudFront Function）
                             │  /v1/desktop/*, /.well-known/* → VPC origin :8787  auth
                             │  其他                    → VPC origin :8080  relay
                             ▼
                 私有子网 EC2（无公网 IP，t4g.small）
                   ├─ orca-relay  (stablyai/orca cloud/apps/relay，combined 模式，SQLite)
                   └─ orca-auth   (auth/server.mjs，签发 relay JWT)
                 S3 网关端点：拉安装包 · SSM 接口端点：运维
```

## 一键部署（CloudFormation）

前置：本机有 `aws` CLI、Node 22+、`pnpm`，并且把 Orca 源码 clone 到 `~/code/orca`（打包脚本要从里面构建 relay）。

```bash
git clone https://github.com/stablyai/orca.git ~/code/orca
git clone git@github.com:warren830/orca-selfhost.git ~/code/orca-selfhost
cd ~/code/orca-selfhost

# 栈名、区域、AWS profile；区域要有默认 VPC
./cloudformation/deploy.sh orca-relay ap-east-1 default
```

脚本会：查默认 VPC / 可用区 / CloudFront 回源前缀列表 → 生成登录密码 → 部署 `cloudformation/orca-relay.yaml` → 在本机构建安装包（relay + auth + Node 24 运行时，arm64）上传到栈里的 S3 桶。EC2 启动后会自己拉包安装（几分钟）。

最后会打印 **Relay URL** 和 **登录密码（只显示一次，记下来）**。

验证（9 项全过才算部署成功）：

```bash
node smoke-test.mjs https://dxxxx.cloudfront.net '<登录密码>'
```

> 也可以用 Terraform：`terraform-hk/` 是同一套架构（`terraform apply` 后同样用 `build-artifacts.sh` 上传安装包）。两者二选一，不要同时部署到同一个 VPC——SSM 接口端点的私有 DNS 会冲突。

## 桌面端接入

1. 在 Clash 等代理软件里给 `dxxxx.cloudfront.net` 加 **DIRECT** 规则（只加这一个分发域名，不要整个 `cloudfront.net`）。走代理时一旦切节点，WebSocket 长连接会被掐断。

   **Clash Party（mihomo-party）**：用全局覆写，订阅更新后也不会丢。
   1. Clash Party → 覆写 → 新建 → JavaScript，名字随意（例如「Orca 自建 relay 直连」），内容如下：
      ```js
      function main(config) {
        config.rules = ['DOMAIN,dxxxx.cloudfront.net,DIRECT'].concat(config.rules || [])
        return config
      }
      ```
   2. 打开这条覆写的「全局」开关，保存。Clash Party 会重新生成配置并生效。
   3. 验证：在「规则」页搜索 `cloudfront.net`，它应该排在第一条、目标是 `DIRECT`。也可以在终端里执行 `curl -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}\n' https://dxxxx.cloudfront.net/health`（返回 200），然后在「连接」页确认这条连接走的是 `DIRECT`。

   **其他 Clash / mihomo 客户端**：把 `DOMAIN,dxxxx.cloudfront.net,DIRECT` 加到配置文件 `rules:` 的第一行。

   手机上如果也开着代理，同样要加这条规则，或者测试时先关掉代理。
2. 一次性设置本机（之后从 Dock / Spotlight 正常打开 Orca 就行，重启电脑也一直有效）：
   ```bash
   ./macos/install-env.sh dxxxx.cloudfront.net
   ```
   Orca 只从环境变量读 `ORCA_CLOUD_API_URL` / `ORCA_CLOUD_CLIENT_ID` / `ORCA_RELAY_URL`，没有设置界面。这个脚本装一个 LaunchAgent，每次登录时用 `launchctl setenv` 把它们设进用户会话，所有 GUI 启动的 Orca 都会继承。装完后 **Cmd+Q 退出 Orca 再打开一次**才生效（已经在运行的进程不会更新）。打包版 Orca 只接受 HTTPS 地址，所以必须先部署好再接入。

   切回官方 relay：`./macos/install-env.sh --uninstall`，再重开 Orca。
3. 在 Orca 里**新建一个本地 profile** 再登录（换了登录服务后，官方账号的登录态会失效）。浏览器会打开 “Orca relay sign-in”，输入密码。
4. 移动端配对选 **Anywhere / Relay**，手机扫码即可——二维码里带了 relay 地址，手机不用任何设置。

## 测试清单

| 项目 | 做法 | 通过标准 |
|---|---|---|
| 登录 | 第 3 步 | Orca 显示已登录 |
| 配对 | 第 4 步 | 手机能打开会话 |
| 延迟 | 手机上敲字，Wi-Fi 和 4G/5G 各试一次 | 回显可接受 |
| 长连接 | 手机锁屏 15 分钟后再打开 | 会话还在或自动重连 |
| 断网恢复 | 飞行模式 10 秒再关掉 | 自动恢复 |

relay 每 15 秒有一次应用层心跳，CloudFront 的 WebSocket 空闲超时不会触发。

## 升级 Orca 后会不会失效

更新 Orca.app **不会**让本机设置失效：LaunchAgent 和 App 本身无关。真正要防的是**新版桌面端和自建服务端协议不兼容**，比如需要更新的 relay、登录接口格式变了。

**习惯：每次更新 Orca 后，把 relay 也升到同一版本**（就是下面「运维」里的升级 relay 三条命令），再跑一次 `smoke-test.mjs`。

出问题时的排查顺序、风险清单和回退办法见 **[docs/upgrading.md](docs/upgrading.md)**。

## 运维

```bash
# 在机器上执行命令（没有 SSH，只走 SSM）
aws ssm start-session --target <InstanceId> --region ap-east-1

# 看日志
sudo journalctl -u orca-relay -u orca-auth -f

# 升级 relay：更新 Orca 源码后重新打包上传，再让机器重装
git -C ~/code/orca pull
./build-artifacts.sh <BundleBucket> default ap-east-1
aws ssm send-command --region ap-east-1 --instance-ids <InstanceId> \
  --document-name AWS-RunShellScript --parameters 'commands=["/usr/local/sbin/orca-selfhost-install"]'
```

- 数据在 `/var/lib/orca-selfhost/`：auth 的签名密钥（首次启动生成）、relay 的 SQLite。重建机器会让桌面端需要重新登录、手机重新配对。
- 改密码：在机器上改 `/etc/orca-selfhost/site.env` 里的 `OWNER_PASSWORD`，再执行 `sudo /usr/local/sbin/orca-selfhost-install`。（改 CloudFormation 参数或 Terraform 的 `random_password` 不会生效：user data 只在实例首次启动时执行。）
- 删除：`aws cloudformation delete-stack --stack-name orca-relay`（先清空 S3 桶的所有版本），或 `terraform destroy`。

费用（香港，按月）：3 个 SSM 接口端点 ≈ $25，t4g.small + 20GB gp3 ≈ $15，CloudFront 按流量计（个人使用很少）。合计约 $40–50。不需要 SSM 远程运维时可以删掉接口端点省掉大头。

## 安全设计

- auth：PKCE（S256）校验、授权码一次性、5 分钟过期；重定向地址只允许 `http://127.0.0.1:*/auth/callback`；登录失败 15 分钟内 10 次即限流。
- relay token：ES256 JWT，15 分钟有效；只给能证明持有对应主机公钥的 `relayHostId` 签（`relayHostId = sha256(公钥)` 的前 16 位）。
- access / refresh token 与 relay token 用不同的密钥签发；relay 只接受 `aud=orca-relay` + `purpose=host-control` 的 token。
- relay 的 `/v1/admin/*` 运维接口在 CloudFront 边缘就返回 404；即便漏过，它们也只认 Google 签发的服务账号身份，这里配置的是不存在的占位账号。
- 密码只在 CloudFormation 的 NoEcho 参数 / Terraform state 和机器上的 `/etc/orca-selfhost/*.env`（0600）里。**不要把 tfstate 提交到仓库**（已在 `.gitignore`）。

## 为什么是这个架构（踩过的坑）

1. **Orca 的登录服务没开源**。relay 本身在 `stablyai/orca` 的 `cloud/apps/relay`，但桌面端连 relay 前必须先从 Orca Cloud 拿一个 ES256 的 relay token，那部分在私有仓库。`auth/server.mjs` 按桌面端代码里的接口契约（`src/main/orca-profiles/profile-cloud-*.ts`、`src/main/runtime/relay/relay-http-client.ts`）实现了最小可用的替代品。
2. **约束：机器不能有公网暴露，只有 CloudFront 可以**。所以没有 EIP、没有对 0.0.0.0/0 开放的安全组。
3. **试过放 AWS 中国区（宁夏），走不通**：
   - 中国区 CloudFront 的默认域名 `*.cloudfront.cn` 用的是 Amazon 内部 CA 证书（`internal.cloudfront.cn`），手机和 Orca 都不信任，且直接访问返回 403。
   - 必须绑定**在 AWS 中国做过接入备案**的域名 + 上传到 IAM 的证书。在腾讯等其他接入商备案不算——实测这种域名的 SNI 在大陆网络上会被直接黑洞（TCP 通，TLS 握手被切断）。
   - 如果你的域名在 AWS 中国做过接入备案，`terraform-cn/` + `terraform-cn/renew-cert.sh`（acme.sh + DNSPod DNS-01，自动续期并轮换 CloudFront 证书）可以直接用，延迟会比海外低很多。
4. **香港 + 海外 CloudFront 的实际延迟取决于你的运营商**。CloudFront 的边缘节点由 AWS 按线路质量调度，不能手动指定。实测云南联通被调度到美国西海岸节点（~230ms），强行连香港节点反而 430–500ms（联通普通国际出口绕路）。电信 CN2 / 移动通常会被分到香港，延迟几十毫秒。
5. **安全组规则上限**：CloudFront 回源前缀列表一条规则就占 ~55 条配额（上限 60），所以 relay 和 auth 两个端口合成一条 8080–8787 的规则；Terraform 版本改为放行 CloudFront 自动创建的 `CloudFront-VPCOrigins-Service-SG`。
6. **国内拉不动 GitHub / npm / Docker Hub**，所以机器上不构建任何东西：Node 运行时、relay、auth 全在本机打好包（`build-artifacts.sh`），机器只从同区域 S3 拉。

## 目录

| 路径 | 说明 |
|---|---|
| `cloudformation/` | **推荐**：一键部署模板 + `deploy.sh` |
| `terraform-hk/` | 同架构的 Terraform 版本（当前线上用的是这个） |
| `terraform-cn/` | AWS 中国区版本（CloudFront 中国 + ALB + IAM 证书），需要 AWS 中国接入备案的域名 |
| `auth/server.mjs` | 单用户登录 + relay token 签发 |
| `host/` | 机器上的安装脚本和 systemd 单元 |
| `build-artifacts.sh` | 本机打包并上传到 S3 |
| `docs/upgrading.md` | 升级 Orca / relay 的兼容性说明与排查 |
| `smoke-test.mjs` | 端到端验证（模拟桌面端完整流程 + WebSocket 升级） |
| `macos/install-env.sh` | 本机一次性设置：让 Orca 始终连自建 relay（LaunchAgent） |
