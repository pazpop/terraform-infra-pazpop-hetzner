# Épinglée par digest (Dependabot ouvre les PR de mise à jour).
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache curl jq

COPY generate.sh /generate.sh
RUN chmod +x /generate.sh

# Sain si la page a été écrite depuis moins de deux minutes (elle l'est toutes
# les 30 s) : un fichier seulement présent ne prouverait rien, le volume en
# contient un dès sa création.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD find /output/index.html -mmin -2 | grep -q . || exit 1

ENTRYPOINT ["/generate.sh"]
