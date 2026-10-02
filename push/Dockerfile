FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY . .
RUN go mod download && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/push-gateway ./cmd/push-gateway

FROM alpine:3.22
RUN adduser -D -u 10001 pushgw
USER pushgw
COPY --from=build /out/push-gateway /usr/local/bin/push-gateway
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/push-gateway"]
