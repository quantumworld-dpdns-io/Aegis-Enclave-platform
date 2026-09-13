package middleware

import (
	"strconv"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
)

// HTTPMetrics 記錄契約第 3 節的請求計數與延遲。route 使用 Gin 樣板以避免高基數。
func HTTPMetrics(metrics *observability.Metrics) gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		route := c.FullPath()
		if route == "" {
			route = "unmatched"
		}
		status := strconv.Itoa(c.Writer.Status())
		metrics.HTTPRequests.WithLabelValues(c.Request.Method, route, status).Inc()
		metrics.HTTPDuration.WithLabelValues(c.Request.Method, route).Observe(time.Since(start).Seconds())
	}
}
