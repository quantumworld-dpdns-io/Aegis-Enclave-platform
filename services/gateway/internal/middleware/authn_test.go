package middleware

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/dennis/aegis-enclave/services/gateway/internal/config"
	"github.com/dennis/aegis-enclave/services/gateway/internal/identity"
	"github.com/dennis/aegis-enclave/services/gateway/internal/jwks"
	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
	"github.com/dennis/aegis-enclave/services/gateway/internal/testkit"
)

func newAuthnRouter(t *testing.T, keys *jwks.Set, metrics *observability.Metrics, log *observability.Logger) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	cfg := config.Config{
		JWTIssuer:     "https://aegis.local",
		JWTAudience:   "aegis-gateway",
		PseudonymSalt: "test-salt",
	}
	r := gin.New()
	r.Use(JWT(cfg, keys, metrics, log))
	r.GET("/ok", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"subject": ctxString(c, CtxSubject), "role": ctxString(c, CtxRole)})
	})
	return r
}

func TestRejectAlgConfusion(t *testing.T) {
	kp := testkit.NewRSA(t)
	keys, err := jwks.Parse(kp.JWKS)
	if err != nil {
		t.Fatal(err)
	}
	reg := prometheus.NewRegistry()
	metrics := observability.NewMetrics(reg)
	log := observability.NewLogger(io.Discard, "info")
	r := newAuthnRouter(t, keys, metrics, log)

	cases := []struct {
		name  string
		token string
	}{
		{"alg=none", testkit.NoneToken("attacker", "admin")},
		{"hs256-confusion", kp.HS256Confused(t, "attacker", "admin")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/ok", nil)
			req.Header.Set("Authorization", "Bearer "+tc.token)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("應拒絕演算法混淆，得到 %d %s", w.Code, w.Body.String())
			}
		})
	}
	if n := testutil.ToFloat64(metrics.AuthnFailures.WithLabelValues(observability.ReasonInvalidSignature)); n < 2 {
		t.Fatalf("invalid_signature 應至少加 2，得到 %v", n)
	}
}

func TestRejectExpiredToken(t *testing.T) {
	kp := testkit.NewRSA(t)
	keys, err := jwks.Parse(kp.JWKS)
	if err != nil {
		t.Fatal(err)
	}
	reg := prometheus.NewRegistry()
	metrics := observability.NewMetrics(reg)
	r := newAuthnRouter(t, keys, metrics, observability.NewLogger(io.Discard, "info"))

	tok := kp.Sign(t, "alice@example.com", "analyst", -time.Hour)
	req := httptest.NewRequest(http.MethodGet, "/ok", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("過期 token 應 401，得到 %d", w.Code)
	}
	if n := testutil.ToFloat64(metrics.AuthnFailures.WithLabelValues(observability.ReasonExpired)); n != 1 {
		t.Fatalf("expired 計數 = %v", n)
	}
}

func TestMissingToken(t *testing.T) {
	kp := testkit.NewRSA(t)
	keys, _ := jwks.Parse(kp.JWKS)
	reg := prometheus.NewRegistry()
	metrics := observability.NewMetrics(reg)
	r := newAuthnRouter(t, keys, metrics, observability.NewLogger(io.Discard, "info"))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/ok", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("缺 token 應 401，得到 %d", w.Code)
	}
}

func TestValidTokenSetsPseudonym(t *testing.T) {
	kp := testkit.NewRSA(t)
	keys, _ := jwks.Parse(kp.JWKS)
	reg := prometheus.NewRegistry()
	metrics := observability.NewMetrics(reg)
	r := newAuthnRouter(t, keys, metrics, observability.NewLogger(io.Discard, "info"))
	rawSub := "alice@example.com"
	tok := kp.Sign(t, rawSub, "analyst", time.Hour)
	req := httptest.NewRequest(http.MethodGet, "/ok", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("合法 token 應通過，得到 %d %s", w.Code, w.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	want := identity.Tokenize("test-salt", rawSub)
	if body["subject"] != want {
		t.Fatalf("假名不符: %s vs %s", body["subject"], want)
	}
	if strings.Contains(w.Body.String(), rawSub) {
		t.Fatal("回應不可含原始 subject")
	}
}
