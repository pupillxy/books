# fqnovel-unidbg 部署验证记录（2026-10-02）

来源: https://github.com/zero199901/fqnovel-unidbg (135★)
本地路径: `_reference/fqnovel-unidbg-src/`（已构建出 jar）

## 本机验证结果：全链路通过 ✅

| 接口 | 结果 |
|---|---|
| `GET /api/fq-signature/health` | `{"status":"UP"}` — unidbg 加载海外版 SO 成功 |
| `GET /api/fqsearch/books?query=剑来&count=5` | ✅ 真实数据（bookId 7038808223788305445，烽火戏诸侯《剑来》） |
| `GET /api/fqsearch/directory/{bookId}` | ✅ 502 章完整目录（item_id/title/version/chapter_index） |
| `GET /api/fqnovel/chapter/{bookId}/{itemId}` | ✅ 第1章《初遇》2235 字明文（`data.txtContent`）+ HTML 版（`data.rawContent`） |

**意义**: X-Helios/X-Medusa 由 SO 在 unidbg 里自算自初始化，番茄服务器直接接受——无需手机、无需安卓模拟器、无需 frida。

## 本机复现步骤

```sh
# 环境: ~/.jdks/jdk-17（已有），Maven 3.9.9（_reference/maven-home/maven，华为云镜像下载）
# ~/.m2/settings.xml 已配阿里云镜像（central）
export JAVA_HOME="C:\Users\94985\.jdks\jdk-17"
cd _reference/fqnovel-unidbg-src
../maven-home/maven/bin/mvn.cmd -q -DskipTests package     # 已构建: target/unidbg-boot-server-0.0.1-SNAPSHOT.jar
~/.jdks/jdk-17/bin/java.exe -Dfile.encoding=UTF-8 -jar target/unidbg-boot-server-0.0.1-SNAPSHOT.jar
# 服务端口 9999
```

## 可用接口（Go server 对接用）

- `GET /api/fqsearch/books?query=&tabType=1&offset=0&count=20` — 搜索
- `GET /api/fqsearch/directory/{bookId}` — 目录
- `GET /api/fqsearch/chapters/{bookId}` — 章节元数据（含 content_md5，无正文）
- `GET /api/fqnovel/book/{bookId}` — 书籍信息
- `GET /api/fqnovel/chapter/{bookId}/{chapterId}` — 单章正文（txtContent 明文）
- `POST /api/fqnovel/chapters/batch` — 批量正文（**推荐**，单章接口高频会 ILLEGAL_ACCESS 设备风控）
- `POST /api/device/register` + `POST /api/device/update-config` — 设备注册/切换
- `GET /api/fq-signature/test?url=` — 裸签名测试（需带完整 App 参数模板的 URL，否则签名失败是正常的）

## 实测运维发现（2026-10-02 压测得出）

1. **设备生命周期**：持续高频请求 → 设备被标记（批量/单章报「响应格式异常，请手动更新设备信息」）
   → `POST /api/device/register` 换新设备后**必须重启容器**才生效（autoUpdateConfig 不可靠，实测未落盘 yml）。
2. **IP 级限流**：设备换了也没用、搜索都 -1 = IP 被限。冷却几十分钟自愈。
   生产限速建议：3s/批（每批 20 章），整本 500 章 ≈ 2 分钟；异常时任务失败可随时重试（断点续传只拉缺失章）。
3. **上游偶发抖动**：GZIP 格式错/响应格式异常偶发出现，请求层已带 3 次退避重试。
4. **集成状态**：Go server 已接入（`server/internal/unidbg/`）——下载优先 unidbg、TND 兜底；
   搜索/详情/目录网页端优先、unidbg 兜底；`XS_UNIDBG_URL` 留空全部回退旧行为。App 零改动。

## 注意事项

1. 设备配置在 `application.yml` 的 `fq.device`（海外版 GP 模板 WLZ-AN00/68132，install_id 需自行注册刷新）
2. 不要高频调单章接口，用 batch；书源场景不要缓存章节
3. jar 跨架构（纯 Java），NAS docker 直接跑：`docker run -v ... openjdk:17 java -jar ...`
4. Go server 对接: 仿 `server/internal/tnd/tnd.go` 加一个 HTTP client 指向 9999
