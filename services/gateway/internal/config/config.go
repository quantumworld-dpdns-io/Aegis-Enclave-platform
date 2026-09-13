// Package config 從環境變數載入閘道設定，預設值對齊 docs/CONTRACT.md 第 5 節。
package config

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// Config 是閘道執行期設定。僅允許改 services/gateway，因此 Kind 展示缺少的
// TLS／假名化變數在此給安全預設，避免必須改 k8s 清單。
type Config struct {
	ListenAddr     string
	MetricsAddr    string
	DataplaneURL   string
	JWTIssuer      string
	JWTAudience    string
	JWKSPath       string
	RequireMTLS    bool
	RateLimitRPS   float64
	RateLimitBurst int
	OTELEndpoint   string
	LogLevel       string
	// PseudonymSalt 對 JWT sub 做 HMAC-SHA256。契約把金鑰保管放在資料面，
	// 閘道改讀 AEGIS_PSEUDONYM_SALT，讓日誌與指標標籤能在本地完成假名化。
	PseudonymSalt string
	TLSCertPath   string
	TLSKeyPath    string
	TLSClientCA   string
	ShutdownWait  time.Duration
	ProxyTimeout  time.Duration
}

// Load 讀取環境變數。未設定時使用契約預設值。
func Load() Config {
	return Config{
		ListenAddr:     env("AEGIS_LISTEN_ADDR", ":8080"),
		MetricsAddr:    env("AEGIS_METRICS_ADDR", ":9090"),
		DataplaneURL:   env("AEGIS_DATAPLANE_URL", "http://dataplane.aegis.svc.cluster.local:8000"),
		JWTIssuer:      env("AEGIS_JWT_ISSUER", "https://aegis.local"),
		JWTAudience:    env("AEGIS_JWT_AUDIENCE", "aegis-gateway"),
		JWKSPath:       env("AEGIS_JWKS_PATH", "/etc/aegis/jwks.json"),
		RequireMTLS:    envBool("AEGIS_REQUIRE_MTLS", true),
		RateLimitRPS:   envFloat("AEGIS_RATE_LIMIT_RPS", 20),
		RateLimitBurst: envInt("AEGIS_RATE_LIMIT_BURST", 40),
		OTELEndpoint:   env("AEGIS_OTEL_ENDPOINT", ""),
		LogLevel:       strings.ToLower(env("AEGIS_LOG_LEVEL", "info")),
		PseudonymSalt:  env("AEGIS_PSEUDONYM_SALT", "aegis-dev-only-not-for-prod"),
		TLSCertPath:    env("AEGIS_TLS_CERT_PATH", ""),
		TLSKeyPath:     env("AEGIS_TLS_KEY_PATH", ""),
		TLSClientCA:    env("AEGIS_TLS_CLIENT_CA_PATH", ""),
		ShutdownWait:   10 * time.Second,
		ProxyTimeout:   10 * time.Second,
	}
}

// TLSEnabled 表示已掛入伺服器憑證，應以 TLS 1.3 對外。
func (c Config) TLSEnabled() bool {
	return c.TLSCertPath != "" && c.TLSKeyPath != ""
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func envInt(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func envFloat(key string, fallback float64) float64 {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}
