package handler

// App 应用内更新：App 启动后拉 /api/app/latest 比对 version_code，
// 有新版弹窗下载 /api/app/latest/apk 并拉起安装。
//
// 目录约定（XS_APP_APK_DIR 可覆盖，默认 /data/apks，宿主机 xiaoshuo_data/apks）：
//   latest.json  —— {"version_name":"1.1.0","version_code":2,"notes":"..."}（手写/发版脚本更新）
//   *.apk        —— 待分发的安装包（优先 latest.apk，否则取 mtime 最新的一个）
// 无 apk 或无 latest.json 时 Latest 返回 404，App 静默跳过（不影响使用）。
// 公开端点：下载走系统安装器，带不了 JWT；目录内容本身就是要分发的产物。

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

const apkContentType = "application/vnd.android.package-archive"

// apkVersionRe 版本串白名单（防路径穿越/垃圾文件名）
var apkVersionRe = regexp.MustCompile(`^[0-9A-Za-z._+-]{1,32}$`)

type AppUpdateHandler struct{}

func (h *AppUpdateHandler) dir() string {
	if d := os.Getenv("XS_APP_APK_DIR"); d != "" {
		return d
	}
	if st, err := os.Stat("/data"); err == nil && st.IsDir() {
		return "/data/apks"
	}
	return "data/apks"
}

// dirFor 渠道目录：prod=apks/，dev=apks/dev/（各含自己的 latest.json 与安装包），
// 测试发版不干扰生产更新通道
func (h *AppUpdateHandler) dirFor(channel string) string {
	base := h.dir()
	if channel == "dev" {
		return filepath.Join(base, "dev")
	}
	return base
}

// channelOf 解析请求渠道：仅认 "dev"，其余一律 prod（防垃圾参数建目录）
func channelOf(c *gin.Context) string {
	if c.Query("channel") == "dev" {
		return "dev"
	}
	return "prod"
}

// resolveApk 定位当前要分发的 apk：优先 latest.apk，否则 mtime 最新的 *.apk
func (h *AppUpdateHandler) resolveApk(dir string) (path string, size int64, sum string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", 0, "", err
	}
	type cand struct {
		path  string
		mtime int64
	}
	// 纯 mtime 最新者胜：Upload 端点落盘的是带版本号的文件名（保留历史），
	// 不做任何文件名特判（曾因硬编码优先 latest.apk 导致旧包压住新包）
	var cands []cand
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".apk" {
			continue
		}
		p := filepath.Join(dir, e.Name())
		if info, ierr := e.Info(); ierr == nil {
			cands = append(cands, cand{p, info.ModTime().UnixNano()})
		}
	}
	if len(cands) == 0 {
		return "", 0, "", os.ErrNotExist
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].mtime > cands[j].mtime })
	path = cands[0].path
	f, err := os.Open(path)
	if err != nil {
		return "", 0, "", err
	}
	defer f.Close()
	hsh := md5.New()
	size, err = io.Copy(hsh, f)
	if err != nil {
		return "", 0, "", err
	}
	return path, size, hex.EncodeToString(hsh.Sum(nil)), nil
}

// Latest 最新版本元数据：GET /api/app/latest（公开端点）
func (h *AppUpdateHandler) Latest(c *gin.Context) {
	dir := h.dirFor(channelOf(c))
	apkPath, size, sum, err := h.resolveApk(dir)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "暂无可用安装包"})
		return
	}
	var meta struct {
		VersionName string `json:"version_name"`
		VersionCode int64  `json:"version_code"`
		Notes       string `json:"notes"`
	}
	raw, err := os.ReadFile(filepath.Join(dir, "latest.json"))
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "latest.json 缺失"})
		return
	}
	if err := json.Unmarshal(raw, &meta); err != nil || meta.VersionCode <= 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "latest.json 格式无效（需 version_code>0）"})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{
		"version_name": meta.VersionName,
		"version_code": meta.VersionCode,
		"notes":        meta.Notes,
		"size":         size,
		"md5":          sum,
		"url":          absoluteReqURL(c, "/api/app/latest/apk?channel="+channelOf(c)),
		"apk_file":     filepath.Base(apkPath),
	})
}

