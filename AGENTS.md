# AGENTS.md — AI 协作手册

> 本文件面向后续接手的 AI 助手（与人类协作者）。读完即可安全操作本项目。
> 更深的档案：`docs/`、`_reference/*/README.md`、`_reference/fqnovel-unidbg-src/VERIFY.md`。

## 1. 项目是什么

个人用的多源内容平台（全家人用，4 台手机 → NAS）：

- **Flutter App**（`app/`）：书架（本地书）、书城（番茄小说在线读）、短剧（红果）、我的
- **Go server**（`server/`）：gin + SQLite，聚合所有数据源，跑在 NAS Docker
- **fq-unidbg**（`_reference/fqnovel-unidbg-src/`，独立 Java 服务）：番茄海外版 SO 放进
  unidbg 模拟执行自算签名（X-Helios/X-Medusa），让 server 能走番茄 App 协议

仓库：`github.com:pupillxy/books.git`（**建议保持 Private**——含番茄 SO 二进制与逆向档案）。
本地分支 `master`，SSH 认证已配好（id_ed25519 / pupillxy）。

## 2. 数据源一览（改代码前必读）

| 数据 | 来源 | 位置 | 说明 |
|---|---|---|---|
| 番茄·书城浏览/榜单（近似） | 网页端 fanqienovel.com | `server/internal/fanqie/client.go`、`searchweb.go`、`abogus.go` | 免登录抓取 + a_bogus 签名；被风控时负缓存 60s |
| 番茄·App 书城 feed（真实排行榜） | unidbg 服务 | `server/internal/unidbg/unidbg.go` `HomeFeed()` | `GET /api/store/appfeed`；解析 bookmall/tab 推荐流 |
| 番茄·搜索/详情/目录 | 网页优先 → unidbg 兜底 | `handler/store.go` `getBookDetail`/`getChapters` | 网页被风控不再导致详情页失败 |
| 番茄·章节正文（在线读） | 按需回源：网页 → unidbg 兜底 | `handler/book.go` `Chapter`+`fetchOnlineContent` | 读到哪章拉哪章并缓存（FillChapterContent），预取下一章；付费章 402 |
| 番茄·整本离线缓存 | unidbg 下载器（TND 兜底） | `unidbg.DownloadBook`、`store.go triggerDownload` | 3s/批、断点续传；仅显式触发（`?download=1` 或 POST /download） |
| 短剧 | 红果 App 协议 | `server/internal/hongguo/` | 与番茄无关，独立风控（锁版本 73532） |
| 追更 | 每日目录刷新 | `handler/updater.go` | **只刷目录元数据**，新章节靠按需回源，不再批量下载 |

**数据源优先级铁律**：`XS_UNIDBG_URL` 留空 = 全部回退网页/TND 旧行为。App 端 API 形状
永远不变（App 零改动），新数据一律在 server 适配。

## 3. 服务与端口

| 服务 | 端口 | 部署 |
|---|---|---|
| xiaoshuo-server | NAS `18004 → 8080` | `server/deploy/deploy.ps1` 一键构建+部署（linux/amd64） |
| fq-unidbg | NAS `127.0.0.1:9999 → 9999` | compose 服务；镜像 `docker build -t fq-unidbg:latest fq-unidbg-src` |
| tomato-novel-downloader (TND) | NAS `18003 → 18423` | 官方镜像，闭源 crate，仅兜底 |

- NAS：`ssh -p 1622 lin@192.168.31.16`（免密），docker 在 `/usr/local/bin/docker`
- 部署目录：`/volume2/docker/books/`（compose.yaml + src/ + xiaoshuo_data/ + books/ + fq-unidbg-src/ + fq-unidbg/config/）
- compose 改动**必须先备份**（compose.yaml.bakN 惯例），改完 `wc -c` 校验非空
- 环境变量：`XS_UNIDBG_URL=http://fq-unidbg:9999`、`XS_TND_URL`、`XS_FQ_COOKIE`、`XS_JWT_SECRET`、`XS_ADMIN_USER/PASS`
- Docker Hub 在 NAS 上会卡死：Dockerfile 基础镜像一律用 `docker.m.daocloud.io/library/...` 前缀

