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
  local query="$1" scope="${2:-all}" t
  shopt -s nullglob
  [[ "$scope" != "all" ]] && extract_one "$BOOKS_DIR/$scope" 2>/dev/null || true
  for f in "$BOOKS_DIR"/*.epub "$BOOKS_DIR"/*.pdf; do extract_one "$f"; done
  echo "Searching books for: \"$query\"" >&2
  # Multi-word queries match ANY keyword (OR'd); "a quoted phrase" matches exactly.
  # Stopwords are dropped (else "the" floods every context line); full set if all are.
  # grep -i makes case irrelevant, so tokens are lowercased first.
  local sw=" the a an and or of to in on is it for with that this not be are was were do does did how what when who your you my we us i "
  local ql; ql="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')"
  local -a toks=() ga=()
  read -ra toks <<< "${ql//\"/ }"
  if [[ "$ql" =~ ^\".+\"$ ]]; then
    ga=(-e "${ql:1:${#ql}-2}")
  elif (( ${#toks[@]} )); then
    for t in "${toks[@]}"; do [[ -n "$t" && "$sw" != *" $t "* ]] && ga+=("-e" "$t"); done
    (( ${#ga[@]} )) || for t in "${toks[@]}"; do [[ -n "$t" ]] && ga+=("-e" "$t"); done
  fi
  (( ${#ga[@]} )) || ga=(-e "$query")
  # Equal per-source cap: at most 12 matched files shown, so no one source
  # floods unified search and every source stays weighable side by side.
  local -a hits=()
  while IFS= read -r t; do hits+=("$t"); done < <(grep -ril "${ga[@]}" "$CACHE_DIR" 2>/dev/null)
  local total=${#hits[@]} cap=12 i name
  if (( total == 0 )); then echo "(no book matches)" >&2; return 0; fi
  for ((i=0; i<total && i<cap; i++)); do
    t="${hits[i]}"
    local ctx; ctx="$(grep -in -C 4 "${ga[@]}" "$t" 2>/dev/null | head -45)"
    [[ -z "$ctx" ]] && continue   # ranked on stopwords we dropped — skip empty blocks
    name="$(basename "$t" .txt | sed -E 's/ --.*//; s/_/ /g')"
    echo ""
    echo "[BOOK] $name  ($t)"
    printf '%s\n' "$ctx"
  done
  (( total > cap )) && echo "(+$((total-cap)) more books matched — refine the query to narrow)" >&2
  return 0
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
(Search shows max 12 matched books; refine the query to narrow.)
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
