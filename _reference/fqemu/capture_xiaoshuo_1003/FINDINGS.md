# 书城·小说频道/榜单 协议采集结论（2026-10-03）

> **实施状态（同日）**：server 已按本档案接入官方协议——
> `unidbg.go` 新增 `fetchApp`（通用 fqapp/fetch 回放+风控自愈）、`AppRanks`、
> `RankPageBooks`（cell/change/v1 模板 rankPageQuery，gender_list_type 1男/0女）；
> `store.go` 的 `/api/store/featured/:board`（四主榜卡）、`/api/store/ranks`（官方11榜）、
> `/api/store/ranks/:id/books`（完整榜单页）、`/api/store/search`（offset 透传修复翻页）
> 全部 App 协议优先 + 网页兜底，App 端零改动。响应形状与旧网页源完全一致。

环境：fqsig AVD（x86_64, Android 15）+ 番茄 7.3.7.33 (73733) + frida-server 16.7.19（root）
Hook 点：`com.bytedance.frameworks.baselib.network.http.NetworkParams.tryAddSecurityFactor(String, Map)`
（复用 stage1_73733/pass_a.js，spawn 模式；全量 (url, 签名头) 在 `rank_urls.jsonl`）

## 端点地图（业务参数已剥离设备/遥测噪音）

### 1. 频道内容（含首屏书单）
`GET /reading/bookapi/bookmall/tab/v`
- `tab_type`: **-1**=推荐频道，**25**=小说频道，**2**=榜单卡 cell 刷新
- `offset=0`，`client_req_type`: 3=进频道 / 4=站内 cell 刷新 / 1024=切 bottom tab
- 频道首屏书籍**内嵌在响应里**，瀑布流滚动才走 cell/change

### 2. 频道瀑布流加载更多（小说频道滚动）
`GET /reading/bookapi/bookmall/cell/change/v`
- `tab_type=25`, `offset=13`（衔接首屏数量）, `algo_type=167`（小说频道 feed cell）,
  `cell_id=<从 tab/v 响应取>`, `plan_id=<同>`, `client_req_type=2`, `change_type=0`

### 3. 榜单卡子榜切换（推荐频道页内那张卡：推荐榜/完本榜/巅峰榜/新书榜）
`GET /reading/bookapi/bookmall/cell/change/v`
- `tab_type=2`, `cell_id=<榜单卡实例ID，本次会话=7098235271900037133>`,
  `algo_type=<子榜>`, `client_req_type=4`, `limit=16`, `offset=0`（翻批 offset+=16）
- **实测 algo_type**：完本榜=100，巅峰榜=200，新书榜=108

### 4. 完整榜单页（小说新书榜/完本榜… 整页）
`GET /reading/bookapi/bookmall/cell/change/v1/`
- `web_page_key=common-rank-list-v1`（整页身份标识）
- `tab_type=2`, `cell_id=<同榜单卡>`, `algo_type=<当前榜>`, `offset=0`, `limit=12`
- `change_type=1`（进页）/ `4`（页内切榜）；`client_req_type=1`（进页）/ `4`（切榜）
- `genre_tab=2`(小说) + `genre_tab_list=2,3,4,5,6,7` ↔ `genre_tab_name_list=小说,出版,短剧,漫剧,听书,短篇`
- 男生/女生榜：`list_gender=1` 恒定，**`gender_list_type`: 1=男生榜，0=女生榜**
- `cell_gender=2`, `rank_sub_info_id=2`, `rank_list_style_type=1`, `list_type=daily`
- 响应自带映射（写死可用）：
  - `main_algo_name=推荐榜,完本榜,新书榜,书友榜,追更榜,黑马榜,巅峰榜,书荒榜,礼物榜,阅读榜,作者榜`
  - `main_algo_type=101,100,108,207,109,102,200,208,188,111,205`
