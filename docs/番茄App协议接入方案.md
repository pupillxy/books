# 番茄 App 协议接入方案（推荐榜 / 全屏 App 数据源）

> 生成日期：2026-09-28
> 目的：书城推荐榜从"网页端书库热门序"（现 A 方案）升级为 App 端真实榜单/推荐流
> 结论先行：**可行，且不需要 root 真机、iPhone 用户也能用**——设备身份可凭空注册，签名只卡两个头（X-Helios / X-Medusa），一次性提取后服务器永久自持。你的 root 手机 + NAS 容器各有一次性用途。

---

## 1. 目标回顾

现书城推荐榜 = 番茄网页端书库接口（全分类+热门排序），和手机 App 首页推荐榜不一致（无运营位、无个性化、无短剧混排）。
目标：server 直接以 App 协议访问番茄，拿到和手机 App 同源的数据。

## 2. 调研发现（全部有代码/文档佐证，参考仓库见 §7）

### 2.0 实测记录（2026-09-28/29，两轮实测，最终 ✅ 全链路打通）

**第二轮（2026-09-29）—— 模拟器签名 oracle，全链路验证成功：**

| 步骤 | 结果 |
|---|---|
| x86_64 AVD（Android 15 Google APIs）+ 番茄 7.3.7.33 ARM 转译运行 | ✅ App 满血跑（首页真实数据截图确认） |
| frida-server 16.7.19（root） | ✅ 正常 hook |
| 找到真签名入口：`NetworkParams.tryAddSecurityFactor(String, Map)` 静态方法 | ✅（73733 版 ms.bd.c.r4 已非签名类，混淆名轮换） |
| oracle 生成全套 6 签名头（含 X-Helios/X-Medusa） | ✅ |
| App 原生参数模板（40+ 参数）+ oracle 签名 + 普通 HTTP | ✅ **搜索 171KB / 书城 feed 346KB 真实数据** |
| 手拼简版参数 URL（无论签名与否、curl 还是 app 内 okhttp） | ❌ 200 空 body —— **参数集必须用 App 模板** |
| ARM64 AVD on Windows | ❌ 新版模拟器(37.x)已禁止 x86 主机跑 arm64 镜像，旧版直链全 404 |
| APK 来源 | ✅ 豌豆荚直链 v7.3.7.33（vcode 73733，md5 校验通过），ARM 转译可跑 |

结论：**方案全部打通**，"无 root、无真机"成立——模拟器（后续可迁 NAS docker redroid）就是签名 oracle + 请求网关。工具链固化在 `_reference/fqemu/`（README 含完整配方/踩坑/重建步骤）。

**第一轮（2026-09-28）—— 纯服务端直连尝试（已弃）：**

| 实验 | 结果 |
|---|---|
| 设备注册（POST log.snssdk.com/service/2/device_register/，无签名） | ✅ 成功，拿到 device_id/install_id |
| 搜索接口 v71332 + X-Gorgon / 无签名 / 老版本 70532、69932 / 海版 68132 | ❌ 全部 200 空 body |
| TND 二进制 strings | 端点家族与 fanqie-dl 一致，无 feed 端点 |

### 2.1 设备身份：凭空注册，不需要真机

- 注册端点：`POST https://log.snssdk.com/service/2/device_register/`（备选 `log.isnssdk.com`），**无需签名**。
- 请求体：JSON（`magic_tag: "ss_app_log"` + header：aid=1967、app_name=novelapp、version_code=71332、package=com.dragon.read、device_model/brand、cdid、openudid 等随机生成即可）。
- 返回 device_id / install_id，持久化后 server 就是"一台设备"。
- 佐证：`_reference/fqd-rs2/src/api/client.rs:89-124`（完整实现）；TND 闭源 crate 的错误提示也点名该域名（`_reference/tnd-src/src/prewarm_state.rs:12`）。

### 2.2 签名：服务端只验 2 个头，且都可以一次性提取

fanqie-dl 作者用 Frida 做了系统排除实验（`_reference/fqd-rs2/ISSUE.md`，2026-03-31）：

| 测试 | 结果 |
|---|---|
| 全部 6 个签名头（Gorgon/Argus/Ladon/Khronos/Helios/Medusa） | ✅ 有数据 |
| **只带 Helios+Medusa** | ✅ 有数据 |
| 缺 Helios 或缺 Medusa / 伪造任一 | ❌ 空响应 |
| 不带 Gorgon/Argus/Ladon/Khronos | ✅ 有数据（**这 4 个根本不验**） |

