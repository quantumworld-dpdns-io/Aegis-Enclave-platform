package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
	"github.com/dennis/aegis-enclave/services/gateway/internal/policy"
)

// Authz 以 OPA/Rego 做授權。拒絕時累加 aegis_authz_denied_total（subject 為假名）。
func Authz(engine *policy.Engine, metrics *observability.Metrics, log *observability.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		subject := ctxString(c, CtxSubject)
		role := ctxString(c, CtxRole)
		dec, err := engine.Eval(c.Request.Context(), policy.Input{
			Subject: subject,
			Role:    role,
			Method:  c.Request.Method,
			Path:    c.Request.URL.Path,
		})
		if err != nil || !dec.Allow {
			resource := c.FullPath()
			if resource == "" {
				resource = c.Request.URL.Path
			}
			if subject != "" {
				metrics.AuthzDenied.WithLabelValues(subject, resource).Inc()
			}
			reason := dec.Reason
			if reason == "" {
				reason = "policy:deny"
			}
			log.Emit(observability.Event{
				Level:     "warn",
				Event:     "authz.decision",
				RequestID: ctxString(c, CtxRequestID),
				TraceID:   ctxString(c, CtxTraceID),
				Subject:   subject,
				Resource:  resource,
				Decision:  "deny",
				Reason:    reason,
			})
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "forbidden", "reason": reason})
			return
		}
		log.Emit(observability.Event{
			Level:     "info",
			Event:     "authz.decision",
			RequestID: ctxString(c, CtxRequestID),
			TraceID:   ctxString(c, CtxTraceID),
			Subject:   subject,
			Resource:  c.Request.URL.Path,
			Decision:  "allow",
			Reason:    dec.Reason,
		})
		c.Next()
	}
}
