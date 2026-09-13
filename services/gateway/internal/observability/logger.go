package observability

import (
	"encoding/json"
	"io"
	"os"
	"strings"
	"time"
)

// Event 對齊 docs/CONTRACT.md 第 4 節的稽核 JSON 欄位。
// subject 必須已是假名；呼叫端不得傳入原始 PII、金鑰或完整 JWT。
type Event struct {
	TS        string `json:"ts"`
	Level     string `json:"level"`
	Service   string `json:"service"`
	Event     string `json:"event"`
	RequestID string `json:"request_id,omitempty"`
	TraceID   string `json:"trace_id,omitempty"`
	Subject   string `json:"subject,omitempty"`
	Resource  string `json:"resource,omitempty"`
	Decision  string `json:"decision,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

// Logger 把稽核事件寫成單行 JSON。
type Logger struct {
	out   io.Writer
	level string
}

// NewLogger 建立日誌器。out 為 nil 時寫 stdout。
func NewLogger(out io.Writer, level string) *Logger {
	if out == nil {
		out = os.Stdout
	}
	if level == "" {
		level = "info"
	}
	return &Logger{out: out, level: strings.ToLower(level)}
}

// Emit 寫出一筆事件。ts／service 由這裡補齊，避免各呼叫點格式不一致。
func (l *Logger) Emit(e Event) {
	if e.Level == "" {
		e.Level = "info"
	}
	e.Service = "gateway"
	if e.TS == "" {
		e.TS = time.Now().UTC().Format(time.RFC3339)
	}
	// 防衛：完整 JWT 絕不可進日誌。
	if looksLikeJWT(e.Subject) || looksLikeJWT(e.Reason) {
		e.Reason = "redacted"
		e.Subject = ""
	}
	enc := json.NewEncoder(l.out)
	_ = enc.Encode(e)
}

func looksLikeJWT(s string) bool {
	parts := strings.Split(s, ".")
	return len(parts) == 3 && len(parts[0]) > 10 && len(parts[1]) > 10
}