- **X-Medusa**：纯算法已还原（MD5 → 随机数/aid 混合 → SHA-1 → AES-128-ECB keystream → base64），可移植 Go（`src/signer/mod.rs` 注释列全了步骤）。
- **X-Helios**：CFF 混淆内联代码，作者用 dynarmic（ARM64 JIT 模拟器）直接跑 so 里的代码块（`src/signer/emulator.rs`），依赖一组 Frida 导出的内存 dump（`lib/so_code.bin`、`so_data1.bin`、`memdump.bin`、sign key）——**仓库未附带，README 明说 WIP：需 ARM64 设备 + Frida 提取**。
- 签名与 URL 绑定；so 版本 com.dragon.read v7.1.3.32（对应 UA `com.dragon.read/71332`）。

### 2.3 接口家族：`api5-normal-sinfonlinec.fqnovel.com` + `/reading/...`

fanqie-dl 已实现（参数结构可直接抄）：

| 端点 | 用途 |
|---|---|
| `/reading/bookapi/search/tab/v` | App 搜索（比网页搜索更全） |
| `/reading/bookapi/detail/v1/` | 书籍详情 |
| `/reading/bookapi/directory/all_items/v1/` | 完整目录 |
| `/reading/reader/full/v1/` | 章节正文（AES 加密，密钥协商获得） |
| `/reading/crypt/registerkey` | 内容解密密钥协商 |

公共 query（aid=1967 / app_name=novelapp / version_code=71332 / device_id / iid / cdid / openudid / _rticket）见 `client.rs:172-198`。
**缺口：首页推荐流/榜单端点未在开源项目中出现**，需按 §5 步骤发现（预期在 `/reading/...` 同族）。

### 2.4 相关项目现状

| 项目 | 状态 | 对我们的价值 |
|---|---|---|
| TND（在用，NAS docker） | 完整可用但 official-api crate **闭源** | 证明无 root 服务器端跑 App 协议可行；二进制可挖端点 |
| fanqie-dl（linzj，Rust） | 框架全、签名卡 Helios/Medusa 提取 | **主路线骨架**：端点+注册+解密+模拟器框架 |
| ying-ck/fanqienovel-downloader（Python） | 网页端+第三方 API 路线 | 参考价值低 |
| 中转服务（文档 §6 的 101.35.133.34） | 闭源黑盒 | 仅调试对照，不上生产 |

## 3. 路线对比

| 路线 | 做法 | 工作量 | 风险 | 结论 |
|---|---|---|---|---|
| 甲. 中转服务顶上 | server 调闭源中转的 search/detail | 半天 | 黑盒随时跑路，数据经第三方 | 仅调试对照，不上生产 |
| **乙. fanqie-dl 骨架 + 补签名提取** | Frida 一次性提取 dump/sign key → fork 加 HTTP 薄层 → NAS docker sidecar → Go server 接入 | 1-2 天 | 番茄改版需重提取（锁 7.1.3.32 缓解） | **推荐主路线** |
| 丙. Go 全自研 | Medusa 纯 Go 移植 + unicorn-go 跑 Helios | 1 周+ | 同乙，且模拟器层重造 | 乙验证价值后再考虑 |

## 4. 你的 root 手机和 NAS 容器的角色（都是一次性的）

- **root 安卓手机**：充当 Frida 提取载体——跑一次番茄 App，导出 Helios/Medusa 所需的内存 dump 和 sign key（fanqie-dl 缺的唯一拼图）。提取完文件固化进 sidecar 镜像，**之后手机再也不用参与**。（用 PC 安卓模拟器替代也可，真机更稳。）
- **NAS 的 TND 容器**：二进制里含闭源 official-api crate 的全部端点常量，`strings` 扫一遍很可能直接把 feed/榜单端点挖出来；数据目录里还有它注册成功的设备信息可对照格式。

NAS 上执行（SSH 进群晖）：

```sh
sudo docker ps | grep -i tomato        # 找容器名
sudo docker exec <容器名> sh -c "strings /app/tomato-novel-downloader | grep -E '^/reading/' | sort -u"
sudo docker exec <容器名> sh -c "strings /app/tomato-novel-downloader | grep -iE 'rank|feed|bookapi|card|banner' | sort -u | head -60"
sudo docker exec <容器名> sh -c "ls -la ${TOMATO_DATA_DIR:-/app/data} 2>/dev/null; find / -maxdepth 4 -name '*iid*' -o -name '*device*' 2>/dev/null | grep -v proc | head"
```

