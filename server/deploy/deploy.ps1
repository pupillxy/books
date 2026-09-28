cd d:\dev\xiaoshuo\server

# 1. build linux amd64
$env:CGO_ENABLED='0'; $env:GOOS='linux'; $env:GOARCH='amd64'
go build -trimpath -ldflags "-s -w" -o deploy/xiaoshuo-server ./cmd/server
if ($LASTEXITCODE -ne 0) { "[FAIL] build"; exit 1 }

# 2. pack + md5（显式用 Windows 系统自带 bsdtar：Git Bash 的 GNU tar 处理不了 Windows 路径）
& "$env:SystemRoot\System32\tar.exe" -czf "$env:TEMP\xs-deploy.tgz" -C d:\dev\xiaoshuo\server\deploy xiaoshuo-server Dockerfile
if ($LASTEXITCODE -ne 0) { "[FAIL] pack"; exit 1 }
$md5 = (certutil -hashfile "$env:TEMP\xs-deploy.tgz" MD5 | Select-Object -Skip 1 -First 1) -replace ' ',''
"local md5: $md5"

# 3. upload
[IO.File]::WriteAllText("$env:TEMP\xs-deploy.b64", [Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:TEMP\xs-deploy.tgz")))
ssh -p 1622 lin@192.168.31.16 "rm -f /tmp/xs-deploy.b64 /tmp/xs-deploy.tgz"
if ($LASTEXITCODE -ne 0) { "[FAIL] ssh connect"; exit 1 }
$p = Start-Process ssh -ArgumentList '-p','1622','lin@192.168.31.16','cat > /tmp/xs-deploy.b64' -RedirectStandardInput "$env:TEMP\xs-deploy.b64" -RedirectStandardOutput "$env:TEMP\ssh-out.txt" -RedirectStandardError "$env:TEMP\ssh-err.txt" -NoNewWindow -Wait -PassThru
if ($p.ExitCode -ne 0) { "[FAIL] upload"; exit 1 }

# 4. verify
$b64Len = ([IO.File]::ReadAllText("$env:TEMP\xs-deploy.b64")).Length
$remoteLen = ssh -p 1622 lin@192.168.31.16 "wc -c < /tmp/xs-deploy.b64"
if (-not $remoteLen -or [long]$remoteLen -ne $b64Len) { "[FAIL] size mismatch"; exit 1 }
ssh -p 1622 lin@192.168.31.16 "base64 -d /tmp/xs-deploy.b64 > /tmp/xs-deploy.tgz"
if ($LASTEXITCODE -ne 0) { "[FAIL] remote decode"; exit 1 }
$remote = ssh -p 1622 lin@192.168.31.16 "md5sum /tmp/xs-deploy.tgz"
if (-not $remote -or -not $remote.Contains($md5)) { "[FAIL] md5 mismatch: $remote"; exit 1 }
"[OK] md5 verified"

# 5. extract + build image
ssh -p 1622 lin@192.168.31.16 "rm -rf /volume2/docker/books/src"
ssh -p 1622 lin@192.168.31.16 "mkdir -p /volume2/docker/books/src"
ssh -p 1622 lin@192.168.31.16 "tar -xzf /tmp/xs-deploy.tgz -C /volume2/docker/books/src"
ssh -p 1622 lin@192.168.31.16 "rm -f /tmp/xs-deploy.b64 /tmp/xs-deploy.tgz"
ssh -p 1622 lin@192.168.31.16 "/usr/local/bin/docker build -t xiaoshuo-server:latest /volume2/docker/books/src 2>&1 | tail -n 3"

# 6. recreate container + logs
ssh -p 1622 lin@192.168.31.16 "cd /volume2/docker/books; /usr/local/bin/docker compose up -d --no-deps --force-recreate xiaoshuo-server 2>&1 | tail -n 2; sleep 3; /usr/local/bin/docker logs xiaoshuo-server 2>&1 | tail -n 6"

"[DONE] deploy finished"
