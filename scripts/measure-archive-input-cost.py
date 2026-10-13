#!/usr/bin/env python3
"""Release-build #199 inputs, with each opening bounded by its own process timeout."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--zipfoundation", type=Path, help="Use an existing public ZIPFoundation checkout")
parser.add_argument("--timeout", type=float, default=120, help="Seconds allowed for each own child process")
parser.add_argument("--repeats", type=int, default=1)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
scratch = root / ".build" / "measure-archive-input-cost"
sources = scratch / "Sources"
sources.mkdir(parents=True, exist_ok=True)
for module, relative in [("EPUBCore", "Sources/EPUBCore"), ("EPUBReading", "Sources/EPUBReading"), ("EPUBText", "Sources/EPUBText"),
                         ("EPUBTestSupport", "Tests/EPUBTestSupport")]:
    link = sources / module
    if not link.exists():
        link.symlink_to(root / relative, target_is_directory=True)
tests = scratch / "Tests"
if not tests.exists():
    tests.symlink_to(root / "Tests/EPUBReadingTests", target_is_directory=True)
dependency = (f'.package(path: {json.dumps(str(args.zipfoundation.resolve()))})' if args.zipfoundation
              else '.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")')
(scratch / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ArchiveInputCost", platforms: [.macOS("27.0")], dependencies: [DEPENDENCY], targets: [
 .target(name: "EPUBCore"), .target(name: "EPUBReading", dependencies: ["EPUBCore", "ZIPFoundation"]),
 .target(name: "EPUBTestSupport", dependencies: ["ZIPFoundation"]),
 .target(name: "EPUBText", dependencies: ["EPUBCore", "EPUBReading"]),
 .executableTarget(name: "ArchiveInputCost", dependencies: ["EPUBCore", "EPUBReading", "EPUBTestSupport"]),
 .testTarget(name: "EPUBReadingTests", dependencies: ["EPUBCore", "EPUBReading", "EPUBText", "EPUBTestSupport"], path: "Tests")
])
'''.replace("DEPENDENCY", dependency))
probe = sources / "ArchiveInputCost"
probe.mkdir(exist_ok=True)
(probe / "main.swift").write_text('''import Foundation
import Darwin
import EPUBReading
import EPUBTestSupport
setvbuf(stdout, nil, _IOLBF, 0)
let mode = CommandLine.arguments[1], entries = Int(CommandLine.arguments[2])!
let data = try Fixture.sharedInputArchive(entries: entries, streamBytes: mode == "header" ? 0 : 4 << 20,
                                         longHeader: mode == "header", earlyEnd: mode == "early",
                                         distinctHeaders: mode == "overlap")
_ = try EPUBPublication.open(data: Fixture.epub())
func cpu() -> Double {
 var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
 return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
let start = Date(), before = cpu()
var outcome = ""
final class Calls: @unchecked Sendable { var count = 0 }
let calls = Calls()
do { let book = try EPUBPublication.open(data: data, onProgress: { _ in calls.count += 1 }); outcome = "opened spine=\\(book.spine.count)" }
catch { outcome = String(describing: error) }
print("\\(mode) entries=\\(entries) bytes=\\(data.count) callbacks=\\(calls.count) cpu=\\(cpu() - before) wall=\\(Date().timeIntervalSince(start)) \\(outcome)")
''')
subprocess.run(["swift", "build", "--package-path", str(scratch), "-c", "release", "--product", "ArchiveInputCost", "-j", "2"], check=True)
binary = scratch / ".build" / "release" / "ArchiveInputCost"
for mode, counts in [("header", [1, 19_993]), ("deflate", [1, 2_000]),
                     ("early", [1, 2_000]), ("overlap", [1, 500])]:
    for count in counts:
        for repeat in range(args.repeats):
            try:
                result = subprocess.run([str(binary), mode, str(count)], capture_output=True, text=True,
                                        timeout=args.timeout, check=True)
                print(result.stdout, end="", flush=True)
            except subprocess.TimeoutExpired:
                print(f"{mode} entries={count} TIMEOUT after {args.timeout}s", flush=True)