把输出发我即可。

## 5. 分阶段执行计划（路线乙）

- ~~**阶段 0 · 端点侦察**~~ ✅ 完成（2026-09-29）：TND strings + 豌豆荚 APK 获取 + fanqie-dl 端点家族确认。
- ~~**阶段 1 · 签名提取**~~ ✅ 完成（2026-09-29）：**改用 x86_64 AVD + ARM 转译 + frida RPC oracle 形态**（ARM64 AVD 被 Windows 新版模拟器封杀；frida 17 无 Java 桥需用 16.x）。签名入口实锤为 `NetworkParams.tryAddSecurityFactor` 静态方法，oracle 可签任意 URL。
- ~~**阶段 2 · oracle 服务化**~~ ✅ 完成（2026-09-29）：`_reference/fqemu/oracle_server.py` 常驻 HTTP 服务（/health /sign /fetch），实测搜索 172KB / 书城 feed 347KB 真实数据。
- ~~**阶段 3 · Go server 接入**~~ ✅ 完成（2026-09-29）：`internal/fanqie/appclient.go`（oracle 封装 + SearchApp/HomeFeed + 设备参数模板），环境变量 `XS_FQ_ORACLE` 启用；新端点 `GET /api/store/app/search`、`GET /api/store/app/homefeed`（含在库标记）；冒烟测试 `TestSmokeAppClient` + 起 server 带鉴权端到端验证通过（搜索 4.5KB / feed 17.2KB 真实数据）。
- ~~**阶段 4 · App 端**~~ ✅ 完成（2026-09-29）：书城页「推荐榜」Tab 切 App 排行榜原文（`/store/app/homefeed`，16 本与手机 App 首页一致），完本榜/新书榜/巅峰榜保留书库近似（A 方案）；新增 `store_search_page.dart` 真搜索页（App 源搜索，防抖 + 分页），搜索框从跳书库改为跳真搜索。`flutter analyze`/`test` 全绿。
- ~~**部署打通**~~ ✅ 完成（2026-09-29）：NAS compose 加 `XS_FQ_ORACLE=http://192.168.31.102:8765`（PC 局域网 IP），server 重部署后端到端验证通过（生产 API 返回真实榜单/搜索数据）；Windows 防火墙已放行 8765；PC 一键启动脚本 `_reference/fqemu/start_fq_oracle.bat`。注意 redroid on 群晖因内核缺 binder 模块不可行，oracle 维持 PC 承载。
- **待办 · 日常运维**：PC 重启后双击 `start_fq_oracle.bat` 拉起链路；PC IP 变化需同步改 NAS compose（建议路由器给 PC 绑静态 DHCP）；番茄 App 大版本升级后重抓参数模板并同步 `appclient.go` 版本参数。

## 6. 风险与对策

1. **改版失效**：签名绑定 so 版本 → 全链路锁 7.1.3.32（UA/版本号/参数一致），和红果锁 73532 同策略；改版后重新提取（手机+frida 流程已文档化，半天内可重做）。
2. **风控**：注册设备冷启动高频请求易被标记 → 低频起步、请求间隔随机（fanqie-dl 已带 0.8-1.2s 抖动）、不迁移大流量。
3. **无个性化**：注册设备拿到的推荐是冷启动泛化热门（运营权重仍在，比网页书库序更接近 App）；要"你的个性化"需账号 token，无 root 提不了——接受泛化，或网页 Cookie 部分补充。
4. **合规**：同文档 §8 口径——个人自用、限速、不分发内容。

## 7. 参考仓库（已克隆到 `_reference/`）

| 目录 | 内容 |
|---|---|
| `_reference/fqd-rs2/` | fanqie-dl（Rust）：设备注册、端点、签名框架、dynarmic 模拟器、逆向笔记 |
| `_reference/tnd-src/` | TND 源码（official-api 闭源，其余可读） |
| `_reference/fqd-py/` | ying-ck 下载器（Python，网页+第三方路线） |
| `_reference/guoapp/` | 红果 App 协议（已移植进本项目，X-Gorgon 参考） |
