package middleware

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"

	"github.com/dennis/aegis-enclave/services/gateway/internal/config"
	"github.com/dennis/aegis-enclave/services/gateway/internal/identity"
	"github.com/dennis/aegis-enclave/services/gateway/internal/jwks"
	"github.com/dennis/aegis-enclave/services/gateway/internal/observability"
)

// 伺服器端寫死允許的非對稱演算法，不信任 header 的 alg。
var allowedAlgs = map[string]struct{}{
	"RS256": {},
	"RS384": {},
	"RS512": {},
	"ES256": {},
	"ES384": {},
	"ES512": {},
	"PS256": {},
	"PS384": {},
	"PS512": {},
}

var symmetricAlgs = map[string]struct{}{
	"HS256": {},
	"HS384": {},
	"HS512": {},
	"none":  {},
	"None":  {},
	"NONE":  {},
}

// Claims 只取授權需要的欄位。role 會轉成下游 X-Aegis-Role。
type Claims struct {
	jwt.RegisteredClaims
	Role string `json:"role"`
}

// JWT 驗簽並把假名化 subject 寫入 context。
func JWT(cfg config.Config, keys *jwks.Set, metrics *observability.Metrics, log *observability.Logger) gin.HandlerFunc {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512"}),
		jwt.WithIssuer(cfg.JWTIssuer),
		jwt.WithAudience(cfg.JWTAudience),
		jwt.WithExpirationRequired(),
	)
	return func(c *gin.Context) {
		raw, ok := bearerToken(c.GetHeader("Authorization"))
		if !ok {
			failAuthn(c, metrics, log, observability.ReasonMissingToken)
			return
		}
		alg, err := peekAlg(raw)
		if err != nil || isForbiddenAlg(alg) {
			// alg=none 與對稱演算法（含 RS256→HS256 混淆）一律當無效簽章。
			failAuthn(c, metrics, log, observability.ReasonInvalidSignature)
			return
		}
		claims := &Claims{}
		_, err = parser.ParseWithClaims(raw, claims, func(t *jwt.Token) (any, error) {
			if _, ok := allowedAlgs[t.Method.Alg()]; !ok {
				return nil, errors.New("拒絕未列入白名單的演算法")
			}
			kid, _ := t.Header["kid"].(string)
			return keys.Keyfunc(kid)
		})
		if err != nil {
			reason := observability.ReasonInvalidSignature
			if errors.Is(err, jwt.ErrTokenExpired) {
				reason = observability.ReasonExpired
			}
			failAuthn(c, metrics, log, reason)
			return
		}
		if claims.Subject == "" {
			failAuthn(c, metrics, log, observability.ReasonInvalidSignature)
			return
		}
		pseudo := identity.Tokenize(cfg.PseudonymSalt, claims.Subject)
		c.Set(CtxSubject, pseudo)
		c.Set(CtxRole, claims.Role)
		c.Next()
	}
}

func failAuthn(c *gin.Context, metrics *observability.Metrics, log *observability.Logger, reason string) {
	metrics.AuthnFailures.WithLabelValues(reason).Inc()
	log.Emit(observability.Event{
		Level:     "warn",
		Event:     "authn.failure",
		RequestID: ctxString(c, CtxRequestID),
		TraceID:   ctxString(c, CtxTraceID),
		Resource:  c.Request.URL.Path,
		Decision:  "deny",
		Reason:    reason,
	})
	c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized", "reason": reason})
}

func bearerToken(h string) (string, bool) {
	if h == "" {
		return "", false
	}
	const prefix = "Bearer "
	if len(h) < len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return "", false
	}
	tok := strings.TrimSpace(h[len(prefix):])
	return tok, tok != ""
}

func peekAlg(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return "", errors.New("malformed jwt")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		raw, err = base64.URLEncoding.DecodeString(parts[0])
		if err != nil {
			return "", err
		}
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(raw, &header); err != nil {
		return "", err
	}
	return header.Alg, nil
}

func isForbiddenAlg(alg string) bool {
	if alg == "" {
		return true
	}
	if _, ok := symmetricAlgs[alg]; ok {
		return true
	}
	if _, ok := allowedAlgs[strings.ToUpper(alg)]; !ok {
		return true
	}
	return false
}
