# 书城分类页协议采集与接入结论（2026-10-05）

> **实施状态（同日）**：server + App 已按本档案接入并装机验证——
> server 新端点 `GET /api/store/categories?gender=1|0`（标签树，6h 正缓存+陈旧值兜底）、
> `GET /api/store/categoryfeed?category_id=&gender=&filters=&offset=`（书单，3min 正/60s 负
> 缓存，filters 白名单同 novelfeed）；unidbg.go 新增 `CategoryFront`/`CategoryLanding`。
> App 书城搜索框右侧新增「分类」按钮 → `store_category_page.dart`（男生/女生频道 +
> 左侧栏分组 + 三列标签墙）→ `store_category_result_page.dart`（banner 语 + 相关分类词条
> + 字数/状态/排序三行筛选 + 评分书单行卡，无限滚动）。
> 端到端装机验证：男/女频道标签树、玄幻/现代言情书单、完结筛选、滚动翻页、
> 相关分类整页跳转全通；女生·现代言情页与官方 App 截图逐项一致（banner 文案、
> 相关词、书单同序）。

环境：fqsig AVD（emulator-5554）+ 番茄 7.3.7.33 + frida hook
`tryAddSecurityFactor`（spawn 模式，复用 capture_xiaoshuo_1003/capture_rank.js）。
采集 176 发（capture_urls.jsonl）；UI 由 adb input 驱动；采集后已 force-stop。

## 1. ⭐ 分类页两个端点（App 实测定案）

书城页搜索框右侧「分类」按钮 → 分类页（男生/女生/听书/出版/短剧/漫画顶部 tab +
热门标签/主题/角色/情节左侧栏 + 标签墙）。点标签 → 标签书单落地页。

### 1.1 标签树 `GET /reading/bookapi/new_category/front/v:version/`

- query：`source=&distinct_style=1&new_category_tab=<T>&category_new_page_715=0` + 公共参数
- **`new_category_tab`**：`-1`=默认页（服务器判定 default_tab=1=男生，回男生树）；
  `0`=女生；`1`=男生。官方全集 tab_type_list=`[1,0,3,2,6,5]` ↔
  tab_name_list=`[男生,女生,听书,出版,短剧,漫画]`（`category_tab_config` 每响应都带）
- 响应：`category_tab_data{category_tab, tab_name, cell_data[]}`，
  `cell_data[i] = {cell_name: 热门标签|主题|角色|情节, atom_data[].category_data{name,
  category_id, pic_url, category_landpage_url}}`
- 标签 `category_id` 全局唯一（玄幻=7、都市=1、现代言情=3、悬疑脑洞=539…）
- 样本：resp_front_male.json（男生 25/46/19/82 个标签）、resp_front_female.json（女生）

### 1.2 标签书单 `GET /reading/bookapi/new_category/landing/v`

- query：`offset=<N>&genre_type=0&category_type=0&is_merged_landing_page=false&
  source=front_category&category_id=<ID>&category_new_page_715=0&limit=20&page_version=2&
  no_need_all_tag=false&query_gender=<0|1>&client_req_type=<T>[&selected_items=<逗号串>]`
- **`client_req_type`**：`3`=首屏 / `4`=筛选变更 / `2`=翻页（与 bookmall cell/change 同族语义）
- **`query_gender`**：0=女生 1=男生（跟频道走；同一 category_id 在两频道树都有时以此区分）
- **`selected_items`**：与筛选条一一对应，逗号多选，值即筛选行下发的 selector_item_id
- 响应：`selector.rows[]`（筛选行服务端下发）、`category{description}` /
  `category_desc{desc}`（落地页绿色 banner 语）、`book_info[]`、`offset`、`has_more`
- `book_info` 字段与 bookmall 同族（book_id/book_name/author/abstract/category/thumb_url/
  tags/word_number/score/serial_count），**read_count 是原始数字**（"1167785"），需自行
  格式化成 "116.8万人在读"
- **creation_status 语义与 bookmall 一致：0=完结 1=连载**（完结筛选回放 20 本全 0 实测）
- 样本：resp_landing_xuanhuan.json（limit=10 原始抓包同款）、resp_landing_filtered.json
  （word_num_gte200+creation_status_end+sort_score 组合，limit=20）

### 1.3 官方筛选 selector_item_id 全集（landing 响应 rows[] 实测）

| 行 | 取值 |
|---|---|
| 字数 | word_num_default / word_num_lte10 / lte30 / lte50 / gte30 / gte50 / gte100 / gte200 / gte300 / gte500 |
| 状态 | creation_status_default / _end(完结) / _half_year_end / _loading(连载中) / _3day_update / _7day_update / _1month_update |
| 排序 | sort_default(综合) / sort_new_book(新书) / sort_score(高分) / sort_word_number(字数) |
| 相关分类 | cate_<id>（该分类的子分类/相邻分类，可整页跳转，如玄幻→cate_257玄幻脑洞） |

注意：bookmall 频道筛选条的 `finished`/`word_num_gt_200w` 风格值与这里不同族
（`creation_status_end`/`word_num_gte200`），两套 selected_items 体系不通用。

## 2. 生产回放验证（fqapp/fetch）

- `new_category/front/v:version/`：**`v:version` 路径后缀是 App 原样发出的字面量，照抄可用**
- `new_category/landing/v`：无后缀；limit=20 与 selected_items 组合均生效
- 两个端点在 73733 设备 + 生产 unidbg 下均 code=0，未见风控（非 tab/v 敏感家族）

## 3. App 协议路径宝库（dex 字符串提取）

`apk_bookapi_paths.txt` = 番茄 7.3.7.33 dex 里全部 `/reading/bookapi/` 路径（199 个）。
本轮分类页即由此定位（`category/list/v`、`new_category/front|cell|landing/v` 等候选，
再经真机抓包确认实际调用）。后续接新页面先翻这份清单。

## 4. 运维/踩坑（本轮新增）

- **AVD 内核路由丢失**：模拟器冷启动后 app 全部卡启动页（网络图标 3G），
  `adb shell ip route` 只有 link 路由没有 default。修复：`adb root` +
  `ip route add default via 10.0.2.2 dev eth0`。宿主 ICMP 转发被 Windows 防火墙挡掉
  （ping 223.5.5.5 全丢），**判定模拟器断网要用 TCP 测试**（`nc -w3 -z 223.5.5.5 53`），
  别只看 ping。
- fq-unidbg 容器端口映射实际是 `192.168.31.16:9999`（LAN IP，非 127.0.0.1），PC 可直连。
- main.go 曾把 `/store/library/categories` 路由吞进行尾注释（编辑事故，本轮修复）——
  新增路由后用 `go build` 之外的 grep/日志复核一次注册生效。
- flutter 3.27 的 APK 输出路径是 `app/build/app/outputs/flutter-apk/`（多一层 app/）。

## 5. 已知未做

- 官方分类页还有 听书/出版/短剧/漫画 三个内容形态的频道（tab id 3/2/6/5），本服务
  只透出小说两频道（男生/女生）；漫画在书城已有独立频道，听书/短剧内容形态未接。
- 分类页左侧栏「角色/情节」分组官方各有 19/82 个标签，全量透出（无裁剪）。
- landing 的相关分类词条跳转后筛选重置为默认（官方行为同款，未做联动记忆）。
