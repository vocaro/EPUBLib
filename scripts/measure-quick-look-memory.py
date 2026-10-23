#!/usr/bin/env python3
"""Measure the memory and time of Quick Look thumbnails and previews of EPUB books (#695).

Runs `QuickLookMemoryTests` from a release build: on the Mac in a fresh process for each book
and call, and in a disposable iOS simulator in one process for each call over every book.
Packs the W3C reading-system tests, which are expanded directories, into EPUB files first.
Run it as exclusive work, so no other build or test shares the machine:

    eval "$(bash scripts/fetch-corpora.sh)"
    python3 scripts/eng admit --exclusive -- python3 scripts/measure-quick-look-memory.py --mac --simulator

`doc/testing.md`, "Quick Look memory", says what each column holds.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
import zipfile

root = Path(__file__).resolve().parent.parent
CALLS = ["thumbnail", "preview"]


def pack_w3c(tests, target):
    """Each W3C test directory as an OCF container: mimetype first and stored, the rest deflated."""
    target.mkdir(parents=True, exist_ok=True)
    packed = []
    for directory in sorted(p for p in tests.iterdir() if p.is_dir()):
        epub = target / f"{directory.name}.epub"
        if not epub.exists():
            staging = epub.with_suffix(".partial")
            with zipfile.ZipFile(staging, "w") as archive:
                mimetype = directory / "mimetype"
                if mimetype.is_file() and not mimetype.is_symlink():
                    archive.write(mimetype, "mimetype", compress_type=zipfile.ZIP_STORED)
                for path in sorted(directory.rglob("*")):
                    relative = path.relative_to(directory).as_posix()
                    if relative == "mimetype" or path.is_symlink() or not path.is_file() or path.name == ".DS_Store":
                        continue
                    archive.write(path, relative, compress_type=zipfile.ZIP_DEFLATED)
            staging.rename(epub)
        packed.append(epub)
    return packed


def rows(output):
    return [line.split("QUICKLOOK ", 1)[1].split("\t") for line in output.splitlines() if line.startswith("QUICKLOOK ")]


def run_mac(books, calls, out, timeout):
    subprocess.run(["swift", "build", "-c", "release", "--build-tests", "-Xswiftc", "-enable-testing", "-j", "4"],
                   cwd=root, check=True)
    bundle = root / ".build" / "release" / "EPUBViewingTests.xctest"
    results = []
    for call in calls:
        for book in books:
            environment = dict(os.environ, EPUBLIB_QUICK_LOOK_INPUTS=str(book), EPUBLIB_QUICK_LOOK_CALL=call)
            command = ["xcrun", "xctest", "-XCTest", "EPUBViewingTests.QuickLookMemoryTests/testQuickLookMemory", str(bundle)]
            try:
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=timeout)
                found = rows(result.stdout + result.stderr)
                if result.returncode != 0 or len(found) != 1:
                    found = [[book.name, call, f"failed: exit {result.returncode}", "", "", "", "", "", "", ""]]
            except subprocess.TimeoutExpired:
                found = [[book.name, call, f"unmeasured: process exceeded {timeout} s", "", "", "", "", "", "", ""]]
            results += found
            print("mac\t" + "\t".join(found[0]), flush=True)
    write(out / "mac.tsv", results)
    return results


def run_simulator(books, calls, out, runtime):
    name = f"EPUBLib-QuickLook-{uuid.uuid4().hex[:8]}"
    device = subprocess.run(["xcrun", "simctl", "create", name, "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime],
                            capture_output=True, text=True, check=True).stdout.strip().upper()
    print(f"simulator {name} {device}", flush=True)
    results = []
    try:
        subprocess.run(["xcrun", "simctl", "boot", device], check=True)
        subprocess.run(["perl", "-e", "alarm shift; exec @ARGV", "600", "xcrun", "simctl", "bootstatus", device, "-b"], check=True)
        derived = root / ".build" / "quick-look-memory"
        destination = ["-scheme", "EPUBLib-Package", "-destination", f"platform=iOS Simulator,id={device}",
                       "-derivedDataPath", str(derived), "-configuration", "Release", "ENABLE_TESTABILITY=YES",
                       "CODE_SIGNING_ALLOWED=NO", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"]
        with open(out / "simulator-build.log", "w") as log:
            subprocess.run(["xcodebuild", "build-for-testing"] + destination, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
        inputs = ":".join(str(book) for book in books)
        for call in calls:
            environment = dict(os.environ, TEST_RUNNER_EPUBLIB_QUICK_LOOK_INPUTS=inputs, TEST_RUNNER_EPUBLIB_QUICK_LOOK_CALL=call)
            result = subprocess.run(["xcodebuild", "test-without-building", "-only-testing:EPUBViewingTests/QuickLookMemoryTests"] + destination,
                                    cwd=root, env=environment, capture_output=True, text=True)
            (out / f"simulator-{call}.log").write_text(result.stdout + result.stderr)
            found = rows(result.stdout + result.stderr)
            summary = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("QUICKLOOK-SUMMARY")]
            print(f"simulator {call}: exit {result.returncode}, {len(found)} of {len(books)} books; {summary[-1] if summary else 'no summary'}",
                  flush=True)
            if "Executed 1 test" not in result.stdout + result.stderr:
                print(f"simulator {call}: the test did not run once; see simulator-{call}.log", flush=True)
            results += found
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True)
        print(f"deleted {device}", flush=True)
    write(out / "simulator.tsv", results)
    return results


def write(path, results):
    header = "book\tcall\toutcome\tarchive_bytes\tfootprint_before\tsampled_rise\tlifetime_peak\tpressure_before\tpressure_after\tmilliseconds"
    path.write_text("\n".join([header] + ["\t".join(row) for row in results]) + "\n")


def summarize(label, results):
    for call in CALLS:
        measured = [r for r in results if r[1] == call and r[6] and r[7] == "1" and r[8] == "1"]
        spoiled = [r for r in results if r[1] == call and r[6] and not (r[7] == "1" and r[8] == "1")]
        if not measured and not spoiled:
            continue
        mib = lambda value: int(value) / 1_048_576
        peak = max(measured, key=lambda r: int(r[6]), default=None)
        rise = max(measured, key=lambda r: int(r[5]), default=None)
        slow = max(measured, key=lambda r: float(r[9]), default=None)
        print(f"{label} {call}: {len(measured)} measured at normal pressure, {len(spoiled)} unmeasured (pressure rose)")
        if peak:
            print(f"  highest lifetime peak {mib(peak[6]):.1f} MiB ({peak[0]}, footprint before {mib(peak[4]):.1f} MiB)")
            print(f"  largest sampled rise {mib(rise[5]):.1f} MiB ({rise[0]}); slowest {float(slow[9]):.0f} ms ({slow[0]})")
        outcomes = {}
        for r in results:
            if r[1] == call:
                outcomes[r[2].split(" ")[0]] = outcomes.get(r[2].split(" ")[0], 0) + 1
        print(f"  outcomes {json.dumps(outcomes, sort_keys=True)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mac", action="store_true", help="measure on this Mac, a fresh process per book and call")
    parser.add_argument("--simulator", action="store_true", help="measure in a disposable iPhone 17 Pro simulator")
    parser.add_argument("--books", nargs="*", type=Path, default=[], help="further EPUB files or directories of them")
    parser.add_argument("--no-w3c", action="store_true", help="leave out the W3C tests")
    parser.add_argument("--call", choices=CALLS, action="append", help="measure only this call (repeatable)")
    parser.add_argument("--timeout", type=float, default=120, help="seconds each Mac process may take")
    parser.add_argument("--runtime", default=os.environ.get("EPUB_SIM_RUNTIME", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
    args = parser.parse_args()
    if not (args.mac or args.simulator):
        parser.error("choose --mac, --simulator or both")
    out = root / ".build" / "quick-look-memory" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True)
    books = []
    if not args.no_w3c:
        tests = os.environ.get("EPUBLIB_W3C_EPUB_TESTS")
        if not tests:
            parser.error("set EPUBLIB_W3C_EPUB_TESTS (scripts/fetch-corpora.sh), or pass --no-w3c")
        books += pack_w3c(Path(tests), root / ".build" / "quick-look-memory" / "w3c-epub-tests")
    for path in args.books:
        books += sorted(path.glob("*.epub")) if path.is_dir() else [path]
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip()
    print(f"commit {commit}; {len(books)} books; output {out}", flush=True)
    calls = args.call or CALLS
    if args.mac:
        summarize("mac", run_mac(books, calls, out, args.timeout))
    if args.simulator:
        summarize("simulator", run_simulator(books, calls, out, args.runtime))
    return 0


if __name__ == "__main__":
    sys.exit(main())
