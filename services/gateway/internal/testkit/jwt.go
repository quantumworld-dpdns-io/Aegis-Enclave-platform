// Package testkit 提供單元測試用的 RSA／JWKS／JWT 輔助函式。
package testkit

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// KeyPair 測試用 RSA 金鑰與 JWKS。
type KeyPair struct {
	Priv *rsa.PrivateKey
	Kid  string
	JWKS []byte
}

// NewRSA 產生 RS256 金鑰對與對應 JWKS。
func NewRSA(t *testing.T) *KeyPair {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("產生 RSA: %v", err)
	}
	kid := "test-key"
	n := base64.RawURLEncoding.EncodeToString(priv.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(priv.E)).Bytes())
	doc := map[string]any{
		"keys": []map[string]string{{
			"kty": "RSA",
			"kid": kid,
			"use": "sig",
			"alg": "RS256",
			"n":   n,
			"e":   e,
		}},
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("JWKS: %v", err)
	}
	return &KeyPair{Priv: priv, Kid: kid, JWKS: raw}
}

// Claims 測試用宣告。
type Claims struct {
	jwt.RegisteredClaims
	Role string `json:"role"`
}

// Sign 簽發合法 RS256 token。
func (k *KeyPair) Sign(t *testing.T, sub, role string, ttl time.Duration) string {
	t.Helper()
	now := time.Now()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   sub,
			Issuer:    "https://aegis.local",
			Audience:  jwt.ClaimStrings{"aegis-gateway"},
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
			IssuedAt:  jwt.NewNumericDate(now),
		},
		Role: role,
	})
	tok.Header["kid"] = k.Kid
	s, err := tok.SignedString(k.Priv)
	if err != nil {
		t.Fatalf("簽發 JWT: %v", err)
	}
	return s
}

// NoneToken 偽造 alg=none。
func NoneToken(sub, role string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	payload, _ := json.Marshal(map[string]any{
		"sub": sub,
		"iss": "https://aegis.local",
		"aud": "aegis-gateway",
		"exp": time.Now().Add(time.Hour).Unix(),
		"role": role,
	})
	return header + "." + base64.RawURLEncoding.EncodeToString(payload) + "."
}

// HS256Confused 用 RSA 公鑰 PEM 當 HMAC 密鑰（經典 alg confusion）。
func (k *KeyPair) HS256Confused(t *testing.T, sub, role string) string {
	t.Helper()
	now := time.Now()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   sub,
			Issuer:    "https://aegis.local",
			Audience:  jwt.ClaimStrings{"aegis-gateway"},
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
			IssuedAt:  jwt.NewNumericDate(now),
		},
		Role: role,
	})
	tok.Header["kid"] = k.Kid
	// 以公鑰模數當對稱密鑰，模擬「把 JWKS 公鑰當 HMAC secret」。
	secret := k.Priv.PublicKey.N.Bytes()
	s, err := tok.SignedString(secret)
	if err != nil {
		t.Fatalf("HS256: %v", err)
	}
	return s
}
