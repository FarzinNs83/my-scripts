"""The React project on disk: package.json, .rgen/config.json, planned file changes and npm commands."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_FILE = ".rgen/config.json"


class ProjectError(Exception):
    pass


@dataclass
class Project:
    root: Path
    package: dict = field(default_factory=dict)
    config: dict = field(default_factory=dict)

    @property
    def exists(self) -> bool:
        return (self.root / "package.json").is_file()

    def has_dep(self, name: str) -> bool:
        return any(name in (self.package.get(k) or {}) for k in ("dependencies", "devDependencies"))

    @property
    def pm(self) -> str:
        """Package manager: from config, then lock files, then npm."""
        if self.config.get("pm"):
            return self.config["pm"]
        for lock, pm in (("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun")):
            if (self.root / lock).is_file():
                return pm
        return "npm"

    def save_config(self, values: dict) -> None:
        self.config = {**self.config, **values}
        path = self.root / CONFIG_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.config, indent=2) + "\n", encoding="utf-8")

    def reload(self) -> None:
        fresh = load(self.root)
        self.package, self.config = fresh.package, {**fresh.config, **self.config}

    # ------------------------------------------------------------------ commands
    def install_cmd(self, packages: list[str], dev: bool = False) -> list[str]:
        pm = self.pm
        verb = "install" if pm == "npm" else "add"
        flag = {"npm": "-D", "pnpm": "-D", "yarn": "-D", "bun": "-d"}[pm] if dev else None
        return [pm, verb, *([flag] if flag else []), *packages]

    def dlx_cmd(self, *args: str) -> list[str]:
        prefix = {"npm": ["npx", "--yes"], "pnpm": ["pnpm", "dlx"], "yarn": ["yarn", "dlx"], "bun": ["bunx"]}[self.pm]
        return [*prefix, *args]

    def run(self, cmd: list[str], dry_run: bool = False) -> None:
        print(f"  $ {' '.join(cmd)}", flush=True)
        if dry_run:
            return
        exe = shutil.which(cmd[0])  # resolves npm.cmd / npx.cmd on Windows
        if exe is None:
            raise ProjectError(f"'{cmd[0]}' not found on PATH")
        result = subprocess.run([exe, *cmd[1:]], cwd=self.root)
        if result.returncode != 0:
            raise ProjectError(f"command failed ({result.returncode}): {' '.join(cmd)}")


    def format(self, rels: list[str]) -> None:
        """Run the project's prettier on generated code, so it matches 'npm run format' (skipped when not installed)."""
        exe = shutil.which("prettier", path=str(self.root / "node_modules" / ".bin"))
        files = [r for r in rels if r.endswith((".ts", ".tsx")) and (self.root / r).is_file()]
        if exe and files:
            subprocess.run([exe, "--write", "--log-level", "silent", *files], cwd=self.root)


def find_root(start: Path) -> Path | None:
    current = start.resolve()
    for candidate in (current, *current.parents):
        if (candidate / "package.json").is_file():
            return candidate
    return None


def load(start: Path) -> Project:
    root = find_root(start)
    if root is None:
        return Project(root=start.resolve())
    try:
        package = json.loads((root / "package.json").read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as e:
        raise ProjectError(f"{root / 'package.json'}: invalid JSON ({e})") from e
    config: dict = {}
    path = root / CONFIG_FILE
    if path.is_file():
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            raise ProjectError(f"{path}: invalid JSON ({e})") from e
    return Project(root=root, package=package, config=config if isinstance(config, dict) else {})


# --------------------------------------------------------------------------- changes
@dataclass
class Planned:
    rel: str
    content: str
    action: str  # create | overwrite | update | skip
    newline: str = "\n"


class Changes:
    """New files plus edits to existing ones, keyed by project-relative path.

    Edits made after a file was planned apply to the planned content, so one run can
    create the router and register a route in it.
    """

    def __init__(self, project: Project, force: bool = False):
        self.project = project
        self.force = force
        self.files: dict[str, Planned] = {}
        self.messages: list[str] = []

    def add(self, rel: str, content: str) -> Planned:
        if rel in self.files:
            return self.files[rel]
        path = self.project.root / rel
        action = "create" if not path.exists() else ("overwrite" if self.force else "skip")
        f = Planned(rel, content, action)
        self.files[rel] = f
        return f

    def read(self, rel: str) -> str | None:
        f = self.files.get(rel)
        if f is not None and f.action != "skip":
            return f.content
        path = self.project.root / rel
        if not path.is_file():
            return None
        return path.read_bytes().decode("utf-8").replace("\r\n", "\n")

    def exists(self, rel: str) -> bool:
        return self.read(rel) is not None

    def edit(self, rel: str, text: str) -> None:
        f = self.files.get(rel)
        if f is not None and f.action != "skip":
            f.content = text
            return
        path = self.project.root / rel
        newline = "\r\n" if b"\r\n" in path.read_bytes() else "\n"
        self.files[rel] = Planned(rel, text, "update", newline)

    def note(self, message: str) -> None:
        if message and message not in self.messages:
            self.messages.append(message)

    def write(self) -> None:
        for f in self.files.values():
            if f.action == "skip":
                continue
            path = self.project.root / f.rel
            path.parent.mkdir(parents=True, exist_ok=True)
            content = f.content.replace("\n", f.newline) if f.newline != "\n" else f.content
            path.write_bytes(content.encode("utf-8"))


def insert_at_marker(text: str, marker: str, line: str) -> str | None:
    """Put `line` above the `// rgen:<marker>` comment, with the comment's indentation.

    Returns the text unchanged when the line is already there, and None when the marker is missing.
    """
    m = re.search(rf"^([ \t]*)(?://|#|\{{/\*) rgen:{marker}\b.*$", text, re.M)
    if not m:
        return None
    if any(existing.strip() == line.strip() for existing in text.split("\n")):
        return text
    return text[: m.start()] + m.group(1) + line + "\n" + text[m.start():]
