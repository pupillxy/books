package main

import (
	"log"
	"os"
	"time"

	"github.com/gin-gonic/gin"

	"xiaoshuo/internal/config"
	"xiaoshuo/internal/database"
	"xiaoshuo/internal/fanqie"
	"xiaoshuo/internal/handler"
	"xiaoshuo/internal/hongguo"
	"xiaoshuo/internal/middleware"
	"xiaoshuo/internal/scanner"
	"xiaoshuo/internal/tnd"
	"xiaoshuo/internal/unidbg"
)

func main() {
	cfg := config.Load()

	// 仅当使用容器默认路径且本机无 /data 时（Windows 开发环境）才重定向到 ./data
	if cfg.DBPath == "/data/xiaoshuo.db" {
		if dir := detectLocalDataDir(); dir != "" {
			log.Printf("使用本地数据目录: %s", dir)
			cfg.DBPath = dir + "/xiaoshuo.db"
			cfg.DownloadDir = dir + "/downloads"
		}
	}
	os.MkdirAll(cfg.DownloadDir, 0o755)

	sqlDB, err := database.Open(cfg.DBPath)
	if err != nil {
		log.Fatal("打开数据库失败: ", err)
	}
	store := database.NewStore(sqlDB)

	if err := store.EnsureAdmin(cfg.AdminUser, cfg.AdminPass); err != nil {
		log.Fatal("初始化管理员失败: ", err)
	}

	sc := scanner.New(store, cfg.DownloadDir)
	// 启动即扫描 + 定时扫描 + 有下载任务时加速轮询（60s，尽快发现 TND 下载完成的文件）
	go func() {
		sc.RunOnce()
		for {
			time.Sleep(30 * time.Second)
			if active, _ := store.HasActiveDownloadTasks(); active {
				sc.RunOnce()
			}
		}
	}()
	go func() {
		for range time.Tick(cfg.ScanInterval) {
			sc.RunOnce()
		}
	}()

	gin.SetMode(gin.ReleaseMode)
	r := gin.Default()
	r.MaxMultipartMemory = 0
	r.Use(middleware.CORS())

	api := r.Group("/api")
	auth := &handler.AuthHandler{DB: store, Secret: cfg.JWTSecret}
	// 番茄网页端 Cookie（XS_FQ_COOKIE）：带登录态可绕过匿名风控限流，与 TND 批量下载共存
	fqClient := fanqie.NewClient(os.Getenv("XS_FQ_COOKIE"))
	tndClient := tnd.New(cfg.TNDURL, cfg.TNDPassword)
	uniClient := unidbg.New(cfg.UnidbgURL) // unidbg 签名服务：番茄海外版 SO 自算签名
	book := &handler.BookHandler{DB: store, Scanner: sc, FQ: fqClient, UNI: uniClient}
	shelf := &handler.ShelfHandler{DB: store}
	progress := &handler.ProgressHandler{DB: store}
	storeH := &handler.StoreHandler{DB: store, FQ: fqClient, TND: tndClient, UNI: uniClient}
	handler.StartUpdater(storeH) // 每日追更：未完结的番茄书自动补章

	api.POST("/auth/login", auth.Login)

	authed := api.Group("/", middleware.Auth(cfg.JWTSecret))
	authed.GET("/me", auth.Me)
	authed.PUT("/me/password", auth.ChangePassword)

	// 书城
	authed.GET("/store/ranks", storeH.Ranks)
	authed.GET("/store/ranks/:rankID/books", storeH.RankBooks)
	authed.GET("/store/featured", storeH.FeaturedBoards)           // App 推荐榜卡近似榜单清单
	authed.GET("/store/featured/:board", storeH.FeaturedBooks)     // recommend/finished/new/peak
	authed.GET("/store/search", storeH.Search)                     // 书城搜索（网页端）	authed.GET("/store/library/categories", storeH.LibraryCategories) // 书库分类树
	authed.GET("/store/library/books", storeH.LibraryBooks)          // 书库筛选列表
	authed.GET("/store/books/:fanqieID", storeH.BookDetail)
	authed.POST("/store/books/:fanqieID/auto", storeH.AutoDownload) // 详情页进入即自动入库+整本下载
	authed.POST("/store/books/:fanqieID/add", storeH.AddBook)
	authed.POST("/store/books/:fanqieID/download", storeH.TriggerDownload)
	authed.GET("/store/downloads", storeH.Downloads)

	// 书库
	authed.GET("/books", book.List)
	authed.GET("/books/:id", book.Detail)
	authed.GET("/books/:id/chapters/:idx", book.Chapter)

	// 书架
	authed.GET("/shelf", shelf.List)
	authed.POST("/shelf", shelf.Add)
	authed.DELETE("/shelf/:bookId", shelf.Remove)

	// 阅读进度
	authed.PUT("/progress", progress.Save)
	authed.GET("/progress/:bookId", progress.Get)

	// 短剧（红果）：目录/搜索/详情/取流走鉴权，流代理公开但带签名时效
	drama := handler.NewDramaHandler(hongguo.NewClient(), store, cfg.JWTSecret)
	authed.GET("/drama/genres", drama.Genres)
	authed.GET("/drama/catalog", drama.Catalog)
	authed.GET("/drama/search", drama.Search)
	authed.GET("/drama/detail", drama.Detail)
	authed.GET("/drama/play", drama.Play)
	authed.PUT("/drama/progress", drama.SaveProgress)      // 上报观看进度（切集时）
	authed.GET("/drama/progress/:sid", drama.GetProgress)   // 查某部剧看到第几集
	authed.GET("/drama/history", drama.History)             // 观看记录列表
	authed.DELETE("/drama/history/:sid", drama.DeleteHistory)
	api.GET("/drama/stream", drama.Stream)
	api.GET("/drama/seg", drama.Seg)
	api.GET("/drama/cover", drama.Cover) // 封面代理：磁盘缓存+singleflight+限速+熔断（签名即鉴权）

	// 管理员
	admin := authed.Group("/admin", middleware.AdminRequired())
	admin.GET("/users", auth.ListUsers)
	admin.POST("/users", auth.CreateUser)
	admin.DELETE("/users/:id", auth.DeleteUser)
	admin.POST("/scan", book.TriggerScan)
	admin.GET("/scan", book.ScanStatus)

	// 封面文件服务（本机路径 → 静态文件）
	r.Static("/covers", cfg.DownloadDir)

	log.Printf("小说服务启动 :%s (数据: %s, 下载目录: %s)", cfg.Port, cfg.DBPath, cfg.DownloadDir)
	if err := r.Run(":" + cfg.Port); err != nil {
		log.Fatal("启动失败: ", err)
	}
}

// detectLocalDataDir: 仅在 /data 不存在时（Windows 开发环境）返回 ./data
func detectLocalDataDir() string {
	if _, err := os.Stat("/data"); err == nil {
		return ""
	}
	os.MkdirAll("data/downloads", 0o755)
	abs, _ := os.Getwd()
	return abs + "/data"
}