- 分页行为：**一次请求带足 30+ 名**，滚动到底未触发新请求（offset/limit 服务端支持但客户端首屏用不上）

## algo_type 汇总（榜单家族）
| 榜 | algo_type |
|---|---|
| 推荐榜 | 101 |
| 完本榜 | 100 |
| 新书榜 | 108 |
| 书友榜 | 207 |
| 追更榜 | 109 |
| 黑马榜 | 102 |
| 巅峰榜 | 200 |
| 书荒榜 | 208 |
| 礼物榜 | 188 |
| 阅读榜 | 111 |
| 作者榜 | 205 |
| 小说频道 feed cell | 167 |

## 接入提示（对应 server /api/fqapp/fetch）
- 设备参数（iid/device_id/cdid/...）由 unidbg 侧自带，业务参数取上表即可
- cell_id/plan_id 是动态 ID，需先调 tab/v 从响应解析（HomeFeed 已解析 bookmall/tab，
  同一路径加 tab_type=2/25 即可拿到对应 cell）
- 响应体形状本次未抓（只抓了请求）；用 fqapp/fetch 回放一次 cell/change/v1/ 即可拿到
  榜单 JSON 结构（rank items: book_id/title/category/字数/新增阅读/连续更新天数）

## 漫画协议 — 实测（频道 feed + 详情 + 阅读）
1. **漫画频道 feed**: 同 bookmall 家族，**`tab_type=9` = 漫画频道**
   - 首屏内嵌 tab/v；滚动加载 `bookmall/cell/change/v?tab_type=9&cell_id=7023314149891375141&offset=0→20→...&limit=20&client_req_type=2`
2. **点封面直接进漫画阅读器**（详情浮层），一套请求：
   - `bookapi/comic_tab/comic_detail/v?book_id=` — 漫画详情（人气/评分/总话数）
   - `bookapi/directory/all_items/v?book_id=` — 话列表（与小说目录同端点）
   - **`reader/full/v?book_id=&item_id=`** — 单话内容（漫画版；参数与小说正文完全同形，无额外字段）
   - `reader/comic/conf/v` / `reader/comic/item_tail/recommend/v` / `ugc/comic/item/comment/v` — 配置/话尾推荐/评论
3. **翻页零签名请求** — 整话图片 URL 列表在 reader/full/v 一次下发，图片为 CDN 无签名直链（不经 tryAddSecurityFactor）
- 对接提示: 番茄自有漫画可以走 unidbg `/api/fqapp/fetch` 原样回放（raw body 透传），
  不必依赖腾讯动漫/拷贝漫画爬虫；解析差异只在响应（图片列表 vs txtContent）

## 搜索协议 — 实测（热词进入 + 输入联想 + 翻页）
1. **联想（每敲一次键盘一发）**: `GET /reading/bookapi/search/suggest/v:version/?q=<当前完整输入>`
   （参数名是 `q` 不是 query；need_preload=true）
2. **结果页首查**: `GET /reading/bookapi/search/tab/v`
   核心参数: `query=龙族&count=0&offset=0&tab_name=store&tab_type=1&search_source=1&use_correct=true`
   来源标识（热词点击时）: `clicked_content=hot_query_rank`、
   `search_id=rank_list#<ts>#514##1@<ts2>`、`search_source_id=rank_list#<ts>#514##`
3. **结果翻页**: 同端点同参数，**offset+=14**（首批 14 条；count=0 = 服务端默认每页 14）
   实测第二页: `search/tab/v?query=龙族&offset=14&count=0`
- 噪音参数（客户端行为遥测，回放可省）: last_book_id/last_chapter_id/last_consume_interval/
  last_search_page_query/normal_session_id/bookshelf_search_plan/only_feed/only_large_card/passback
- 与 unidbg `/api/fqsearch/books` 的上游（search/tab/v）一致 ✓；结果页顶部 tab
  （综合/漫剧/短剧/社区/漫画/听书）对应 tab_type/tab_name 取值差异，书类搜索用 store

