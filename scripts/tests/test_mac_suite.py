"""scripts/test-mac.sh, the Mac suite, against a fake `swift`; nothing is built or tested."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from support import HANG_SECONDS

SCRIPT = Path(__file__).resolve().parents[1] / "test-mac.sh"
# Records its arguments and prints what `swift test` would for the outcome the test asks for.
FAKE_SWIFT = """
import json, os, sys
with open(os.environ["FAKE_SWIFT_ARGUMENTS"], "w") as record:
    json.dump(sys.argv[1:], record)
print("Test Suite 'All tests' started at 2026-10-23 00:00:00.000.")
if os.environ.get("FAKE_SWIFT_UNMEASURED"):
    for test in ("testA", "testB"):
        print(f"/tmp/Tests/X.swift:9: -[EPUBViewingTests.XTests {test}] : Test skipped - Unmeasured: the 80 s backstop passed")
print("Test Suite 'All tests' passed at 2026-10-23 00:00:01.000.")
print("\\t Executed 3 tests, with 2 tests skipped and 0 failures (0 unexpected) in 0.001 (0.001) seconds")
sys.exit(int(os.environ.get("FAKE_SWIFT_EXIT", "0")))
"""


class MacSuiteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="epublib-mac-suite-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/test-mac.sh")
        tools = self.root / "bin"
        tools.mkdir()
        (tools / "swift").write_text(f"#!{sys.executable}\n" + FAKE_SWIFT)
        (tools / "swift").chmod(0o755)
        self.arguments = self.root / "arguments.json"
        self.env = {"PATH": f"{tools}{os.pathsep}/usr/bin:/bin", "HOME": str(self.root),
                    "FAKE_SWIFT_ARGUMENTS": str(self.arguments)}

    def run_suite(self, *arguments, **environment):
        return subprocess.run(["bash", "scripts/test-mac.sh", *arguments], cwd=self.root,
                              env=dict(self.env, **environment), capture_output=True, text=True,
                              timeout=HANG_SECONDS)

    def test_arguments_reach_swift_test_with_a_bounded_build_and_the_log_is_kept(self):
        result = self.run_suite("--filter", "NativeSessionTests")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.arguments.read_text()), ["test", "--jobs", "4", "--filter", "NativeSessionTests"])
        self.assertIn("Executed 3 tests", (self.root / ".build/validation/mac.log").read_text())
        self.assertNotIn("Unmeasured", result.stdout)
        self.run_suite(EPUB_BUILD_JOBS="2")
        self.assertEqual(json.loads(self.arguments.read_text())[:3], ["test", "--jobs", "2"])

    def test_a_test_the_host_decided_leaves_the_run_unmeasured_not_passed(self):
        result = self.run_suite(FAKE_SWIFT_UNMEASURED="1")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("Unmeasured: macOS: 2 tests a busy host decided; see .build/validation/mac.log", result.stdout)
        self.assertIn("XTests testB] : Test skipped - Unmeasured: the 80 s backstop passed", result.stdout.splitlines()[-1])

    def test_a_failure_keeps_its_status_whatever_else_was_unmeasured(self):
        result = self.run_suite(FAKE_SWIFT_UNMEASURED="1", FAKE_SWIFT_EXIT="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertNotIn("Unmeasured: macOS", result.stdout)

    def test_build_workers_must_be_a_positive_number(self):
        for value in ["0", "-1", "four"]:
            result = self.run_suite(EPUB_BUILD_JOBS=value)
            self.assertEqual(result.returncode, 2, value)
            self.assertIn("EPUB_BUILD_JOBS must be a positive number", result.stderr)
            self.assertFalse(self.arguments.exists(), "nothing ran")


if __name__ == "__main__":
    unittest.main()
