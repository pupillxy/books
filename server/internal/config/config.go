package config

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Port         string
	DBPath       string
	DownloadDir  string
	JWTSecret    string
	ScanInterval time.Duration
	AdminUser    string
	AdminPass    string
	TNDURL       string // Tomato-Novel-Downloader 服务地址（NAS Docker），空=禁用
	TNDPassword  string // TND Web UI 锁定密码（TOMATO_WEB_PASSWORD），未锁定留空
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func Load() *Config {
	intervalMin, _ := strconv.Atoi(env("XS_SCAN_INTERVAL_MIN", "30"))
	if intervalMin <= 0 {
		intervalMin = 30
	}
	secret := env("XS_JWT_SECRET", "")
	if secret == "" {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			log.Fatal("生成 JWT 密钥失败: ", err)
		}
		secret = hex.EncodeToString(b)
		log.Println("警告: 未设置 XS_JWT_SECRET，已生成随机密钥（重启后所有登录态失效）")
	}
	return &Config{
		Port:         env("XS_PORT", "8080"),
		DBPath:       env("XS_DB", "/data/xiaoshuo.db"),
		DownloadDir:  env("XS_DOWNLOAD_DIR", "/data/downloads"),
		JWTSecret:    secret,
		ScanInterval: time.Duration(intervalMin) * time.Minute,
		AdminUser:    env("XS_ADMIN_USER", "admin"),
		AdminPass:    env("XS_ADMIN_PASS", "admin123"),
		TNDURL:       env("XS_TND_URL", ""),
		TNDPassword:  env("XS_TND_PASSWORD", ""),
	}
}