## 4. fq-unidbg 服务（最容易踩坑的部分）

来源 zero199901/fqnovel-unidbg（135★）+ 我们的补丁。**SO 在 unidbg 里自算签名**，
不要试图手写签名算法（fanqie-dl 纯算路线卡 Medusa 多年无人完成，档案在 `_reference/fqd-rs2/`）。

### 端点
- `GET  /api/fq-signature/health` — 探活
- `GET  /api/fqsearch/books?query=&count=` — App 搜索
- `GET  /api/fqsearch/directory/{bookId}` — 目录（item_data_list；`chapter_index` 类型不定，Go 侧已用 flexInt 容错）
- `GET  /api/fqnovel/book/{bookId}` — 书籍信息（稳定；目录接口的 book_info 有缓存波动，别用）
- `GET  /api/fqnovel/chapter/{bookId}/{itemId}` — 单章正文（`data.txtContent` 明文，首行是章节名需 TrimPrefix）
- `POST /api/fqnovel/chapters/batch` — 批量正文 `{"bookId","chapterIds":[...]}`（**单章接口高频会 ILLEGAL_ACCESS 设备风控**，一律用 batch）
- `POST /api/fqapp/fetch` — **我们加的通用代签代发**：`{"path":"/reading/bookapi/xxx","query":"已编码业务参数串","host":null}`。
  服务用自身设备配置拼完整 URL → 签名 → 代发 → 解 gzip 透传上游 body。任意 bookapi 端点都能接。
- `POST /api/device/register` — 换设备（响应含新 device 全套信息）

### 设备生命周期（生产必读）
- 设备被标记（报「响应格式异常/空响应，请手动更新设备信息」）：
  `POST /api/device/register`（body 可空 JSON，自动换设备）→ **必须重启容器才生效**
  （autoUpdateConfig 实测不落盘 application.yml！手动改 yml 也可以）。
- **IP 级限流**：换设备也没用、连搜索都 code=-1 = IP 被限。冷却几十分钟自愈，不要慌。
- 限速纪律：批量正文 3s/批（每批 20 章）；测试时克制，PC 与 NAS 共用同一公网 IP。
- 设备信息在 `application.yml` 的 `fq.device`（当前 Xiaomi 23127PN0CC / 68132 海外版）。
  签名与 URL 绑定且校验设备一致性——**URL 里的 device_id/iid/cdid 必须与 unidbg 配置一致**，
  否则 native 直接崩（报「获取结果指针失败」）。
- 签名接口 `/api/fq-signature/*` 对外可用性差（需完整 headers map + 完整参数 URL 才不崩），
  **不要依赖它**，需要任意端点签名时用 `/api/fqapp/fetch`。

### 本地构建/运行
```sh
# JAVA_HOME = C:\Users\94985\.jdks\jdk-17；Maven 在 _reference/maven-home/maven（阿里云镜像已配 ~/.m2/settings.xml）
cd _reference/fqnovel-unidbg-src
../maven-home/maven/bin/mvn.cmd -q -B -DskipTests package
~/.jdks/jdk-17/bin/java.exe -Dfile.encoding=UTF-8 -jar target/unidbg-boot-server-0.0.1-SNAPSHOT.jar
```

## 5. Flutter App 要点

- 4 Tab：书架 / **书城（FanqiePage，新设计）** / 短剧 / 我的（`ui/home_page.dart`）
- 阅读器：`reader_page.dart` 走 `ReaderSource` 抽象；在线书 `ApiReaderSource` →
  `/api/books/:id/chapters/:idx`（服务端按需回源，App 无感知）
- 书城新页 `ui/fanqie_page.dart`：「APP·推荐」（App 同源排行榜）+ 四榜 + 搜索/书库入口；
  **结构铁律：Sliver 只能出现在顶层 CustomScrollView 的 slivers 里**，
  Column/Row 里放 Sliver 会触发 `child == _child` 断言崩溃（已踩过）
