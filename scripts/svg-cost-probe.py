#!/usr/bin/env python3
"""Characterize the vendored SVG parser in capped children, without invoking the reader.

Run from this checkout: python3 scripts/svg-cost-probe.py --output /private/tmp/svg-cost-probe
Each child is terminated at 256 MiB RSS or 10 seconds. No dangerous maximal repro is parsed.
The generated inputs and JSON preserve the experiment; timings are never test assertions.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

C = r'''
#include "resvg.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); if (!f) return 2;
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *data = malloc(n); fread(data, 1, n, f); fclose(f);
    resvg_options *options = resvg_options_create(); resvg_render_tree *tree = NULL;
    struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
    int status = resvg_parse_tree_from_data(data, n, options, &tree);
    clock_gettime(CLOCK_MONOTONIC, &b); struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    printf("{\"status\":%d,\"seconds\":%.6f,\"peakRSSBytes\":%ld}\n", status,
        (b.tv_sec-a.tv_sec)+(b.tv_nsec-a.tv_nsec)/1e9, usage.ru_maxrss); fflush(stdout);
    if (tree) resvg_tree_destroy(tree); resvg_options_destroy(options); free(data); return status;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[1]
    library = repo / "Vendor/Resvg/Resvg.xcframework/macos-arm64_x86_64"
    source = args.output / "probe.c"
    source.write_text(C)
    binary = args.output / "probe"
    subprocess.run(["xcrun", "clang", "-O2", "-I", str(library / "Headers"), str(source),
                    str(library / "libresvg.a"), "-framework", "CoreFoundation", "-framework", "Security",
                    "-liconv", "-o", str(binary)], check=True)
    results = []
    for name, units, property_name in [("mask", "", "mask"), ("mask-shared", "maskUnits='userSpaceOnUse'", "mask"),
                                        ("clip-bbox", "clipPathUnits='objectBoundingBox'", "clip-path"), ("clip-shared", "", "clip-path")]:
        tag = "mask" if name.startswith("mask") else "clipPath"
        for shapes, references in [(100, 1), (100, 100), (1000, 100)]:
            drawing = ("<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><defs>"
                       f"<{tag} id='r' {units}>" + "<rect width='1' height='1'/>" * shapes + f"</{tag}></defs>"
                       + f"<rect width='2' height='2' {property_name}='url(#r)'/>" * references + "</svg>")
            path = args.output / f"{name}-{shapes}-{references}.svg"
            path.write_text(drawing)
            process = subprocess.Popen([str(binary), str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            start = time.monotonic()
            stopped = None
            while process.poll() is None:
                rss = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True, text=True).stdout.strip()
                if (rss and int(rss) > 256 * 1024) or time.monotonic() - start > 10:
                    stopped = "memory cap" if rss and int(rss) > 256 * 1024 else "time cap"
                    process.kill()
                    break
                time.sleep(0.02)
            output, error = process.communicate()
            result = {"name": name, "shapes": shapes, "references": references, "inputBytes": len(drawing.encode()),
                      "verdict": stopped or "completed", "returncode": process.returncode}
            if output.strip(): result.update(json.loads(output))
            if error.strip(): result["stderr"] = error.strip()[:1000]
            results.append(result)
            print(json.dumps(result), flush=True)
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")

if __name__ == "__main__":
    main()
