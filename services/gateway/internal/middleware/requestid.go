package middleware

import (
	"crypto/sha256"
	"encoding/hex"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// RequestID 接受或產生 X-Aegis-Request-ID，並衍生 trace_id 供稽核串接。
func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		rid := c.GetHeader(HeaderRequestID)
		if rid == "" {
			rid = uuid.NewString()
		}
		sum := sha256.Sum256([]byte(rid))
		traceID := hex.EncodeToString(sum[:16])
		c.Set(CtxRequestID, rid)
		c.Set(CtxTraceID, traceID)
		c.Header(HeaderRequestID, rid)
		c.Next()
	}
}
