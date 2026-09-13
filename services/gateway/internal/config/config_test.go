package config

import (
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv("AEGIS_LISTEN_ADDR", "")
	t.Setenv("AEGIS_REQUIRE_MTLS", "")
	cfg := Load()
	if cfg.ListenAddr != ":8080" || cfg.MetricsAddr != ":9090" {
		t.Fatalf("埠預設值不符契約: %+v", cfg)
	}
	if cfg.JWTAudience != "aegis-gateway" || cfg.JWTIssuer != "https://aegis.local" {
		t.Fatalf("JWT 預設值不符: %+v", cfg)
	}
	if !cfg.RequireMTLS {
		t.Fatal("契約預設 AEGIS_REQUIRE_MTLS=true")
	}
}

func TestRequireMTLSCanDisable(t *testing.T) {
	t.Setenv("AEGIS_REQUIRE_MTLS", "false")
	cfg := Load()
	if cfg.RequireMTLS {
		t.Fatal("Kind demo 必須能關閉 mTLS")
	}
}
