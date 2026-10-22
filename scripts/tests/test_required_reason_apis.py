"""The required-reason API check, over object files described to a fake `xcrun`."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
TARGETS = ("EPUBCore", "EPUBReading", "EPUBText", "EPUBWriting", "EPUBViewing")
MACOS, IOS_SIMULATOR = 1, 7
# Beside each object, `<object>.symbols` holds what `nm -u` lists for it and
# `<object>.platform` the platform number of its LC_BUILD_VERSION. Beside a resvg archive,
# `<archive>.error` holds what `nm` says when it cannot read a member.
FAKE_XCRUN = """
import os, sys
if sys.argv[1:7] == ["nm", "--no-llvm-bc", "-arch", "all", "-u", "-A"]:
    path = sys.argv[7]
    if os.path.exists(path + ".error"):
        sys.exit(open(path + ".error").read())
    for symbol in open(path + ".symbols").read().split():
        print(f"(for architecture arm64):{path}:resvg.resvg-cgu.0.rcgu.o: {symbol}")
elif sys.argv[1:4] == ["nm", "-u", "-A"]:
    for path in sys.argv[4:]:
        for symbol in open(path + ".symbols").read().split():
            print(f"{path}: {symbol}")
elif sys.argv[1:3] == ["otool", "-l"]:
    for path in sys.argv[3:]:
        print(f"{path}:\\nLoad command 1\\n      cmd LC_BUILD_VERSION\\n platform {open(path + '.platform').read()}")
else:
    sys.exit(f"unexpected {sys.argv}")
