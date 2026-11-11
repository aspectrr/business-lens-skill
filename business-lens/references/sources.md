# Trusted Source Registry

Authors and content Collin trusts for business thinking. Use this to fetch fresh
or seed the caches. Keep additions here as Collin's trusted set grows.

## Paul Graham (essays) — Collin's #1 source
paulgraham.com — plain HTML, curl+pandoc fetches cleanly.
| Topic | URL |
|-------|-----|
| Do Things That Don't Scale | https://paulgraham.com/ds.html |
| How to Get Startup Ideas | https://paulgraham.com/getideas.html |
| Default Alive or Default Dead | https://paulgraham.com/die.html |
| Ramen Profitable | https://paulgraham.com/ramenprofitable.html |
| Make Something People Want | https://paulgraham.com/goodtaste.html |
| How to Do Great Work | https://paulgraham.com/greatwork.html |
| Founder Type | https://paulgraham.com/foundermode.html (verify URL) |
| Before the Startup (talk to users) | https://paulgraham.com/before.html |

Seed the cache: `web-search.sh fetch https://paulgraham.com/ds.html pg-ds`

## Marc Andreessen (pmarca blog) — already in books as PDF
The-pmarca-Blog-Archives.pdf covers his full blog. Searchable via `book-search.sh`.

## Alex Hormozi — books + YouTube
- Books: `$100M Offers`, `$100M Leads`, `$100M Money Models` (in ~/Desktop/learning/books)
- YouTube: `yt-search.sh sync https://www.youtube.com/@AlexHormozi/videos`

## David Ogilvy — book + swiped.co teardowns
`Ogilvy on Advertising` (in ~/Desktop/learning/books). Classic ads he wrote are also
on swiped.co with modern annotation — `swiped-sync.sh sync` caches them; cite the
swipe URL alongside the book when the ads themselves are the evidence.

## Charlie Munger — book
`Poor Charlie's Almanack` (EPUB + PDF in ~/Desktop/learning/books)

## Rob Fitzpatrick — book
`The Mom Test` (in ~/Desktop/learning/books)

## Other books in the library (broader thinking)
- Man's Search for Meaning (Frankl) — purpose/why
- The Art of Doing Science and Engineering (Hamming) — greatness/creativity
- You and Your Research (Hamming) — also as PDF
- The 38 Letters from J.D. Rockefeller to his son — principles/legacy
- The Richest Man in Babylon — personal finance fundamentals
- Total Recall (Schwarzenegger) — ambition/discipline
- About Behaviorism (Skinner) — human behavior

## Swiped.co (Swipe-Worthy) — advertising teardown corpus
442+ annotated ad teardowns (hooks, split-tests, direct mail, print, display) by
Mike Schauer. Ingested by `swiped-sync.sh sync` into `~/.cache/business-lens/swiped/`
(analysis text + OCR of the ad images); auto-synced daily. Browse the live archive:
https://swiped.co/browse — cite swipes as `[WEB] <title> — swiped.co/file/<slug>`.
