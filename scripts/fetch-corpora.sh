#!/bin/bash
# Fetch the public W3C corpora the opt-in corpus tests read, at pinned commits, and print the
# variables that point the tests at them:
#
#     eval "$(bash scripts/fetch-corpora.sh)"
#     swift test --filter "SpecConformanceW3CCorpus|EPUBCheckCorpus"
#
# The corpora are kept outside the checkout, in one place every worktree shares
# (EPUBLIB_CORPORA_DIR, default ~/Library/Caches/EPUBLib/corpora), so each is fetched once.
# They are data: the tests read their files and run nothing from them.
set -euo pipefail
directory="${EPUBLIB_CORPORA_DIR:-$HOME/Library/Caches/EPUBLib/corpora}"
mkdir -p "$directory"

# A corpus lives in a directory named for its commit, so a new pin fetches beside the old one.
fetch() {
    local name="$1" url="$2" commit="$3"
    local target="$directory/$name-${commit:0:12}"
    if [[ ! -d "$target" ]]; then
        local staging
        staging=$(mktemp -d "$directory/.$name.XXXXXX")
        git -C "$staging" init -q
        git -C "$staging" remote add origin "$url"
        git -C "$staging" fetch -q --depth 1 origin "$commit" >&2
        git -C "$staging" -c advice.detachedHead=false checkout -q FETCH_HEAD
        rm -rf "$staging/.git"
        # A rename fails when another session has put the corpus there first; theirs stands.
        python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$staging" "$target" 2>/dev/null \
            || rm -rf "$staging"
    fi
    echo "$target"
}

w3c=$(fetch epub-tests https://github.com/w3c/epub-tests.git 54092b4233253e9aac80e93ec4782b380b4b3403)
epubcheck=$(fetch epubcheck https://github.com/w3c/epubcheck.git 0cc28fb25fdb3cc7455f029e53afe9e00d7ae607)

printf 'export EPUBLIB_W3C_EPUB_TESTS=%q\n' "$w3c/tests"
printf 'export EPUBLIB_EPUBCHECK_FIXTURES=%q\n' "$epubcheck/src/test/resources"
# The writer's books are validated by the EPUBCheck program itself, when it is installed.
if cli=$(command -v epubcheck); then printf 'export EPUBLIB_EPUBCHECK_CLI=%q\n' "$cli"; fi
