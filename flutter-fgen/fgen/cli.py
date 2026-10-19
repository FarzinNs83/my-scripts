"""Command line interface: argument parsing, the interactive wizard and the post-generation steps."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__
from .engine import TemplateError
from .generator import (
    BUILTIN_TEMPLATES,
    MODEL_MODES,
    RESULT_MODES,
    Catalog,
    GeneratorError,
    Options,
    PlannedFile,
    available_layers,
    plan_feature,
    required_packages,
    template_roots,
    write,
)
from .naming import parse_name, split_names
from .project import Project, ProjectError
from .project import load as load_project


# --------------------------------------------------------------------------- output
class _Style:
    def __init__(self) -> None:
        enabled = sys.stdout.isatty() and "NO_COLOR" not in os.environ
        if enabled and os.name == "nt":
            os.system("")  # enables ANSI escape handling in the Windows console
        self.enabled = enabled

    def _wrap(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.enabled else text

    def bold(self, t: str) -> str: return self._wrap("1", t)
    def dim(self, t: str) -> str: return self._wrap("2", t)
    def green(self, t: str) -> str: return self._wrap("32", t)
    def yellow(self, t: str) -> str: return self._wrap("33", t)
    def red(self, t: str) -> str: return self._wrap("31", t)
    def cyan(self, t: str) -> str: return self._wrap("36", t)


style = _Style()


def _fail(message: str, code: int = 1) -> int:
    print(style.red(f"error: {message}"), file=sys.stderr)
    return code


# --------------------------------------------------------------------------- prompts
class _Abort(Exception):
    pass


def _input(prompt: str) -> str:
    try:
        return input(prompt)
    except (EOFError, KeyboardInterrupt):
        print()
        raise _Abort from None


def ask(question: str, default: str = "") -> str:
    hint = f" {style.dim('[' + default + ']')}" if default else ""
    while True:
        answer = _input(f"{style.cyan('?')} {style.bold(question)}{hint}: ").strip()
        if answer or default:
            return answer or default


def confirm(question: str, default: bool = True) -> bool:
    hint = "Y/n" if default else "y/N"
    while True:
        answer = _input(f"{style.cyan('?')} {style.bold(question)} {style.dim('[' + hint + ']')}: ").strip().lower()
        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False


def choose(question: str, options: list[tuple[str, str]], default: str) -> str:
    print(f"{style.cyan('?')} {style.bold(question)}")
    ids = [o[0] for o in options]
    width = max(len(i) for i in ids)
    for index, (oid, label) in enumerate(options, 1):
        marker = style.green(">") if oid == default else " "
        print(f"  {marker} {index}) {oid.ljust(width)}  {style.dim(label)}")
    default_index = ids.index(default) + 1 if default in ids else 1
    while True:
        answer = _input(f"  {style.dim('choose [' + str(default_index) + ']')}: ").strip()
        if not answer:
            return ids[default_index - 1]
        if answer.isdigit() and 1 <= int(answer) <= len(ids):
            return ids[int(answer) - 1]
        if answer in ids:
            return answer


def choose_many(question: str, options: list[str]) -> list[str]:
    print(f"{style.cyan('?')} {style.bold(question)} {style.dim('(comma separated, Enter = all)')}")
    for index, option in enumerate(options, 1):
        print(f"    {index}) {option}")
    while True:
        answer = _input(f"  {style.dim('choose [all]')}: ").strip()
        if not answer:
            return list(options)
        picked: list[str] = []
        valid = True
        for piece in answer.replace(" ", ",").split(","):
            if not piece:
                continue
            if piece.isdigit() and 1 <= int(piece) <= len(options):
                piece = options[int(piece) - 1]
            if piece not in options:
                valid = False
                break
            if piece not in picked:
                picked.append(piece)
        if valid and picked:
            return picked


# --------------------------------------------------------------------------- arguments
def _csv(value: str | None) -> set[str]:
    return {v.strip() for v in (value or "").split(",") if v.strip()}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fgen",
        description="Generate feature-first Flutter code for different architectures and state managers.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "commands:\n"
            "  fgen list                 show architectures, state managers and layers\n"
            "  fgen eject [--to DIR]     copy the built-in templates for customisation\n"
            "\n"
            "examples:\n"
            "  fgen                                  interactive mode\n"
            "  fgen auth                             clean + riverpod (defaults)\n"
            "  fgen auth,profile -a mvvm -s bloc     two features, MVVM + Bloc\n"
            "  fgen cart -r either -m plain          Either<Failure, T>, no freezed\n"
            "  fgen cart --only domain,data          only some layers\n"
            "  fgen cart --dry-run                   show what would be written\n"
        ),
    )
    p.add_argument("features", nargs="*", help="feature name(s): 'auth', 'auth,profile' or 'auth profile'")
    p.add_argument("-a", "--arch", help="architecture (default: clean)")
    p.add_argument("-s", "--state", help="state management (default: riverpod)")
    p.add_argument("-r", "--result", choices=list(RESULT_MODES), help="error handling style (default: future)")
    p.add_argument("-m", "--model", choices=list(MODEL_MODES), help="model style (default: freezed)")
    p.add_argument("--only", help="generate only these layers (comma separated, see 'fgen list')")
    p.add_argument("--skip", help="skip these layers (comma separated)")
    p.add_argument("-d", "--dir", default="lib/features", help="features directory (default: lib/features)")
    p.add_argument("--no-core", action="store_true", help="don't create shared files under lib/core")
    p.add_argument("-n", "--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("-f", "--force", action="store_true", help="overwrite existing feature files (core files are never overwritten)")
    p.add_argument("-i", "--interactive", action="store_true", help="ask for every option")
    p.add_argument("--pub", action="store_true", help="run 'flutter pub add' for missing packages")
    p.add_argument("--build", action="store_true", help="run build_runner afterwards when code generation is needed")
    p.add_argument("--no-format", action="store_true", help="don't run 'dart format' on the generated files")
    p.add_argument("--templates", help="extra templates directory (overrides built-in files with the same path)")
    p.add_argument("-C", "--project", help="run as if started in this directory")
    p.add_argument("-V", "--version", action="version", version=f"fgen {__version__}")
    return p


# --------------------------------------------------------------------------- commands
def cmd_list(project: Project | None, extra_templates: str | None) -> int:
    catalog = Catalog.load(template_roots(project.root if project else None, extra_templates))
    print(style.bold("Architectures (-a)"))
    for v in catalog.sorted_archs():
        print(f"  {v.id.ljust(18)} {style.dim(v.label)}")
    print(style.bold("\nState management (-s)"))
    for v in catalog.sorted_states():
        print(f"  {v.id.ljust(18)} {style.dim(v.label)}")
    print(style.bold("\nError handling (-r)"))
    for k, label in RESULT_MODES.items():
        print(f"  {k.ljust(18)} {style.dim(label)}")
    print(style.bold("\nModels (-m)"))
    for k, label in MODEL_MODES.items():
        print(f"  {k.ljust(18)} {style.dim(label)}")
    print(style.bold("\nLayers (--only / --skip)"))
    if project:
        for v in catalog.sorted_archs():
            layers = available_layers(catalog, project, Options(arch=v.id, state=catalog.sorted_states()[0].id))
            print(f"  {v.id.ljust(18)} {', '.join(layers)}")
    else:
        print(style.dim("  (run inside a Flutter project to see the layers of each architecture)"))
    print(style.bold("\nTemplate sources") + style.dim(" (later ones override earlier ones)"))
    for root in catalog.roots:
        print(f"  {root}")
    return 0


def cmd_eject(args: list[str], project: Project | None) -> int:
    p = argparse.ArgumentParser(prog="fgen eject", description="Copy the built-in templates so you can edit them.")
    p.add_argument("--to", help="target directory (default: <project>/.fgen/templates)")
    p.add_argument("-f", "--force", action="store_true", help="overwrite files that already exist there")
    ns = p.parse_args(args)
    if ns.to:
        target = Path(ns.to)
    elif project:
        target = project.root / ".fgen" / "templates"
    else:
        return _fail("not inside a Flutter project; pass --to DIR")
    copied = skipped = 0
    for source in BUILTIN_TEMPLATES.rglob("*"):
        if not source.is_file():
            continue
        dest = target / source.relative_to(BUILTIN_TEMPLATES)
        if dest.exists() and not ns.force:
            skipped += 1
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
        copied += 1
    print(style.green(f"Copied {copied} template files to {target}") + (style.dim(f" ({skipped} already existed)") if skipped else ""))
    if project and target.resolve() == (project.root / ".fgen" / "templates").resolve():
        print(style.dim("fgen picks these up automatically in this project. Delete the files you don't change."))
    else:
        print(style.dim(f"Use them with --templates {target} or set FGEN_TEMPLATES={target}"))
    return 0


# --------------------------------------------------------------------------- generate
def _wizard(ns: argparse.Namespace, catalog: Catalog, project: Project) -> tuple[list[str], Options]:
    print(style.bold(f"fgen {__version__}") + style.dim(f"  project: {project.package} ({project.root})\n"))

    features = split_names(ns.features) if ns.features else []
    while not features:
        features = split_names([ask("Feature name(s), comma separated")])
        for f in features:
            try:
                parse_name(f)
            except ValueError as e:
                print(style.red(f"  {e}"))
                features = []
                break

    opts = Options(features_dir=ns.dir, core=not ns.no_core, force=ns.force)
    opts.arch = choose("Architecture", [(v.id, v.label) for v in catalog.sorted_archs()], ns.arch or "clean")
    opts.state = choose("State management", [(v.id, v.label) for v in catalog.sorted_states()], ns.state or "riverpod")
    if catalog.archs[opts.arch].meta.get("uses_result", True):
        opts.result = choose("Error handling", list(RESULT_MODES.items()), ns.result or "future")
    opts.model = choose("Models", list(MODEL_MODES.items()), ns.model or "freezed")

    layers = available_layers(catalog, project, opts)
    picked = choose_many("Layers to generate", layers)
    if len(picked) != len(layers):
        opts.only = set(picked)
    return features, opts


def _plan_all(catalog: Catalog, project: Project, features: list[str], opts: Options) -> list[PlannedFile]:
    files: list[PlannedFile] = []
    seen: set[str] = set()
    for raw in features:
        names = parse_name(raw)
        for f in plan_feature(catalog, project, names, opts):
            if f.rel not in seen:  # shared core files appear once
                seen.add(f.rel)
                files.append(f)
    return files


def _print_plan(files: list[PlannedFile]) -> None:
    marks = {"create": style.green("+ create   "), "overwrite": style.yellow("~ overwrite"), "skip": style.dim("= exists   ")}
    for f in files:
        print(f"  {marks[f.action]} {f.rel if f.action != 'skip' else style.dim(f.rel)}")


def _run(command: list[str], cwd: Path) -> bool:
    exe = shutil.which(command[0])
    if not exe:
        print(style.yellow(f"'{command[0]}' was not found on PATH; skipping: {' '.join(command)}"))
        return False
    print(style.dim(f"$ {' '.join(command)}"))
    return subprocess.run([exe, *command[1:]], cwd=cwd).returncode == 0


def cmd_generate(ns: argparse.Namespace, project: Project) -> int:
    catalog = Catalog.load(template_roots(project.root, ns.templates))
    interactive = ns.interactive or not ns.features

    if interactive:
        features, opts = _wizard(ns, catalog, project)
    else:
        features = split_names(ns.features)
        opts = Options(
            arch=ns.arch or "clean",
            state=ns.state or "riverpod",
            result=ns.result or "future",
            model=ns.model or "freezed",
            features_dir=ns.dir,
            only=_csv(ns.only),
            skip=_csv(ns.skip),
            core=not ns.no_core,
            force=ns.force,
        )
    opts.validate(catalog)

    known_layers = set(available_layers(catalog, project, opts))
    unknown = (opts.only | opts.skip) - known_layers
    if unknown:
        return _fail(f"unknown layer(s): {', '.join(sorted(unknown))} (available: {', '.join(sorted(known_layers))})")

    files = _plan_all(catalog, project, features, opts)
    existing = [f for f in files if f.action == "skip" and not f.core]
    if interactive and existing and not opts.force:
        print(style.yellow(f"\n{len(existing)} feature file(s) already exist."))
        if confirm("Overwrite them?", default=False):
            opts.force = True
            files = _plan_all(catalog, project, features, opts)

    print(style.bold(f"\n{opts.arch} + {opts.state} · result: {opts.effective_result(catalog)} · models: {opts.model}"))
    _print_plan(files)
    to_write = [f for f in files if f.action != "skip"]
    missing_deps, missing_dev, needs_build = required_packages(files, project)

    if ns.dry_run:
        print(style.dim("\n(dry run: nothing was written)"))
        _print_packages(missing_deps, missing_dev)
        return 0
    if not to_write:
        print(style.yellow("\nNothing to write. Use --force to overwrite existing feature files."))
        return 0
    if interactive and not confirm(f"Write {len(to_write)} file(s)?"):
        print("Cancelled.")
        return 0

    write(to_write)
    print(style.green(f"\nWrote {len(to_write)} file(s)."))

    dart_files = [str(f.path) for f in to_write if f.rel.endswith(".dart")]
    if dart_files and not ns.no_format and shutil.which("dart"):
        subprocess.run([shutil.which("dart"), "format", "--output=write", *dart_files], cwd=project.root,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if missing_deps or missing_dev:
        _print_packages(missing_deps, missing_dev)
        if ns.pub or (interactive and confirm("Add them now with 'flutter pub add'?")):
            _run(["flutter", "pub", "add", *missing_deps, *(f"dev:{d}" for d in missing_dev)], project.root)

    if needs_build:
        if ns.build or (interactive and confirm("Run build_runner now?")):
            _run(["dart", "run", "build_runner", "build"], project.root)
        else:
            print(style.dim("\nCode generation needed:  dart run build_runner build"))

    notes: list[str] = []
    for raw in features:
        n = parse_name(raw).as_dict()
        for note in catalog.states[opts.state].meta.get("notes", []) + catalog.archs[opts.arch].meta.get("notes", []):
            text = note.format_map(n)
            if text not in notes:
                notes.append(text)
    if notes:
        print(style.bold("\nNext steps"))
        for note in notes:
            print(f"  - {note}")
    return 0


def _print_packages(deps: list[str], dev: list[str]) -> None:
    if not deps and not dev:
        return
    print(style.bold("\nMissing packages"))
    print("  flutter pub add " + " ".join([*deps, *(f"dev:{d}" for d in dev)]))


# --------------------------------------------------------------------------- entry
def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass

    argv = list(sys.argv[1:] if argv is None else argv)

    # -C/--project and --templates also apply to the sub-commands
    start = Path.cwd()
    for flag in ("-C", "--project"):
        if flag in argv[:-1]:
            start = Path(argv[argv.index(flag) + 1])
    extra_templates = argv[argv.index("--templates") + 1] if "--templates" in argv[:-1] else None

    try:
        project: Project | None = load_project(start)
    except ProjectError:
        project = None

    try:
        if argv and argv[0] == "list":
            return cmd_list(project, extra_templates)
        if argv and argv[0] == "eject":
            rest = argv[1:]
            for flag in ("-C", "--project", "--templates"):
                while flag in rest:
                    i = rest.index(flag)
                    del rest[i:i + 2]
            return cmd_eject(rest, project)

        ns = build_parser().parse_args(argv)
        if project is None:
            return _fail("not inside a Flutter/Dart project (pubspec.yaml not found)", 2)
        return cmd_generate(ns, project)
    except _Abort:
        return 130
    except (GeneratorError, TemplateError, ValueError) as e:
        return _fail(str(e))
