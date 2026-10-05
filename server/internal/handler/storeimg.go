package handler

// 书城图片代理：书城浏览封面（/api/store/img）与书架封面（/api/store/cover/:fid）
// 统一收口到本服务，磁盘缓存 + singleflight 去重 + 匀速限速/并发闸 + 负缓存 + 熔断
// （机制与 drama cover.go 同款，闸门实例独立）。动机（10/05 定案）：
//  1. 性能：上游封面是番茄 CDN 签名直链，App 直连 = 首屏十几条并发 TLS 握手
//     （dart:io 握手在 UI isolate 执行，正是书城滚动掉帧的来源）。收口到 NAS
//     单主机后 keep-alive 连接复用，握手风暴消失，LAN TTFB 毫秒级。
//  2. 持久：入库存的签名直链 x-expires 约 1~2 个月就 403（书架 24/56 本封面
//     已实测阵亡）。磁盘缓存落盘后永久可服务；签名死了由 /cover/:fid 用详情
//     刷新拿新链自愈并回写 DB。
// 出参改写（imgOut）把 http(s) 封面换成绝对代理地址，App 侧 Image.network
// 本来就吃绝对 URL，零改动。

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"xiaoshuo/internal/fanqie"
	"xiaoshuo/internal/model"
)

// storeImgSignTTL 代理签名时效：出参每次响应都现签，唯一吃长时效的是
// 瀑布流 DB 回放缓存（feed_cache 最长 6h），1 年绰绰有余
const storeImgSignTTL = 365 * 24 * time.Hour

// storeImgDirDefault 图片缓存目录：Docker 数据卷 /data/imgcache；本机开发 data/imgcache
func storeImgDirDefault() string {
	if d := os.Getenv("XS_STORE_IMG_DIR"); d != "" {
		return d
	}
	if st, err := os.Stat("/data"); err == nil && st.IsDir() {
		return "/data/imgcache"
	}
	return "data/imgcache"
}

// initImg 惰性初始化（StoreHandler 在 main.go 是字面量构造，无构造函数）
func (h *StoreHandler) initImg() {
	h.imgOnce.Do(func() {
		h.imgDir = storeImgDirDefault()
		h.imgGate = newCoverGate()
		h.imgHTTP = &http.Client{Timeout: 30 * time.Second}
	})
}

// signStoreImg 上游图片 URL → 签名相对代理路径（已是相对路径则原样返回）。
// **确定性签名**：载荷只有 URL、不带时效，同一上游 URL 永远得到同一代理地址——
// 详情页每 3s 轮询下载状态，若每次现签新链，客户端图片缓存按 URL 失效，
// 封面会在占位图与真图间反复闪烁（10/06 实测回归，详见下面的兼容说明）。
// 图片是公开 CDN 资源且磁盘缓存本就永久，签名不带时效无风险。
func (h *StoreHandler) signStoreImg(rawurl string) string {
	if rawurl == "" {
		return ""
	}
	if strings.HasPrefix(rawurl, "/") {
		return rawurl
	}
	encoded := base64.RawURLEncoding.EncodeToString([]byte(rawurl))
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	return "/api/store/img?p=" + encoded + "&s=" + hex.EncodeToString(mac.Sum(nil))[:32]
}

// imgOut 出参改写：http(s) 封面 → 绝对代理地址；空/非 http（本地路径等）原样返回
func (h *StoreHandler) imgOut(c *gin.Context, rawurl string) string {
	if !isCoverURL(rawurl) {
		return rawurl
	}
	return absoluteReqURL(c, h.signStoreImg(rawurl))
}

// rewriteLibraryCovers 批量改写 LibraryBook 列表的封面出参
func (h *StoreHandler) rewriteLibraryCovers(c *gin.Context, books []fanqie.LibraryBook) {
	for i := range books {
		books[i].Cover = h.imgOut(c, books[i].Cover)
	}
}

