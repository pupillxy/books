# 小说服务端 NAS 部署脚本

> 改编自 music-server 的部署流程，目标、路径、上传方式均已适配本项目
> NAS：`lin@192.168.31.16:1622`（docker 在 `/usr/local/bin/docker`）
> 部署目录：`/volume2/docker/books/`（compose.yaml + src/ + data/ + books/）
> 服务地址：`http://192.168.31.16:18004`（账号 admin / admin123）

## 使用方式

整段复制到 PowerShell 运行即可。任一步校验失败会立即中止，不会拿坏包构建。

```powershell
cd d:\dev\xiaoshuo\server

# 1. 编译 Linux amd64 静态二进制（每次部署前必须重编，防止二进制落后于源码）
$env:CGO_ENABLED='0'; $env:GOOS='linux'; $env:GOARCH='amd64'
go build -trimpath -ldflags "-s -w" -o deploy/xiaoshuo-server ./cmd/server
if ($LASTEXITCODE -ne 0) { "❌ 编译失败"; exit 1 }

# 2. 打包并算 md5（二进制 + Dockerfile 平铺在包根，Dockerfile 的 COPY 路径才能对上）
tar -czf "$env:TEMP\xs-deploy.tgz" -C d:\dev\xiaoshuo\server\deploy xiaoshuo-server Dockerfile
$md5 = (certutil -hashfile "$env:TEMP\xs-deploy.tgz" MD5 | Select-Object -Skip 1 -First 1) -replace ' ',''
"本地 md5: $md5"

# 3. base64 后经 ssh stdin 流式上传（单连接传整个文件）
#    ⚠️ 不要用 echo 分块追加：Windows ssh.exe 单条命令行超 32KB 直接启动失败
#    （分块方式如必须使用，每块不得超过 19000 字符且每块后必须检查 $LASTEXITCODE）
[IO.File]::WriteAllText("$env:TEMP\xs-deploy.b64", [Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:TEMP\xs-deploy.tgz")))
ssh -p 1622 lin@192.168.31.16 "rm -f /tmp/xs-deploy.b64 /tmp/xs-deploy.tgz"
if ($LASTEXITCODE -ne 0) { "❌ ssh 连接失败"; exit 1 }
$p = Start-Process ssh -ArgumentList '-p','1622','lin@192.168.31.16','cat > /tmp/xs-deploy.b64' `
    -RedirectStandardInput "$env:TEMP\xs-deploy.b64" `
    -RedirectStandardOutput "$env:TEMP\ssh-out.txt" `
    -RedirectStandardError "$env:TEMP\ssh-err.txt" -NoNewWindow -Wait -PassThru
if ($p.ExitCode -ne 0) { "❌ 上传失败: $(Get-Content "$env:TEMP\ssh-err.txt")"; exit 1 }

# 4. 校验：先比对字节数（stdin 原样写入、无追加换行，应完全相等），再比对 md5
#    字节数不对说明丢块/截断；md5 不一致说明内容损坏——两者都直接中止，不拿坏包构建
$b64Len = ([IO.File]::ReadAllText("$env:TEMP\xs-deploy.b64")).Length
$remoteLen = ssh -p 1622 lin@192.168.31.16 "wc -c < /tmp/xs-deploy.b64"
if (-not $remoteLen -or [long]$remoteLen -ne $b64Len) { "❌ 字节数不一致（本地 $b64Len vs 远端 $remoteLen），传输不完整"; exit 1 }
$remote = (ssh -p 1622 lin@192.168.31.16 "base64 -d /tmp/xs-deploy.b64 > /tmp/xs-deploy.tgz && md5sum /tmp/xs-deploy.tgz")
if (-not $remote -or -not $remote.Contains($md5)) { "❌ md5 不一致，传输损坏"; exit 1 }
"✅ md5 校验通过: $md5"

# 5. 解压到生产 src/ 并创建镜像（构建完成自动导入 NAS 镜像库）
ssh -p 1622 lin@192.168.31.16 "rm -rf /volume2/docker/books/src && mkdir -p /volume2/docker/books/src && tar -xzf /tmp/xs-deploy.tgz -C /volume2/docker/books/src && rm -f /tmp/xs-deploy.b64 /tmp/xs-deploy.tgz && /usr/local/bin/docker build -t xiaoshuo-server:latest /volume2/docker/books/src 2>&1 | tail -n 3"

