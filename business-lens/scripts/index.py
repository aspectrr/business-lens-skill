#!/usr/bin/env python3
"""index.py — FTS5 index over the business-lens cache (books, transcripts, web).

One row per cached file. `reindex` is incremental: only new/changed files are
re-read, and deletions are detected against the files side table. `search`
ORs query tokens and ranks with BM25; "a quoted phrase" is an exact phrase
query. Env: CACHE_ROOT overrides the cache dir (default ~/.cache/business-lens).
"""
import os
import sqlite3
import sys

CACHE = os.environ.get("CACHE_ROOT", os.path.expanduser("~/.cache/business-lens"))
DB = os.path.join(CACHE, "index.db")
SOURCES = ("books", "transcripts", "web")


def find_files():
    """All indexable files under the three source dirs → {path: (mtime, size)}."""
    out = {}
    for src in SOURCES:
        root = os.path.join(CACHE, src)
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                if f.endswith((".txt", ".md")):
                    p = os.path.join(dirpath, f)
                    try:
                        st = os.stat(p)
                        out[p] = (int(st.st_mtime), st.st_size)
                    except OSError:
                        pass
    return out


def source_of(path):
    return os.path.relpath(path, CACHE).split(os.sep)[0]


def connect():
    db = sqlite3.connect(DB)
    try:
        db.execute("SELECT count(*) FROM docs")
    except sqlite3.Error:
        db.close()
        if os.path.exists(DB):
            os.remove(DB)  # corrupt/foreign index → clean rebuild
        db = sqlite3.connect(DB)
    db.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5"
        "(body, path UNINDEXED, source UNINDEXED, tokenize = 'porter')"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS files"
        " (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER)"
    )
    return db


