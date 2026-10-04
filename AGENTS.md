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
| 番茄·分类页（标签树+书单） | unidbg 服务 | `unidbg.go` `CategoryFront/CategoryLanding` | `GET /api/store/categories` + `/api/store/categoryfeed`；new_category 协议（10/05 定案，档案 capture_xiaoshuo_1005） |
| 番茄·搜索/详情/目录 | 搜索（10/05 起）：**TND 首选**（仅 offset=0，上游无翻页参数）→ App 协议（unidbg）→ 网页兜底；详情/目录仍 App 协议优先 → 网页兜底 | `handler/store.go` `Search`/`getBookDetail`/`getChapters`、`tnd.go` `Search` | TND 搜索直连官方基础设施（`GET /api/search?q=`，一次约 20 条，401 自动重登录）；搜索接口 `creation_status` 语义 1=完结 0=连载（同详情、与书城卡相反）。App 搜索在 NAS 偶发服务层 NPE（"Cannot read the array length"），网页兜底覆盖 |
| 番茄·章节正文（在线读） | 按需回源：**当前只走 TND 范围任务（10/05 起，实测 ~5s/次）**；App 协议/真机签名桥/网页端三个通道由 `book.go` 顶部 const 开关临时关闭（恢复时改回 true） | `handler/book.go` `Chapter`+`fetchOnlineContents` | 读到哪章拉哪章并缓存（FillChapterContent），预取下一章；失败 402「稍后重试」。TND 可读「网页仅试读」的章。通道失败进健康记忆 10 分钟内跳过。关桥原因：桥不常开，每个健康窗口首笔正文白等 12s 拨号超时（10/05 前「新书首章 ~20s」即 12s 桥超时 + TND 叠加） |
| 番茄·TND 按需单章（10/04 新增） | TND 范围任务（`/api/jobs` + `range_start/end`） | `tnd.go` `CreateRangeJob/WaitJob`、`book.go` `tndChapters` | 走番茄官方接口+闭源证件，读全量正文、无我们设备的风控压力；实测 8~15s/次。产物 `books/<fid>/status.json`（downloaded[item_id]=[章名,HTML]）或《书名》.epub，按 src_id 对号入座剥 HTML 入库。max_workers 已调 2 |
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
- **正文接口只信任有资历的设备**：新注册设备 feed/目录正常但正文空响应（0 字节），
  且是**所有章节**一起挂，与付费与否无关。内容风控冷却 >1 小时。
  当前配置（10/03 起）用的是 fqsig AVD 实测可读正文的设备（google sdk_gphone64_x86_64，
  device_id 4052162698366793，国内 73733 注册 + oversea 68132 签名混搭被服务端接受）；
  自动轮换已**关闭**（compose `XS_UNIDBG_ROTATE=0`）——10/03 事故证明轮换保 feed 毁正文
  资历（换新设备 34 秒后用户切章即全挂）。设备被标记时先评估：feed 风控可冷却自愈，
  别轻易牺牲正文通道；确要轮换用 `POST /api/device/register` + 重启，并尽快恢复有资历设备。
- **IP 级限流**：换设备也没用、连搜索都 code=-1 = IP 被限。冷却几十分钟自愈，不要慌。
- 限速纪律：批量正文 3s/批（每批 20 章）；测试时克制，PC 与 NAS 共用同一公网 IP。
- 设备信息在 `application.yml` 的 `fq.api.device`（当前 AVD 设备，见 `capture_xiaoshuo_1003/FINDINGS.md`）。
- **身份一致性铁律（10/03 定案）**：version_code/version_name/UA 必须与设备注册方一致
  （AVD 设备=国内 73733 → 全套 73733 身份）。错配（68132 冒充 73733 设备）会让
  正文/tab/v 在一小时内必被标记；当前配置已全套 73733，勿改回 68132。
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
7. **真机签名桥跑在开发机 PC**（192.168.31.102:9998，需 fqsig 模拟器运行 +
   `python _reference/fqemu/capture_xiaoshuo_1003/bridge/bridge_server.py` 常驻）。
   PC 关机/模拟器没开 = 第三通道下线：unidbg 正文被标记期间，
   「网页仅试读」的章由 **TND 单章通道**兜底（10/04 上线），不再必然 402。
   桥启动后 health 应返回 `{"ready": true}`，NAS 侧 curl 通才算数（Windows 防火墙）
8. **TND 通道调研结论（10/04，连接级+TLS 证书级实证）**：
   - TND 搜索/正文**直连番茄官方基础设施**（api5-normal-*.fqnovel.com、*.snssdk.com
     证书验证）+ 少量网页端；crate **绕过系统 DNS**（自带解析器，/etc/hosts 屏蔽实验
     因此无效）；偶尔连一个非番茄 CDN（金山云系 ksc-test），非必需环节。
   - 「第三方 API 地址池」地址+token 闭源在 crate 里，是 no-official 模式的主力 /
     official 模式的兜底，**不是我们配置下的正文主干**。
   - 生态对照：ying-ck/fanqienovel-downloader（2.4k★）正文走硬编码中转
     `101.35.133.34:5000/api/raw_full`（私人设备池，明文 HTTP）；TND = 本地闭源证件；
     我们 = unidbg 真机签名（证件会被打标）。番茄面前没有魔法，只有谁的设备在承压。
   - 探针脚本留档 `_probe/tnd_probe*.py`（连接采样/证书鉴定/range 任务实测）。
   - **TND 容器踩坑**：删 books/ 挂载点目录会使 bind mount 失效（指向旧 inode），
     必须重建目录后 `docker restart tomato-novel-downloader`；probe 清理脚本
     `rmtree(BOOKSDIR)` 类 bug 会整目录删掉——清理时只删白名单条目。
