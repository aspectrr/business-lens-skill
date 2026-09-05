#!/usr/bin/env bash
# search-all.sh — unified search across books, YouTube transcripts, and web articles.
# Runs all three source scripts, consolidates results with source-type tags, and
# returns a deduplicated, attributed summary. This is the primary discovery command.
# No set -e: grep returning non-zero (no matches) is expected, not an error.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY="${1:?usage: search-all.sh \"query\" [yt-channel-url]}"

echo "╔══════════════════════════════════════════════╗"
echo "║  UNIFIED SEARCH: \"$QUERY\""
echo "╚══════════════════════════════════════════════╝"
echo ""

echo "━━━ BOOKS ━━━"
"$DIR/book-search.sh" search "$QUERY" 2>/dev/null || echo "(book search unavailable)"
echo ""
echo "━━━ YOUTUBE TRANSCRIPTS ━━━"
"$DIR/yt-search.sh" search "$QUERY" "${2:-all}" 2>/dev/null || echo "(transcript search unavailable)"
echo ""
echo "━━━ WEB ARTICLES ━━━"
"$DIR/web-search.sh" search "$QUERY" 2>/dev/null || echo "(web search unavailable)"
echo ""
echo "━━━ SUMMARY ━━━"
echo -n "Books:       "; grep -rli "$QUERY" "$HOME/.cache/business-lens/books"/*.txt 2>/dev/null | wc -l | tr -d ' '; echo
echo -n "Transcripts: "; grep -rli "$QUERY" "$HOME/.cache/business-lens/transcripts"/*/*.txt 2>/dev/null | wc -l | tr -d ' '; echo
echo -n "Web:         "; { grep -rli "$QUERY" "$HOME/.cache/business-lens/web"/*.txt "$HOME/.cache/business-lens/web"/*/*.md "$HOME/.cache/business-lens/web"/*/*/*.md 2>/dev/null; } | wc -l | tr -d ' '; echo