// fetchStoreImg 单次上游抓取（不重试；限速/熔断由闸门负责）
func (h *StoreHandler) fetchStoreImg(rawurl string) ([]byte, string, error) {
	req, err := http.NewRequest(http.MethodGet, rawurl, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", coverUserAgent)
	req.Header.Set("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
	resp, err := h.imgHTTP.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", &coverStatusError{code: resp.StatusCode}
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, coverMaxBytes+1))
	if err != nil {
		return nil, "", err
	}
	if len(data) > coverMaxBytes {
		return nil, "", fmt.Errorf("图片超过 %dMB 上限", coverMaxBytes>>20)
	}
	ctype := strings.TrimSpace(strings.SplitN(resp.Header.Get("Content-Type"), ";", 2)[0])
	if !strings.HasPrefix(ctype, "image/") {
		ctype = http.DetectContentType(data)
	}
	return data, ctype, nil
}

// serveStoreImg 磁盘命中/抓取成功后的统一透出（immutable：URL 载荷绑死具体上游地址）
func serveStoreImg(c *gin.Context, data []byte, ctype, cache string) {
	c.Header("Cache-Control", "public, max-age=31536000, immutable")
	c.Header("X-Img-Cache", cache)
	c.Data(http.StatusOK, ctype, data)
}

// verifyStoreImgPayload 校验 p/s 签名参数，返回上游 URL（仿 ComicImg）
func (h *StoreHandler) verifyStoreImgPayload(c *gin.Context) (rawurl string, ok bool) {
	encoded := c.Query("p")
	signature := c.Query("s")
	if encoded == "" || signature == "" {
		return "", false
	}
	payload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return "", false
	}
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	if hex.EncodeToString(mac.Sum(nil))[:32] != signature {
		return "", false
	}
	// 载荷兼容两种格式：rawurl（现行确定性签名）与 rawurl|expires（旧格式，
	// feed_cache 6h 回放缓存里可能残留），旧格式仍校验时效
	parts := strings.Split(string(payload), "|")
	switch len(parts) {
	case 1:
		return parts[0], true
	case 2:
		expires, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || time.Now().Unix() > expires {
			return "", false
		}
		return parts[0], true
	default:
		return "", false
	}
}

