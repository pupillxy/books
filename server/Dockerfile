FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /xiaoshuo-server ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 app
ENV TZ=Asia/Shanghai XS_DB=/data/xiaoshuo.db XS_DOWNLOAD_DIR=/data/downloads
USER app
VOLUME /data
EXPOSE 8080
COPY --from=build /xiaoshuo-server /usr/local/bin/xiaoshuo-server
ENTRYPOINT ["xiaoshuo-server"]
