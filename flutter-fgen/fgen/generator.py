"""Turns the template catalog + options into a list of files to write."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

from .engine import Template
from .naming import Names, lower_first
from .project import Project

BUILTIN_TEMPLATES = Path(__file__).parent / "templates"
NAME_TOKEN = "NAME"
TEMPLATE_SUFFIX = ".tmpl"

RESULT_MODES = {
    "future": "Plain Future<T>, errors are thrown",
    "either": "Either<Failure, T> from fpdart",
    "result": "Own sealed Result<T> (Ok / Err), no extra package",
}
MODEL_MODES = {
    "freezed": "freezed + json_serializable (needs build_runner)",
    "plain": "Hand-written classes, no code generation",
}


class GeneratorError(Exception):
    pass


# --------------------------------------------------------------------------- catalog
@dataclass
class Variant:
    """An architecture or a state-management option, described by its meta.json."""

    id: str
    meta: dict[str, Any]

    @property
    def label(self) -> str:
        return self.meta.get("label", self.id)

    @property
    def order(self) -> int:
        return int(self.meta.get("order", 100))


@dataclass
class Catalog:
    files: dict[str, Path]  # posix relative path -> source file (highest-priority root wins)
    roots: list[Path]
    archs: dict[str, Variant] = field(default_factory=dict)
    states: dict[str, Variant] = field(default_factory=dict)

    @classmethod
    def load(cls, extra_roots: list[Path] | None = None) -> "Catalog":
        roots = [BUILTIN_TEMPLATES, *(r for r in (extra_roots or []) if r.is_dir())]
        files: dict[str, Path] = {}
        for root in roots:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    files[path.relative_to(root).as_posix()] = path
        catalog = cls(files=files, roots=roots)
        for kind, target in (("arch", catalog.archs), ("state", catalog.states)):
            for rel, path in files.items():
                parts = rel.split("/")
                if len(parts) == 3 and parts[0] == kind and parts[2] == "meta.json":
                    try:
                        meta = json.loads(path.read_text(encoding="utf-8"))
                    except json.JSONDecodeError as e:
                        raise GeneratorError(f"{path}: invalid JSON ({e})") from e
                    target[parts[1]] = Variant(parts[1], meta)
        return catalog

    def sorted_archs(self) -> list[Variant]:
        return sorted(self.archs.values(), key=lambda v: (v.order, v.id))

    def sorted_states(self) -> list[Variant]:
        return sorted(self.states.values(), key=lambda v: (v.order, v.id))

    def under(self, prefix: str) -> dict[str, Path]:
        """Template files below `prefix/`, keyed by their path relative to it (meta.json excluded)."""
        prefix = prefix.rstrip("/") + "/"
        return {
            rel[len(prefix):]: path
            for rel, path in self.files.items()
            if rel.startswith(prefix) and rel != prefix + "meta.json"
        }


# --------------------------------------------------------------------------- options
@dataclass
class Options:
    arch: str = "clean"
    state: str = "riverpod"
    result: str = "future"
    model: str = "freezed"
    features_dir: str = "lib/features"
    only: set[str] = field(default_factory=set)
    skip: set[str] = field(default_factory=set)
    core: bool = True
    force: bool = False

    def validate(self, catalog: Catalog) -> None:
        if self.arch not in catalog.archs:
            raise GeneratorError(f"unknown architecture '{self.arch}' (available: {', '.join(catalog.archs)})")
        if self.state not in catalog.states:
            raise GeneratorError(f"unknown state management '{self.state}' (available: {', '.join(catalog.states)})")
        if self.result not in RESULT_MODES:
            raise GeneratorError(f"unknown result mode '{self.result}' (available: {', '.join(RESULT_MODES)})")
        if self.model not in MODEL_MODES:
            raise GeneratorError(f"unknown model mode '{self.model}' (available: {', '.join(MODEL_MODES)})")
        parts = PurePosixPath(self.features_dir.replace("\\", "/")).parts
        if not parts or parts[0] != "lib" or ".." in parts:
            raise GeneratorError("--dir must be inside lib/ (e.g. lib/features)")

    def effective_result(self, catalog: Catalog) -> str:
        """Architectures without a data layer have nothing to wrap, so they always use plain futures."""
        return self.result if catalog.archs[self.arch].meta.get("uses_result", True) else "future"

    def conditions(self, catalog: Catalog) -> set[str]:
        return {self.arch, self.state, self.effective_result(catalog), self.model}


# --------------------------------------------------------------------------- context
@dataclass
class Dep:
    """What the presentation controller depends on (a use case, a repository, ... or nothing)."""

    type: str
    var: str
    uri: str
    call_template: str

    @property
    def provider(self) -> str:
        return lower_first(self.type) + "Provider"

    def call(self, target: str | None = None) -> str:
        return self.call_template.replace("$v", target or "_" + self.var)


def _indent(code: str, spaces: int) -> list[str]:
    pad = " " * spaces
    return [pad + line if line else line for line in code.split("\n")]


def build_context(project: Project, names: Names, opts: Options, catalog: Catalog) -> dict[str, Any]:
    n = names.as_dict()

    def fmt(value: str) -> str:
        return value.format_map(n)

    arch = catalog.archs[opts.arch].meta
    state = catalog.states[opts.state].meta
    result = opts.effective_result(catalog)
    features_rel = "/".join(PurePosixPath(opts.features_dir.replace("\\", "/")).parts[1:])
    fimport = f"package:{project.package}/{features_rel}/{names.snake}" if features_rel else f"package:{project.package}/{names.snake}"
    core = f"package:{project.package}/core"

    item = fmt(arch["item"])
    dep = None
    if arch.get("dep"):
        d = arch["dep"]
        dep = Dep(type=fmt(d["type"]), var=fmt(d["var"]), uri=f"{fimport}/{fmt(d['path'])}", call_template=fmt(d["call"]))

    def wrap(t: str) -> str:
        return {"future": t, "either": f"Either<Failure, {t}>", "result": f"Result<{t}>"}[result]

    def ok(expr: str) -> str:
        return {"future": expr, "either": f"Right({expr})", "result": f"Ok({expr})"}[result]

    def err(expr: str) -> str:
        return {"future": f"throw {expr}", "either": f"Left({expr})", "result": f"Err({expr})"}[result]

    result_imports = {
        "future": "",
        "either": f"import 'package:fpdart/fpdart.dart';\nimport '{core}/error/failure.dart';",
        "result": f"import '{core}/error/result.dart';",
    }[result]

    def handle(on_success: str, on_error: str, target: str | None = None) -> str:
        """Await the dependency and branch on success / failure.

        `on_success` can use `data`; `on_error` can use `message`. `{pascal}`-style
        placeholders are filled in.
        """
        if dep is None:
            raise GeneratorError("handle() used in a template, but this architecture has no dependency")
        call = dep.call(target)
        success, error = fmt(on_success), fmt(on_error)
        if result == "future":
            lines = ["try {", f"  final data = await {call};", *_indent(success, 2),
                     "} catch (e) {", "  final message = e.toString();", *_indent(error, 2), "}"]
        elif result == "either":
            lines = [f"switch (await {call}) {{", "  case Left(value: Failure(:final message)):", *_indent(error, 4),
                     "  case Right(value: final data):", *_indent(success, 4), "}"]
        else:
            lines = [f"switch (await {call}) {{", "  case Ok(value: final data):", *_indent(success, 4),
                     "  case Err(failure: Failure(:final message)):", *_indent(error, 4), "}"]
        return "\n".join(lines)

    def fetch_return(target: str | None = None) -> str:
        """`return ...;` that yields the data or throws the failure (for Riverpod's build())."""
        if dep is None:
            raise GeneratorError("fetch_return() used in a template, but this architecture has no dependency")
        call = dep.call(target)
        if result == "future":
            return f"return {call};"
        if result == "either":
            return "\n".join([f"return switch (await {call}) {{", "  Left(value: final Failure failure) => throw failure,",
                              "  Right(value: final data) => data,", "};"])
        return "\n".join([f"return switch (await {call}) {{", "  Ok(value: final data) => data,",
                          "  Err(:final failure) => throw failure,", "};"])

    return {
        **n,
        "names": names,
        "pkg": project.package,
        "fimport": fimport,
        "core": core,
        "arch": opts.arch,
        "state": opts.state,
        "init": False,  # True while rendering for 'fgen init'
        "riverpod": opts.state in ("riverpod", "riverpod_classic"),
        "result": result,
        "model": opts.model,
        "freezed": opts.model == "freezed",
        "item": item,
        "item_import": f"{fimport}/{fmt(arch['item_path'])}",
        "list_type": f"List<{item}>",
        "ret": wrap(f"List<{item}>"),
        "dep": dep,
        "controller": fmt(state["controller"]),
        "controller_import": f"{fimport}/{fmt(state['controller_path'])}",
        "result_imports": result_imports,
        "wrap": wrap,
        "ok": ok,
        "err": err,
        "handle": handle,
        "fetch_return": fetch_return,
    }


# --------------------------------------------------------------------------- planning
@dataclass
class PlannedFile:
    path: Path          # absolute output path
    rel: str            # path relative to the project root (posix)
    content: str
    layer: str
    action: str         # create | overwrite | update | skip
    core: bool = False
    newline: str = "\n"  # line ending used when writing (kept for edited files)


def _resolve_path(rel: str, conditions: set[str], snake: str) -> str | None:
    """Apply `@a,b` (include if any matches) / `@!a,b` (exclude if any matches) segments."""
    out = []
    for segment in rel.split("/"):
        if segment.startswith("@!"):
            if conditions & set(segment[2:].split(",")):
                return None
        elif segment.startswith("@"):
            if not conditions & set(segment[1:].split(",")):
                return None
        elif segment.startswith("dot_"):  # dot_gitkeep -> .gitkeep (keeps packaging happy)
            out.append("." + segment[4:])
        else:
            out.append(segment)
    path = "/".join(out).replace(NAME_TOKEN, snake)
    if path.endswith(TEMPLATE_SUFFIX):
        path = path[: -len(TEMPLATE_SUFFIX)]
    return path


def _tidy(text: str) -> str:
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip("\n") + "\n"


def _render_file(source: Path, context: dict[str, Any]) -> str | None:
    """Returns None when a non-empty template renders to nothing (= file not wanted)."""
    raw = source.read_text(encoding="utf-8").replace("\r\n", "\n")
    if not raw.strip():
        return ""
    text = Template(raw, str(source)).render(context)
    return _tidy(text) if text.strip() else None


def plan_feature(catalog: Catalog, project: Project, names: Names, opts: Options) -> list[PlannedFile]:
    context = build_context(project, names, opts, catalog)
    conditions = opts.conditions(catalog)
    feature_dir = opts.features_dir.replace("\\", "/").rstrip("/") + "/" + names.snake

    # Later sources override earlier ones for the same output path.
    sources: dict[str, tuple[Path, bool]] = {}
    for prefix, is_core in (("common", False), (f"arch/{opts.arch}", False), (f"state/{opts.state}", False), ("core", True)):
        for rel, path in catalog.under(prefix).items():
            out = _resolve_path(rel, conditions, names.snake)
            if out is None:
                continue
            target = f"lib/core/{out}" if is_core else f"{feature_dir}/{out}"
            sources[target] = (path, is_core)

    planned: list[PlannedFile] = []
    for rel, (source, is_core) in sources.items():
        if is_core and not opts.core:
            continue
        layer = "core" if is_core else (rel[len(feature_dir) + 1:].split("/")[0] if "/" in rel[len(feature_dir) + 1:] else "di")
        if opts.only and layer not in opts.only:
            continue
        if layer in opts.skip:
            continue
        content = _render_file(source, context)
        if content is None:
            continue
        path = project.root / rel
        if not path.exists():
            action = "create"
        elif opts.force and not is_core:
            action = "overwrite"
        else:
            action = "skip"
        planned.append(PlannedFile(path=path, rel=rel, content=content, layer=layer, action=action, core=is_core))

    planned.sort(key=lambda f: (f.core, f.rel))
    return planned


def available_layers(catalog: Catalog, project: Project, opts: Options) -> list[str]:
    probe = Options(**{**opts.__dict__, "only": set(), "skip": set(), "force": False})
    layers: list[str] = []
    for f in plan_feature(catalog, project, Names("sample"), probe):
        if f.layer not in layers:
            layers.append(f.layer)
    return layers


def write(files: list[PlannedFile]) -> None:
    for f in files:
        if f.action == "skip":
            continue
        f.path.parent.mkdir(parents=True, exist_ok=True)
        with open(f.path, "w", encoding="utf-8", newline=f.newline) as handle:
            handle.write(f.content)


# --------------------------------------------------------------------------- packages
_IMPORT = re.compile(r"""^import\s+['"]package:([A-Za-z0-9_]+)/""", re.M)
_PART = re.compile(r"""^part\s+['"]([^'"]+)['"]""", re.M)


def required_packages(files: list[PlannedFile], project: Project) -> tuple[list[str], list[str], bool]:
    """(missing dependencies, missing dev dependencies, needs build_runner) for the files being written."""
    deps: set[str] = set()
    dev: set[str] = set()
    for f in files:
        if f.action == "skip" or not f.rel.endswith(".dart"):
            continue
        imports = set(_IMPORT.findall(f.content))
        deps |= imports
        parts = _PART.findall(f.content)
        if any(p.endswith(".freezed.dart") for p in parts):
            dev |= {"freezed", "build_runner"}
        if any(p.endswith(".g.dart") for p in parts):
            dev.add("build_runner")
            if "riverpod_annotation" in imports:
                dev.add("riverpod_generator")
            if "fromJson" in f.content and imports & {"freezed_annotation", "json_annotation"}:
                deps.add("json_annotation")
                dev.add("json_serializable")
    deps -= {project.package, "flutter", "flutter_test", "flutter_localizations"}
    needs_build = "build_runner" in dev
    return (
        sorted(d for d in deps if not project.has_package(d)),
        sorted(d for d in dev if not project.has_package(d)),
        needs_build,
    )


def template_roots(project_root: Path | None, extra: str | None) -> list[Path]:
    """Lowest priority first: $FGEN_TEMPLATES, --templates, <project>/.fgen/templates."""
    roots: list[Path] = []
    env = os.environ.get("FGEN_TEMPLATES")
    if env:
        roots.append(Path(env).expanduser())
    if extra:
        roots.append(Path(extra).expanduser())
    if project_root:
        roots.append(project_root / ".fgen" / "templates")
    return roots
