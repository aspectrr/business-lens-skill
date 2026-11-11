#!/usr/bin/env bash
# swiped-sync.sh — sync swiped.co ad teardowns into the business-lens corpus,
# OCR the ad images (tesseract), and keep originals for later vision work.
#
#   swiped-sync.sh sync [--limit N]   # crawl browse pages, fetch unseen swipes
#   swiped-sync.sh search "query"     # grep cached swipe markdown
#   swiped-sync.sh read  <slug>       # dump one swipe's markdown
#   swiped-sync.sh ocr   <image>      # OCR any image file to stdout
#   swiped-sync.sh refetch <slug>     # rebuild one swipe from the live page
#   swiped-sync.sh list               # cached slugs + count
#
# Cache: ~/.cache/business-lens/swiped/<slug>.md + images/<slug>/*.png
# Politeness: sleep between requests, back off on Cloudflare blocks, resumable
# (dedupe = .md existence). First full run fetches ~442 swipes — hours; run it
# in the background and let it resume across runs.
set -uo pipefail

CACHE_ROOT="${CACHE_ROOT:-$HOME/.cache/business-lens}"
CACHE="$CACHE_ROOT/swiped"
IMAGES="$CACHE/images"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
SLEEP="${SWIPED_SLEEP:-4}"          # seconds between requests
MAX_PAGES=60                        # safety cap for browse pagination
ANNOTATIONS="${SWIPED_ANNOTATIONS:-1}"  # set 0 to skip wpstickies probes

command -v tesseract >/dev/null 2>&1 || { echo "swiped-sync.sh: tesseract not found — brew install tesseract" >&2; exit 1; }
mkdir -p "$CACHE" "$IMAGES"

# single-instance lock for sync — two concurrent syncs race on the same slugs
LOCK="$CACHE/.lock"
if [[ "${1:-}" == "sync" ]] && ! mkdir "$LOCK" 2>/dev/null; then
  echo "swiped-sync.sh: another sync is already running" >&2; exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null' EXIT
# GET with Cloudflare-block backoff. Body on stdout; non-empty on success.
http_get() {
  local url="$1" out try
  for try in 0 1 2; do
    (( try > 0 )) && sleep 60
    out="$(curl -sL --compressed --max-time 60 -A "$UA" "$url")" || { sleep "$SLEEP"; continue; }
    if grep -q "Attention Required\|Just a moment" <<<"$out"; then
      echo "  cloudflare block on $url — backing off" >&2
      continue
    fi
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    sleep "$SLEEP"
  done
  return 1
}

# POST with the same backoff; extra args pass through to curl (form fields etc.).
http_post() {
  local url="$1" out try
  shift
  for try in 0 1 2; do
    (( try > 0 )) && sleep 60
    out="$(curl -sL --compressed --max-time 60 -A "$UA" -H "X-Requested-With: XMLHttpRequest" -X POST "$url" "$@")" || { sleep "$SLEEP"; continue; }
    [[ -n "$out" && "$out" != *'Attention Required'* ]] && { printf '%s' "$out"; return 0; }
    sleep "$SLEEP"
  done
  return 1
}

# Parse a saved swipe page. Emits TAB-separated records:
#   T\t<title>  G\t<tags csv>  M\t<meta pairs>  D\t<analysis>  I\t<img url>
# (single bash-callable python block; the page structure is swiped.co-specific)
parse_page() {
  python3 - "$1" <<'PYEOF'
import re, sys, html
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()

def txt(s):
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s))).strip()

m = re.search(r"<h1>(.*?)</h1>", raw, re.S)
print("T\t" + (txt(m.group(1)) if m else ""))

tags = re.findall(r'<span class="category"><a[^>]*>(.*?)</a>', raw, re.S)
print("G\t" + ", ".join(dict.fromkeys(txt(t) for t in tags if txt(t))))

pairs = re.findall(
    r'<span class="typed"[^>]*>(.*?)</span>\s*<span class="metainfo"[^>]*>(.*?)</span>',
    raw, re.S)
print("M\t" + "; ".join(f"{txt(a)} {txt(b)}" for a, b in pairs if txt(b)))

