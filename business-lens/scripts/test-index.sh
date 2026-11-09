#!/usr/bin/env bash
# test-index.sh — self-check for index.py + search-all.sh. Assert-based, no framework,
# runs against a throwaway CACHE_ROOT fixture.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CACHE_ROOT="$TMP/cache"
mkdir -p "$CACHE_ROOT/books" "$CACHE_ROOT/transcripts/ch" "$CACHE_ROOT/web"
printf 'grand slam offer so good people feel stupid saying no\n' > "$CACHE_ROOT/books/offers.txt"
printf 'retention before acquisition. fix churn first.\n' > "$CACHE_ROOT/transcripts/ch/vid1.txt"
printf 'sell the outcome not the feature\n' > "$CACHE_ROOT/web/post.md"
fail() { echo "FAIL: $1" >&2; exit 1; }
tab=$'\t'

python3 "$DIR/index.py" reindex >/dev/null 2>&1 || fail "reindex errored"

# OR query: 'outcome feature' must match only the web post
out="$(python3 "$DIR/index.py" search "outcome feature" --top 5)" || fail "search errored"
grep -q "COUNT${tab}web${tab}1" <<<"$out"        || fail "OR query: web count should be 1"
grep -q "COUNT${tab}books${tab}0" <<<"$out"      || fail "OR query: books count should be 0"
[[ "$(grep -c '^WEB' <<<"$out")" -eq 1 ]]        || fail "OR query: should list 1 ranked web hit"

# phrase query matches only the exact-phrase doc
out="$(python3 "$DIR/index.py" search '"sell the outcome"')" || fail "phrase search errored"
grep -q "COUNT${tab}web${tab}1" <<<"$out"        || fail "phrase: web count should be 1"
grep -q "COUNT${tab}books${tab}0" <<<"$out"      || fail "phrase must not match books"

# per-source counts over a multi-source OR query
out="$(python3 "$DIR/index.py" search "offer churn outcome")" || fail "counts search errored"
grep -q "COUNT${tab}books${tab}1" <<<"$out"      || fail "books count"
grep -q "COUNT${tab}transcripts${tab}1" <<<"$out" || fail "transcripts count"
grep -q "COUNT${tab}web${tab}1" <<<"$out"        || fail "web count"

# changed file re-indexes (size change triggers it even in the same mtime second)
printf 'brand image is ninety percent\n' >> "$CACHE_ROOT/transcripts/ch/vid1.txt"
python3 "$DIR/index.py" reindex >/dev/null 2>&1 || fail "reindex after edit errored"
out="$(python3 "$DIR/index.py" search "brand image")" || fail "re-search after edit errored"
grep -q "COUNT${tab}transcripts${tab}1" <<<"$out" || fail "changed file not re-indexed"

# deletion drops the row; zero-result search still succeeds
rm "$CACHE_ROOT/web/post.md"
python3 "$DIR/index.py" reindex >/dev/null 2>&1 || fail "reindex after delete errored"
out="$(python3 "$DIR/index.py" search "outcome feature")" || fail "search after delete errored"
grep -q "COUNT${tab}web${tab}0" <<<"$out"        || fail "deleted file still counted"
[[ "$(grep -c '^WEB' <<<"$out")" -eq 0 ]]        || fail "deleted file still listed"

# no-op reindex reports up to date
out="$(python3 "$DIR/index.py" reindex 2>&1 >/dev/null)"
grep -q "up to date" <<<"$out"                   || fail "no-op reindex should report 'up to date'"

# search-all end-to-end: banner + ranked section header + summary (re-add the deleted
# post first — also exercises incremental pickup of new files)
printf 'sell the outcome not the feature\n' > "$CACHE_ROOT/web/post.md"
python3 "$DIR/index.py" reindex >/dev/null 2>&1
out="$(CACHE_ROOT="$CACHE_ROOT" "$DIR/search-all.sh" "outcome feature")"
grep -q "UNIFIED SEARCH" <<<"$out"               || fail "search-all banner missing"
grep -q '\[WEB\]' <<<"$out"                      || fail "search-all missing [WEB] hit"
grep -q "Web:         1" <<<"$out"               || fail "search-all SUMMARY web count wrong"

# semantic mode: embed the fixture and check that a query sharing no keywords
# with post.md still ranks it first (that's the whole point). Needs uv+fastembed.
if command -v uv >/dev/null 2>&1; then
  CACHE_ROOT="$CACHE_ROOT" uv run --quiet --with sentence-transformers python3 "$DIR/index.py" embed >/dev/null 2>&1 \
    || fail "embed errored"
  out="$(CACHE_ROOT="$CACHE_ROOT" uv run --quiet --with sentence-transformers python3 "$DIR/index.py" search --semantic "delivering results to buyers instead of technical specs" --top 3)" \
    || fail "semantic search errored"
  grep -qE "^WEB${tab}.*post\.md${tab}1${tab}1${tab}0\.[5-9]" <<<"$out" \
    || fail "semantic: post.md should rank first with sim >= 0.5"
  out="$(CACHE_ROOT="$CACHE_ROOT" "$DIR/search-all.sh" --semantic "delivering results to buyers instead of technical specs")"
  grep -q "UNIFIED SEARCH (SEMANTIC)" <<<"$out" || fail "semantic search-all banner missing"
  grep -q '\[WEB\] .* (similarity 0\.' <<<"$out" || fail "semantic search-all hit missing score/lines"
  grep -q "Web:         1" <<<"$out"              || fail "semantic search-all SUMMARY wrong"
else
  echo "uv not found — skipping semantic tests"
fi

echo "all index tests passed"