# 6. 重建容器并查看启动日志
#    ⚠️ 必须带 --no-deps：TND 容器由独立的 book 项目管理（网络 book_default），
#    compose 全量 up 会因容器名冲突报错；跨项目互通靠 compose.yaml 里的
#    networks: tnd: external: name: book_default 声明
ssh -p 1622 lin@192.168.31.16 "cd /volume2/docker/books && /usr/local/bin/docker compose up -d --no-deps --force-recreate xiaoshuo-server 2>&1 | tail -n 2; sleep 3; /usr/local/bin/docker logs xiaoshuo-server 2>&1 | tail -n 6"

"✅ 代码已上传，服务已重建并启动"
```

## NAS 上的目录结构

```
/volume2/docker/books/
├── compose.yaml      # TND + xiaoshuo-server 两个服务（改动前备份为 compose.yaml.bak）
├── src/              # 部署物（xiaoshuo-server 二进制 + Dockerfile），每次部署覆盖
├── data/             # SQLite 数据库（xiaoshuo.db）
└── books/            # 与 TND 容器共享的下载目录，扫描导入的来源
```

## compose.yaml 关键配置（xiaoshuo-server 服务）

```yaml
  xiaoshuo-server:
    image: xiaoshuo-server:latest
    container_name: xiaoshuo-server
    restart: unless-stopped
    ports:
      - "18004:8080"
    environment:
      - XS_TND_URL=http://tomato-novel-downloader:18423   # 容器名互访（book_default 网络）
      - XS_DOWNLOAD_DIR=/app/books                        # 与 TND 共享 ./books 卷
      - XS_JWT_SECRET=<固定随机串，写在 NAS compose 里>
      - XS_FQ_ORACLE=http://192.168.31.102:8765           # 番茄 App 源（PC 模拟器签名 oracle），已配置 2026-09-29
    volumes:
      - ./data:/data
      - ./books:/app/books
    networks:
      - default
      - tnd          # external: name: book_default

networks:
  tnd:
    external: true
    name: book_default
```

> **XS_FQ_ORACLE 说明**（2026-09-29 新增，已写入 NAS compose，改配置前备份为 compose.yaml.bak）：
> 指向 PC 上的番茄签名 oracle（`_reference/fqemu/oracle_server.py`，端口 8765）。
> - **它只写在 NAS compose 里**，部署脚本不会碰它，重部署不会丢。
> - 依赖三件事同时在线：PC 开着模拟器（fqsig）+ oracle_server.py 在跑 + Windows 防火墙放行 8765（已放行，规则名 "FQ Oracle 8765"）。
> - **PC 重启后**：双击 `_reference/fqemu/start_fq_oracle.bat` 一键拉起，别关窗口。
> - **PC 局域网 IP 变了**（DHCP）：改 NAS compose 里这一行 → `docker compose up -d --no-deps --force-recreate xiaoshuo-server`；建议路由器给 PC 绑静态 DHCP 租约（当前 192.168.31.102）。
> - oracle 没跑时：书城的「推荐榜」Tab 报错重试，完本榜/新书榜/巅峰榜和其余功能不受影响（网页端 A 方案兜底）。
> - 群晖本机跑 redroid 不可行（内核缺 binder 模块），oracle 维持 PC 承载。

## 部署脚本

**用 `deploy/deploy.ps1`**（2026-09-29 修正版，PowerShell 5.1 直接可跑）：
- 修复了原文档脚本的三个坑：`&&` 分隔符（PS 5.1 不支持）、UTF-8 无 BOM 被 PS 5.1 当 GBK 解析、Git Bash 的 GNU tar 打包 Windows 路径失败导致传了旧包（md5 校验只能证明"传输完整"，不能证明"包是新的"）。
- 打包显式使用 `$env:SystemRoot\System32\tar.exe`。

```powershell
powershell -ExecutionPolicy Bypass -File d:\dev\xiaoshuo\server\deploy\deploy.ps1
```

部署前检查：模拟器和 oracle 在跑（PC 浏览器开 http://127.0.0.1:8765/health 应返回 ok）；部署后看日志确认有"番茄 App 源已启用"。

## 常用运维命令

```powershell
# 看日志
ssh -p 1622 lin@192.168.31.16 "/usr/local/bin/docker logs -f xiaoshuo-server"

# 重启（不重新部署）
ssh -p 1622 lin@192.168.31.16 "cd /volume2/docker/books && /usr/local/bin/docker compose restart xiaoshuo-server"

# 手动触发扫描导入（App 端 我的 → 扫描导入 亦可）
$token = (Invoke-RestMethod -Uri 'http://192.168.31.16:18004/api/auth/login' -Method Post -ContentType 'application/json' -Body '{"username":"admin","password":"admin123"}').token
Invoke-RestMethod -Uri 'http://192.168.31.16:18004/api/admin/scan' -Method Post -Headers @{ Authorization = "Bearer $token" }
```