9. **书城 cell/change 冷会话软空页（10/04，10/05 缓存方案定案）**：番茄 bookmall
   cell/change/v 在个性化会话冷启动/突发连打后会返回 **code=0 空页**（HTTP 200、无卡片、
   has_more=false，持续约 1 分钟自愈；unidbg 设备本身正常，榜单等其他端点不受影响）。
   **10/05 定案（根治）**：`AppFeedPage` 三层取数——内存缓存（3min 正/60s 负）→
   DB 持久缓存 `feed_cache` 表（非强刷 6h 内直回放不碰上游，负缓存期回退任意年龄
   陈旧值，上游失败也回退陈旧值）→ 上游聚合拉取（`guessFeedFetch`：逐页打到
   ≥10 本或 3 页上限，游标取最后成功页）。App 下拉刷新/手动重试带 `refresh=1`
   绕过①②强制回源并回写两级缓存（更新只跟随下拉刷新）；首屏因此毫秒级且完全
   绕开冷会话。空页重试仍保留在 `unidbg.FeedPage` 内（800ms 一次）。实测样本
   `_probe/store_feed_1004/`。
10. **AVD 断网假象（10/05）**：模拟器 App 全卡启动页、状态栏 3G 时，先查
    `adb shell ip route`——AVD 冷启动偶发丢 default 路由，修复 `adb root` +
    `ip route add default via 10.0.2.2 dev eth0`。宿主防火墙挡 ICMP 转发，ping 不通
    不代表断网，**判定用 TCP**（`nc -w3 -z 223.5.5.5 53`）。另：fq-unidbg 实际绑
    `192.168.31.16:9999`（LAN IP），PC 可直连调试。

## 8. 文件地图

```
docs/NAS部署脚本.md            — NAS 部署全流程（compose 片段/运维/踩坑）
docs/番茄App协议接入方案.md      — App 协议调研史（含 9-29 oracle 弃用决策）
_reference/fqnovel-unidbg-src/  — unidbg 签名服务（VERIFY.md = 验证+运维记录）
_reference/fqemu/               — 旧 oracle 档案 + stage1_73733 采集档案（签名样本/脚本）
_reference/fqd-rs2/             — fanqie-dl 逆向档案（Medusa VM 分析，ISSUE.md 是宝库）
_reference/tnd-src/             — TND 源码（official-api crate 闭源）
_probe/                         — TND 通道调研探针（连接采样/证书鉴定/range 任务实测）
app/build/outputs/flutter-apk/  — 构建出的 APK
```

## 9. 已知未做 / 想做

- 「猜你喜欢」瀑布流已接通（10/03，纯 cell/change 翻页 `/api/store/appfeed/page`；
  旧「动态 lynx 模板」方案已弃）。10/04 补：服务端 3min 缓存 + 上游空页重试/兜底
  （见 §7 第 9 条），修「书城下方空白需手动下拉」与首屏慢
- 漫画频道已接通（10/04）：书城三频道（推荐/小说/漫画），`/api/store/comicfeed`
  + `/api/store/comics/:id`（详情+话列表）+ `/api/store/comics/:id/chapters/:itemID`
  （整话图片走 `/api/store/comicimg` 解密代理——**图片文件本身是 AES-256-GCM 加密**，
  文件=nonce(12B)‖密文‖tag(16B)，密钥=该话 encrypt_key，算法档案
  `_reference/fqemu/capture_xiaoshuo_1004/FINDINGS.md`）。未做：漫画阅读进度持久化
- 小说频道筛选瀑布流已接通（10/04，`/api/store/novelfeed`，`selected_items` 逗号多选，
  值如 finished/online_in_past_one_year/word_num_gt_200w/male/female/bian_ji_tui_jian）。
  书城卡 `creation_status` 语义 0=完结 1=连载（与详情接口相反，勿再改回）
- 书城分类页已接通（10/05）：搜索框右侧「分类」按钮 → 男生/女生频道标签树
  （热门标签/主题/角色/情节，点标签进书单页）+ 落地页（banner 语 + 相关分类词条 +
  字数/状态/排序筛选 + 评分书单）。协议 `new_category/front/v:version/` +
  `new_category/landing/v`（client_req_type 3=首屏/4=筛选/2=翻页；landing 的
  selected_items 用 `creation_status_end`/`word_num_gte200` 风格值，与 bookmall 频道
  筛选条的 `finished`/`word_num_gt_200w` **不通用**）。端点 `/api/store/categories` +
  `/api/store/categoryfeed`；协议档案 `_reference/fqemu/capture_xiaoshuo_1005/FINDINGS.md`
  （含 199 个 bookapi 路径清单 = 接新页面的第一手候选）。未做：听书/出版/短剧/漫画
  分类频道（内容形态未接）
- 「付费章」旧结论已推翻（10/03 实测）：网页端只给试读 ≠ 付费章，App 协议匿名设备
  可读（第 63 章实例，`_reference/fqemu/capture_xiaoshuo_1003/FINDINGS.md`）。
  未做：`book.go` 的 402 文案「该章节为会员内容」仍以网页 ErrChapterLocked 判定，误导，
  待改成中性文案；真正需要账号权益的章是否存在待遇见时再验证。
