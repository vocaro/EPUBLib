"""Isolated copies of the runner scripts, with no host commands on PATH."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from _engineering import toolkit_location

# How long a script copy with fake tools may run: they take about a second, so this only bounds
# a hang, and a gate on a busy host does not reach it (doc/testing.md, "Local gate").
HANG_SECONDS = 120


def engineering_configuration():
    """This checkout's engineering.json, naming the toolkit its own adapters find (#701).

    The copies run from a temporary folder with an environment of their own, so neither
    VOCARO_ENGINEERING_ROOT nor the main checkout of a worktree reaches them: they are given
    the toolkit's absolute path.
    """
    configuration = json.loads((SCRIPTS.parent / "engineering.json").read_text())
    configuration["toolkit"]["path"] = str(toolkit_location(SCRIPTS.parent))
    return configuration


class ScriptTestCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="epublib-script-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        for name in ("hosted-run.py", "run-voiceover-sessions.py", "run-voiceover-mac.py"):
            shutil.copyfile(SCRIPTS / name, self.scripts / name)
        shutil.copyfile(SCRIPTS / "_engineering.py", self.scripts / "_engineering.py")
        configuration = engineering_configuration()
        configuration["hostedRepositories"] = [configuration["repository"]]
        (self.root / "engineering.json").write_text(json.dumps(configuration))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Do not inherit workflow inputs, GitHub credentials or the real gh/git/open tools.
        self.env = {"PATH": str(self.bin), "HOME": str(self.root), "PYTHONDONTWRITEBYTECODE": "1"}

    def tool(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)

    def run_script(self, name, *arguments, **environment):
        return subprocess.run([sys.executable, str(self.scripts / name), *arguments],
                              cwd=self.root, env=dict(self.env, **environment),
                              capture_output=True, text=True, timeout=HANG_SECONDS)

    def module(self, name):
        spec = importlib.util.spec_from_file_location(name.replace("-", "_"), self.scripts / name)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
