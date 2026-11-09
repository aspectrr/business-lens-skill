#!/usr/bin/env bash
# search-all.sh — unified search over books, transcripts, and web via the FTS5 index.
#
# Default mode: BM25 keyword search. Multi-word queries match ANY keyword (OR'd,
# relevance-ranked); "a quoted phrase" matches exactly. Stopwords dropped.
#   search-all.sh "sell the outcome not the feature"
#
# Semantic mode: embeddings (bge-small via fastembed through uv). Matches IDEAS —
# a query can hit text sharing no keywords with it. Scores are cosine 0-1.
#   search-all.sh --semantic "how do I sell outcomes instead of specs"
#
# First index/embedding build takes minutes; every later run is incremental.
# Per-source context comes from a narrow grep (keyword) or the chunk's own line
# range (semantic) — nothing scans the whole cache twice.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SEMANTIC=0; ARGS=()
for a in "$@"; do
  if [[ "$a" == "--semantic" ]]; then SEMANTIC=1; else ARGS+=("$a"); fi
done
QUERY="${ARGS[0]:?usage: search-all.sh [--semantic] \"query\" [yt-channel-url-or-slug]}"
SCOPE="${ARGS[1]:-}"

# Optional 2nd arg: scope transcript results to one channel (url or slug).
FILTER=""
[[ -n "$SCOPE" ]] && FILTER="$(echo "$SCOPE" | sed -E 's#https?://[^/]+/##; s#/.*##; s/[^a-zA-Z0-9_-]//g')"

PY=(python3)
if (( SEMANTIC )); then
  command -v uv >/dev/null 2>&1 || { echo "semantic mode needs uv (brew install uv)" >&2; exit 1; }
  PY=(uv run --quiet --with sentence-transformers python3)
  python3 "$DIR/index.py" reindex || exit 1
  "${PY[@]}" "$DIR/index.py" embed || exit 1
  OUT="$("${PY[@]}" "$DIR/index.py" search --semantic "$QUERY" --top 12)" || exit 1
else
  python3 "$DIR/index.py" reindex || exit 1
  OUT="$(python3 "$DIR/index.py" search "$QUERY" --top 12)" || exit 1
fi

