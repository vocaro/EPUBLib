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


def toolkit_root(root):
    config = json.loads((Path(root) / "engineering.json").read_text())
    location = os.environ.get("VOCARO_ENGINEERING_ROOT") or config.get("toolkit", {}).get("path", "../apple-engineering")
    result = (Path(root) / location).resolve()
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


if __name__ == "__main__":
    # Used by a legacy shell gate, without disabling locking in its test fixtures.
    if len(sys.argv) != 3 or sys.argv[1] != "--verify-exclusive":
        raise SystemExit(2)
    try:
        toolkit_root(project_root(__file__))
        from vocaro_engineering import resources
        token = json.loads(os.environ.get(resources.TOKEN, "{}"))
        expected = Path(str(Path(sys.argv[2]).resolve()) + ".warm-push-guard")
        supplied = Path(token.get("guard", str(expected))).resolve()
        approved = supplied == expected and resources.inherited(exclusive=True)
    except (OSError, ValueError, RuntimeError):
        approved = False
    raise SystemExit(0 if approved else 1)
