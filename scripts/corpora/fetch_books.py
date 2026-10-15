#!/usr/bin/env python3
"""Fetch, verify and pin a book corpus named by a manifest in scripts/corpora.

    python3 -I scripts/corpora/fetch_books.py verify|fetch|pin MANIFEST CORPORA_DIR [--out PINNED]

A manifest is tab-separated, with a header row whose first five columns are url, sha256, bytes,
title and genre; any further columns are kept as they are. Lines starting with # are comments,
two of which the script reads: `# corpus: NAME` and `# pinned: YYYY-MM-DD` (or `-`). The books
live in CORPORA_DIR/NAME-YYYY-MM-DD, so a new pin fetches beside the old one.

- verify: checks the books present against the manifest, with no network. Silent when the
  corpus is unpinned or not fetched.
- fetch: verifies, then downloads only the books that are missing. A download whose SHA-256
  differs from the manifest's is kept as NAME.mismatch-SHA12 and reported; nothing present is
  replaced. A mismatch means the publisher rebuilt the book: re-pin (doc/testing.md, "Corpus runs").
- pin: downloads every book afresh into NAME-TODAY and writes the manifest to PINNED (default:
  MANIFEST) with the sha256 and bytes it found and the new date.

Downloads are polite: each host's robots.txt is read first (a missing one allows everything) and
nothing is fetched when it disallows any URL for this agent; one request at a time, at least 2 s
apart (EPUBLIB_FETCH_DELAY may raise that), and one fetch at a time across sessions (a lock file
in CORPORA_DIR); redirects to another host are refused.

Exit status 0, and the corpus directory on stdout, when every book is present and verified.
The books are data: nothing here runs anything from them.
"""
import datetime, fcntl, hashlib, os, re, sys, time, urllib.error, urllib.parse, urllib.request

TOKEN = "epublib-corpus-fetch"
AGENT = "EPUBLib-corpus-fetch/1.0 (+https://github.com/vocaro/EPUBLib; one request per 2 s)"
DELAY = max(2.0, float(os.environ.get("EPUBLIB_FETCH_DELAY", "2")))
_last = [0.0]


def say(message):
    print(message, file=sys.stderr)


class SameHostRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        if urllib.parse.urlsplit(url).hostname != urllib.parse.urlsplit(request.full_url).hostname:
            raise urllib.error.HTTPError(url, code, "redirect to another host refused", headers, fp)
        return super().redirect_request(request, fp, code, message, headers, url)


_opener = urllib.request.build_opener(SameHostRedirects)


def get(url, sink):
    wait = DELAY - (time.monotonic() - _last[0])
    if wait > 0:
        time.sleep(wait)
    try:
        with _opener.open(urllib.request.Request(url, headers={"User-Agent": AGENT}), timeout=900) as response:
            while chunk := response.read(1 << 16):
                sink(chunk)
    finally:
        _last[0] = time.monotonic()


def robots_rules(text):
    """The Allow/Disallow rules of the group naming this agent (RFC 9309), else of the * group."""
    groups, agents, rules, in_rules = [], [], [], False
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if ":" not in line:
            continue
        field, value = (part.strip() for part in line.split(":", 1))
        field = field.lower()
        if field == "user-agent":
            if in_rules:
                groups.append((agents, rules))
                agents, rules, in_rules = [], [], False
            agents.append(value.lower())
        elif field in ("allow", "disallow"):
            in_rules = True
            rules.append((field, value))
    if agents:
        groups.append((agents, rules))
    mine = [rule for names, group in groups if TOKEN in names for rule in group]
    return mine or [rule for names, group in groups if "*" in names for rule in group]


def allowed(rules, path):
    """The longest matching rule decides; on a tie Allow wins; no match allows."""
    length, verdict = -1, True
    for kind, pattern in rules:
        if not pattern:
            continue
        regex = re.escape(pattern).replace(r"\*", ".*")
        if regex.endswith(r"\$"):
            regex = regex[:-2] + "$"
        if re.match(regex, path) and (len(pattern) > length or (len(pattern) == length and kind == "allow")):
            length, verdict = len(pattern), kind == "allow"
    return verdict


def check_robots(urls):
    for origin in sorted({urllib.parse.urlsplit(url)[:2] for url in urls}):
        body = []
        try:
            get(f"{origin[0]}://{origin[1]}/robots.txt", body.append)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        rules = robots_rules(b"".join(body).decode("utf-8", "replace"))
        refused = [url for url in urls if urllib.parse.urlsplit(url)[:2] == origin
                   and not allowed(rules, urllib.parse.urlsplit(url).path)]
        if refused:
            say(f"robots.txt on {origin[1]} disallows {len(refused)} of the URLs for {TOKEN}; nothing fetched.")
            sys.exit(3)


