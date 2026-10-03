# 升级 Orca 后会不会失效

**简短回答：正常更新 Orca 不会让本机设置失效**，但新版桌面端有可能和自建服务端不兼容。养成习惯：**每次更新 Orca 后，把 relay 也升到同一版本**（见下面的「升级 relay」）。

## 什么不受影响

`macos/install-env.sh` 装的是一个 LaunchAgent（`~/Library/LaunchAgents/com.orca-selfhost.env.plist`），它在每次登录时用 `launchctl setenv` 把 `ORCA_CLOUD_API_URL` / `ORCA_CLOUD_CLIENT_ID` / `ORCA_RELAY_URL` 设进用户会话。Orca 更新只替换 `/Applications/Orca.app`，碰不到这个 LaunchAgent，所以更新后从 Dock / Spotlight 打开的 Orca 照样连自建 relay。

## 真正的风险：新版改了和服务端之间的协议

| 风险 | 可能性 | 表现 | 怎么修 |
|---|---|---|---|
| relay 协议更新：新版桌面端需要更新的 relay 功能，而服务端还是旧版本 | 中 | 能登录，但配对失败、连接异常或部分功能不工作 | [升级 relay](#升级-relay) |
| 登录接口变化：新版改了 `/v1/desktop/auth/*` 的请求或响应格式。`auth/server.mjs` 是照着当前桌面端代码写的，其中 `relay-token` 的响应用 `.strict()` 校验，多一个字段都不行 | 低到中 | 登录失败，或登录后一直连不上 relay | [改 auth](#改-auth) |
| 地址覆盖被取消：新版不再从环境变量读这些地址，或者正式包禁止覆盖 | 低 | Orca 悄悄连回官方，自建服务端日志里收不到任何请求 | 看新版源码 `src/main/orca-profiles/profile-cloud-auth-config.ts` 改成了什么 |

Orca 官方的约定（`docs/reference/remote-wire-compatibility.md`）是桌面端和服务端各自独立更新、版本不一致是常态，新字段必须向后兼容，所以大多数小版本更新不会出问题。

当前部署对应的版本，供以后比对：

- 服务端 relay 来自 `stablyai/orca` commit `a4606cc`（2026-09-30）。机器上用 `cat /opt/orca-selfhost/relay/ORCA_COMMIT` 查看。
- 当时的桌面端是 Orca 1.4.216。本机用 `defaults read /Applications/Orca.app/Contents/Info CFBundleShortVersionString` 查看。

## 更新后出问题的排查顺序

### 1. 先确认服务端本身是好的

```bash
cd ~/code/orca-selfhost
node smoke-test.mjs https://<你的分发域名>.cloudfront.net '<登录密码>'
```

- **9 项全过**：服务端没问题，问题出在新版桌面端的变化上。做第 2 步。
- **有失败**：问题在服务端（机器、CloudFront 或证书）。看日志：
  ```bash
  aws ssm start-session --target <InstanceId> --region ap-east-1
  sudo journalctl -u orca-relay -u orca-auth --since "1 hour ago"
  ```

### 2. 确认 Orca 还在连自建服务

```bash
pid=$(pgrep -f "Orca.app/Contents/MacOS/Orca" | head -1)
ps eww -p "$pid" | tr ' ' '\n' | grep '^ORCA_'
```

应该看到 3 个 `ORCA_*` 变量都指向你的分发域名。

- **看不到变量**：Orca 是在 LaunchAgent 生效前启动的，用 Cmd+Q 退出后重开。
- **变量在，但服务端日志里没有任何登录或 relay 请求**：就是上表的第 3 种风险。

### 3. 升级 relay

用最新的 Orca 源码重新打包并部署，让服务端和桌面端保持同一版本：

```bash
git -C ~/code/orca pull
cd ~/code/orca-selfhost
./build-artifacts.sh <BundleBucket> default ap-east-1
aws ssm send-command --region ap-east-1 --instance-ids <InstanceId> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/sbin/orca-selfhost-install"]'
```

- `<BundleBucket>` 和 `<InstanceId>` 在 CloudFormation 栈的 Outputs 里，或者用 `terraform -chdir=terraform-hk output` 查看。
- 重装只替换程序，`/var/lib/orca-selfhost/` 下的签名密钥和 SQLite 会保留，所以不需要重新登录或重新配对。
- 重装会重启服务，正在用的连接会断开一次，然后自动重连。
- 装完再跑一次第 1 步的冒烟测试。

### 4. 改 auth

如果升级 relay 后还是登录失败，就是登录接口变了。对照新版桌面端的这几个文件，调整 `auth/server.mjs`：

| 文件 | 内容 |
|---|---|
| `src/main/orca-profiles/profile-cloud-auth-config.ts` | 有哪些接口、读哪些环境变量 |
| `src/main/orca-profiles/profile-cloud-client.ts` | session / refresh / capabilities 的请求和响应格式 |
| `src/main/runtime/relay/relay-http-client.ts` | relay-token 的请求和响应格式（strict 校验） |
| `cloud/apps/relay/src/relay-token-verifier.ts` | relay 对 JWT claims 的要求 |

改完之后：

1. 重新打包部署（同第 3 步）。
2. 先在本机跑一遍冒烟测试。
3. 再用真实的 Orca 登录验证。

## 回退

如果一时修不好，可以先切回官方 relay，不影响继续使用 Orca：

```bash
./macos/install-env.sh --uninstall   # 然后 Cmd+Q 退出 Orca 再重开
```

修好后重新运行 `./macos/install-env.sh <分发域名>` 就切回自建。

如果只是 relay 升级出了问题，S3 桶开了版本控制，可以回退到上一版安装包：

```bash
aws s3api list-object-versions --bucket <BundleBucket> --prefix orca-selfhost.tar.gz \
  --query 'Versions[].[VersionId,LastModified]' --output text
aws s3api copy-object --bucket <BundleBucket> --key orca-selfhost.tar.gz \
  --copy-source "<BundleBucket>/orca-selfhost.tar.gz?versionId=<旧版本ID>"
# 再执行一次第 3 步里的 send-command
```
