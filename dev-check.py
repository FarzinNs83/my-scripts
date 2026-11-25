#!/usr/bin/env python3
"""Run the project's existing checks before a push."""

import argparse
import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


LOCKFILES = {"pnpm": "pnpm-lock.yaml", "yarn": "yarn.lock", "bun": "bun.lock", "npm": "package-lock.json"}


def package_manager(root, manifest):
    declared = manifest.get("packageManager", "")
    if declared:
        manager = declared.partition("@")[0]
        if manager not in LOCKFILES:
            raise ValueError(f"Unsupported package manager: {manager}")
        return manager
    for directory in (root, *root.parents):
        found = [manager for manager, lock in LOCKFILES.items() if (directory / lock).is_file()]
        if (directory / "bun.lockb").is_file() and "bun" not in found:
            found.append("bun")
        if len(found) > 1:
            raise ValueError(f"Multiple lockfile types in {directory}; pass --pm.")
        if found:
            return found[0]
    return "npm"


def project_commands(root, args):
    package = root / "package.json"
    if package.is_file():
        manifest = json.loads(package.read_text(encoding="utf-8-sig"))
        if not isinstance(manifest, dict):
            raise ValueError("package.json must contain an object.")
        scripts = manifest.get("scripts", {})
        if not isinstance(scripts, dict):
            raise ValueError("The scripts field in package.json must contain an object.")
        manager = args.pm or package_manager(root, manifest)
        tests = "test:run" if "test:run" in scripts else "test"
        tasks = ["lint", "typecheck"]
        if not args.skip_tests:
            tasks.append(tests)
        if args.build:
            tasks.append("build")
        return [[manager, "run", task] for task in tasks if task in scripts]

    pubspec = root / "pubspec.yaml"
    if pubspec.is_file():
        if args.pm:
            raise ValueError("--pm only applies to package.json projects.")
        if args.build:
            raise ValueError("Flutter builds need a target. Run flutter build <target> directly.")
        commands = [["dart", "format", "--output=none", "--set-exit-if-changed", "."], ["flutter", "analyze"]]
        if not args.skip_tests and any((root / "test").rglob("*_test.dart")):
            commands.append(["flutter", "test"])
        return commands
    raise ValueError(f"No package.json or pubspec.yaml in {root}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", nargs="?", default=".", type=Path, help="project directory (default: current directory)")
    parser.add_argument("--pm", choices=LOCKFILES, help="override the detected JavaScript package manager")
    parser.add_argument("--skip-tests", action="store_true", help="skip tests, for example when the test script watches files")
    parser.add_argument("--build", action="store_true", help="also run the JavaScript build script")
    parser.add_argument("--dry-run", action="store_true", help="show the commands without running them")
    args = parser.parse_args()
    root = args.project.resolve()
    try:
        commands = project_commands(root, args)
        if not commands:
            raise ValueError("No matching checks are defined in this project.")
        print(f"Project: {root}", flush=True)
        for command in commands:
            print(f"$ {shlex.join(command)}", flush=True)
            if args.dry_run:
                continue
            executable = shutil.which(command[0])
            if executable is None:
                raise ValueError(f"{command[0]} is missing from PATH.")
            result = subprocess.run([executable, *command[1:]], cwd=root, check=False)
            if result.returncode:
                print(f"Check failed: {shlex.join(command)}", file=sys.stderr)
                return 1
    except (OSError, ValueError) as error:
        print(f"dev-check: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
