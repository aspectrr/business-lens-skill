#!/usr/bin/env bash
# book-search.sh — extract (cache) & search/read Collin's business book library.
# Sources EPUB + PDF from ~/Desktop/learning/books, caches extracted .txt so
# repeat lookups are instant. Re-extracts only when the source file changes.
set -euo pipefail

BOOKS_DIR="${BOOKS_DIR:-$HOME/Desktop/learning/books}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/business-lens/books}"
mkdir -p "$CACHE_DIR"

# resolve a cached book by fuzzy substring of its filename
resolve() {
  local hit
  hit="$(for f in "$CACHE_DIR"/*.txt; do basename "$f"; done 2>/dev/null | grep -i "$1" | head -1)" || true
  [[ -z "$hit" ]] && { echo "No cached book matches '$1'. Run: book-search.sh sync" >&2; return 1; }
  echo "$CACHE_DIR/$hit"
}

extract_one() {
  local src="$1" base cache
  base="$(basename "$src")"
  cache="$CACHE_DIR/${base%.*}.txt"
  if [[ -f "$cache" && "$cache" -nt "$src" ]]; then return 0; fi
  echo "  extracting: $base" >&2
  case "${src##*.}" in
    epub) ebook-convert "$src" "$cache" >/dev/null 2>&1 || echo "    (ebook-convert failed for $base)" >&2 ;;
    pdf)  pdftotext -layout "$src" "$cache" 2>/dev/null        || echo "    (pdftotext failed for $base)"    >&2 ;;
    *)    echo "    (skipped unknown type: $base)" >&2 ;;
  esac
}

sync_all() {
  echo "Extracting books from $BOOKS_DIR …" >&2
  shopt -s nullglob
  for f in "$BOOKS_DIR"/*.epub "$BOOKS_DIR"/*.pdf; do extract_one "$f"; done
  local n; n="$(ls "$CACHE_DIR"/*.txt 2>/dev/null | wc -l | tr -d ' ')"
  echo "Done. $n books cached in $CACHE_DIR" >&2
}

search() {
  local query="$1" scope="${2:-all}"
  shopt -s nullglob
  [[ "$scope" != "all" ]] && extract_one "$BOOKS_DIR/$scope" 2>/dev/null || true
  for f in "$BOOKS_DIR"/*.epub "$BOOKS_DIR"/*.pdf; do extract_one "$f"; done
  echo "Searching books for: \"$query\"" >&2
  local found=0
  for t in "$CACHE_DIR"/*.txt; do
    if grep -qi "$query" "$t" 2>/dev/null; then
      found=1
      local name; name="$(basename "$t" .txt | sed -E 's/ --.*//; s/_/ /g')"
      echo ""
      echo "[BOOK] $name"
      grep -ni -C 4 "$query" "$t" 2>/dev/null | head -45
    fi
  done
  [[ "$found" -eq 0 ]] && echo "(no book matches)" >&2
}

# read: dump full text or a line range of a cached book (use after search finds line nos)
read_book() {
  local book="$1" start="${2:-1}" count="${3:-0}"
  local f; f="$(resolve "$book")" || return 1
  local total; total="$(wc -l < "$f" | tr -d ' ')"
  if [[ "$count" -eq 0 ]]; then count="$total"; fi
  echo "[BOOK] $(basename "$f" .txt | sed -E 's/ --.*//; s/_/ /g')  ($total lines, showing $start-$((start+count-1)))" >&2
  sed -n "${start},$((start+count-1))p" "$f"
}

usage() {
  cat >&2 <<EOF
book-search.sh — search & read Collin's book library (~/Desktop/learning/books)
  book-search.sh search "value equation"        # grep every book, with context
  book-search.sh read   "mom test"               # dump full text of a book
  book-search.sh read   "offers" 145 30         # dump lines 145-174
  book-search.sh sync                            # (re)extract all books to cache
  book-search.sh list                            # show cached books
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  search) search "${1:?pass a search query}" "${2:-all}" ;;
  read)   read_book "${1:?need a book name/substring}" "${2:-1}" "${3:-0}" ;;
  sync)   sync_all ;;
  list)   for f in "$CACHE_DIR"/*.txt; do basename "$f" .txt | sed -E 's/ --.*//; s/_/ /g'; done 2>/dev/null || echo "(none cached — run: book-search.sh sync)" ;;
  *)      usage; exit 1 ;;
esac
