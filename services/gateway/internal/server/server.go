// Package server 組裝 Gin 路由、TLS 1.3 與優雅關機。
package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/dennis/aegis-enclave/services/gateway/internal/config"
	"github.com/dennis/aegis-enclave/services/gateway/internal/jwks"
	"github.com/dennis/aegis-enclave/services/gateway/internal/middleware"
	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
	"github.com/dennis/aegis-enclave/services/gateway/internal/policy"
	"github.com/dennis/aegis-enclave/services/gateway/internal/proxy"
)

// Server 同時聽業務埠與指標埠。
type Server struct {
	cfg     config.Config
	http    *http.Server
	metrics *http.Server
	engine  *gin.Engine
	keys    *jwks.Set
	dp      *proxy.Client
	log     *observability.Logger
}

// Options 可注入測試用依賴。
type Options struct {
	Config   config.Config
	Logger   *observability.Logger
	Metrics  *observability.Metrics
	Register prometheus.Registerer
	Gatherer prometheus.Gatherer
	Keys     *jwks.Set
	Policy   *policy.Engine
	Proxy    *proxy.Client
	Limiter  *middleware.Limiter
}

// New 建立閘道。
func New(opt Options) (*Server, error) {
	if opt.Logger == nil {
		opt.Logger = observability.NewLogger(nil, opt.Config.LogLevel)
	}
	if opt.Register == nil {
		opt.Register = prometheus.DefaultRegisterer
	}
	if opt.Gatherer == nil {
		opt.Gatherer = prometheus.DefaultGatherer
	}
	if opt.Metrics == nil {
		opt.Metrics = observability.NewMetrics(opt.Register)
	}
	if opt.Keys == nil {
		keys, err := jwks.LoadFile(opt.Config.JWKSPath)
		if err != nil {
			return nil, err
		}
		opt.Keys = keys
	}
	if opt.Policy == nil {
		eng, err := policy.NewEngine()
		if err != nil {
			return nil, err
		}
		opt.Policy = eng
	}
	if opt.Proxy == nil {
		opt.Proxy = proxy.New(opt.Config.DataplaneURL, opt.Config.ProxyTimeout)
	}
	if opt.Limiter == nil {
		opt.Limiter = middleware.NewLimiter(opt.Config.RateLimitRPS, opt.Config.RateLimitBurst)
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(middleware.RequestID())
	r.Use(middleware.HTTPMetrics(opt.Metrics))

	s := &Server{cfg: opt.Config, engine: r, keys: opt.Keys, dp: opt.Proxy, log: opt.Logger}

	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	r.GET("/readyz", s.readyz)

	protected := r.Group("/")
	protected.Use(
		middleware.MTLS(opt.Config.RequireMTLS, opt.Metrics, opt.Logger),
		middleware.JWT(opt.Config, opt.Keys, opt.Metrics, opt.Logger),
		middleware.Authz(opt.Policy, opt.Metrics, opt.Logger),
		middleware.RateLimit(opt.Limiter, opt.Metrics, opt.Logger),
	)
	protected.POST("/api/v1/vault/records", opt.Proxy.Forward("/internal/v1/records"))
	protected.GET("/api/v1/vault/records/:id", func(c *gin.Context) {
		opt.Proxy.Forward(proxy.RecordPath(c.Param("id")))(c)
	})
	protected.POST("/api/v1/carbon/retire", opt.Proxy.Forward("/internal/v1/chain/retire"))

	s.http = &http.Server{
		Addr:              opt.Config.ListenAddr,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		TLSConfig:         tlsConfig(opt.Config),
	}
	s.metrics = &http.Server{
		Addr:              opt.Config.MetricsAddr,
		Handler:           metricsMux(opt.Gatherer),
		ReadHeaderTimeout: 5 * time.Second,
	}
	return s, nil
}

// Handler 回傳業務 HTTP handler，供測試使用。
func (s *Server) Handler() http.Handler { return s.engine }

func (s *Server) readyz(c *gin.Context) {
	if !s.keys.Ready() {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "jwks_missing"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ready"})
}

// Run 啟動兩個埠並等待 SIGINT/SIGTERM 後優雅關機。
func (s *Server) Run() error {
	errCh := make(chan error, 2)
	go func() {
		s.log.Emit(observability.Event{Event: "server.start", Reason: "listen " + s.cfg.ListenAddr})
		var err error
		if s.cfg.TLSEnabled() {
			err = s.http.ListenAndServeTLS(s.cfg.TLSCertPath, s.cfg.TLSKeyPath)
		} else {
			// Kind demo 無 TLS 憑證，改聽明文 HTTP；正式環境應掛憑證走 TLS 1.3。
			err = s.http.ListenAndServe()
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()
	go func() {
		if err := s.metrics.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- fmt.Errorf("metrics: %w", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errCh:
		_ = s.shutdown()
		return err
	case <-sig:
		return s.shutdown()
	}
}

func (s *Server) shutdown() error {
	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.ShutdownWait)
	defer cancel()
	err1 := s.http.Shutdown(ctx)
	err2 := s.metrics.Shutdown(ctx)
	if err1 != nil {
		return err1
	}
	return err2
}

func tlsConfig(cfg config.Config) *tls.Config {
	tc := &tls.Config{
		MinVersion: tls.VersionTLS13,
		MaxVersion: tls.VersionTLS13,
	}
	if !cfg.RequireMTLS {
		return tc
	}
	tc.ClientAuth = tls.RequireAndVerifyClientCert
	if cfg.TLSClientCA != "" {
		pem, err := os.ReadFile(cfg.TLSClientCA)
		if err == nil {
			pool := x509.NewCertPool()
			pool.AppendCertsFromPEM(pem)
			tc.ClientCAs = pool
		}
	}
	return tc
}

func metricsMux(g prometheus.Gatherer) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(g, promhttp.HandlerOpts{}))
	return mux
}