// ApkFile 分发安装包：GET /api/app/latest/apk（公开端点，流式透传）
func (h *AppUpdateHandler) ApkFile(c *gin.Context) {
	apkPath, _, _, err := h.resolveApk(h.dirFor(channelOf(c)))
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "暂无可用安装包"})
		return
	}
	c.Header("Content-Type", apkContentType)
	c.File(apkPath)
}

// Upload 安装包上传：POST /api/app/upload?platform=android&version=1.1.1&version_code=3&notes=...
// multipart 字段 file=@xxx.apk；请求头 X-Upload-Token 必须等于 XS_UPLOAD_TOKEN
// （环境变量未配置 = 上传通道整体禁用）。落盘为 xiaoshuo-<version>.apk（保留历史，
// resolveApk 按 mtime 取最新），并重写 latest.json——build_all.ps1 发版脚本调用。
func (h *AppUpdateHandler) Upload(c *gin.Context) {
	want := os.Getenv("XS_UPLOAD_TOKEN")
	if want == "" {
		log.Printf("[app] 上传被拒：未配置 XS_UPLOAD_TOKEN")
		c.JSON(http.StatusForbidden, gin.H{"code": -1, "error": "上传通道未配置（XS_UPLOAD_TOKEN）"})
		return
	}
	if c.GetHeader("X-Upload-Token") != want {
		c.JSON(http.StatusForbidden, gin.H{"code": -1, "error": "上传 token 无效"})
		return
	}
	if c.Query("platform") != "android" {
		c.JSON(http.StatusBadRequest, gin.H{"code": -1, "error": "platform 仅支持 android"})
		return
	}
	version := c.Query("version")
	if !apkVersionRe.MatchString(version) {
		c.JSON(http.StatusBadRequest, gin.H{"code": -1, "error": "version 格式无效"})
		return
	}
	vcode, err := strconv.ParseInt(c.Query("version_code"), 10, 64)
	if err != nil || vcode <= 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": -1, "error": "version_code 无效"})
		return
	}
	notes := strings.TrimSpace(c.Query("notes"))
	if len(notes) > 1000 {
		notes = notes[:1000]
	}
	fh, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": -1, "error": "缺少 file 字段"})
		return
	}
	dir := h.dirFor(channelOf(c))
	if channelOf(c) == "dev" {
		_ = os.MkdirAll(dir, 0o755)
	}
	dest := filepath.Join(dir, "xiaoshuo-"+version+".apk")
	if err := c.SaveUploadedFile(fh, dest); err != nil {
		log.Printf("[app] 安装包保存失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"code": -1, "error": "安装包保存失败"})
		return
	}
	st, err := os.Stat(dest)
	if err != nil || st.Size() < 1<<20 { // 明显不是安装包（<1MB）
		os.Remove(dest)
		c.JSON(http.StatusBadRequest, gin.H{"code": -1, "error": "文件疑似无效安装包"})
		return
	}
	// latest.json 原子重写（临时文件 + rename）
	meta := map[string]any{
		"version_name": version,
		"version_code": vcode,
		"notes":        notes,
	}
	raw, _ := json.MarshalIndent(meta, "", "  ")
	tmp := dest + ".json.tmp"
	if werr := os.WriteFile(tmp, raw, 0o644); werr == nil {
		_ = os.Rename(tmp, filepath.Join(dir, "latest.json"))
	}
	log.Printf("[app] 新版本已上传: %s (version_code=%d, %d bytes)", dest, vcode, st.Size())
	c.JSON(http.StatusOK, gin.H{
		"code":         0,
		"version_name": version,
		"version_code": vcode,
		"size":         st.Size(),
		"apk_file":     filepath.Base(dest),
	})
}
