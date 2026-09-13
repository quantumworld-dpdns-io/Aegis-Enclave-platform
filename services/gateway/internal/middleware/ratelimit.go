package middleware

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
)

type bucket struct {
	tokens float64
	last   time.Time
}

// Limiter 以假名 subject 為鍵的 token bucket（不依賴 golang.org/x/time，以相容 Go 1.23）。
type Limiter struct {
	rps     float64
	burst   float64
	mu      sync.Mutex
	buckets map[string]*bucket
}

// NewLimiter 建立每 subject 限流器。
func NewLimiter(rps float64, burst int) *Limiter {
	if rps <= 0 {
		rps = 20
	}
	if burst <= 0 {
		burst = 40
	}
	return &Limiter{
		rps:     rps,
		burst:   float64(burst),
		buckets: make(map[string]*bucket),
	}
}

func (l *Limiter) allow(subject string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b, ok := l.buckets[subject]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[subject] = b
	}
	elapsed := now.Sub(b.last).Seconds()
	b.tokens += elapsed * l.rps
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// RateLimit 超出額度回 429，並累加 aegis_ratelimit_throttled_total。
func RateLimit(l *Limiter, metrics *observability.Metrics, log *observability.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		subject := ctxString(c, CtxSubject)
		if subject == "" {
			c.Next()
			return
		}
		if !l.allow(subject) {
			metrics.RatelimitThrottled.WithLabelValues(subject).Inc()
			log.Emit(observability.Event{
				Level:     "warn",
				Event:     "ratelimit.throttled",
				RequestID: ctxString(c, CtxRequestID),
				TraceID:   ctxString(c, CtxTraceID),
				Subject:   subject,
				Resource:  c.Request.URL.Path,
				Decision:  "deny",
				Reason:    "rate_limited",
			})
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate_limited"})
			return
		}
		c.Next()
	}
}
