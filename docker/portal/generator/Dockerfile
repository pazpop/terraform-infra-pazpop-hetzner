# Épinglée par digest (Dependabot ouvre les PR de mise à jour).
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache curl jq

COPY generate.sh /generate.sh
RUN chmod +x /generate.sh

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD test -f /output/index.html || exit 1

ENTRYPOINT ["/generate.sh"]
