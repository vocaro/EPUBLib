"""The license text check, over a copy of the repository's layout and real Git checkouts (#699)."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
FOLIATE = SCRIPTS.parent / "Sources/EPUBCore/Licenses/foliate-js/LICENSE"
# Each pinned package's files, as a test repository holds them.
UPSTREAM = {
    "ZIPFoundation": {"LICENSE": "ZIPFoundation MIT\n"},
    "MathMLLayout": {"LICENSE": "MathMLLayout MIT\n", "doc/licenses/SRE-NOTICE.txt": "SRE notice\n",
                     "Sources/Kept.swift": "// not copied\n"},
    "StaticSVG": {"LICENSE": "StaticSVG MIT\n", "THIRD_PARTY_NOTICES.md": "StaticSVG notices\n",
                  "Resvg/dependencies.json": "[]\n",
                  "Resvg/Licenses/resvg-0.48.1/LICENSE-MIT": "resvg MIT\n"},
}
# Where each copy sits in Sources/EPUBCore/Licenses.
COPIES = {
    "ZIPFoundation/LICENSE": ("ZIPFoundation", "LICENSE"),
    "MathMLLayout/LICENSE.txt": ("MathMLLayout", "LICENSE"),
    "MathMLLayout/SRE-NOTICE.txt": ("MathMLLayout", "doc/licenses/SRE-NOTICE.txt"),
    "StaticSVG/LICENSE.txt": ("StaticSVG", "LICENSE"),
    "StaticSVG/THIRD_PARTY_NOTICES.md": ("StaticSVG", "THIRD_PARTY_NOTICES.md"),
    "StaticSVG/dependencies.json": ("StaticSVG", "Resvg/dependencies.json"),
    "StaticSVG/Licenses/resvg-0.48.1/LICENSE-MIT": ("StaticSVG", "Resvg/Licenses/resvg-0.48.1/LICENSE-MIT"),
}
NOTICES = """# Third-party notices

