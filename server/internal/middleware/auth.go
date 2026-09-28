package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

type ctxKey string

const (
	CtxUserID  ctxKey = "user_id"
	CtxIsAdmin ctxKey = "is_admin"
)

func Auth(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
			return
		}
		token, err := jwt.Parse(strings.TrimPrefix(h, "Bearer "), func(t *jwt.Token) (any, error) {
			if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
				return nil, jwt.ErrSignatureInvalid
			}
			return []byte(secret), nil
		})
		if err != nil || !token.Valid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "登录态无效"})
			return
		}
		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "登录态无效"})
			return
		}
		uid, ok := claims["uid"].(float64)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "登录态无效"})
			return
		}
		isAdmin, _ := claims["admin"].(bool)
		ctx := context.WithValue(c.Request.Context(), CtxUserID, int64(uid))
		ctx = context.WithValue(ctx, CtxIsAdmin, isAdmin)
		c.Request = c.Request.WithContext(ctx)
		c.Next()
	}
}

func UserID(c *gin.Context) int64 {
	return c.Request.Context().Value(CtxUserID).(int64)
}

func IsAdmin(c *gin.Context) bool {
	v, ok := c.Request.Context().Value(CtxIsAdmin).(bool)
	return ok && v
}

func AdminRequired() gin.HandlerFunc {
	return func(c *gin.Context) {
		if !IsAdmin(c) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "需要管理员权限"})
			return
		}
		c.Next()
	}
}
