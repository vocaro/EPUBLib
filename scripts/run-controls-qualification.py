#!/usr/bin/env python3
"""Run one scenario of Examples/ControlsQualification on a simulator this caller owns.

    scripts/run-controls-qualification.py --device UDID --name phone-toolbar \\
        --args "-QualificationBook ltr" --steps steps.txt

The probe performs the steps of the file one per line and writes its log, accessibility trees
and screenshots to .build/qualification/runs/NAME. A step `signal=WORDS` hands over to this
script, which runs the simulator command the words name and lets the probe continue:

    signal=content_size accessibility-extra-extra-extra-large    simctl ui content_size
    signal=appearance dark                                        simctl ui appearance
    signal=screens NAME            a screenshot of every integrated display, as NAME-display<id>.png
    signal=hinge ARGUMENTS…        --hinge-script UDID ARGUMENTS…, to fold or turn an iPhone Duo
    signal=simctl ARGUMENTS…       any other simctl subcommand, with DEVICE for the UDID

simctl has no fold command, and `simctl io screenConfig` crash-loops the iPhone Duo simulator's
SpringBoard: never send it there.

Build first, with the Xcode whose simulator runtime the device uses; see
doc/issue-49-51-controls-qualification.md. The device is never created, booted or deleted here.

Every xcodebuild and xcrun call here uses /Applications/Xcode.app, as scripts/test-ios.sh does,
whatever `xcode-select` names; set DEVELOPER_DIR for another Xcode, for the build as well. A
probe built with a different Xcode from the one running it is not run.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
target = parser.add_mutually_exclusive_group(required=True)
target.add_argument("--device", help="UDID of a booted simulator created for this run")
target.add_argument("--mac", action="store_true",
                    help="this Mac instead: the probe then takes its pointer and keyboard, so ask whoever is using it first")
parser.add_argument("--name", required=True)
parser.add_argument("--args", default="", help="launch arguments of the host")
parser.add_argument("--steps", required=True, help="file of probe steps, one per line")
parser.add_argument("--derived-data", default=".build/qualification/derived")
parser.add_argument("--hinge-script", help="a command taking UDID then `<degrees>` or `orientation <name>`")
parser.add_argument("--timeout", type=int, default=900)
options = parser.parse_args()

os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
root = Path(__file__).resolve().parents[1]
out = root / ".build/qualification/runs" / options.name
out.mkdir(parents=True, exist_ok=True)
for stale in out.iterdir():
    shutil.rmtree(stale) if stale.is_dir() else stale.unlink()
(out / "args.txt").write_text("\n".join(shlex.split(options.args)) + "\n")
(out / "steps.txt").write_text(Path(options.steps).read_text())


def output(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout.strip()


def simctl(*arguments):
    result = subprocess.run(["xcrun", "simctl", *arguments], capture_output=True, text=True)
    return (result.stdout + result.stderr).strip()


def integrated_displays():
    ids, name = [], None
    for line in simctl("io", options.device, "enumerate").splitlines():
        line = line.strip()
        if line.startswith("Screen ID:"): name = line.split(":")[1].strip()
        if line == "Screen Type: Integrated" and name: ids.append(name)
    return sorted(ids)


def handle(words):
    # The probe names its signal file with underscores for spaces: rejoin the two-word options.
    if words[:2] in (["content", "size"], ["increase", "contrast"]):
        words = ["_".join(words[:2])] + words[2:]
    command, rest = words[0], words[1:]
    if command in ("content_size", "appearance", "increase_contrast"):
        return simctl("ui", options.device, command, *rest)
    if command == "screens":
        for display in integrated_displays():
            simctl("io", options.device, "screenshot", f"--display={display}", str(out / f"{rest[0]}-display{display}.png"))
        return "captured " + ", ".join(integrated_displays())
    if command == "hinge" and options.hinge_script:
        result = subprocess.run([options.hinge_script, options.device, *rest], capture_output=True, text=True)
        time.sleep(1.5)
        return (result.stdout + result.stderr).strip() or "posted"
    if command == "simctl":
        return simctl(*[options.device if word == "DEVICE" else word for word in rest])
    return "UNKNOWN SIGNAL"


xcode = output("xcodebuild", "-version").replace("\n", " ")
meta = [
    "revision " + output("git", "-C", str(root), "rev-parse", "HEAD"),
    "tree " + ("clean" if not output("git", "-C", str(root), "status", "--porcelain", "--", "Sources") else "Sources modified"),
    "macOS " + output("sw_vers", "-productVersion") + " " + output("sw_vers", "-buildVersion"),
    xcode + " at " + os.environ["DEVELOPER_DIR"],
]
if options.mac:
    scheme, destination = "ControlsProbeMac", "platform=macOS"
    meta.append("device this Mac, " + output("sysctl", "-n", "hw.model"))
else:
    scheme, destination = "ControlsProbeIOS", f"platform=iOS Simulator,id={options.device}"
    meta += [
        "device " + next((line.strip() for line in simctl("list", "devices").splitlines() if options.device in line), "unknown"),
        "runtime " + output("xcrun", "simctl", "getenv", options.device, "SIMULATOR_RUNTIME_VERSION")
        + " " + output("xcrun", "simctl", "getenv", options.device, "SIMULATOR_RUNTIME_BUILD_VERSION"),
        "model " + output("xcrun", "simctl", "getenv", options.device, "SIMULATOR_MODEL_IDENTIFIER"),
    ]
# The probe's test bundle names the Xcode that built it. test-without-building runs another
# Xcode's build without a word, and meta.txt would then name an Xcode the probe was not built with.
bundle = next((root / options.derived_data / "Build/Products").glob(f"*/{scheme}-Runner.app/**/{scheme}.xctest"), None)
plist = next((path for path in (bundle / "Info.plist", bundle / "Contents/Info.plist") if path.exists()), None) if bundle else None
built = plistlib.loads(plist.read_bytes()).get("DTXcodeBuild") if plist else None
meta.append("probe built with Xcode " + (built or "unknown"))
(out / "meta.txt").write_text("\n".join(meta + ["args " + options.args]) + "\n")
if built and built not in xcode.split():
    raise SystemExit(f"NOT RUN: the probe in {options.derived_data} was built with Xcode {built} and this run would use "
                     f"{xcode}.\nSet DEVELOPER_DIR to one Xcode for the build and the run.")

environment = dict(os.environ, TEST_RUNNER_QUALIFICATION_OUT=str(out))
with open(out / "xcodebuild.log", "w") as log:
    run = subprocess.Popen(
        ["xcodebuild", "-project", str(root / "Examples/ControlsQualification/ControlsQualification.xcodeproj"),
         "-scheme", scheme, "-destination", destination,
         "-derivedDataPath", str(root / options.derived_data), "-parallel-testing-enabled", "NO",
         # A step XCTest counts as a failure would otherwise end in minutes of `simctl diagnose`.
         "-collect-test-diagnostics", "never",
         f"-only-testing:{scheme}/ControlsProbe/testOperate", "-resultBundlePath", str(out / "result.xcresult"),
         "test-without-building"],
        stdout=log, stderr=subprocess.STDOUT, env=environment)
    deadline = time.time() + options.timeout
    while run.poll() is None:
        for signal in out.glob("signal-*"):
            words = signal.name[len("signal-"):].split("_")
            reply = handle(words)
            with open(out / "log.txt", "a") as record:
                record.write(f"        host {' '.join(words)}: {reply}\n")
            signal.unlink()
            (out / ("ack-" + signal.name[len("signal-"):])).touch()
        if time.time() > deadline:
            run.terminate()
            print("TIMED OUT")
        time.sleep(0.1)
for marker in out.glob("ack-*"):
    marker.unlink()
if options.mac:
    # The Mac's test runner cannot write here: take its log and trees from xcodebuild's output
    # and its screenshots from the result bundle.
    trees, lines = {}, []
    for line in (out / "xcodebuild.log").read_text(errors="replace").splitlines():
        if line.startswith("QUALIFICATION-TREE "):
            name, _, text = line[len("QUALIFICATION-TREE "):].partition(" | ")
            trees.setdefault(name, []).append(text)
        elif line.startswith("QUALIFICATION "):
            lines.append(line[len("QUALIFICATION "):])
    (out / "log.txt").write_text("\n".join(lines) + "\n")
    for name, text in trees.items():
        (out / f"{name}.tree.txt").write_text("\n".join(text) + "\n")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(out / "result.xcresult"),
                    "--output-path", str(out / "attachments")], capture_output=True)
print((out / "log.txt").read_text() if (out / "log.txt").exists() else "NO LOG; see " + str(out / "xcodebuild.log"))
print(f"xcodebuild exit {run.returncode}; records in {out}")