"""


class RequiredReasonAPITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="epublib-required-reason-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPTS / "check-required-reason-apis.py", self.root / "scripts/check-required-reason-apis.py")
        bin = self.root / "bin"
        bin.mkdir()
        (bin / "xcrun").write_text(f"#!{sys.executable}\n{FAKE_XCRUN}")
        (bin / "xcrun").chmod(0o755)
        self.env = {"PATH": str(bin), "HOME": str(self.root), "PYTHONDONTWRITEBYTECODE": "1"}
        # Swift Build's layout for the Mac, and Xcode's for the iOS simulator.
        self.mac = self.root / ".build/out/Intermediates.noindex/EPUBLib.build/Debug"
        self.ios = self.root / ".build/ios-validation/Build/Intermediates.noindex/EPUBLib.build/Debug-iphonesimulator"
        for target in TARGETS:
            self.object(self.mac / f"{target}-t.build/Objects-normal/arm64/Clean.o", MACOS)
            self.object(self.ios / f"{target}-t.build/Objects-normal/arm64/Clean.o", IOS_SIMULATOR)
        self.resvg = self.root / "Vendor/Resvg/Resvg.xcframework"
        for slice in ("ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64"):
            self.archive(slice)

    def archive(self, slice, *symbols):
        path = self.resvg / slice / "libresvg.a"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"")
        Path(f"{path}.symbols").write_text("\n".join(["_CCRandomGenerateBytes", "__Unwind_Resume", *symbols]))
        return path

    def object(self, path, platform, *symbols):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"")
        Path(f"{path}.platform").write_text(str(platform))
        Path(f"{path}.symbols").write_text("\n".join(["_swift_retain", "_$s10Foundation4DateVMa", *symbols]))

    def run_check(self, *roots):
        return subprocess.run([sys.executable, str(self.root / "scripts/check-required-reason-apis.py"), *roots],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=15)

    def test_clean_objects_on_both_platforms_pass(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("10 objects of five targets on iOS and macOS, and the three resvg slices", result.stdout)

    def test_a_listed_api_in_a_resvg_slice_is_named(self):
        self.archive("macos-arm64_x86_64", "_fstat$INODE64")
        self.archive("ios-arm64", "_stat")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("CResvg (macOS) libresvg.a:resvg.resvg-cgu.0.rcgu.o: _fstat$INODE64 (file timestamp)", result.stderr)
        self.assertIn("CResvg (iOS) libresvg.a:resvg.resvg-cgu.0.rcgu.o: _stat (file timestamp)", result.stderr)

    def test_a_resvg_slice_nm_cannot_read_fails(self):
        archive = self.archive("ios-arm64_x86_64-simulator")
        Path(f"{archive}.error").write_text("nm: error: libresvg.a(member.o): Unknown attribute kind (105)")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unread resvg slice: ios-arm64_x86_64-simulator: nm: error:", result.stderr)

    def test_no_vendored_resvg_fails(self):
        shutil.rmtree(self.root / "Vendor")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unread resvg slice: no libresvg.a under", result.stderr)

    def test_swiftpm_build_system_layout_is_found_through_debug(self):
        shutil.rmtree(self.root / ".build/out")
        native = self.root / ".build/arm64-apple-macosx/debug"
        for target in TARGETS:
            self.object(native / f"{target}.build/Clean.swift.o", MACOS)
        (self.root / ".build/debug").symlink_to(native, target_is_directory=True)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_form_of_a_listed_api_is_named_with_its_category(self):
        self.object(self.ios / "EPUBViewing-t.build/Objects-normal/arm64/Canvas.o", IOS_SIMULATOR,
                    "_objc_msgSend$systemUptime", "_mach_absolute_time", "_objc_msgSend$activeInputModes",
                    "_OBJC_CLASS_$_NSUserDefaults", "_NSURLContentModificationDateKey", "_NSFileSystemFreeSize",
                    "_$s10Foundation17URLResourceValuesV23volumeAvailableCapacitySiSgvg")
        self.object(self.mac / "EPUBReading-t.build/Objects-normal/arm64/Archive.o", MACOS, "_stat$INODE64", "_getattrlist")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        for line in ("EPUBViewing (iOS) Canvas.o: _objc_msgSend$systemUptime (system boot time)",
                     "_mach_absolute_time (system boot time)", "_objc_msgSend$activeInputModes (active keyboards)",
                     "_OBJC_CLASS_$_NSUserDefaults (user defaults)", "_NSURLContentModificationDateKey (file timestamp)",
                     "_NSFileSystemFreeSize (disk space)", "volumeAvailableCapacitySiSgvg (disk space)",
                     "EPUBReading (macOS) Archive.o: _stat$INODE64 (file timestamp)",
                     "_getattrlist (file timestamp or disk space)"):
            self.assertIn(line, result.stderr)
        self.assertEqual(result.stderr.count("Required-reason API:"), 9)

    def test_unlisted_neighbours_and_other_targets_pass(self):
        # A message that only shares a prefix, a property of the library's own, and targets
        # outside the five, one of which starts with one's name.
        self.object(self.ios / "EPUBViewing-t.build/Objects-normal/arm64/Canvas.o", IOS_SIMULATOR,
                    "_objc_msgSend$systemUptimeObserver", "_objc_msgSend$processInfo", "_statistics",
                    "_$s10Foundation17URLResourceValuesV11isDirectorySbSgvg",
                    "_$s11EPUBWriting19EPUBPackageMetadataV16modificationDate10Foundation0F0Vvg")
        self.object(self.ios / "EPUBViewingTestSupport-t.build/Objects-normal/arm64/Support.o", IOS_SIMULATOR,
                    "_mach_absolute_time")
        self.object(self.root / ".build/ios-validation/Build/Intermediates.noindex/ZIPFoundation.build/"
                    "Debug-iphonesimulator/ZIPFoundation-t.build/Objects-normal/arm64/FileManager.o",
                    IOS_SIMULATOR, "_lstat")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_target_with_no_objects_on_a_platform_fails(self):
        shutil.rmtree(self.ios / "EPUBText-t.build")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("No compiled objects for EPUBText (iOS)", result.stderr)
        self.assertNotIn("Verified", result.stdout)

    def test_the_platform_is_read_from_the_object_not_its_folder(self):
        # A Mac Catalyst object (platform 6) in an iOS folder does not stand for iOS.
        Path(f"{self.ios}/EPUBCore-t.build/Objects-normal/arm64/Clean.o.platform").write_text("6")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("No compiled objects for EPUBCore (iOS)", result.stderr)

    def test_named_folders_replace_the_default_ones(self):
        result = self.run_check(str(self.mac))
        self.assertEqual(result.returncode, 1)
        self.assertIn("EPUBCore (iOS), EPUBReading (iOS)", result.stderr)


if __name__ == "__main__":
    unittest.main()
