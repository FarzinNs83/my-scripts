"""Locating the Flutter/Dart project and reading its pubspec.yaml (without a YAML library)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


class ProjectError(Exception):
    pass


@dataclass
class Project:
    root: Path
    package: str
    dependencies: set[str] = field(default_factory=set)
    dev_dependencies: set[str] = field(default_factory=set)

    @property
    def lib(self) -> Path:
        return self.root / "lib"

    def has_package(self, name: str) -> bool:
        return name in self.dependencies or name in self.dev_dependencies


def find_root(start: Path) -> Path:
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / "pubspec.yaml").is_file():
            return candidate
    raise ProjectError("Not inside a Flutter/Dart project (pubspec.yaml not found).")


def _section_keys(text: str, section: str) -> set[str]:
    keys: set[str] = set()
    inside = False
    indent: int | None = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            inside = line.rstrip() == f"{section}:"
            indent = None
            continue
        if not inside:
            continue
        current = len(line) - len(line.lstrip())
        if indent is None:
            indent = current
        if current == indent:
            m = re.match(r"\s*([A-Za-z0-9_]+)\s*:", line)
            if m:
                keys.add(m.group(1))
    return keys


def load(start: Path) -> Project:
    root = find_root(start)
    text = (root / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^name:\s*['\"]?([A-Za-z0-9_]+)", text, re.M)
    if not m:
        raise ProjectError(f"Could not read the package name from {root / 'pubspec.yaml'}.")
    return Project(
        root=root,
        package=m.group(1),
        dependencies=_section_keys(text, "dependencies"),
        dev_dependencies=_section_keys(text, "dev_dependencies"),
    )
