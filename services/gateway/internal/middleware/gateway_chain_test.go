package middleware_test

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/dennis/aegis-enclave/services/gateway/internal/config"
	"github.com/dennis/aegis-enclave/services/gateway/internal/identity"
	"github.com/dennis/aegis-enclave/services/gateway/internal/jwks"
	"github.com/dennis/aegis-enclave/services/gateway/internal/middleware"
	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
	"github.com/dennis/aegis-enclave/services/gateway/internal/proxy"
	"github.com/dennis/aegis-enclave/services/gateway/internal/server"
	"github.com/dennis/aegis-enclave/services/gateway/internal/testkit"
)

type harness struct {
	handler http.Handler
	metrics *observability.Metrics
	logs    *bytes.Buffer
	rawSub  string
	token   func(role string, ttl time.Duration) string
	pseudo  string
}

func newHarness(t *testing.T, rps float64, burst int) *harness {
	t.Helper()
	kp := testkit.NewRSA(t)
	keys, err := jwks.Parse(kp.JWKS)
	if err != nil {
		t.Fatal(err)
	}
	rawSub := "alice@example.com"
	salt := "test-salt"
	reg := prometheus.NewRegistry()
	metrics := observability.NewMetrics(reg)
	var logs bytes.Buffer
	log := observability.NewLogger(&logs, "info")

	downstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(middleware.HeaderRequestID) == "" || r.Header.Get(middleware.HeaderSubject) == "" {
			http.Error(w, "missing aegis headers", http.StatusBadRequest)
			return
		}
		if strings.Contains(r.Header.Get(middleware.HeaderSubject), rawSub) {
			http.Error(w, "raw subject leaked", http.StatusBadRequest)
			return
		}
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/internal/v1/records":
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{"id":"rec-1"}`)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/internal/v1/records/"):
			_, _ = io.WriteString(w, `{"id":"rec-1"}`)
		case r.Method == http.MethodPost && r.URL.Path == "/internal/v1/chain/retire":
			_, _ = io.WriteString(w, `{"ok":true}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(downstream.Close)

	cfg := config.Config{
		ListenAddr:     ":0",
		MetricsAddr:    ":0",
		DataplaneURL:   downstream.URL,
		JWTIssuer:      "https://aegis.local",
		JWTAudience:    "aegis-gateway",
		RequireMTLS:    false,
		RateLimitRPS:   rps,
		RateLimitBurst: burst,
		PseudonymSalt:  salt,
		LogLevel:       "info",
	}
	srv, err := server.New(server.Options{
		Config:   cfg,
		Logger:   log,
		Metrics:  metrics,
		Register: reg,
		Gatherer: reg,
		Keys:     keys,
		Proxy:    proxy.New(downstream.URL, time.Second),
		Limiter:  middleware.NewLimiter(rps, burst),
	})
	if err != nil {
		t.Fatal(err)
	}
	return &harness{
		handler: srv.Handler(),
		metrics: metrics,
		logs:    &logs,
		rawSub:  rawSub,
		pseudo:  identity.Tokenize(salt, rawSub),
		token: func(role string, ttl time.Duration) string {
			return kp.Sign(t, rawSub, role, ttl)
		},
	}
}

func (h *harness) do(method, path, token string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set(middleware.HeaderRequestID, "demo-test-001")
	w := httptest.NewRecorder()
	h.handler.ServeHTTP(w, req)
	return w
}

func TestAuthzDeniesAnalystCarbonRetire(t *testing.T) {
	h := newHarness(t, 20, 40)
	w := h.do(http.MethodPost, "/api/v1/carbon/retire", h.token("analyst", time.Hour))
	if w.Code != http.StatusForbidden {
		t.Fatalf("analyst 退役應 403，得到 %d %s", w.Code, w.Body.String())
	}
	if n := testutil.ToFloat64(h.metrics.AuthzDenied.WithLabelValues(h.pseudo, "/api/v1/carbon/retire")); n != 1 {
		t.Fatalf("authz denied 計數 = %v", n)
	}
	if strings.Contains(h.logs.String(), h.rawSub) {
		t.Fatalf("稽核日誌含原始 subject: %s", h.logs.String())
	}
}

func TestAuthzAllowsAnalystVaultWrite(t *testing.T) {
	h := newHarness(t, 20, 40)
	w := h.do(http.MethodPost, "/api/v1/vault/records", h.token("analyst", time.Hour))
	if w.Code != http.StatusCreated {
		t.Fatalf("analyst 寫入 vault 應 201，得到 %d %s", w.Code, w.Body.String())
	}
}

func TestRateLimitPerSubject(t *testing.T) {
	h := newHarness(t, 1, 1)
	tok := h.token("analyst", time.Hour)
	first := h.do(http.MethodGet, "/api/v1/vault/records/demo-1", tok)
	if first.Code != http.StatusOK {
		t.Fatalf("第一發應通過，得到 %d %s", first.Code, first.Body.String())
	}
	second := h.do(http.MethodGet, "/api/v1/vault/records/demo-1", tok)
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("超出 burst 應 429，得到 %d", second.Code)
	}
	if n := testutil.ToFloat64(h.metrics.RatelimitThrottled.WithLabelValues(h.pseudo)); n != 1 {
		t.Fatalf("throttled 計數 = %v", n)
	}
}

func TestAuditLogOmitsRawSubject(t *testing.T) {
	h := newHarness(t, 20, 40)
	_ = h.do(http.MethodGet, "/api/v1/vault/records/demo-1", h.token("analyst", time.Hour))
	out := h.logs.String()
	if !strings.Contains(out, `"event":"authz.decision"`) {
		t.Fatalf("缺少 authz.decision: %s", out)
	}
	if !strings.Contains(out, h.pseudo) {
		t.Fatalf("日誌應含假名 %s: %s", h.pseudo, out)
	}
	if strings.Contains(out, h.rawSub) {
		t.Fatalf("日誌含原始 subject: %s", out)
	}
	if strings.Contains(out, "Bearer ") || strings.Count(out, "eyJ") > 0 {
		t.Fatalf("日誌疑似含 JWT: %s", out)
	}
}

func TestHealthzNeedsNoAuth(t *testing.T) {
	h := newHarness(t, 20, 40)
	w := h.do(http.MethodGet, "/healthz", "")
	if w.Code != http.StatusOK {
		t.Fatalf("healthz 應 200，得到 %d", w.Code)
	}
}