## 正文（阅读器）协议 — 实测翻章验证
- **进阅读器首章**: `GET /reading/reader/full/v?item_id=<章ID>&book_id=<书ID>`
- **下一章/目录跳章**: `GET /reading/reader/batch_full/v?item_ids=<章ID>&book_id=<书ID>`
  （App 即使单章也走 batch 端点；与 unidbg FQNovelService 用的上游一致 ✓）
- **预取**: `GET /reading/reader/item_summary/mget/v?item_ids=<后续3章>,&book_id=...`
  （后续章节元数据摘要，非正文；翻页Within章不发任何请求）
- 章节ID来源: 详情页时 `bookapi/directory/all_items/v` 已拉全量目录
- 正文在响应 `data.txtContent` 明文，首行是章节名（unidbg 侧已知）

## 意外收获
- 误触进了详情页+阅读器：`bookapi/detail/v`、`directory/all_items/v`、`reader/...` 全套
  也在 jsonl 里（#172-#237），做详情页/阅读器协议时可直接翻

## 阅读器实测补录（同日下午，reader_urls.jsonl + r*.png）

场景：《我的师兄们，帅是真帅，穷是真穷》(7613292466841586713) 第 63 章（item
7635596458531504665）——生产 server 判「会员内容」拿不到的那一章。

1. **官方 App（未登录、AVD 设备 4052162698366793 / novelapp 73733）实测读到了第 63 章全文**。
   请求：`reader/full/v?item_id=7635596458531504665&key_register_ts=0&book_id=...`
   ——与 fq-unidbg `/api/fqapp/fetch` 回放的端点+业务参数**完全一致**（回放返回 0 字节）。
   结论：**该章不是付费权益墙**；AGENTS.md §9「付费章需账号」的旧结论对本章不成立。
2. 翻章协议链实测：详情页 `multi-detail/v` → 全量目录 `item_summary/mget/v`（~300 章分 3 批）
   → 首章 `reader/full/v` → 跳章 `reader/full/v`（单章）→ 预取 `batch_full/v?...&req_type=1`
   （一次 4-19 章不等）。item_id 与 server 库中 src_id 完全一致。
3. **0 字节的真因是设备资历**：11:39:51 生产 feed 风控触发自动轮换注册全新设备（OnePlus
   8646959051760540），11:40:50 用户切章——新设备对**所有**正文请求（含免费章）返回 0 字节，
   与「新注册设备 feed/目录正常但正文空响应」既有结论一致；网页端对该章只下发截断试读
   （isLockedTeaser 判 locked），于是 402 文案误标为「会员内容」。
4. **已实施修复（同日）**：把 AVD 设备身份（device_id 4052162698366793 / iid 252250513213995 /
   cdid b49e8968…，google sdk_gphone64_x86_64，国内 73733 注册）填入 oversea 68132 的
   unidbg 配置——**混搭被服务端接受**。先本地 jar 验证（fqapp/fetch 与 chapters/batch 均返回
   第 63 章完整解密正文 2948 字），随后替换生产 `/volume2/docker/books/fq-unidbg/config/
   application.yml`（备份 .bak1）并重启容器，`/api/books/34/chapters/62` 端到端返回全文。
   同时 compose `XS_UNIDBG_ROTATE` 1→0（备份 .bak6）：轮换保 feed 毁正文资历，是本次
   事故根因；设备被标记时手动 register+重启并评估资历代价。

## 推荐频道切子榜行为 — 实测（同日第三次采集，rankswitch_urls.jsonl）
- 切 推荐榜→完本榜→巅峰榜 每次只发**一发** `cell/change/v?tab_type=2&cell_id=<榜单卡>&
  algo_type=100/200/108&client_req_type=4&limit=16&offset=0`，只刷榜单卡自身
