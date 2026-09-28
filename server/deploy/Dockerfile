FROM alpine:3.20

# 国内源 + CA 证书（出站 HTTPS 调番茄）+ 时区
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
 && apk add --no-cache ca-certificates tzdata \
 && update-ca-certificates

WORKDIR /app
COPY xiaoshuo-server .
RUN chmod +x xiaoshuo-server

EXPOSE 8080
ENTRYPOINT ["/app/xiaoshuo-server"]
