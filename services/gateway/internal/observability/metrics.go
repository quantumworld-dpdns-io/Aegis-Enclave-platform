// Package observability 提供契約第 3 節的 Prometheus 指標與第 4 節稽核日誌。
package observability

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics 名稱必須與 docs/CONTRACT.md 第 3 節完全一致，模組 F 的告警只認這些名字。
type Metrics struct {
	HTTPRequests       *prometheus.CounterVec
	HTTPDuration       *prometheus.HistogramVec
	AuthnFailures      *prometheus.CounterVec
	AuthzDenied        *prometheus.CounterVec
	RatelimitThrottled *prometheus.CounterVec
}

// NewMetrics 註冊到指定 Registerer。測試可傳入獨立 registry，避免 DefaultRegisterer 互撞。
func NewMetrics(reg prometheus.Registerer) *Metrics {
	if reg == nil {
		reg = prometheus.DefaultRegisterer
	}
	factory := promauto.With(reg)
	return &Metrics{
		HTTPRequests: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "aegis_http_requests_total",
			Help: "全部請求計數",
		}, []string{"method", "route", "status"}),
		HTTPDuration: factory.NewHistogramVec(prometheus.HistogramOpts{
			Name: "aegis_http_request_duration_seconds",
			Help: "請求延遲",
		}, []string{"method", "route"}),
		AuthnFailures: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "aegis_authn_failures_total",
			Help: "驗證失敗（missing_token/invalid_signature/expired/no_client_cert）",
		}, []string{"reason"}),
		AuthzDenied: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "aegis_authz_denied_total",
			Help: "授權政策拒絕；subject 必須是假名",
		}, []string{"subject", "resource"}),
		RatelimitThrottled: factory.NewCounterVec(prometheus.CounterOpts{
			Name: "aegis_ratelimit_throttled_total",
			Help: "被限流的請求；subject 必須是假名",
		}, []string{"subject"}),
	}
}

// 契約允許的驗證失敗原因。
const (
	ReasonMissingToken     = "missing_token"
	ReasonInvalidSignature = "invalid_signature"
	ReasonExpired          = "expired"
	ReasonNoClientCert     = "no_client_cert"
)
