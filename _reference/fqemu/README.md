# 番茄 App 协议 · 模拟器签名 oracle（已验证打通 2026-09-29）

本目录保存 fanqie-dl/TND 调研 + x86_64 模拟器签名 oracle 的全套验证脚本。
方案文档见 `docs/番茄App协议接入方案.md`。**脚本为实验产物，不属于 server 代码。**

## 已验证的完整链路（全部实测通过）

```
PC x86_64 AVD (fqsig, Android 15, Google APIs, adb root)
  └─ 番茄 7.3.7.33 (vcode 73733, ARM 转译运行) + frida-server 16.7.19
       └─ frida RPC: NetworkParams.tryAddSecurityFactor(url, headers)
            → 返回全套 6 签名头 (X-Gorgon/X-Argus/X-Ladon/X-Khronos/X-Helios/X-Medusa)
       └─ 签名后的 URL 用普通 HTTP 请求 → code:0, 真实数据
```

已验证的端点：
- `/reading/bookapi/search/tab/v` — 搜索（171KB 结果，"剑来" 实测）
- `/reading/bookapi/bookmall/tab/v` — **书城首页推荐流**（346KB，含排行榜 cell）
- 采集到的其它端点：detail/directory/reader/registerkey（fanqie-dl 同款）

## 关键认知（踩坑记录）

1. **签名入口**：`com.bytedance.frameworks.baselib.network.http.NetworkParams.tryAddSecurityFactor(String url, Map<String,List<String>> headers)` 静态方法。
   - 入参 url 必须是**完整 URL（带 https:// scheme）**，否则抛 "it must be http/https/wss"。
   - 返回 Map 的 key/value 需 `.toString()` 转换。
2. **URL 参数集必须用 App 自己的模板**（40+ 个公共参数：channel/update_version_code/manifest_version_code/resolution/dpi/language/rom_version/host_abi/dragon_device_type/pv_player/compliance_status/need_personal_recommend/player_so_load/is_android_pad_screen 等）。手拼简版参数 → 200 空 body。参数模板从捕获的真实请求里取（captured_urls.txt）。
3. **ms.bd.c.r4 在 7.3.7.33 已不是签名类**（方法只剩 a(Context)/b()/c()）；签名入口已上移到 NetworkParams 静态层。混淆类名随版本轮换，别硬编码。
4. **设备注册无门槛**：POST log.snssdk.com/service/2/device_register/ 免签名直接拿 device_id/iid（probe_app_api.py 实测成功）。
5. **curl 复放无需特殊 TLS**：签名对 + 参数全即可，普通 urllib/curl 都能拿数据。
6. 模拟器重启后要重新 `adb root` + 重启 frida-server（以 root 跑）。
7. Git Bash 下 adb 命令带设备路径时加 `MSYS_NO_PATHCONV=1`。

## 环境重建步骤

```sh
# 1. SDK 组件（JAVA_HOME 指 Android Studio jbr）
sdkmanager "system-images;android-35;google_apis;x86_64" "platform-tools"
avdmanager create avd -n fqsig -k "system-images;android-35;google_apis;x86_64" -d pixel_6

# 2. 启动（WHPX 加速）
emulator -avd fqsig -gpu swiftshader_indirect -memory 4096 -no-boot-anim

# 3. root + frida-server
adb root
adb push frida-server16 /data/local/tmp/frida-server
adb shell "chmod 755 /data/local/tmp/frida-server & nohup /data/local/tmp/frida-server -D"

# 4. 番茄 APK：豌豆荚直链下载 v7.3.7.33 (md5 acf46ca0...，见 captured_urls 同期记录)
adb install fanqie.apk   # ARM 转译运行，已验证

# 5. 宿主机客户端
pip install frida==16.7.19 frida-tools==13.7.1   # 必须配 frida-server 16.x（17.x 无 Java 全局桥）
```

## 脚本索引

| 脚本 | 用途 |
|---|---|
| `oracle_server.py` | **常驻签名服务**（阶段2 产物）：`/health` `/sign?url=` `/fetch?url=`，自动跟随 App 进程重启 |
| `oracle_replay.py` | 一次性验证脚本：oracle 签任意 URL + 普通 HTTP 拉数据（首次实测成功） |
| `capture_static.py` | spawn 冷启动，被动捕获 App 真实签名请求（URL 模板来源） |
| `capture_search.py` | spawn + UI 自动化，驱动 App 做真实搜索 |
| `find_signer.py` / `probe_class.py` | 枚举 metasec 类、定位签名入口 |
| `probe_app_api.py` | 设备注册实测 + 老版本/海版协议绕过尝试（结论：绕不过） |
| `search_full_url.txt` | 已验证成功的搜索 URL 模板（"剑来"） |
| `real_bookmall_url.txt` | 已验证成功的书城 feed URL（App 原生） |
| `captured_urls.txt` / `captured_search.txt` | App 真实请求原始捕获 |

## oracle 服务化（阶段 2 已完成，2026-09-29 实测）

```sh
python oracle_server.py 8765     # 常驻，自动 attach 番茄进程（跟随 App 重启）
# GET /health                     → {"ok":true,"pid":6019}
# GET /sign?url=<完整URL整段编码>  → {"headers":{...6签名头}}
# GET /fetch?url=<完整URL整段编码> → 签名+代发，透传上游响应体
```

实测：`/fetch` 搜索 172,900B code:0 ✓；书城 feed 347,835B ✓。
注意：`url` 参数值需 URL 编码后**整段再编码一次**传入（服务端 parse_qs 解一层）。

## 部署现状（2026-09-29，NAS 生产已接通）

```
4 台手机 → NAS xiaoshuo-server (192.168.31.16:18004)
              └─ XS_FQ_ORACLE=http://192.168.31.102:8765（PC）
                   └─ PC 模拟器 fqsig + 番茄 7.3.7.33 + frida + oracle_server.py
```

- **NAS compose** 已加 `XS_FQ_ORACLE`（备份：compose.yaml.bak），server 二进制已重部署（日志有"番茄 App 源已启用"）。
- **Windows 防火墙** 已放行入站 TCP 8765（规则名 FQ Oracle 8765）。
- **一键启动**：PC 重启后双击 `start_fq_oracle.bat`（模拟器→frida→番茄→oracle 顺序拉起，占住窗口即常驻）。
- ⚠️ PC 的局域网 IP 若变化（DHCP），需同步改 NAS compose 里的 `XS_FQ_ORACLE` 并重建容器；建议在路由器把 PC 设静态 DHCP 租约。
- redroid（NAS 本机跑 Android 容器）因群晖内核缺 binder 模块基本不可行，维持 PC 承载 oracle 即可。

## 生产化改造待办（对应方案文档阶段 3-4）

1. ~~Go server 接入~~ ✅ 完成：`internal/fanqie/appclient.go` + `/api/store/app/search|homefeed`（XS_FQ_ORACLE 启用）。
2. **feed/榜单端点枚举**：签名配方已通，对 `/reading/bookapi/*` 家族批量探测；bookmall/tab 已含首页推荐流+排行榜 cell。
3. **频率控制 + 设备养护**：低频起步，参数模板随 App 版本更新重新捕获（capture_static.py 一键重抓；App 版本升级后同步更新 appclient.go 里的版本参数）。
