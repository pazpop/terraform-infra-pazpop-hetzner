#!/bin/sh
# Régénère index.html à partir des conteneurs Docker portant les labels
# pazpop.portal.* (lus via docker-socket-proxy, jamais le socket directement).
# Boucle simple plutôt qu'un flux d'évènements Docker : un déploiement/arrêt
# apparaît ou disparaît au prochain passage (30s max), largement suffisant
# pour ce projet et beaucoup plus simple à lire/déboguer.
set -eu

OUT=/output/index.html
PROXY_URL=http://docker-socket-proxy:2375

html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

render() {
  tmp=$(mktemp)
  cat > "$tmp" <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>pazpop</title>
<style>
  body { font-family: monospace; background: #05060f; color: #cfe8ff; display: flex; flex-direction: column; align-items: center; padding: 12vh 1rem; margin: 0; min-height: 100vh; box-sizing: border-box; }
  h1 { color: #ffe66d; letter-spacing: 0.1em; }
  ul { list-style: none; padding: 0; width: min(360px, 90vw); }
  li + li { margin-top: 0.75rem; }
  a { display: block; padding: 0.9rem 1.2rem; background: rgba(78,225,255,0.08); border: 1px solid rgba(78,225,255,0.35); border-radius: 6px; color: #4ee1ff; text-decoration: none; text-align: center; transition: background 0.15s; }
  a:hover { background: rgba(78,225,255,0.18); }
  p.empty { opacity: 0.7; }
</style>
</head>
<body>
<h1>pazpop</h1>
<ul>
HTML_HEAD

  apps=$(curl -sf "$PROXY_URL/containers/json" \
    | jq -r '[.[] | select(.Labels["pazpop.portal.enable"]=="true") | {name: .Labels["pazpop.portal.name"], url: .Labels["pazpop.portal.url"]}] | sort_by(.name) | .[] | @base64')

  if [ -z "$apps" ]; then
    echo '<p class="empty">Aucune application déployée pour le moment.</p>' >> "$tmp"
  else
    for row in $apps; do
      decoded=$(echo "$row" | base64 -d)
      name=$(echo "$decoded" | jq -r '.name // "?"' | html_escape)
      url=$(echo "$decoded" | jq -r '.url // "#"' | html_escape)
      printf '<li><a href="%s">%s</a></li>\n' "$url" "$name" >> "$tmp"
    done
  fi

  cat >> "$tmp" <<'HTML_FOOT'
</ul>
</body>
</html>
HTML_FOOT

  mv "$tmp" "$OUT"
}

while true; do
  render || echo "generate.sh: échec de rendu, nouvelle tentative dans 30s" >&2
  sleep 30
done
