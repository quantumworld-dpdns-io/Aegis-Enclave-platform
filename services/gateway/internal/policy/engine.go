// Package policy 以嵌入的 Rego 政策做授權決策。
package policy

import (
	"context"
	"embed"
	"fmt"

	"github.com/open-policy-agent/opa/v1/rego"
)

//go:embed authz.rego
var policyFS embed.FS

// Input 是送給 Rego 的授權輸入。subject 必須已是假名。
type Input struct {
	Subject string `json:"subject"`
	Role    string `json:"role"`
	Method  string `json:"method"`
	Path    string `json:"path"`
}

// Decision 對應政策輸出。
type Decision struct {
	Allow  bool   `json:"allow"`
	Reason string `json:"reason"`
}

// Engine 預編譯 Rego 查詢，避免每個請求重新剖析政策。
type Engine struct {
	prepared rego.PreparedEvalQuery
}

// NewEngine 載入嵌入的 authz.rego 並準備查詢。
func NewEngine() (*Engine, error) {
	src, err := policyFS.ReadFile("authz.rego")
	if err != nil {
		return nil, fmt.Errorf("讀取 Rego: %w", err)
	}
	prepared, err := rego.New(
		rego.Query("data.aegis.authz.decision"),
		rego.Module("authz.rego", string(src)),
	).PrepareForEval(context.Background())
	if err != nil {
		return nil, fmt.Errorf("編譯 Rego: %w", err)
	}
	return &Engine{prepared: prepared}, nil
}

// Eval 回傳允許與否與政策理由。
func (e *Engine) Eval(ctx context.Context, in Input) (Decision, error) {
	rs, err := e.prepared.Eval(ctx, rego.EvalInput(in))
	if err != nil {
		return Decision{Reason: "policy:error"}, fmt.Errorf("評估政策: %w", err)
	}
	if len(rs) == 0 || len(rs[0].Expressions) == 0 {
		return Decision{Allow: false, Reason: "policy:deny"}, nil
	}
	raw, ok := rs[0].Expressions[0].Value.(map[string]any)
	if !ok {
		return Decision{Allow: false, Reason: "policy:deny"}, nil
	}
	dec := Decision{Reason: "policy:deny"}
	if allow, ok := raw["allow"].(bool); ok {
		dec.Allow = allow
	}
	if reason, ok := raw["reason"].(string); ok && reason != "" {
		dec.Reason = reason
	}
	return dec, nil
}