def digest(path):
    h, size = hashlib.sha256(), 0
    with open(path, "rb") as handle:
        while chunk := handle.read(1 << 20):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def download(url, target):
    part = f"{target}.part-{os.getpid()}"
    h, size = hashlib.sha256(), [0]
    with open(part, "wb") as handle:
        def sink(chunk):
            handle.write(chunk)
            h.update(chunk)
            size[0] += len(chunk)
        try:
            get(url, sink)
        except Exception:
            handle.close()
            os.remove(part)
            raise
    return part, h.hexdigest(), size[0]


def main():
    args = sys.argv[1:]
    out = None
    if "--out" in args:
        index = args.index("--out")
        out = args[index + 1]
        del args[index:index + 2]
    if len(args) != 3 or args[0] not in ("verify", "fetch", "pin"):
        say(__doc__.split("\n\n")[1])
        sys.exit(2)
    mode, manifest, corpora = args
    lines = open(manifest, encoding="utf-8").read().splitlines()
    meta = dict(re.findall(r"^# (corpus|pinned): (\S+)", "\n".join(lines), re.M))
    if "corpus" not in meta or "pinned" not in meta:
        say(f"{manifest}: missing `# corpus:` or `# pinned:` line")
        sys.exit(2)
    entries = [(number, line.split("\t")) for number, line in enumerate(lines)
               if line.strip() and not line.startswith("#") and not line.startswith("url\t")]
    today = datetime.date.today().isoformat()
    date = today if mode == "pin" else meta["pinned"]
    directory = os.path.join(corpora, f"{meta['corpus']}-{date}")
    if mode != "pin" and (date == "-" or any(f[1] in ("", "-") for _, f in entries)):
        if mode == "fetch":
            say(f"{manifest} is not pinned: pin it first (doc/testing.md, \"Corpus runs\").")
        sys.exit(1)
    if mode == "verify" and not os.path.isdir(directory):
        sys.exit(1)

    problems, missing, pins = 0, [], {}
    for number, fields in entries:
        url, expected = fields[0], fields[1]
        target = os.path.join(directory, os.path.basename(urllib.parse.urlsplit(url).path))
        if mode == "pin" or not os.path.exists(target):
            missing.append((number, url, expected, target))
            continue
        found, _ = digest(target)
        if found != expected:
            say(f"MISMATCH (kept, not replaced): {target} has {found}, the manifest {expected}")
            problems += 1
    if mode == "verify" and missing:
        say(f"{len(missing)} of {len(entries)} books missing in {directory}")
        problems += len(missing)
        missing = []
    if missing:
        os.makedirs(directory, exist_ok=True)
        # One fetch at a time across sessions, so requests stay 2 s apart; a book another
        # session fetched while this one waited is not fetched again.
        lock = open(os.path.join(corpora, ".fetch-books.lock"), "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
        if mode == "fetch":
            missing = [item for item in missing if not (os.path.exists(item[3]) and digest(item[3])[0] == item[2])]
        if missing:
            check_robots([url for _, url, _, _ in missing])
        for number, url, expected, target in missing:
            try:
                part, found, size = download(url, target)
            except Exception as error:
                say(f"FAILED: {url}: {error}")
                problems += 1
                continue
            if mode == "pin":
                os.replace(part, target)
                pins[number] = (found, size)
                say(f"pinned: {os.path.basename(target)} {found} {size}")
            elif found == expected:
                os.rename(part, target)
                say(f"fetched: {os.path.basename(target)}")
            else:
                kept = f"{target}.mismatch-{found[:12]}"
                os.replace(part, kept)
                say(f"MISMATCH (download kept as {os.path.basename(kept)}): {url} has {found}, the manifest {expected}")
                problems += 1
    if mode == "pin":
        if problems:
            say(f"{problems} books not fetched; the manifest is not written.")
            sys.exit(1)
        written = []
        for number, line in enumerate(lines):
            if number in pins:
                fields = line.split("\t")
                fields[1], fields[2] = pins[number][0], str(pins[number][1])
                line = "\t".join(fields)
            elif line.startswith("# pinned: "):
                line = f"# pinned: {today}"
            written.append(line)
        with open(out or manifest, "w", encoding="utf-8") as handle:
            handle.write("\n".join(written) + "\n")
        say(f"wrote {out or manifest}: {len(pins)} books pinned on {today}")
    say(f"{len(entries)} books, {problems} problems, in {directory}")
    if problems:
        sys.exit(1)
    print(directory)


main()
