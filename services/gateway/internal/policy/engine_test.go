package policy

import (
	"context"
	"testing"
)

func TestEngineVaultAndCarbon(t *testing.T) {
	eng, err := NewEngine()
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	allow, err := eng.Eval(ctx, Input{Subject: "sub_abc", Role: "analyst", Method: "GET", Path: "/api/v1/vault/records/1"})
	if err != nil || !allow.Allow {
		t.Fatalf("analyst 應可讀 vault: %+v %v", allow, err)
	}
	deny, err := eng.Eval(ctx, Input{Subject: "sub_abc", Role: "analyst", Method: "POST", Path: "/api/v1/carbon/retire"})
	if err != nil {
		t.Fatal(err)
	}
	if deny.Allow {
		t.Fatal("analyst 不應能退役碳權")
	}
	if deny.Reason != "policy:deny" {
		t.Fatalf("拒絕理由: %s", deny.Reason)
	}
	op, err := eng.Eval(ctx, Input{Subject: "sub_op", Role: "operator", Method: "POST", Path: "/api/v1/carbon/retire"})
	if err != nil || !op.Allow {
		t.Fatalf("operator 應可退役: %+v %v", op, err)
	}
}
