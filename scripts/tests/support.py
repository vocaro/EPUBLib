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
        configuration = json.loads((SCRIPTS.parent / "engineering.json").read_text())
        configuration["toolkit"]["path"] = str((SCRIPTS.parent / configuration["toolkit"]["path"]).resolve())
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
                              capture_output=True, text=True, timeout=15)

    def module(self, name):
        spec = importlib.util.spec_from_file_location(name.replace("-", "_"), self.scripts / name)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
