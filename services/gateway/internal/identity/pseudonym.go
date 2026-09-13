// Package identity 負責把真實主體識別碼轉成契約規定的假名。
package identity

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

// Tokenize 以 HMAC-SHA256(salt, raw) 產生 subject 假名：sub_ + 前 16 碼十六進位。
// 決定論 tokenization：同一 salt 與同一 raw 永遠得到同一假名，便於 join 分析。
func Tokenize(salt, raw string) string {
	mac := hmac.New(sha256.New, []byte(salt))
	_, _ = mac.Write([]byte(raw))
	sum := hex.EncodeToString(mac.Sum(nil))
	if len(sum) > 16 {
		sum = sum[:16]
	}
	return "sub_" + sum
}
