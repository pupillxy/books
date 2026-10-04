# 书城频道 tab（小说筛选条 + 漫画）协议采集结论（2026-10-04）

> **实施状态（同日）**：server + App 已按本档案接入——
> server 新端点 `/api/store/novelfeed`（cell/change tab_type=25 + selected_items 白名单筛选，
> 3min 正缓存/60s 负缓存）、`/api/store/comicfeed`（tab_type=9）、`/api/store/comics/:id`
> （comic_detail + all_items）、`/api/store/comics/:id/chapters/:itemID`（reader/full 宽容
> 图片解析 + decrypt-content 兜底）；unidbg.go 顺带修正书城卡 creation_status 语义
> （0=完结 1=连载，与详情接口相反——完本榜 30 本全 0 实测定案）。
> App 书城砍成 推荐/小说/漫画 三频道：小说=筛选条+双列大卡瀑布流（筛选值与频道偏好联动），
> 漫画=双列卡 → StoreComicDetailPage（话列表）→ StoreComicReaderPage（竖屏滚图，
> 当前话打开即预取下一话）。端到端已在模拟器装机验证（novelfeed/comicfeed/详情均通；
> 单话图片端到端验证受设备内容风控 110 影响待冷却后复核，解析有离线单测兜底）。

环境：fqsig AVD（emulator-5554, 1080x2400）+ 番茄 73733 + frida hook
`tryAddSecurityFactor`（复用 capture_xiaoshuo_1003/capture_rank.js，spawn 模式）。
采集：channel_run.py + channel_urls.jsonl（171 发）；UI 由 adb input 驱动。
采集结束即 force-stop App（避免与生产 unidbg 双身份并发——10/03 教训）。

## 1. 书城频道 tab 家族（bookmall/tab/v 的 tab_type 实测补全）

切频道 = `GET /reading/bookapi/bookmall/tab/v?tab_type=<X>&offset=0&client_req_type=4`：

| 顶部 tab | tab_type | 备注 |
|---|---|---|
| 推荐 | **-1** | 已知（10/03） |
| 小说 | **25** | 已知；本次实测带筛选条 |
| 漫画 | **9** | 已知（10/03），本次复核一致 |
| 经典/知识/听书/短篇/新书 | 未逐个点 | 同族端点，切 tab 必发 tab/v |

- 冷启动进推荐：`tab_type=-1, client_req_type=3`；bottom tab 切回：`client_req_type=1024`
- **tab/v 是风控最敏感端点**（采集后经生产 fqapp/fetch 回放 tab/v=110 ILLEGAL_ACCESS，
  同一时刻 cell/change 回放 code=0 —— 再次印证 10/03「摆脱 tab/v」的架构决策）

## 2. ⭐ 小说频道筛选条协议（本次新定案）

频道顶部筛选条（完结/一年内上架/200万字以上/男生 + 右侧漏斗角标）：

- **筛选/翻页统一走** `GET /reading/bookapi/bookmall/cell/change/v`：
  - `tab_type=25&algo_type=167&cell_id=7011478717935386631&plan_id=<动态>&offset=0`
  - **`selected_items=<逗号多选>`** ← 筛选编码就在这一个参数
  - `unlimited_selector_change_type=2`（筛选变更标记）、`client_req_type=2`
- **筛选取值实测**（多选累加，组内互斥的会被替换）：

| UI 文案 | selected_items 值 |
|---|---|
| 完结 | `finished` |
| 一年内上架 | `online_in_past_one_year` |
| 200万字以上 | `word_num_gt_200w` |
| 男生 / 女生 | `male` / `female`（组内互斥） |
| 编辑推荐（筛选器面板） | `bian_ji_tui_jian`（拼音！其他大概率也是拼音风格） |

- 组合示例：`selected_items=bian_ji_tui_jian,online_in_past_one_year,finished,word_num_gt_200w,female`
  （顺序=面板分组顺序：综合 → 上架时间 → 更新状态 → 字数 → 性别）
- **筛选器面板**（点漏斗角标弹出，底部弹窗）全量选项（未逐一抓值）：
  - 综合：编辑推荐 / Lv4及以上作者 / 书友淘金 / 老书虫在看 / “细糠” / 多人催更 / 多人二刷 / 多人追评
  - 上架时间：7/14/30天内上架、半年内、一年内上架
  - 更新状态：完结 / 连载中 / 半年内完结 / 3日/7日/1月内更新
  - 字数偏好：10万/30万/50万/100万/200万/500万字以上
  - 性别偏好：男生 / 女生；按钮：清空 / 确定(N)
