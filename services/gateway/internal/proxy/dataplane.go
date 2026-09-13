// Package proxy 把已通過驗證授權的請求轉發到資料面。
package proxy

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/dennis/aegis-enclave/services/gateway/internal/middleware"
)

// Client 轉發 HTTP 到 dataplane。
type Client struct {
	base   string
	client *http.Client
}

// New 建立下游客戶端。
func New(baseURL string, timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	return &Client{
		base: strings.TrimRight(baseURL, "/"),
		client: &http.Client{
			Timeout: timeout,
		},
	}
}

// Health 呼叫資料面 /internal/healthz。
func (c *Client) Health(r *http.Request) error {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, c.base+"/internal/healthz", nil)
	if err != nil {
		return err
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 400 {
		return errStatus(resp.StatusCode)
	}
	return nil
}

type statusError int

func (e statusError) Error() string { return http.StatusText(int(e)) }

func errStatus(code int) error { return statusError(code) }

// Forward 把目前請求的 method／body 轉到 destPath，並帶契約規定的下游標頭。
func (c *Client) Forward(destPath string) gin.HandlerFunc {
	return func(gc *gin.Context) {
		target := c.base + destPath
		req, err := http.NewRequestWithContext(gc.Request.Context(), gc.Request.Method, target, gc.Request.Body)
		if err != nil {
			gc.AbortWithStatusJSON(http.StatusBadGateway, gin.H{"error": "bad_gateway"})
			return
		}
		if ct := gc.GetHeader("Content-Type"); ct != "" {
			req.Header.Set("Content-Type", ct)
		}
		req.Header.Set(middleware.HeaderRequestID, stringOr(gc, middleware.CtxRequestID))
		req.Header.Set(middleware.HeaderSubject, stringOr(gc, middleware.CtxSubject))
		req.Header.Set(middleware.HeaderRole, stringOr(gc, middleware.CtxRole))

		resp, err := c.client.Do(req)
		if err != nil {
			gc.AbortWithStatusJSON(http.StatusBadGateway, gin.H{"error": "bad_gateway"})
			return
		}
		defer resp.Body.Close()
		for k, vs := range resp.Header {
			if strings.EqualFold(k, "Content-Length") {
				continue
			}
			for _, v := range vs {
				gc.Writer.Header().Add(k, v)
			}
		}
		gc.Status(resp.StatusCode)
		_, _ = io.Copy(gc.Writer, resp.Body)
	}
}

// RecordPath 組成資料面紀錄路徑。
func RecordPath(id string) string {
	return "/internal/v1/records/" + url.PathEscape(id)
}

func stringOr(c *gin.Context, key string) string {
	v, _ := c.Get(key)
	s, _ := v.(string)
	return s
}
