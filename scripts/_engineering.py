"""Locate one maintained toolkit implementation for a small project adapter."""
import json
import os
from pathlib import Path
import sys


def project_root(source):
    for parent in Path(source).resolve().parents:
        if (parent / "engineering.json").is_file():
            return parent
    raise RuntimeError("No engineering.json above the project adapter")


def main_checkout(root):
    """The main checkout of the repository that root is a linked worktree of, or None.

    A linked worktree's .git is a file naming its directory inside the repository's .git, whose
    commondir file leads back to that .git: the parent of `git rev-parse --git-common-dir`.
    It is read without running Git, which script tests may replace with fake commands on PATH.
    """
    try:
        line = (Path(root) / ".git").read_text().strip()
    except OSError:  # the main checkout's .git is a directory
        return None
    if not line.startswith("gitdir:"):
        return None
    private = Path(root) / line.removeprefix("gitdir:").strip()
    try:
        common = private / (private / "commondir").read_text().strip()
    except OSError:  # a submodule's .git file names a repository of its own
        return None
    return common.resolve().parent


def toolkit_location(root):
    """VOCARO_ENGINEERING_ROOT, else toolkit.path beside this checkout or, from a linked
    worktree such as a session's under .claude/worktrees, beside the main checkout."""
    override = os.environ.get("VOCARO_ENGINEERING_ROOT")
    if override:
        return (Path(root) / override).resolve()
    config = json.loads((Path(root) / "engineering.json").read_text())
    location = config.get("toolkit", {}).get("path", "../apple-engineering")
    candidates = [(base / location).resolve() for base in (Path(root), main_checkout(root)) if base is not None]
    return next((path for path in candidates if (path / "src/python/vocaro_engineering").is_dir()), candidates[-1])


def toolkit_root(root):
    result = toolkit_location(root)
    if not (result / "src/python/vocaro_engineering").is_dir():
        raise RuntimeError(f"Shared engineering checkout missing: {result}; provision vocaro/apple-engineering or set VOCARO_ENGINEERING_ROOT")
    sys.path.insert(0, str(result / "src/python"))
    return result


def load(namespace, relative):
    """Retain the adapter's namespace so existing script import/mocking contracts still work.

    The source has one maintained owner. __file__ remains the project entry point for its
    fixture paths; source support files are addressed explicitly through support_path.
    """
    root = project_root(namespace["__file__"])
    kit = toolkit_root(root)
    source = (kit / relative).resolve()
    if not source.is_relative_to(kit):
        raise ValueError("Shared source escapes toolkit")
    namespace["__eng_project_config__"] = json.loads((root / "engineering.json").read_text())
    namespace["__eng_toolkit_root__"] = kit
    exec(compile(source.read_bytes(), str(source), "exec"), namespace)


def support_path(name):
    kit = toolkit_root(project_root(__file__))
    candidates = {
        "voiceover-ax-observer.swift": "src/swift/VoiceOver/voiceover-ax-observer.swift",
        "voiceover-link-verbosity.swift": "src/swift/VoiceOver/voiceover-link-verbosity.swift",
        "probe-simulator-voiceover-activation.m": "src/objc/VoiceOver/probe-simulator-voiceover-activation.m",
    }
    return kit / candidates[name]


def verify_admission(lock):
    """Whether this process inherits a live admission, heavy or exclusive, in lock's namespace.

    A gate fixture with its own lock file must not reuse the suite's admission that tests it.
    """
    try:
        toolkit_root(project_root(__file__))
        from vocaro_engineering import resources
        token = json.loads(os.environ.get(resources.TOKEN, "{}"))
        expected = Path(str(Path(lock).resolve()) + ".warm-push-guard")
        supplied = Path(token.get("guard", str(expected))).resolve()
        return supplied == expected and resources.inherited()
    except (OSError, ValueError, RuntimeError):
        return False


def admit(timeout, command):
    """Run command as one job of the host's heavy-work queue, without `eng admit`'s policy fetch."""
    toolkit_root(project_root(__file__))
    from vocaro_engineering import resources
    try:
        return resources.main(["--timeout", timeout, "--", *command])
    except (TimeoutError, RuntimeError) as error:
        print(f"gate admission: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    # Used by scripts/gate-lock.sh, without disabling locking in its test fixtures.
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-admission":
        raise SystemExit(0 if verify_admission(sys.argv[2]) else 1)
    if len(sys.argv) > 4 and sys.argv[1] == "--admit" and sys.argv[3] == "--":
        raise SystemExit(admit(sys.argv[2], sys.argv[4:]))
    raise SystemExit(2)
