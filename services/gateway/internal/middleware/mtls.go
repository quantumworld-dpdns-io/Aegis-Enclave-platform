package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
)

// MTLS 在應用層檢查用戶端憑證。TLS 交握層由 server 套 TLS 1.3 + ClientAuth。
// Kind demo 把 AEGIS_REQUIRE_MTLS 關掉，此中介層直接放行。
func MTLS(require bool, metrics *observability.Metrics, log *observability.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !require {
			c.Next()
			return
		}
		if c.Request.TLS == nil || len(c.Request.TLS.PeerCertificates) == 0 {
			metrics.AuthnFailures.WithLabelValues(observability.ReasonNoClientCert).Inc()
			log.Emit(observability.Event{
				Level:     "warn",
				Event:     "authn.failure",
				RequestID: ctxString(c, CtxRequestID),
				TraceID:   ctxString(c, CtxTraceID),
				Resource:  c.Request.URL.Path,
				Decision:  "deny",
				Reason:    observability.ReasonNoClientCert,
			})
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized", "reason": observability.ReasonNoClientCert})
			return
		}
		c.Next()
	}
}

func ctxString(c *gin.Context, key string) string {
	v, _ := c.Get(key)
	s, _ := v.(string)
	return s
}
