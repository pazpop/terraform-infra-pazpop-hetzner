FROM alpine:3.20

RUN apk add --no-cache curl jq

COPY generate.sh /generate.sh
RUN chmod +x /generate.sh

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD test -f /output/index.html || exit 1

ENTRYPOINT ["/generate.sh"]
