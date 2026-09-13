package jwks

import (
	"testing"

	"github.com/dennis/aegis-enclave/services/gateway/internal/testkit"
)

func TestParseAndKeyfunc(t *testing.T) {
	kp := testkit.NewRSA(t)
	set, err := Parse(kp.JWKS)
	if err != nil {
		t.Fatal(err)
	}
	if !set.Ready() {
		t.Fatal("應有公鑰")
	}
	if _, err := set.Keyfunc(kp.Kid); err != nil {
		t.Fatal(err)
	}
	if _, err := set.Keyfunc("nope"); err == nil {
		t.Fatal("未知 kid 應失敗")
	}
}

func TestRejectSymmetricJWK(t *testing.T) {
	_, err := Parse([]byte(`{"keys":[{"kty":"oct","k":"c2VjcmV0","alg":"HS256"}]}`))
	if err == nil {
		t.Fatal("對稱金鑰不得進入 JWKS")
	}
}