- 主题：`core/mo_theme.dart`（朱砂棕），跟随深浅色用 `MoStyle.strongOf(context)`/`softOf(context)`
- API：`core/api.dart`；会话 `sessionProvider`（core/session.dart）
- 检查命令：`flutter analyze` + `flutter test`（改动后必须全绿）

## 6. Go server 要点

- 包结构：`handler/`（HTTP）、`fanqie/`（网页源+abogus）、`unidbg/`（App 源客户端）、
  `hongguo/`、`tnd/`、`database/`（SQLite）、`scanner/`（本地书/TND 导入）、`config/`
- 新数据源端点的响应形状必须与 App 现有模型（`app/lib/models.dart`）兼容——App 零改动原则
- `unidbg.Client`：重试 3 次退避、批量 3s 限速、断点续传（UpsertChapterContent 增量回填）
- 章节在线回源在 `book.go Chapter`：DB 空 content → FQ 网页 → UNI 兜底 → FillChapterContent
- 检查命令：`go build ./... && go vet ./... && go test ./internal/...`

## 7. 高频踩坑（血的教训）

1. **Windows + Git Bash 环境坑**：
   - Windows 的 python 不认 `/tmp`（Git Bash 虚拟路径）——跨工具临时文件放**工作区目录**
   - bash heredoc `<<'EOF'` 里嵌大段 python 的转义极易出错（`\\n`、`$$`）——
     **复杂补丁一律用 Write 工具写独立 .py 文件再执行**，不要 heredoc 内联
   - `grep` 是 ugrep 别名，部分参数行为不同；`adb pull` 的 `/data/app/...` 路径加 `MSYS_NO_PATHCONV=1`
   - powershell -File 传 Windows 路径用正斜杠 `d:/dev/...`
2. **GitHub 大文件**：`.gitignore` 已排除档案里的 apk/zip/dumps/target/results；
   勿把 133MB 的国内 APK 或构建产物加进 git
3. **番茄接口风控双层**：设备级（换设备+重启容器）→ IP 级（冷却自愈）。
   一切高频操作前先想限速
4. **adb/模拟器**：fqsig AVD 是 x86_64 + ndk_translation（ARM 转译）——guest 代码
   **无法被 Frida hook**（ARM libc 不在模块表），但内存可读可扫（地址 ~0x14xxxxxx）
5. **compose 编辑**：ssh cat 拉到本地改完推回，**先备份**，推完 `wc -c` 校验；
   `cat x | ssh "cat > f && build &"` 这种管道+后台组合会把文件截断（踩过）
6. 番茄网页详情/目录被限流是常态：`store.go` 已有负缓存+三重兜底，别删

## 8. 文件地图

```
docs/NAS部署脚本.md            — NAS 部署全流程（compose 片段/运维/踩坑）
docs/番茄App协议接入方案.md      — App 协议调研史（含 9-29 oracle 弃用决策）
_reference/fqnovel-unidbg-src/  — unidbg 签名服务（VERIFY.md = 验证+运维记录）
_reference/fqemu/               — 旧 oracle 档案 + stage1_73733 采集档案（签名样本/脚本）
_reference/fqd-rs2/             — fanqie-dl 逆向档案（Medusa VM 分析，ISSUE.md 是宝库）
_reference/tnd-src/             — TND 源码（official-api crate 闭源）
app/build/outputs/flutter-apk/  — 构建出的 APK
```

## 9. 已知未做 / 想做

- 「猜你喜欢」个性化推荐流（动态 lynx 模板 + 独立分页接口）未接——排行榜已同源
- 漫画频道（腾讯动漫 ac.qq.com 爬取 + 拷贝漫画）已验证未实现，见对话档案
- 番茄付费章节：网页/unidbg 免费通道都拿不到，402 提示用户离线缓存（其实也拿不到，需账号）
