# 多階段建置：編譯靜態二進位後放入 distroless nonroot。
# 對齊 k8s securityContext（非 root、唯讀根檔、無 shell）。
FROM golang:1.23-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w" -o /out/gateway ./cmd/gateway

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/gateway /gateway
USER nonroot:nonroot
EXPOSE 8080 9090
ENTRYPOINT ["/gateway"]