def reindex():
    os.makedirs(CACHE, exist_ok=True)
    db = connect()
    current = find_files()
    indexed = {p: (m, s) for p, m, s in db.execute("SELECT path, mtime, size FROM files")}
    to_drop = [p for p in indexed if p not in current]
    to_update = [p for p, ms in current.items() if indexed.get(p) != ms]
    n_new = sum(1 for p in to_update if p not in indexed)
    if not to_update and not to_drop:
        print(f"index up to date ({len(current)} files)", file=sys.stderr)
        return
    if len(to_update) > 200:
        print(f"indexing {len(to_update)} files …", file=sys.stderr)
    for p in to_update:
        with open(p, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
        m, s = current[p]
        db.execute("DELETE FROM docs WHERE path = ?", (p,))
        db.execute(
            "INSERT INTO docs (body, path, source) VALUES (?, ?, ?)",
            (body, p, source_of(p)),
        )
        db.execute("INSERT OR REPLACE INTO files VALUES (?, ?, ?)", (p, m, s))
    for p in to_drop:
        db.execute("DELETE FROM docs WHERE path = ?", (p,))
        db.execute("DELETE FROM files WHERE path = ?", (p,))
    db.commit()
    print(
        f"indexed: {n_new} new, {len(to_update) - n_new} updated, "
        f"{len(to_drop)} removed ({len(current)} total)",
        file=sys.stderr,
    )


# Kept in sync with the grep-side list in the search scripts. BM25's IDF already
# downweights these in ranking, but filtering them keeps file counts meaningful too.
STOP = {"the", "a", "an", "and", "or", "of", "to", "in", "on", "is", "it", "for",
        "with", "that", "this", "not", "be", "are", "was", "were", "do", "does",
        "did", "how", "what", "when", "who", "your", "you", "my", "we", "us", "i"}


def fts_query(q):
    """OR'd tokens for a normal query; exact phrase when the query is quoted."""
    q = q.strip()
    if len(q) > 2 and q.startswith('"') and q.endswith('"'):
        inner = q[1:-1].replace('"', '""').strip()
        return f'"{inner}"' if inner else None
    raw = [t for t in q.replace('"', " ").split() if t]
    toks = [t for t in raw if t.lower() not in STOP] or raw
    if not toks:
        return None
    return " OR ".join('"' + t.replace('"', '""') + '"' for t in toks)


def search(argv):
    query, source, top = None, None, 12
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--source":
            source = args.pop(0)
            if source not in SOURCES:
                sys.exit(f"index.py: --source must be one of {', '.join(SOURCES)}")
        elif a == "--top":
            top = int(args.pop(0))
        elif query is None:
            query = a
        else:
            sys.exit("index.py: usage: index.py search QUERY [--source S] [--top N]")
    if not query:
        sys.exit("index.py: usage: index.py search QUERY [--source S] [--top N]")
    match = fts_query(query)
    if not match:
        sys.exit("index.py: empty query")
    db = connect()
    where, params = "docs MATCH ?", [match]
    if source:
        where += " AND source = ?"
        params.append(source)
    counts = dict(db.execute(f"SELECT source, count(*) FROM docs WHERE {where} GROUP BY source", params))
    for s in SOURCES:
        print(f"COUNT\t{s}\t{counts.get(s, 0)}")
    rows = db.execute(
        f"SELECT path, source, bm25(docs) FROM docs WHERE {where} ORDER BY rank LIMIT ?",
        params + [top],
    ).fetchall()
    for path, src, rank in rows:
        print(f"{src.upper()}\t{path}\t{rank:.3f}")
    if not any(counts.values()):
        print(
            "no matches — try fewer keywords, or \"quote a phrase\" for exact wording",
            file=sys.stderr,
        )


# --- semantic search (embeddings) -------------------------------------------
# bge-small-en-v1.5 (384-dim) via sentence-transformers — torch/MPS on Apple
# Silicon (~330 chunks/s); CPU fallback still beats ONNX. Query time loads the
# model once (~10s). Files are embedded as ~CHUNK_CHARS line-aligned chunks
# (whole-file rows would only ever see a book's preface, and meetings-cli-style
# small chunks are both sharper and quadratically cheaper to embed). Each chunk
# keeps its real line range so semantic hits still yield citation-grade lines.
ST_MODEL = "BAAI/bge-small-en-v1.5"
# Meta tag: swapping backend/model invalidates stored vectors (embed() wipes vec).
EMBED_MODEL = ST_MODEL + " (sentence-transformers)"
CHUNK_CHARS = 400
SCORE_FLOOR = 0.4  # cosine above this counts as a "hit" in the per-source SUMMARY


def ensure_vec_schema(db):
    db.execute(
        "CREATE TABLE IF NOT EXISTS vec (path TEXT, source TEXT, chunk_no INTEGER, "
        "start_line INTEGER, end_line INTEGER, mtime INTEGER, size INTEGER, embedding BLOB)"
    )
    db.execute("CREATE INDEX IF NOT EXISTS vec_path ON vec(path)")
    db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")


def chunks_of(body):
    """Yield (start_line, end_line, text) chunks of ~CHUNK_CHARS, cut on line boundaries.
    Overlong single lines (extracted EPUB/PDF pages are often one giant line) are
    split — an unbounded chunk pads the whole embedding batch and stalls ONNX. A
    line's extra pieces stay attributed to that same line number."""
    start, buf, n, last = 1, [], 0, 0
    for i, line in enumerate(body.splitlines(), 1):
        pieces = [line[j:j + CHUNK_CHARS] for j in range(0, len(line), CHUNK_CHARS)] or [""]
        for k, piece in enumerate(pieces):
            buf.append(piece)
            n += len(piece) + 1
            last = i
            if n >= CHUNK_CHARS:
                yield start, i, "\n".join(buf)
                start = i if k + 1 < len(pieces) else i + 1
                buf, n = [], 0
    if buf:
        yield start, last, "\n".join(buf)


def _embedder():
    # heavy import lives here; only semantic paths pay for it (~10s model load)
    from sentence_transformers import SentenceTransformer

    return SentenceTransformer(ST_MODEL)


def _embed_texts(model, texts):
    return model.encode(texts, batch_size=256, normalize_embeddings=True)


def _embed_query(model, text):
    # bge models are trained with this instruction prefix on the query side
    # (short query → passage retrieval); passage side gets no prefix.
    q = model.encode(
        ["Represent this sentence for searching relevant passages: " + text],
        normalize_embeddings=True,
    )[0]
    return q


def embed():
    """Incrementally embed all indexed files (run inside `uv run --with fastembed`)."""
    import numpy as np

    os.makedirs(CACHE, exist_ok=True)
    db = connect()
    ensure_vec_schema(db)
    row = db.execute("SELECT value FROM meta WHERE key = 'embed_model'").fetchone()
    files = {p: (m, s) for p, m, s in db.execute("SELECT path, mtime, size FROM files")}
    if row and row[0] != EMBED_MODEL:
        db.execute("DELETE FROM vec")  # model changed → embeddings incompatible
    vecd = {p: (m, s) for p, m, s in db.execute(
        "SELECT path, mtime, size FROM vec GROUP BY path")}
    if not files:
        sys.exit("index.py: files table empty — run `index.py reindex` first")
    to_drop = [p for p in vecd if p not in files]
    to_do = [p for p, ms in files.items() if vecd.get(p) != ms]
    if not to_do and not to_drop:
        print("embeddings up to date", file=sys.stderr)
        return
    if not row or row[0] != EMBED_MODEL:
        db.execute("INSERT OR REPLACE INTO meta VALUES ('embed_model', ?)", (EMBED_MODEL,))
    for p in to_drop + to_do:
        db.execute("DELETE FROM vec WHERE path = ?", (p,))
    model = _embedder()
    state = {"total": 0}

    def flush(batch):
        if not batch:
            return
        for row, emb in zip(batch, _embed_texts(model, [b[7] for b in batch])):
            p, cno, cs, ce, src, m, s, _ = row
            v = np.asarray(emb, dtype=np.float32)
            norm = np.linalg.norm(v)
            if norm:
                v = v / norm  # pre-normalized → cosine = dot product
            db.execute(
                "INSERT INTO vec VALUES (?,?,?,?,?,?,?,?)",
                (p, src, cno, cs, ce, m, s, sqlite3.Binary(v.tobytes())),
            )
        state["total"] += len(batch)
        batch.clear()

    # Commit per FILE: a crash mid-file rolls that file back completely, so the
    # next run re-embeds it — never a half-embedded file marked up-to-date.
    batch = []
    for fi, p in enumerate(to_do):
        with open(p, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
        m, s = files[p]
        src = source_of(p)
        for cno, (cs, ce, text) in enumerate(chunks_of(body)):
            batch.append((p, cno, cs, ce, src, m, s, text))
            if len(batch) >= 256:
                flush(batch)
        flush(batch)
        db.commit()
        if (fi + 1) % 200 == 0 or fi + 1 == len(to_do):
            print(f"  embedded {state['total']} chunks, {fi + 1}/{len(to_do)} files …", file=sys.stderr)
    db.commit()
    print(
        f"embedded {state['total']} chunks across {len(to_do)} files "
        f"({len(to_drop)} files removed)",
        file=sys.stderr,
    )


def search_semantic(argv):
    """Embed the query, cosine over chunks, best chunk per file. Same output shape
    as keyword search, plus start/end line columns for context extraction."""
    import numpy as np

    query, source, top = None, None, 12
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--source":
            source = args.pop(0)
            if source not in SOURCES:
                sys.exit(f"index.py: --source must be one of {', '.join(SOURCES)}")
        elif a == "--top":
            top = int(args.pop(0))
        elif query is None:
            query = a
    if not query:
        sys.exit("index.py: usage: index.py search --semantic QUERY [--source S] [--top N]")
    db = connect()
    ensure_vec_schema(db)
    if db.execute("SELECT count(*) FROM vec").fetchone()[0] == 0:
        sys.exit("index.py: no embeddings yet — run: index.py embed (first build takes minutes)")
    model = _embedder()
    q = np.asarray(_embed_query(model, query), dtype=np.float32)
    norm = np.linalg.norm(q)
    if norm:
        q = q / norm
    rows = db.execute(
        "SELECT path, source, start_line, end_line, embedding FROM vec"
    ).fetchall()
    mat = np.stack([np.frombuffer(r[4], dtype=np.float32) for r in rows])
    scores = mat @ q
    best = {}
    for i, r in enumerate(rows):
        p = r[0]
        if p not in best or scores[i] > best[p][0]:
            best[p] = (scores[i], i)
    ranked = sorted(best.items(), key=lambda kv: -kv[1][0])
    counts = {}
    for p, (sc, _i) in ranked:
        if sc >= SCORE_FLOOR:
            counts[source_of(p)] = counts.get(source_of(p), 0) + 1
    for s in SOURCES:
        print(f"COUNT\t{s}\t{counts.get(s, 0)}")
    shown = {s: 0 for s in SOURCES}
    for p, (sc, i) in ranked:
        s = source_of(p)
        if source and s != source:
            continue
        if shown[s] >= top:
            continue
        shown[s] += 1
        r = rows[i]
        print(f"{s.upper()}\t{p}\t{r[2]}\t{r[3]}\t{sc:.3f}")
    if not any(counts.values()):
        print(
            "no strong semantic matches — try keyword mode (drop --semantic), "
            "or different wording",
            file=sys.stderr,
        )


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "reindex":
        reindex()
    elif cmd == "embed":
        embed()
    elif cmd == "search":
        rest = sys.argv[2:]
        if "--semantic" in rest:
            rest.remove("--semantic")
            search_semantic(rest)
        else:
            search(rest)
    else:
        sys.exit(
            "usage: index.py reindex\n"
            "       index.py embed                              # build embeddings (needs fastembed, via uv)\n"
            "       index.py search QUERY [--semantic] [--source S] [--top N]"
        )
