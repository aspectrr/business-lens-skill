#!/usr/bin/env bash
# web-search.sh — fetch (cache) & search/read web articles from trusted sources.
# Uses curl + pandoc to convert HTML→text and cache by a friendly name, so
# articles from trusted authors become permanently searchable offline.
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-$HOME/.cache/business-lens/web}"
mkdir -p "$CACHE_DIR"

# friendly name from a url: last path segment, cleaned
name_from_url() {
  echo "$1" | sed -E 's#https?://[^/]+/##; s#/$##; s#^.*/##; s#\.[a-z]+$##; s/[^a-zA-Z0-9_-]/_/g'
}

fetch() {
  local url="$1" name out
  name="${2:-$(name_from_url "$url")}"
  out="$CACHE_DIR/$name.txt"
  echo "Fetching $url …" >&2
  # python3 stdlib HTML→text: strips tags/entities, skips script/style, preserves paragraphs.
  # better than pandoc for table-layout pages (PG's 1990s HTML).
  # NOTE: do NOT skip <img>/<col> — void elements have no end tag, so a skip flag
  # on them would permanently suppress all following text.
  curl -sLA "Mozilla/5.0" "$url" | python3 -c '
import sys, html, re
from html.parser import HTMLParser
class T(HTMLParser):
    def __init__(self):
        super().__init__(); self.t=[]; self.s=False
    def handle_starttag(self,t,a):
        if t in("script","style"): self.s=True
    def handle_endtag(self,t):
        if t in("script","style"): self.s=False
        if t in("p","br","div","tr","li","h1","h2","h3","td"): self.t.append("\n")
    def handle_data(self,d):
        if not self.s: self.t.append(d)
p=T(); p.feed(sys.stdin.read())
out=html.unescape("".join(p.t))
lines=[l.strip() for l in out.splitlines() if l.strip()]
print("\n".join(lines))
' > "$out" 2>/dev/null || {
    echo "fetch/convert failed (try native web_fetch for JS-heavy pages)" >&2; return 1;
  }
  local lines; lines="$(wc -l < "$out" | tr -d ' ')"
  echo "Cached → $name.txt ($lines lines)" >&2
}

search() {
  local query="$1" found=0
  shopt -s nullglob
  local -a files=( "$CACHE_DIR"/*.txt "$CACHE_DIR"/*/*.md "$CACHE_DIR"/*/*/*.md "$CACHE_DIR"/*/*.txt )
  [[ ${#files[@]} -eq 0 ]] && { echo "(no cached articles. run: web-search.sh fetch <url>)" >&2; return; }
  echo "Searching web articles for: \"$query\"" >&2
  for t in "${files[@]}"; do
    if grep -qi "$query" "$t" 2>/dev/null; then
      found=1
      local src; src="$(grep -m1 -iE '^(source|url):' "$t" 2>/dev/null | sed 's/^[Ss]ource: //;s/^[Uu]rl: //')" || true
      echo ""
      echo "[WEB] $(basename "$t" | sed 's/\.txt$//;s/\.md$//')${src:+  →  $src}"
      grep -ni -C 4 "$query" "$t" 2>/dev/null | head -45
    fi
  done
  [[ "$found" -eq 0 ]] && echo "(no web matches)" >&2
}

# read: dump full cached article
read_article() {
  local name="$1" f
  f="$CACHE_DIR/$(name_from_url "$name").txt"
  [[ -z "$name" || "$name" == "$CACHE_DIR/.txt" ]] && { echo "need an article name" >&2; return 1; }
  if [[ ! -f "$f" ]]; then
    local hit
    hit="$(for f in "$CACHE_DIR"/*.txt; do basename "$f"; done 2>/dev/null | grep -i "$name" | head -1)" || true
    [[ -n "$hit" ]] && f="$CACHE_DIR/$hit" || { echo "no cached article matches '$name'" >&2; return 1; }
  fi
  echo "[WEB] $(basename "$f" .txt)" >&2
  cat "$f"
}

usage() {
  cat >&2 <<EOF
web-search.sh — fetch (cache) & search/read web articles
  web-search.sh fetch <url> [name]      # curl + pandoc → text cache
  web-search.sh search "query"          # grep cached articles
  web-search.sh read   <name|url>       # dump full cached article
  web-search.sh list                    # show cached articles
NOTE: for JS-heavy or paywalled pages, use the native web_fetch tool instead.
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  fetch) fetch "${1:?need a url}" "${2:-}" ;;
  search) search "${1:?need a query}" ;;
  read)   read_article "${1:?need an article name}" ;;
  list)   for f in "$CACHE_DIR"/*.txt; do basename "$f" .txt; done 2>/dev/null || echo "(none cached)" ;;
  *)      usage; exit 1 ;;
esac