# grep args (keyword mode): OR'd literal tokens, or the whole quoted phrase.
# Stopwords dropped (else "the" floods every context line); full set if all are.
# grep -i makes case irrelevant, so tokens are lowercased.
STOPWORDS=" the a an and or of to in on is it for with that this not be are was were do does did how what when who your you my we us i "
QL="$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')"
read -ra TOKS <<< "${QL//\"/ }"
GREP_ARGS=()
if [[ "$QL" =~ ^\".+\"$ ]]; then
  GREP_ARGS=(-e "${QL:1:${#QL}-2}")
elif (( ${#TOKS[@]} )); then
  for t in "${TOKS[@]}"; do [[ -n "$t" && "$STOPWORDS" != *" $t "* ]] && GREP_ARGS+=("-e" "$t"); done
  (( ${#GREP_ARGS[@]} )) || for t in "${TOKS[@]}"; do [[ -n "$t" ]] && GREP_ARGS+=("-e" "$t"); done
fi
(( ${#GREP_ARGS[@]} )) || GREP_ARGS=(-e "$QUERY")

echo "╔══════════════════════════════════════════════╗"
echo "║  UNIFIED SEARCH${SEMANTIC:+ (SEMANTIC)}: \"$QUERY\""
echo "╚══════════════════════════════════════════════╝"

declare -A COUNTS=()
declare -a B=() T=() W=()       # paths
declare -a BX=() BY=() TX=() TY=() WX=() WY=()  # semantic: chunk start/end lines
declare -a BSC=() TSC=() WSC=()                 # semantic: similarity scores
while IFS=$'\t' read -r tag a b c d; do
  case "$tag" in
    COUNT)       COUNTS["$a"]="$b" ;;
    BOOKS)       B+=("$a"); BX+=("$b"); BY+=("$c"); BSC+=("$d") ;;
    TRANSCRIPTS) [[ -z "$FILTER" || "$a" == *"/$FILTER/"* ]] && { T+=("$a"); TX+=("$b"); TY+=("$c"); TSC+=("$d"); } ;;
    WEB)         W+=("$a"); WX+=("$b"); WY+=("$c"); WSC+=("$d") ;;
  esac
done <<< "$OUT"

show_books() {
  echo "━━━ BOOKS ━━━"
  local i t name
  for i in "${!B[@]}"; do
    t="${B[i]}"
    if (( SEMANTIC )); then
      name="$(basename "$t" .txt | sed -E 's/ --.*//; s/_/ /g')"
      echo ""
      echo "[BOOK] $name  (similarity ${BSC[i]:-?}, lines ${BX[i]}-${BY[i]})"
      sed -n "${BX[i]},${BY[i]}p" "$t" | nl -ba -v "${BX[i]}"
    else
      local ctx; ctx="$(grep -in -C 4 "${GREP_ARGS[@]}" "$t" 2>/dev/null | head -45)"
      [[ -z "$ctx" ]] && continue   # ranked on stopwords we dropped — skip empty blocks
      name="$(basename "$t" .txt | sed -E 's/ --.*//; s/_/ /g')"
      echo ""
      echo "[BOOK] $name  ($t)"
      printf '%s\n' "$ctx"
    fi
  done
  (( ${#B[@]} == 0 )) && echo "(no matches)"
  echo ""
}

show_transcripts() {
  echo "━━━ YOUTUBE TRANSCRIPTS ━━━"
  local i t
  for i in "${!T[@]}"; do
    t="${T[i]}"
    echo ""
    if (( SEMANTIC )); then
      echo "[VIDEO] $t  →  https://youtube.com/watch?v=$(basename "$t" .txt)  (similarity ${TSC[i]:-?}, lines ${TX[i]}-${TY[i]})"
      sed -n "${TX[i]},${TY[i]}p" "$t" | nl -ba -v "${TX[i]}"
    else
      local ctx; ctx="$(grep -in -C 2 "${GREP_ARGS[@]}" "$t" 2>/dev/null | head -30)"
      [[ -z "$ctx" ]] && continue
      echo "[VIDEO] $t  →  https://youtube.com/watch?v=$(basename "$t" .txt)"
      printf '%s\n' "$ctx"
    fi
  done
  (( ${#T[@]} == 0 )) && echo "(no matches)"
  echo ""
}

show_web() {
  echo "━━━ WEB ARTICLES ━━━"
  local i t
  for i in "${!W[@]}"; do
    t="${W[i]}"
    echo ""
    if (( SEMANTIC )); then
      echo "[WEB] $t  (similarity ${WSC[i]:-?}, lines ${WX[i]}-${WY[i]})"
      sed -n "${WX[i]},${WY[i]}p" "$t" | nl -ba -v "${WX[i]}"
    else
      local ctx; ctx="$(grep -in -C 4 "${GREP_ARGS[@]}" "$t" 2>/dev/null | head -45)"
      [[ -z "$ctx" ]] && continue
      echo "[WEB] $t"
      printf '%s\n' "$ctx"
    fi
  done
  (( ${#W[@]} == 0 )) && echo "(no matches)"
  echo ""
}

show_books
show_transcripts
show_web

echo "━━━ SUMMARY ━━━"
echo "Books:       ${COUNTS[books]:-0}"
echo "Transcripts: ${COUNTS[transcripts]:-0}"
echo "Web:         ${COUNTS[web]:-0}"
TOTAL=$(( ${COUNTS[books]:-0} + ${COUNTS[transcripts]:-0} + ${COUNTS[web]:-0} ))
if (( TOTAL == 0 )); then
  if (( SEMANTIC )); then
    echo "(no strong semantic matches — try keyword mode (drop --semantic) or different wording)"
  else
    echo "(no matches — try fewer keywords, or \"quote a phrase\" for exact wording)"
  fi
fi
exit 0