- **ZIPFoundation 0.9.20** — MIT.
- **foliate-js** at `78914aef4466eb960965702401634c2cb348e9b1` — MIT.
- **MathMLLayout 0.3.1** — MIT. It includes **resvg 0.48.1**, which is not a list item.
- **StaticSVG 0.1.1** — MIT.
"""
VERSIONS = {"ZIPFoundation": "0.9.20", "MathMLLayout": "0.3.1", "StaticSVG": "0.1.1"}


class LicenseCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="epublib-licenses-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPTS / "check-licenses.py", self.root / "scripts/check-licenses.py")
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1",
                    "PYTHONDONTWRITEBYTECODE": "1"}
        self.checkouts = self.root / ".build/checkouts"
        self.revisions = {name: self.commit(name, files) for name, files in UPSTREAM.items()}
        self.write("LICENSE", "EPUBLib MIT\n")
        self.write("doc/third-party-notices.md", NOTICES)
        self.pin()
        licenses = self.root / "Sources/EPUBCore/Licenses"
        self.write("Sources/EPUBCore/Licenses/EPUBLib/LICENSE", "EPUBLib MIT\n")
        (licenses / "foliate-js").mkdir()
        shutil.copyfile(FOLIATE, licenses / "foliate-js/LICENSE")
        for copy, (name, source) in COPIES.items():
            self.write(f"Sources/EPUBCore/Licenses/{copy}", UPSTREAM[name][source])
        self.write("Sources/EPUBCore/Licenses/StaticSVG/.DS_Store", "ignored\n")

    def write(self, path, text):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text)

    def git(self, checkout, *arguments):
        return subprocess.run(["git", "-C", str(checkout), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                               *arguments], env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, name, files):
        checkout = self.checkouts / name
        if not checkout.exists():
            checkout.mkdir(parents=True)
            self.git(checkout, "init", "-q")
        for path, text in files.items():
            (checkout / path).parent.mkdir(parents=True, exist_ok=True)
            (checkout / path).write_text(text)
        self.git(checkout, "add", ".")
        self.git(checkout, "commit", "-q", "-m", "files")
        return self.git(checkout, "rev-parse", "HEAD")

    def pin(self):
        pins = [{"identity": name.lower(), "kind": "remoteSourceControl",
                 "location": f"https://github.com/example/{name}.git",
                 "state": {"revision": self.revisions[name], "version": VERSIONS[name]}} for name in UPSTREAM]
        self.write("Package.resolved", json.dumps({"pins": pins, "version": 3}))

    def check(self):
        return subprocess.run([sys.executable, "scripts/check-licenses.py"], cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def assertFails(self, *lines):
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout)
        for line in lines:
            self.assertIn(f"License texts: {line}\n", result.stderr)

    def test_copies_of_the_pinned_files_pass(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified 9 license and notice files of 5 components", result.stdout)

    def test_a_changed_missing_or_unpinned_copy_fails(self):
        licenses = self.root / "Sources/EPUBCore/Licenses"
        (licenses / "StaticSVG/Licenses/resvg-0.48.1/LICENSE-MIT").write_text("resvg MIT, changed\n")
        (licenses / "MathMLLayout/SRE-NOTICE.txt").unlink()
        self.write("Sources/EPUBCore/Licenses/StaticSVG/Licenses/kurbo-0.13.1/LICENSE-MIT", "kurbo\n")
        self.write("Sources/EPUBCore/Licenses/README.md", "about these\n")
        self.write("Sources/EPUBCore/Licenses/Other/LICENSE", "other\n")
        self.assertFails("StaticSVG/Licenses/resvg-0.48.1/LICENSE-MIT: differs from its source",
                         "MathMLLayout/SRE-NOTICE.txt: missing",
                         "StaticSVG/Licenses/kurbo-0.13.1/LICENSE-MIT: copies nothing pinned",
                         "Sources/EPUBCore/Licenses/README.md: outside every component",
                         "Sources/EPUBCore/Licenses/Other: no such component")

    def test_copies_are_read_at_the_pinned_revision(self):
        # A checkout moved past the pin still holds the pinned files.
        self.commit("ZIPFoundation", {"LICENSE": "ZIPFoundation MIT, 2026\n"})
        self.assertEqual(self.check().returncode, 0)
        self.revisions["ZIPFoundation"] = self.git(self.checkouts / "ZIPFoundation", "rev-parse", "HEAD")
        self.pin()
        self.assertFails("ZIPFoundation/LICENSE: differs from its source")
        self.revisions["StaticSVG"] = "0" * 40
        self.pin()
        self.assertFails(f"StaticSVG: no revision {'0' * 40} in {self.checkouts / 'StaticSVG'}: "
                         f"fatal: not a tree object")

    def test_a_notice_file_at_a_packages_top_that_nothing_copies_fails(self):
        # As StaticSVG's THIRD_PARTY_NOTICES.md was before #699's review; a file under a folder
        # whose name says license is code, and is not one.
        self.revisions["ZIPFoundation"] = self.commit("ZIPFoundation", {"NOTICE": "ZIPFoundation notice\n",
                                                                        "Sources/LicenseKit.swift": "// code\n"})
        self.pin()
        self.assertFails(f"ZIPFoundation: NOTICE at {self.revisions['ZIPFoundation']} is a license or notice"
                         " file nothing copies")
        self.assertNotIn("LicenseKit", self.check().stderr)

    def test_the_root_license_and_foliate_license_are_held(self):
        self.write("LICENSE", "EPUBLib MIT, changed\n")
        (self.root / "Sources/EPUBCore/Licenses/foliate-js/LICENSE").write_text("foliate\n")
        self.assertFails("EPUBLib/LICENSE: differs from its source", "foliate-js/LICENSE: differs from its source")

    def test_the_notices_name_each_component_at_its_pin(self):
        self.write("doc/third-party-notices.md", NOTICES.replace("0.9.20", "0.9.19")
                   .replace("- **foliate-js** at", "- foliate-js at") + "- **Readium 2.0** — BSD.\n")
        self.assertFails("doc/third-party-notices.md: ZIPFoundation at 0.9.19, pinned at 0.9.20",
                         "doc/third-party-notices.md: names no foliate-js",
                         "doc/third-party-notices.md: Readium has no folder in Sources/EPUBCore/Licenses")

    def test_a_missing_checkout_or_pin_fails(self):
        shutil.rmtree(self.checkouts / "StaticSVG")
        self.assertFails(f"StaticSVG: no checkout at {self.checkouts / 'StaticSVG'}; run `swift build` first")
        pins = json.loads((self.root / "Package.resolved").read_text())
        pins["pins"] = [pin for pin in pins["pins"] if pin["identity"] != "mathmllayout"]
        self.write("Package.resolved", json.dumps(pins))
        self.assertFails("Package.resolved pins ['staticsvg', 'zipfoundation']; this check copies from "
                         "['mathmllayout', 'staticsvg', 'zipfoundation']")


if __name__ == "__main__":
    unittest.main()