m = re.search(r'<div id="swipe-excerpt">.*?<p[^>]*>(.*?)</p>', raw, re.S)
if m:
    block = re.sub(r'<a class="opendesc">.*?</a>', " ", m.group(1), flags=re.S)
    text = txt(block)
    if text:
        print("D\t" + text)

for tag in re.findall(r"<img[^>]*class=\"wpstickies\"[^>]*>", raw):
    sm = re.search(r'src="([^"]+)"', tag)
    if sm and "/uploads/" in sm.group(1):
        print("I\t" + sm.group(1))
PYEOF
}

ocr_image() {  # path -> OCR text (stripped, marked when nothing readable)
  local text
  text="$(tesseract "$1" - 2>/dev/null | sed '/^[[:space:]]*$/d')"
  [[ -n "$text" ]] && printf '%s\n' "$text" || echo "(no readable text)"
}

annotations_for() {  # image url -> flattened sticky text (empty when none)
  local json out
  json="$(http_post "https://swiped.co/wp-admin/admin-ajax.php" \
    --data-urlencode "action=wpstickies_get" \
    --data-urlencode "image=$1")" || return 0
  out="$(python3 -c '
import json, sys, re, html
try:
    sticks = json.load(sys.stdin).get("stickies") or []
except Exception:
    sys.exit(0)
for s in sticks:
    if not isinstance(s, dict): continue
    parts = [html.unescape(re.sub(r"<[^>]+>", " ", str(s.get(k, "")))).strip()
             for k in ("title", "content")]
    line = " — ".join(p for p in parts if p)
    if line: print(line)
' <<<"$json" 2>/dev/null)"
  printf '%s' "$out"
}

ingest_slug() {  # $1 = slug; writes $CACHE/<slug>.md (atomic via .tmp+mv)
  local slug="$1" page f n=0 url name ocr annot
  page="$(http_get "https://swiped.co/file/$slug/")" || { echo "  fetch failed: $slug" >&2; return 1; }
  f="$CACHE/.page.html"
  printf '%s' "$page" > "$f"
  mkdir -p "$IMAGES/$slug"

  local title="" tags="" meta="" analysis=""
  while IFS=$'\t' read -r kind val; do
    case "$kind" in
      T) title="$val" ;;
      G) tags="$val" ;;
      M) meta="$val" ;;
      D) analysis="$val" ;;
    esac
  done < <(parse_page "$f")

  {
    echo "Source: https://swiped.co/file/$slug/"
    echo "Title: $title"
    echo "Tags: $tags"
    [[ -n "$meta" ]] && echo "Swiped: $meta"
    echo
    [[ -n "$analysis" ]] && { echo "## Analysis"; echo "$analysis"; echo; }

    while IFS=$'\t' read -r kind url; do
      [[ "$kind" == "I" ]] || continue
      n=$((n + 1))
      name="$(basename "${url%%\?*}")"
      name="$(printf '%02d-%s' "$n" "$name")"
      local img="$IMAGES/$slug/$name"
      if [[ ! -s "$img" ]]; then
        sleep "$SLEEP"
        curl -sL --compressed --max-time 120 -A "$UA" "$url" -o "$img" || true
      fi
      echo "## Image $n: ${name#*-}  (images/$slug/$name)"
      if [[ -s "$img" ]]; then
        echo "OCR:"
        ocr_image "$img"
      else
        echo "(image download failed)"
        rm -f "$img"
      fi
      if [[ "$ANNOTATIONS" == 1 ]]; then
        sleep "$SLEEP"
        annot="$(annotations_for "$url")"
        [[ -n "$annot" ]] && { echo "Annotations:"; echo "$annot"; }
      fi
      echo
    done < <(parse_page "$f" | grep $'^I\t')
  } > "$CACHE/$slug.md.tmp"

  if [[ $n -eq 0 && -z "$analysis" ]]; then
    echo "  no content extracted for $slug — skipping" >&2
    rm -f "$CACHE/$slug.md.tmp"
    return 1
  fi
  mv "$CACHE/$slug.md.tmp" "$CACHE/$slug.md"
  echo "✓ $slug  ($n images)  — $title"
}

