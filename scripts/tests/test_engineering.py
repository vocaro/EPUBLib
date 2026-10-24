"""The adapters find the shared toolkit from a session's worktree, beside the main checkout (#701)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from support import HANG_SECONDS

SCRIPTS = Path(__file__).resolve().parents[1]
# Stand-ins for the toolkit's command line and for the source hosted-run.py loads from it. Each
# says which toolkit it was found in.
CLI = "from pathlib import Path\ndef main(argv):\n    print(Path(__file__).parents[3], *argv)\n    return 0\n"
HOSTED_RUN = "print(__eng_toolkit_root__)\n"


class ToolkitLocationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="epublib-toolkit-location-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.main = self.base / "EPUBLib"
        (self.main / "scripts").mkdir(parents=True)
        for name in ("eng", "_engineering.py", "hosted-run.py"):
            shutil.copyfile(SCRIPTS / name, self.main / "scripts" / name)
        shutil.copyfile(SCRIPTS.parent / "engineering.json", self.main / "engineering.json")
        # No inherited VOCARO_ENGINEERING_ROOT, Git configuration or GIT_DIR from a hook.
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.base), "PYTHONDONTWRITEBYTECODE": "1"}
        self.git(self.main, "init", "-q")
        self.git(self.main, "add", "scripts", "engineering.json")
        self.git(self.main, "-c", "user.name=Toolkit Test", "-c", "user.email=toolkit@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "initial")
        self.worktree = self.main / ".claude/worktrees/session"
        self.git(self.main, "worktree", "add", "-q", "--detach", str(self.worktree))

    def git(self, directory, *args):
        subprocess.run(["git", "-C", str(directory), *args], env=self.env, check=True, timeout=HANG_SECONDS)

    def toolkit(self, path):
        package = path / "src/python/vocaro_engineering"
        (package / "voiceover").mkdir(parents=True)
        (package / "__init__.py").touch()
        (package / "cli.py").write_text(CLI)
        (package / "voiceover/hosted_run.py").write_text(HOSTED_RUN)
        return path

    def run_script(self, checkout, *arguments, **environment):
        return subprocess.run([sys.executable, str(checkout / "scripts" / arguments[0]), *arguments[1:]],
                              cwd=checkout, env=dict(self.env, **environment),
                              capture_output=True, text=True, timeout=HANG_SECONDS)

    def assert_finds(self, checkout, toolkit, **environment):
        engineering = self.run_script(checkout, "eng", "instructions", **environment)
        self.assertEqual((engineering.returncode, engineering.stderr), (0, ""))
        self.assertEqual(engineering.stdout.split(), [str(toolkit), "--project", str(checkout), "instructions"])
        adapter = self.run_script(checkout, "hosted-run.py", **environment)
        self.assertEqual((adapter.returncode, adapter.stderr), (0, ""))
        self.assertEqual(adapter.stdout.strip(), str(toolkit))

    def test_main_checkout_finds_the_toolkit_beside_it(self):
        self.assert_finds(self.main, self.toolkit(self.base / "apple-engineering"))

    def test_worktree_finds_the_toolkit_beside_the_main_checkout(self):
        toolkit = self.toolkit(self.base / "apple-engineering")
        # Git 2.48 and later can record a worktree's paths relative to each other.
        relative = self.main / ".claude/worktrees/relative"
        self.git(self.main, "-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", "--detach", str(relative))
        for checkout in (self.worktree, relative):
            with self.subTest(checkout=checkout.name):
                if checkout == relative and Path((relative / ".git").read_text().removeprefix("gitdir:").strip()).is_absolute():
                    self.skipTest("this Git records a worktree's paths in full")
                self.assert_finds(checkout, toolkit)

    def test_toolkit_beside_the_worktree_comes_first(self):
        self.toolkit(self.base / "apple-engineering")
        elsewhere = self.base / "elsewhere/EPUBLib"
        self.git(self.main, "worktree", "add", "-q", "--detach", str(elsewhere))
        self.assert_finds(elsewhere, self.toolkit(self.base / "elsewhere/apple-engineering"))

    def test_variable_names_another_toolkit(self):
        self.toolkit(self.base / "apple-engineering")
        other = self.toolkit(self.base / "other")
        for checkout in (self.main, self.worktree):
            with self.subTest(checkout=checkout.name):
                self.assert_finds(checkout, other, VOCARO_ENGINEERING_ROOT=str(other))

    def test_missing_toolkit_is_named_beside_the_main_checkout(self):
        expected = self.base / "apple-engineering"
        engineering = self.run_script(self.worktree, "eng", "instructions")
        self.assertEqual(engineering.returncode, 2)
        self.assertIn(f"Shared toolkit missing at {expected}.", engineering.stderr)
        adapter = self.run_script(self.worktree, "hosted-run.py")
        self.assertNotEqual(adapter.returncode, 0)
        self.assertIn(f"Shared engineering checkout missing: {expected};", adapter.stderr)


if __name__ == "__main__":
    unittest.main()