- 卡片下方瀑布流（漫剧/爆款大卡）**完全不动、零请求**——它是 tab/v（tab_type=-1）
  首屏内嵌的独立 feed，与榜单卡无任何关联
- 官方卡片视觉上固定展示 8 本（2×4），limit=16 是协议批量，9-16 不直接铺在页面上
- 结论：App 复刻应「卡片 top8 + 下方独立瀑布流」，9-16 不要渲染成列表挂在卡片下
  （会让用户误以为瀑布流跟榜联动）——fanqie_page.dart 已按此改造

## 猜你喜欢瀑布流翻页协议 — 实测（scroll2_urls.jsonl + 生产回放）
- 官方推荐频道下方瀑布流 = **「猜你喜欢」个性化 feed**（AGENTS §9 未接项，本次接通）
- 翻页请求：`cell/change/v?change_type=0&limit=10&cell_id=7011478717935386631&offset=12→24→36…&client_req_type=2&algo_type=167&tab_type=2&plan_id=0`
  - offset 起点 = tab/v 首屏内嵌卡片数（实测 12，含视频卡）；每页推进 = 响应实际卡片数（12）
  - **响应 data 自带 has_more / next_offset**，游标不用自己数
  - 响应结构：cell_view.cell_data 可多层嵌套，书卡在 book_data，漫剧卡是 video_data（无书）
  - feed cell_id（7011478717935386631）与榜单卡 cell_id 一样是服务端内容 ID，跨设备稳定
- server：appfeed 分区透传 cell_id/plan_id/algo_type/next_offset；
  新端点 `/api/store/appfeed/page`（AppFeedPage→FeedPage）回放翻页，生产已验证
- tab/v 在 unidbg 侧被内容风控期间（code=110）翻页端点仍可用，二者风控相互独立

## 推荐 Tab 架构定稿（同日）——彻底摆脱 tab/v
- 实测发现 tab/v 在 AVD 设备上 110 长时间不自愈（15:20→16:40+，远超此前 ~1h 的冷却经验），
  而同设备 cell/change 系全部正常——tab/v 是风控最敏感、行为最脆弱的端点，不值得依赖
- **推荐页改为纯 cell/change 架构**：
  - 推荐榜并入四榜统一机制（featured/recommend = 官方推荐榜 algo 101）
  - 猜你喜欢瀑布流直接从 offset=0 翻 cell/change（实测 offset=0 可用：12卡7书、next_offset=12）
  - server 端 DefaultFeedCellID 兜底，App 不带 cell_id 也能翻页
  - tab/v / HomeFeed / appfeed 从推荐页数据链路中退役（代码保留，别的场景还能用）
- 附带发现：AVD 设备与模拟器内真 App 同 device_id 双身份并发请求，疑似 tab/v 异常
  标记的诱因之一（cell/change 不受影响）；抓包时注意错峰或抓完即停 App

## ⭐ 根因定案：身份错配（同日晚）——必须全套冒充设备注册方
- AVD 设备（国内 novelapp 73733 注册）+ unidbg 68132 海外版身份（version_code/UA/SO），
  短暂可用后正文/ tab/v 必被标记（110 / 响应格式异常）——当天两次事故均为此因
- **改用 73733 全套身份（version_code=73733 / version_name=7.3.7.33 / UA com.dragon.read/73733），
  设备参数不变，全部端点立即恢复**：正文批量 code=0、tab/v code=0、瀑布流翻页正常
- 含义：上游风控校验「设备注册身份 vs 请求身份」一致性；unidbg 的 68132 SO 能为
  73733 参数生成有效签名（SO 只签 URL+headers，不校验版本号语义）
- 生产 fq-unidbg 配置已切 73733 身份（备份 .bak2），VM 端到端实测：
  装 APK → 登录 → 书城 → 目录跳章（第6章/第326章深章按需）全部正常
- 在线读代码层同日改为 batch-only（ChapterContentsBatch，当前章+下一章合并一请求）
