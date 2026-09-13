package middleware

// Gin context 鍵。原始 JWT sub 絕不寫入 context，只保留假名。
const (
	CtxSubject   = "aegis.subject"
	CtxRole      = "aegis.role"
	CtxRequestID = "aegis.request_id"
	CtxTraceID   = "aegis.trace_id"
	HeaderRequestID = "X-Aegis-Request-ID"
	HeaderSubject   = "X-Aegis-Subject"
	HeaderRole      = "X-Aegis-Role"
)
