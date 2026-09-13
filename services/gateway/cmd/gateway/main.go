// 零信任閘道入口：Gin、TLS 1.3、8080 業務／9090 指標、優雅關機。
package main

import (
	"log"

	"github.com/dennis/aegis-enclave/services/gateway/internal/config"
	"github.com/dennis/aegis-enclave/services/gateway/internal/server"
)

func main() {
	cfg := config.Load()
	srv, err := server.New(server.Options{Config: cfg})
	if err != nil {
		log.Fatalf("啟動閘道失敗: %v", err)
	}
	if err := srv.Run(); err != nil {
		log.Fatalf("閘道結束: %v", err)
	}
}