- 快捷条每次勾选立即发一发 cell/change；面板在「确定」时统一发一发
- 筛选结果过少时响应 `has_more=false`，页面显示「已显示全部内容」（5 重筛选实测仅几本）
- `tab/v?tab_type=25` 里也有 `filter_ids`（空），但它不是筛选载体，筛选走 cell/change

## 3. 漫画频道（复核 + 补充）

- 切漫画 tab：`tab/v?tab_type=9&offset=0&client_req_type=4`（首屏内嵌响应）
- 滚动加载：`cell/change/v?tab_type=9&cell_id=7023314149891375141&offset=0&client_req_type=2`
  - **cell_id 与 10/03 档案完全一致**（跨设备稳定，可写死兜底）
  - 漫画 feed **不带 algo_type**（小说频道 feed 是 167）
- 漫画卡文案：`小说漫改·日更·N人在读` / `男生情感·已完结·N人在读`（阅读状态在卡上）
- 漫画详情+阅读全套（10/03 已实测，维持有效）：
  `comic_tab/comic_detail/v?book_id=` → `directory/all_items/v?book_id=` →
  `reader/full/v?book_id=&item_id=`（整话图片 CDN 无签名直链一次下发）

## 4. 生产回放验证（fqapp/fetch，App 强停后）

- `POST /api/fqapp/fetch {"path":"/reading/bookapi/bookmall/cell/change/v",
  "query":"tab_type=25&offset=0&client_req_type=2&algo_type=167&cell_id=7011478717935386631&plan_id=7462280048842653758&change_type=0&limit=0&selected_items=finished"}`
  → **code=0**，data: `cell_view/has_more/next_offset/session_id`
  - 实测 17 cell / 12 本书，`creation_status` 全 0（=完结，筛选服务端真实生效）
  - `has_more=true, next_offset=12` —— 游标由服务端下发，翻页不用自己数
  - 书卡字段与 HomeFeed 同族：book_id/book_name/author/category/word_number/score/thumb_url/tags…
- 同时刻 tab/v 回放 110 —— **server 接筛选频道应走纯 cell/change 架构**（同推荐页定案）

## 5. ⭐ 漫画图片文件加密算法（10/04 Frida hook 定案，md5 逐张验证）

CDN 图片直链下载后**不是明文图片**（header 无 jpeg/png 魔数，每张不同、高熵）：

- **文件布局**：`nonce(12B) ‖ AES-256-GCM 密文 ‖ tag(16B)`（GCM 流式，长度任意）
- **密钥**：该话 `encrypt_key`（64 hex 字符 = 32B），随 reader/full 密文 content
  解密后的 JSON 下发（与 picInfos/lowPicInfos 同级）。结构 = 固定前缀
  `"1967196719671967"`（ASCII，aid=1967）+ 每话 16B 变量，全话所有图共用
- **nonce** = 文件自身前 12 字节（服务端下发时就地前缀，无需额外传递）
- 明文 = 标准 JPEG（`ffd8ffdb` 开头），md5 == picInfos[].md5 ✓
- hook 实测：`javax.crypto` AES/GCM/NoPadding，key=32B，单图 40-80 万字节级调用
- **Go 实现坑**：`gcm.Open(nil, nonce, data[12:], nil)` —— tag 必须附在密文尾部
  一起传入（第 4 参是 AAD；把 tag 单独当 AAD 传会 message authentication failed）

reader/full 响应结构（10/04 全量）：`data.content`=密文(base64)、`data.key_version`
（解密用，传给 decrypt-content）、`data.crypt_status/text_type/parse_mode` 等元数据、
`data.novel_data`=书籍信息卡。解密后 JSON：`{itemId, picInfos[], encrypt:true,
encrypt_key, lowPicInfos[]}`（picInfos 元素 = picUrl/width/height/md5）。

## 6. server/App 实施状态（同日）

- `/api/store/comicimg`（公开端点，HMAC 签名即鉴权，同短剧 stream/cover 模式）：
  server 实时下载 CDN 加密图 → GCM 解密 → 明文 JPEG 透传；`/comics/:id/chapters/:itemID`
  返回签名代理地址（12h 时效），App Image.network 零改动
- 端到端验证：novelfeed/comicfeed/漫画详情/话列表全通；单话图片 md5 吻合；
  模拟器装机 UI 验证三频道+详情+阅读器（图片渲染待 reader/full 风控冷却后复核）
