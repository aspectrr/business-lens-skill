#!/usr/bin/env bash
# yt-search.sh — fetch (cache) & search/read YouTube transcripts via yt-dlp.
# One-time `sync` downloads every transcript for a channel; later `search`
# greps the local cache instantly. Caches by video id so nothing re-downloads.
set -euo pipefail

CACHE_ROOT="${CACHE_ROOT:-$HOME/.cache/business-lens/transcripts}"
mkdir -p "$CACHE_ROOT"

# channel slug from a url (e.g. https://youtube.com/@AlexHormozi/videos → AlexHormozi)
slug() { echo "$1" | sed -E 's#https?://[^/]+/##; s#/.*##; s/[^a-zA-Z0-9_-]//g'; }

# strip WEBVTT/timestamps/tags, normalize CR, dedupe consecutive identical lines
clean_vtt() {
  tr -d '\r' \
    | sed -E '/^WEBVTT/d; /^Kind:/d; /^Language:/d; /^[0-9]{2}:[0-9]{2}/d; s/<[^>]+>//g' \
    | grep -v '^[[:space:]]*$' \
    | awk 'prev!=$0{print; prev=$0}'
}

# optional cookies for private/unlisted playlists: export YT_COOKIES_FILE=/path/to/cookies.txt
ck() { [[ -n "${YT_COOKIES_FILE:-}" ]] && echo --cookies && echo "$YT_COOKIES_FILE"; }

fetch_video() {
  local url="$1" outdir="$2" id cache
  id="$(yt-dlp --no-warnings $(ck) --print id "$url" 2>/dev/null | head -1)"
  [[ -z "$id" ]] && return 1
  cache="$outdir/$id.txt"
  [[ -f "$cache" ]] && return 0
  local tmp; tmp="$(mktemp -d)"
  yt-dlp $(ck) --skip-download --write-subs --write-auto-subs \
    --sub-lang en --convert-subs vtt -o "$tmp/%(id)s" "$url" >/dev/null 2>&1 || true
  local vtt; vtt="$(ls "$tmp"/*.vtt 2>/dev/null | head -1)"
  if [[ -n "$vtt" && -f "$vtt" ]]; then
    clean_vtt < "$vtt" > "$cache"
  else
    echo "(no English transcript)" > "$cache"
  fi
  rm -rf "$tmp"
}

sync_channel() {
  local url="$1" s outdir n
  s="$(slug "$url")"
  outdir="$CACHE_ROOT/$s"; mkdir -p "$outdir"
  echo "Listing videos for $url …" >&2
  local n_total=0
  while read -r id; do
    [[ -z "$id" ]] && continue
    fetch_video "https://www.youtube.com/watch?v=$id" "$outdir" && echo -n "." >&2
    n_total=$((n_total+1))
  done < <(yt-dlp $(ck) --flat-playlist --print "%(id)s" "$url" 2>/dev/null)
  echo "" >&2
  n="$(ls "$outdir"/*.txt 2>/dev/null | wc -l | tr -d ' ')"
  echo "Cached $n/$n_total transcripts → $outdir" >&2
}

search() {
  local query="$1" scope="${2:-all}" dir="$CACHE_ROOT" t
  [[ "$scope" != "all" ]] && dir="$CACHE_ROOT/$(slug "$scope")"
  [[ -d "$dir" ]] || { echo "(no cached transcripts. run: yt-search.sh sync <channel-url>)" >&2; return; }
  echo "Searching transcripts for: \"$query\"" >&2
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
  # One recursive pass (was one grep per file — thousands of process spawns per query).
  # Equal per-source cap: at most 12 matched videos shown, so a big channel
  # (450+ Founders episodes) can't flood unified search and drown books/web.
  local -a hits=()
  while IFS= read -r t; do hits+=("$t"); done < <(grep -ril "${ga[@]}" "$dir" 2>/dev/null)
  local total=${#hits[@]} cap=12 i
  if (( total == 0 )); then echo "(no transcript matches)" >&2; return 0; fi
  for ((i=0; i<total && i<cap; i++)); do
    t="${hits[i]}"
    local ctx; ctx="$(grep -in -C 2 "${ga[@]}" "$t" 2>/dev/null | head -30)"
    [[ -z "$ctx" ]] && continue   # ranked on stopwords we dropped — skip empty blocks
    echo ""
    # Full cache path in the header: line numbers below are unambiguously
    # attributed to one file (agents cite these line numbers).
    echo "[VIDEO] $t  →  https://youtube.com/watch?v=$(basename "$t" .txt)"
    printf '%s\n' "$ctx"
  done
  (( total > cap )) && echo "(+$((total-cap)) more videos matched — refine the query or scope to one channel)" >&2
  return 0
}

# read: dump full transcript of a video (by id or url), fetching if needed
read_transcript() {
  local url="$1" id cache
  id="$(echo "$url" | grep -oE '[a-zA-Z0-9_-]{11}$' || yt-dlp --no-warnings --print id "$url" 2>/dev/null | head -1)"
  [[ -z "$id" ]] && { echo "could not resolve video id from $url" >&2; return 1; }
  # find existing cache, else fetch into _single
  cache="$(find "$CACHE_ROOT" -name "$id.txt" 2>/dev/null | head -1)"
  if [[ -z "$cache" ]]; then
    local d="$CACHE_ROOT/_single"; mkdir -p "$d"
    fetch_video "https://www.youtube.com/watch?v=$id" "$d"
    cache="$d/$id.txt"
  fi
  echo "[VIDEO] https://youtube.com/watch?v=$id" >&2
  cat "$cache"
}

usage() {
  cat >&2 <<EOF
yt-search.sh — search & read YouTube transcripts (cached via yt-dlp)
  yt-search.sh sync   <channel-or-/videos-url>           # download all transcripts
  yt-search.sh search "query" [channel-url]              # grep cached transcripts
  yt-search.sh read   <video-id-or-url>                  # dump full transcript
  yt-search.sh list   [channel-url]                      # show cached channels
(Search matches ANY keyword of a multi-word query; \"quote a phrase\" for exact wording.
Shows max 12 matched videos; scope to one channel or refine the query.)
Examples:
  yt-search.sh sync https://www.youtube.com/@AlexHormozi/videos
  yt-search.sh search "newsletter drop off"
  yt-search.sh read   https://youtube.com/watch?v=dQw4w9WgXcQ
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  sync)   sync_channel "${1:?need a channel/videos url}" ;;
  search) search "${1:?need a query}" "${2:-all}" ;;
  read)   read_transcript "${1:?need a video id or url}" ;;
  list)
    if [[ -n "${1:-}" ]]; then
      local s; s="$(slug "$1")"; ls -1 "$CACHE_ROOT/$s"/*.txt 2>/dev/null | xargs -n1 basename 2>/dev/null || echo "(none)"
    else
      for d in "$CACHE_ROOT"/*/; do echo "$(basename "$d"): $(ls "$d"*.txt 2>/dev/null | wc -l | tr -d ' ') videos"; done 2>/dev/null || echo "(nothing synced yet)"
    fi
    ;;
  *) usage; exit 1 ;;
esac
