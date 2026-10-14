#!/usr/bin/env python3
"""Generate #443 fixtures and measure the bundled renderer in separately capped children.

python3 scripts/svg-font-size-probe.py --generate-only --output /private/tmp/svg-font-size-probe
Then run SVGFontSizeCostTests/testGeneratedProbeFixturesMatchScreen with
EPUBLIB_SVG_FONT_SIZE_PROBE_MANIFEST=/private/tmp/svg-font-size-probe/manifest.json.
Finally run this script with --screen-json /private/tmp/svg-font-size-probe/screen-verdicts.json.
--generate-only writes inputs/manifest without building or running anything.
--render-refused also characterizes the original padded drawing (never in the reader).
Actual Swift screen verdicts, matched by name and SHA-256, are required before measuring.
--screen-probe BIN records BIN screen FILE's actual verdict separately from expectations.

The C child applies a CPU rlimit. Its Python parent watches RSS and wall time and kills only
that owned child. A cap hit is recorded as such, never presented as a completed measurement.
The renderer input is the generated standalone SVG. Font lookup/shaping is not measured:
text positioning resolves before font selection, so no host font database is needed here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

MAX_BYTES = 4 * 1024 * 1024
HEAD = "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='200' height='100'>"
SIZE = " " * 62 + "12"
C = r'''
#include "resvg.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
static double cpu(void) {
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_stime.tv_sec + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    rlim_t seconds = (rlim_t)atoi(argv[2]);
    struct rlimit cap = {seconds, seconds + 1};
    if (setrlimit(RLIMIT_CPU, &cap) != 0) return 3;
    FILE *f = fopen(argv[1], "rb"); if (!f) return 4;
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *data = malloc(n); if (!data || fread(data, 1, n, f) != n) return 5; fclose(f);
    resvg_options *options = resvg_options_create(); resvg_render_tree *tree = NULL;
    struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a); double before = cpu();
    int status = resvg_parse_tree_from_data(data, n, options, &tree);
    double parse = cpu() - before; bool rendered = false; before = cpu();
    if (tree) {
        unsigned char pixels[64 * 32 * 4] = {0};
        resvg_transform transform = resvg_transform_identity();
        transform.a = transform.d = 0.32f;
        rendered = resvg_render_checked(tree, transform, 64, 32, pixels);
    }
    double raster = cpu() - before;
    clock_gettime(CLOCK_MONOTONIC, &b); struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    printf("{\"parserStatus\":%d,\"parseCPUSeconds\":%.6f,\"rasterCPUSeconds\":%.6f,"
           "\"wallSeconds\":%.6f,\"peakRSSBytes\":%ld,\"rendered\":%s}\n", status, parse, raster,
           (b.tv_sec-a.tv_sec)+(b.tv_nsec-a.tv_nsec)/1e9, usage.ru_maxrss, rendered ? "true" : "false"); fflush(stdout);
    if (tree) resvg_tree_destroy(tree); resvg_options_destroy(options); free(data); return status;
}
'''


def fixtures():
    def svg(body):
        return HEAD + body + "</svg>"

    def dash(size, count=20_000, unit="em", levels=1):
        return svg((f"<g font-size='{size}'>" * levels) + "<path d='M0 0h50' stroke='black' stroke-dasharray='"
                   + " ".join(["1" + unit] * count) + "'/>" + "</g>" * levels)

    yield "original-padded", dash(" " * 100_000 + "12"), False
    yield "original-plain", dash("12"), True
    yield "font-size-64", dash(SIZE), True
    yield "font-size-65", dash(" " * 63 + "12"), False
    for unit in ("em", "ex"):
        for levels in (1, 62):
            empty = dash(SIZE, count=0, unit=unit, levels=levels)
            count = (MAX_BYTES - len(empty) + 1) // 4
            yield f"dash-{unit}-bytes-limit-depth-{levels}", dash(SIZE, count=count, unit=unit, levels=levels), True
        # convert_list parses every position before it clamps the result to the character count.
        for attribute in ("x", "y", "dx", "dy"):
            prefix = f"<g font-size='{SIZE}'><text {attribute}='"
            suffix = "'>a</text></g>"
            count = (MAX_BYTES - len(svg(prefix + suffix)) + 1) // 4
            yield f"position-{attribute}-{unit}-bytes-limit", svg(prefix + " ".join(["1" + unit] * count) + suffix), True
    for prop in ("stroke-width", "stroke-dashoffset"):
        shape = f"<path d='M0 0h50' stroke='black' {prop}='1em'/>"
        yield f"{prop}-nodes-limit", svg(f"<g font-size='{SIZE}'>" + shape * 9_998 + "</g>"), True
    for name, declaration in (("css-size", "font-size:" + "12." + "0" * 61),
                              ("css-shorthand", "font:italic 500 " + "12." + "0" * 61 + " serif")):
        yield name + "-64", svg(f"<g style='{declaration}'><path d='M0 0h50' stroke='black' stroke-dasharray='1em 1ex'/></g>"), True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--generate-only", action="store_true")
    parser.add_argument("--render-refused", action="store_true")
    parser.add_argument("--screen-probe", type=Path)
    parser.add_argument("--screen-json", type=Path)
    parser.add_argument("--cpu-seconds", type=int, default=20)
    parser.add_argument("--wall-seconds", type=float, default=30)
    parser.add_argument("--memory-mib", type=int, default=512)
    args = parser.parse_args()
    if min(args.cpu_seconds, args.wall_seconds, args.memory_mib) <= 0:
        parser.error("all caps must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    for name, text, accepted in fixtures():
        data = text.encode("ascii")
        assert len(data) <= MAX_BYTES
        path = args.output / (name + ".svg")
        path.write_bytes(data)
        records.append({"name": name, "file": str(path), "inputBytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(), "expectedScreenAccepted": accepted})
    originals = {record["name"]: record for record in records}
    assert originals["original-padded"]["sha256"] == "b26c407e5278800cd9bd9fda13cce9e431f01bf764739bc4b3cb3e0b9847340b"
    assert originals["original-plain"]["sha256"] == "7fdab3dae03cc36be8401cd6d28cef68626cd3aa05b4b456d19c8ff6c89061ee"
    (args.output / "manifest.json").write_text(json.dumps(records, indent=2) + "\n")
    if args.generate_only:
        print(f"Generated {len(records)} fixtures in {args.output}")
        return
    if not args.screen_json and not args.screen_probe:
        parser.error("render measurements require --screen-json or --screen-probe, not expected verdicts")
    screened_records = {}
    if args.screen_json:
        screened_records = {entry["name"]: entry for entry in json.loads(args.screen_json.read_text())}
        for record in records:
            screened = screened_records.get(record["name"])
            if not screened or screened["sha256"] != record["sha256"] or screened["inputBytes"] != record["inputBytes"]:
                parser.error("screen evidence missing or different input: " + record["name"])
    repo = Path(__file__).resolve().parents[1]
    library = repo / "Vendor/Resvg/Resvg.xcframework/macos-arm64_x86_64"
    source, binary = args.output / "probe.c", args.output / "probe"
    source.write_text(C)
    subprocess.run(["xcrun", "clang", "-O2", "-I", str(library / "Headers"), str(source),
                    str(library / "libresvg.a"), "-framework", "CoreFoundation", "-framework", "Security",
                    "-liconv", "-o", str(binary)], check=True)
    results = []
    for record in records:
        result = dict(record)
        result["caps"] = {"cpuSeconds": args.cpu_seconds, "wallSeconds": args.wall_seconds, "memoryMiB": args.memory_mib}
        accepted = False
        if args.screen_json:
            result["screen"] = screened_records[record["name"]]
            accepted = result["screen"]["screenAccepted"]
        elif args.screen_probe:
            screened = subprocess.run([str(args.screen_probe), "screen", record["file"]],
                                      capture_output=True, text=True, timeout=args.wall_seconds)
            result["screenReturncode"] = screened.returncode
            result["screenOutput"] = screened.stdout.strip()
            accepted = screened.returncode == 0 and "|PASSES|" in screened.stdout
        if not accepted and not (args.render_refused and record["name"] == "original-padded"):
            result["measurement"] = "skipped refused input"
        else:
            process = subprocess.Popen([str(binary), record["file"], str(args.cpu_seconds)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            start = time.monotonic()
            stopped = None
            try:
                while process.poll() is None:
                    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True,
                                         text=True, timeout=2).stdout.strip()
                    if rss and int(rss) > args.memory_mib * 1024:
                        stopped = "memory cap"
                    elif time.monotonic() - start > args.wall_seconds:
                        stopped = "wall cap"
                    if stopped:
                        process.kill()
                        break
                    time.sleep(0.02)
                output, error = process.communicate(timeout=2)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
            result.update({"measurement": stopped or ("completed" if process.returncode == 0 else "child failed or CPU cap"),
                           "returncode": process.returncode, "parentWallSeconds": time.monotonic() - start})
            if output.strip():
                result.update(json.loads(output))
            if error.strip():
                result["stderr"] = error.strip()[:1000]
        results.append(result)
        print(json.dumps(result), flush=True)
        (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
