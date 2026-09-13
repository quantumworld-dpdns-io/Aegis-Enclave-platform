package identity

import "testing"

func TestTokenizeDeterministicAndPrefixed(t *testing.T) {
	a := Tokenize("salt", "alice@example.com")
	b := Tokenize("salt", "alice@example.com")
	c := Tokenize("salt", "bob@example.com")
	if a != b {
		t.Fatalf("同一輸入應得到同一假名: %s vs %s", a, b)
	}
	if a == c {
		t.Fatal("不同主體不應得到同一假名")
	}
	if len(a) != 4+16 || a[:4] != "sub_" {
		t.Fatalf("假名格式不符契約: %q", a)
	}
	if a == "alice@example.com" {
		t.Fatal("假名不可等於原始 subject")
	}
}
