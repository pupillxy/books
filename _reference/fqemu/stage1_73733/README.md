# 阶段1 · 73733 采集记录（2026-10-01/02）

目标: 为 Medusa 纯算还原采集真值数据。模拟器只在采集时开机, 采集完可关。

## 已完成

### 环境重建（全部实测通过）
- fqsig AVD（x86_64, Android 15, google_apis）headless 启动:
  `emulator -avd fqsig -gpu swiftshader_indirect -memory 4096 -no-boot-anim -no-window -no-snapshot-save`
- `adb root` + `/data/local/tmp/frida-server -D`（16.7.19, 宿主机 frida 同版本）
- 番茄 7.3.7.33 (73733) 已装, base.apk 已拉取, `libmetasec_ml.so` 已提取（4.5MB ARM64, AES/MD5 常量仍为运行时解密, 静态搜不到）

### 签名 hook 链路 ✅
- **入口确认**: `com.bytedance.frameworks.baselib.network.http.NetworkParams.tryAddSecurityFactor(String, Map)` 在 73733 依然有效
- **关键坑**: spawn 后 300ms App dex 未加载 → `ClassNotFoundException`。
  解法: `Java.enumerateClassLoadersSync()` 逐个 loadClass 找到含目标类的 loader, 设 `Java.classFactory.loader` 再 hook（pass_a.js）
- **attach 模式不可用**（quick-boot 残留进程 attach 超时, 4 月也记录过反调试）, 必须 spawn
- 产出: `samples.jsonl` 55 组完整 (url, 6签名头), 其中 41 组为 bookapi 家族端点

### 73733 版本新确认（样本分析）
- `X-Argus = base64(时间戳 LE u32)` —— 与 4 月一致, 新版成立
- `X-Medusa[0:4] = LE(时间戳) 且 byte0 XOR 0x05` —— 10 组跨时间戳样本全部吻合（4 月在 71332 上观察到同样 0x05）
- `X-Medusa[4:20]` 并非纯设备常量, **随时间/计数微漂移**（同秒恒定, 跨秒逐位变化）→ 该字段是某种 (session, time) 派生, 必须拿到明文才能还原
- naive AES（4 月 71332 的 key=MD5("1967"+ab7cfe85+"1967")）ECB/CTR 试解 73733 body 全部失败 → key/magic 已换

### 环境重大认知: ndk_translation
- 本模拟器为 x86_64 + ARM 转译（**libndk_translation**, 非 houdini）
- 后果: guest ARM 代码不可被 Frida Interceptor hook（ARM libc 不在模块表里）→ **malloc 跟踪方案作废**（pass_b.js 弃用）
- 但 **guest 内存可读可扫**（Process.enumerateRanges('rw-') 含转译 guest 空间, guest 地址 ~0x14xxxxxx）
- 扫描注意: 大段（guest 堆/ART 堆 >512MB）必须按 256MB 分块扫, 不能跳过

### 内存扫描成果（pass_c, dumps_c/ 720+ 窗口）
- 针: device_id ASCII/LE、iid LE、cdid UUID、X-Medusa(自检)
- devid_le 命中 = 请求参数构造结构（device_id/host_aid/channel 参数对）, 非 Medusa 明文
- **cdid 窗口发现 3 个跨签名稳定 UUID**（handle 配置簇/会话 ID 候选）:
  - `570506ad-0a03-490a-b881-55de96e6d942`（6/6 签名出现）
  - `1d7095dc-ff21-4585-96bc-defec1ed5676`（6/6）
  - `c850462b-b296-4a4c-9f6a-20309906ab02`（5/6）
  - 同窗口含 "session"/"key" 字样 → 4 月笔记所述 Cluster B config 对象可被扫描定位
- 尚未定位到 Medusa 明文缓冲（可能不含原始设备字段, 或扫描时刻已被复用）

## 脚本
| 文件 | 用途 |
|---|---|
| pass_a.js / pass_a2.py | spawn + 类加载器枚举 hook, 抓 (url, 6头) → samples.jsonl |
| pass_b.js/py | malloc 跟踪（**转译环境不可用**, 留档） |
| pass_c.js/py | 签名瞬间全内存分块扫描（当前主力） |
| diag_mods.js | 模块枚举诊断 |

## 下一步
1. 用已知 body 二进制做针定位**密文缓冲区**, dump ±256KB, XOR 滑窗找明文候选（明文若含长零段/结构段可辨识）
2. 完整 dump handle 配置簇（cdid 窗口 ±64KB, 三个 UUID 全命中区域）→ VM+快照兜底路线的原料
3. 明文到手后做字段拟合; 卡住则转 dynarmic VM 快照路线（fqd-rs2 emulator.rs 现成, so 已重新提取）
4. 全程无需 PC 常驻: 采集完模拟器即关, 后续分析纯 PC 静态
