// Package jwks 從本機 JWKS 檔載入非對稱驗簽公鑰。閘道只驗簽、不持有私鑰。
package jwks

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"sync"
)

// ErrKeyNotFound 表示 kid 對不到任何金鑰。
var ErrKeyNotFound = errors.New("jwks: 找不到對應 kid 的公鑰")

// Set 是執行期 JWKS 快取。
type Set struct {
	mu   sync.RWMutex
	keys map[string]crypto.PublicKey
}

type document struct {
	Keys []jwk `json:"keys"`
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
	Crv string `json:"crv"`
	X   string `json:"x"`
	Y   string `json:"y"`
}

// LoadFile 讀取 JWKS JSON。檔案不存在時回傳空集合，讓 Kind 在 Secret 尚未掛入時仍能啟動。
func LoadFile(path string) (*Set, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Set{keys: map[string]crypto.PublicKey{}}, nil
		}
		return nil, fmt.Errorf("讀取 JWKS: %w", err)
	}
	return Parse(raw)
}

// Parse 解析 JWKS 位元組。
func Parse(raw []byte) (*Set, error) {
	var doc document
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("解析 JWKS: %w", err)
	}
	keys := make(map[string]crypto.PublicKey, len(doc.Keys))
	for i, k := range doc.Keys {
		pub, err := k.publicKey()
		if err != nil {
			return nil, fmt.Errorf("JWKS keys[%d]: %w", i, err)
		}
		kid := k.Kid
		if kid == "" {
			kid = fmt.Sprintf("idx-%d", i)
		}
		keys[kid] = pub
	}
	return &Set{keys: keys}, nil
}

// Keyfunc 依 JWT kid 取出公鑰；沒有 kid 時若只有一把金鑰則使用它。
func (s *Set) Keyfunc(kid string) (crypto.PublicKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if kid != "" {
		if k, ok := s.keys[kid]; ok {
			return k, nil
		}
		return nil, ErrKeyNotFound
	}
	if len(s.keys) == 1 {
		for _, k := range s.keys {
			return k, nil
		}
	}
	return nil, ErrKeyNotFound
}

// Ready 表示至少有一把可用公鑰。
func (s *Set) Ready() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.keys) > 0
}

func (k jwk) publicKey() (crypto.PublicKey, error) {
	switch k.Kty {
	case "RSA":
		n, err := parseB64Int(k.N)
		if err != nil {
			return nil, fmt.Errorf("RSA n: %w", err)
		}
		e, err := parseB64Int(k.E)
		if err != nil {
			return nil, fmt.Errorf("RSA e: %w", err)
		}
		if !e.IsInt64() {
			return nil, errors.New("RSA e 過大")
		}
		return &rsa.PublicKey{N: n, E: int(e.Int64())}, nil
	case "EC":
		curve, err := curveByName(k.Crv)
		if err != nil {
			return nil, err
		}
		x, err := parseB64Int(k.X)
		if err != nil {
			return nil, fmt.Errorf("EC x: %w", err)
		}
		y, err := parseB64Int(k.Y)
		if err != nil {
			return nil, fmt.Errorf("EC y: %w", err)
		}
		return &ecdsa.PublicKey{Curve: curve, X: x, Y: y}, nil
	default:
		return nil, fmt.Errorf("不支援的 kty %q（只接受 RSA/EC 非對稱金鑰）", k.Kty)
	}
}

func parseB64Int(s string) (*big.Int, error) {
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		raw, err = base64.URLEncoding.DecodeString(s)
		if err != nil {
			return nil, err
		}
	}
	return new(big.Int).SetBytes(raw), nil
}

func curveByName(name string) (elliptic.Curve, error) {
	switch name {
	case "P-256":
		return elliptic.P256(), nil
	case "P-384":
		return elliptic.P384(), nil
	case "P-521":
		return elliptic.P521(), nil
	default:
		return nil, fmt.Errorf("不支援的 EC 曲線 %q", name)
	}
}