find_slug() {  # name-or-substring -> slug
  local want="$1"
  for f in "$CACHE"/*.md; do
    [[ -e "$f" ]] || return 1
    local base; base="$(basename "$f" .md)"
    [[ "$base" == "$want" ]] && { echo "$base"; return 0; }
  done
  for f in "$CACHE"/*.md; do
    local base; base="$(basename "$f" .md)"
    [[ "$base" == *"$want"* ]] && { echo "$base"; return 0; }
  done
  return 1
}

cmd_sync() {
  local limit=0
  [[ "${1:-}" == "--limit" ]] && { limit="${2:?need a number}"; shift 2; }
  local page=1 new=0 slug
  while (( page <= MAX_PAGES )); do
    local html
    html="$(http_get "https://swiped.co/browse/?sf_paged=$page")" || { echo "browse page $page fetch failed — stopping" >&2; break; }
    local slugs
    slugs="$(grep -oE 'https://swiped\.co/file/[a-z0-9-]+/' <<<"$html" | sed -E 's#.*/file/([^/]+)/#\1#' | sort -u)" || slugs=""
    [[ -z "$slugs" ]] && break
    while IFS= read -r slug; do
      [[ -f "$CACHE/$slug.md" ]] && continue
      sleep "$SLEEP"
      ingest_slug "$slug" || continue
      new=$((new + 1))
      if (( limit && new >= limit )); then
        echo "synced $new new swipes (--limit reached)"
        return 0
      fi
    done <<<"$slugs"
    page=$((page + 1))
  done
  echo "synced $new new swipes"
}

cmd_search() {
  local query="$1" found=0 shown=0 total=0 f
  echo "Searching swiped.co teardowns for: \"$query\"" >&2
  for f in "$CACHE"/*.md; do
    [[ -e "$f" ]] || { echo "(no swipes cached — run: swiped-sync.sh sync)" >&2; return; }
    if grep -qi "$query" "$f" 2>/dev/null; then
      found=1; total=$((total + 1))
      if (( shown < 12 )); then
        shown=$((shown + 1))
        echo ""
        echo "[SWIPED] $(basename "$f" .md)  →  $(grep -m1 '^Source:' "$f")"
        grep -ni -C 4 "$query" "$f" 2>/dev/null | head -45 || true
      fi
    fi
  done
  if [[ "$found" -eq 0 ]]; then echo "(no swipe matches)" >&2
  elif (( total > shown )); then echo "(+$((total - shown)) more swipes matched — refine the query)" >&2; fi
}

cmd_read() {
  local slug f
  slug="$(find_slug "$1")" || { echo "no cached swipe matches '$1'" >&2; return 1; }
  cat "$CACHE/$slug.md"
}

cmd_refetch() {
  local slug
  slug="$(find_slug "$1")" || slug="$1"   # also allows slugs not yet cached
  rm -f "$CACHE/$slug.md"
  sleep "$SLEEP"
  ingest_slug "$slug"
}

case "${1:-}" in
  sync)    shift; cmd_sync "$@" ;;
  search)  shift; [[ $# -ge 1 ]] || { echo "usage: swiped-sync.sh search \"query\"" >&2; exit 1; }; cmd_search "$1" ;;
  read)    shift; [[ $# -ge 1 ]] || { echo "usage: swiped-sync.sh read <slug>" >&2; exit 1; }; cmd_read "$1" ;;
  ocr)     shift; [[ $# -ge 1 ]] || { echo "usage: swiped-sync.sh ocr <image-path>" >&2; exit 1; }; ocr_image "$1" ;;
  refetch) shift; [[ $# -ge 1 ]] || { echo "usage: swiped-sync.sh refetch <slug>" >&2; exit 1; }; cmd_refetch "$1" ;;
  list)    n=$(ls "$CACHE"/*.md 2>/dev/null | wc -l | tr -d ' '); echo "$n swipes cached"; ls "$CACHE"/*.md 2>/dev/null | while read -r f; do basename "$f" .md; done ;;
  *)       grep '^#   ' "$0" | head -8 >&2; exit 1 ;;
esac