// Img 书城图片代理：GET /api/store/img?p=&s=（公开端点，签名即鉴权——
// Flutter 的 Image.network 带不了 Authorization）。
// 浏览面出参每次现签新链，上游签名短期过期无碍：磁盘命中不依赖上游活性。
func (h *StoreHandler) Img(c *gin.Context) {
	rawurl, ok := h.verifyStoreImgPayload(c)
	if !ok || !isCoverURL(rawurl) {
		c.JSON(http.StatusForbidden, gin.H{"error": "图片地址无效或已过期"})
		return
	}
	h.initImg()
	key := coverKey(rawurl)
	if data, ctype := loadCover(h.imgDir, key); data != nil {
		serveStoreImg(c, data, ctype, "hit")
		return
	}
	data, ctype, err := h.imgGate.do(key, func() ([]byte, string, error) {
		release, allowed := h.imgGate.acquire(key)
		if !allowed {
			return nil, "", errCoverGated
		}
		defer release()
		data, ctype, err := h.fetchStoreImg(rawurl)
		h.imgGate.record(key, err == nil, coverStatus(err))
		if err != nil {
			return nil, "", err
		}
		storeCover(h.imgDir, key, data)
		log.Printf("[store] img 上游抓取 %s (%d bytes, %s)", rawurl, len(data), ctype)
		return data, ctype, nil
	})
	if err != nil {
		if err == errCoverGated || coverStatus(err) == http.StatusNotFound || coverStatus(err) == http.StatusGone {
			c.JSON(http.StatusNotFound, gin.H{"error": "图片暂不可用"})
			return
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": "图片获取失败"})
		return
	}
	serveStoreImg(c, data, ctype, "miss")
}

// rewriteRankCovers 同上，榜单条目（fanqie.RankBook）
func (h *StoreHandler) rewriteRankCovers(c *gin.Context, books []fanqie.RankBook) {
	for i := range books {
		books[i].Cover = h.imgOut(c, books[i].Cover)
	}
}

// rewriteShelfCover 书架/书库出参：番茄签名直链 → 本服务书架封面端点（磁盘缓存 +
// 过期自愈）。本地书封面是 downloads/ 本地路径（/covers 静态服务），原样放行。
func rewriteShelfCover(c *gin.Context, b *model.Book) {
	if b == nil || b.FanqieID == "" || !isCoverURL(b.Cover) {
		return
	}
	b.Cover = absoluteReqURL(c, "/api/store/cover/"+b.FanqieID)
}

// bookCoverURL 书架封面源 URL：DB 存量直链优先；refresh=true 强制详情刷新拿新链
// （签名过期自愈），刷新成功回写 DB，下次直接用新 URL。小说详情失败退漫画详情
// （书架也可能有轻量入库的漫画，封面同为番茄 CDN 直链）。
func (h *StoreHandler) bookCoverURL(fid string, refresh bool) (string, error) {
	if !refresh {
		if bk, err := h.DB.GetBookByFanqieID(fid); err == nil && isCoverURL(bk.Cover) {
			return bk.Cover, nil
		}
	}
	cover, err := h.refreshCoverURL(fid)
	if err != nil {
		return "", err
	}
	if bk, berr := h.DB.GetBookByFanqieID(fid); berr == nil {
		if uerr := h.DB.UpdateBookCover(bk.ID, cover); uerr == nil {
			log.Printf("[store] 书架封面签名过期已自愈 fid=%s", fid)
		}
	}
	return cover, nil
}

// refreshCoverURL 详情刷新拿新签名封面直链：小说（App 协议优先、网页兜底）→ 漫画
func (h *StoreHandler) refreshCoverURL(fid string) (string, error) {
	if d, err := h.getBookDetail(fid); err == nil && isCoverURL(d.Cover) {
		return d.Cover, nil
	}
	if info, _, err := h.fetchComic(fid); err == nil && isCoverURL(info.ThumbURL) {
		return info.ThumbURL, nil
	}
	return "", errors.New("详情不可用，无法刷新封面")
}

// fetchBookCover 抓取书架封面字节：磁盘未命中时走 DB 直链，403/410（签名过期）
// 自动详情刷新换新链重试一次。同一 fid 并发请求经 singleflight 合并。
func (h *StoreHandler) fetchBookCover(fid string) ([]byte, string, error) {
	key := "book_" + fid
	return h.imgGate.do(key, func() ([]byte, string, error) {
		url, err := h.bookCoverURL(fid, false)
		if err != nil {
			return nil, "", err
		}
		ukey := coverKey(url)
		release, allowed := h.imgGate.acquire(ukey)
		if !allowed {
			return nil, "", errCoverGated
		}
		data, ctype, err := h.fetchStoreImg(url)
		h.imgGate.record(ukey, err == nil, coverStatus(err))
		release()
		if err != nil {
			st := coverStatus(err)
			if st != http.StatusForbidden && st != http.StatusGone {
				return nil, "", err
			}
			// 签名过期：详情刷新拿新链再试一次（自愈），仍失败才报错
			url2, rerr := h.bookCoverURL(fid, true)
			if rerr != nil {
				return nil, "", err
			}
			ukey2 := coverKey(url2)
			release2, allowed2 := h.imgGate.acquire(ukey2)
			if !allowed2 {
				return nil, "", errCoverGated
			}
			defer release2()
			data, ctype, err = h.fetchStoreImg(url2)
			h.imgGate.record(ukey2, err == nil, coverStatus(err))
			if err != nil {
				return nil, "", err
			}
		}
		storeCover(h.imgDir, key, data)
		return data, ctype, nil
	})
}

// StoreBookCover 书架封面：GET /api/store/cover/:fanqieID（公开端点，与 /covers
// 静态服务同级信任：fid 只指向书封，无敏感数据）。
// 磁盘 key 绑 fid 不绑 URL：签名刷新换链不影响缓存命中，落盘一次永久可服务。
func (h *StoreHandler) StoreBookCover(c *gin.Context) {
	fid := c.Param("fanqieID")
	if !fanqie.ValidateBookID(fid) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "书籍 ID 无效"})
		return
	}
	h.initImg()
	if data, ctype := loadCover(h.imgDir, "book_"+fid); data != nil {
		serveStoreImg(c, data, ctype, "hit")
		return
	}
	data, ctype, err := h.fetchBookCover(fid)
	if err != nil {
		st := coverStatus(err)
		if err == errCoverGated || st == http.StatusNotFound || st == http.StatusGone || st == http.StatusForbidden {
			c.JSON(http.StatusNotFound, gin.H{"error": "封面暂不可用"})
			return
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": "封面获取失败"})
		return
	}
	serveStoreImg(c, data, ctype, "miss")
}
