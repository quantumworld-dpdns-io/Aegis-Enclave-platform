package observability

import (
	"bytes"
	"strings"
	"testing"
)

func TestEmitNeverWritesJWT(t *testing.T) {
	var buf bytes.Buffer
	l := NewLogger(&buf, "info")
	l.Emit(Event{
		Event:   "authz.decision",
		Subject: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhbGljZSJ9.signaturepart",
		Reason:  "ok",
	})
	out := buf.String()
	if strings.Contains(out, "eyJhbGciOiJSUzI1NiJ9") {
		t.Fatalf("日誌含完整 JWT: %s", out)
	}
}
