#!/bin/bash
# An agent must not run this script. Standard Ebooks' robots.txt disallows its downloads
# (/ebooks/*/downloads/*) for AI agents' user agents (claude-user, claude-web, chatgpt-user and
# others), so the owner runs it by hand. scripts/fetch-corpora.sh never calls it: it only verifies
# the books this script fetched, and then prints EPUBLIB_STANDARD_EBOOKS.
#
# Usage: bash scripts/fetch-standard-ebooks.sh [--pin]
#
#   --pin  fetches every book in scripts/corpora/standard-ebooks.tsv afresh into
#          ${EPUBLIB_CORPORA_DIR:-~/Library/Caches/EPUBLib/corpora}/standard-ebooks-TODAY and writes
#          each one's sha256 and bytes and the date into the manifest. Commit the manifest after.
#          A first fetch, and every re-pin, is done this way.
#   (none) fetches the books missing from the pinned corpus and verifies every one against the
#          manifest; a book whose bytes have changed since the pin is reported, never replaced.
#
# The script names itself in its user agent and keeps to robots.txt, one request at a time, at
# least 2 s apart (scripts/corpora/fetch_books.py). The books are data: nothing runs from them.
set -euo pipefail
if [[ -n "${CLAUDECODE:-}" ]]; then
    echo "Refusing: this shell belongs to an agent (CLAUDECODE is set). Standard Ebooks is fetched by the owner only." >&2
    exit 2
fi
books="$(cd "$(dirname "$0")" && pwd)/corpora"
directory="${EPUBLIB_CORPORA_DIR:-$HOME/Library/Caches/EPUBLib/corpora}"
mkdir -p "$directory"
mode=fetch
case "${1:-}" in
    --pin) mode=pin ;;
    "") ;;
    *) echo "usage: $0 [--pin]" >&2; exit 2 ;;
esac
corpus=$(python3 -I "$books/fetch_books.py" "$mode" "$books/standard-ebooks.tsv" "$directory")
printf 'export EPUBLIB_STANDARD_EBOOKS=%q\n' "$corpus"
