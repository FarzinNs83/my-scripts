"""Command line interface: argument parsing, the interactive wizard and the post-generation steps."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath

from . import __version__
from . import assets as assets_mod
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
from .jsonmodel import ModelError
from .jsonmodel import generate as generate_model
from .naming import Names, parse_name, split_names, to_snake
from .project import Project, ProjectError
from .project import load as load_project
from .scaffold import Changes, PageOptions, default_router, plan_init, plan_page, plan_widget, wire_features


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
            "  fgen init                 set up lib/core (network, theme, router, env) and the app shell\n"
            "  fgen page <name>          add a screen and register its route\n"
            "  fgen widget <name>        add a widget (lib/core/widgets or --in FEATURE)\n"
            "  fgen model <Name>         Dart model classes from a JSON sample\n"
            "  fgen assets               constants for the files under assets/ + pubspec entries\n"
            "  fgen list                 show architectures, state managers and layers\n"
            "  fgen eject [--to DIR]     copy the built-in templates for customisation\n"
            "  (run 'fgen <command> --help' for its options; 'fgen -- page' makes a feature named 'page')\n"
            "\n"
            "examples:\n"
            "  fgen                                  interactive mode\n"
            "  fgen auth                             clean + riverpod (or the 'fgen init' choices)\n"
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
    p.add_argument("-d", "--dir", help="features directory (default: lib/features)")
    p.add_argument("--no-core", action="store_true", help="don't create shared files under lib/core")
    p.add_argument("--no-route", action="store_true", help="don't register the screens in the router made by 'fgen init'")
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
    marks = {
        "create": style.green("+ create   "),
        "overwrite": style.yellow("~ overwrite"),
        "update": style.cyan("~ update   "),
        "skip": style.dim("= exists   "),
    }
    for f in files:
        print(f"  {marks[f.action]} {f.rel if f.action != 'skip' else style.dim(f.rel)}")


def _print_messages(messages: list[str]) -> None:
    for message in messages:
        print(style.dim(f"  · {message}"))


def _run(command: list[str], cwd: Path) -> bool:
    exe = shutil.which(command[0])
    if not exe:
        print(style.yellow(f"'{command[0]}' was not found on PATH; skipping: {' '.join(command)}"))
        return False
    print(style.dim(f"$ {' '.join(command)}"))
    return subprocess.run([exe, *command[1:]], cwd=cwd).returncode == 0


def _write_and_finish(project: Project, files: list[PlannedFile], ns: argparse.Namespace, interactive: bool) -> bool:
    """Write the files, format them, then offer 'flutter pub add' and build_runner. False when nothing was written."""
    to_write = [f for f in files if f.action != "skip"]
    missing_deps, missing_dev, needs_build = required_packages(files, project)

    if ns.dry_run:
        print(style.dim("\n(dry run: nothing was written)"))
        _print_packages(missing_deps, missing_dev)
        return False
    if not to_write:
        print(style.yellow("\nNothing to write. Use --force to overwrite existing files."))
        return False
    if interactive and not confirm(f"Write {len(to_write)} file(s)?"):
        print("Cancelled.")
        return False

    write(to_write)
    print(style.green(f"\nWrote {len(to_write)} file(s)."))

    dart_files = [str(f.path) for f in to_write if f.rel.endswith(".dart")]
    if dart_files and not getattr(ns, "no_format", False) and shutil.which("dart"):
        subprocess.run([shutil.which("dart"), "format", "--output=write", *dart_files], cwd=project.root,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if missing_deps or missing_dev:
        _print_packages(missing_deps, missing_dev)
        if getattr(ns, "pub", False) or (interactive and confirm("Add them now with 'flutter pub add'?")):
            _run(["flutter", "pub", "add", *missing_deps, *(f"dev:{d}" for d in missing_dev)], project.root)

    if needs_build:
        if getattr(ns, "build", False) or (interactive and confirm("Run build_runner now?")):
            _run(["dart", "run", "build_runner", "build", "--delete-conflicting-outputs"], project.root)
        else:
            print(style.dim("\nCode generation needed:  dart run build_runner build"))
    return True


def _apply_config(ns: argparse.Namespace, project: Project) -> None:
    """Options not given on the command line fall back to the choices saved by 'fgen init'."""
    cfg = project.config
    for key in ("arch", "state", "result", "model"):
        if getattr(ns, key, None) is None and cfg.get(key):
            setattr(ns, key, cfg[key])
    if getattr(ns, "dir", None) is None:
        ns.dir = cfg.get("features_dir") or "lib/features"


def cmd_generate(ns: argparse.Namespace, project: Project) -> int:
    catalog = Catalog.load(template_roots(project.root, ns.templates))
    interactive = ns.interactive or not ns.features
    _apply_config(ns, project)

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

    changes = Changes(project)
    for f in files:
        changes.add(f)
    wired = wire_features(changes, [parse_name(raw) for raw in features], opts.features_dir, route=not ns.no_route)

    print(style.bold(f"\n{opts.arch} + {opts.state} · result: {opts.effective_result(catalog)} · models: {opts.model}"))
    _print_plan(changes.all())
    _print_messages(wired)
    if not _write_and_finish(project, changes.all(), ns, interactive):
        return 0

    notes: list[str] = []
    # main() / routing notes are only needed when 'fgen init' markers did not take care of it
    sources = catalog.archs[opts.arch].meta.get("notes", [])
    if not wired:
        sources = catalog.states[opts.state].meta.get("notes", []) + sources
    for raw in features:
        n = parse_name(raw).as_dict()
        for note in sources:
            text = note.format_map(n)
            if text not in notes:
                notes.append(text)
    if notes:
        print(style.bold("\nNext steps"))
        for note in notes:
            print(f"  - {note}")
    return 0


# --------------------------------------------------------------------------- init
def cmd_init(args: list[str], project: Project) -> int:
    p = argparse.ArgumentParser(
        prog="fgen init",
        description="Set up lib/core (Dio client, errors, env, theme, router), lib/app.dart, lib/main.dart and a home screen. "
                    "The choices are saved to .fgen/config.json and become the defaults for later commands.",
    )
    p.add_argument("-a", "--arch", help="architecture (default: clean)")
    p.add_argument("-s", "--state", help="state management (default: riverpod)")
    p.add_argument("-r", "--result", choices=list(RESULT_MODES), help="error handling style (default: future)")
    p.add_argument("-m", "--model", choices=list(MODEL_MODES), help="model style (default: freezed)")
    p.add_argument("-d", "--dir", help="features directory (default: lib/features)")
    p.add_argument("--no-router", action="store_true", help="no go_router / GetX routes; app.dart opens the home screen directly")
    p.add_argument("-f", "--force", action="store_true", help="overwrite app.dart, main.dart, theme and router files; routes added since are lost (lib/core shared files are kept)")
    p.add_argument("-n", "--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("-y", "--yes", action="store_true", help="don't ask anything; use the defaults")
    p.add_argument("--pub", action="store_true", help="run 'flutter pub add' for missing packages")
    p.add_argument("--build", action="store_true", help="run build_runner afterwards when code generation is needed")
    p.add_argument("--no-format", action="store_true", help="don't run 'dart format' on the generated files")
    p.add_argument("--templates", help=argparse.SUPPRESS)
    ns = p.parse_args(args)

    catalog = Catalog.load(template_roots(project.root, ns.templates))
    given = any(getattr(ns, k) for k in ("arch", "state", "result", "model"))
    interactive = not ns.yes and not given and sys.stdin.isatty()
    _apply_config(ns, project)

    opts = Options(arch=ns.arch or "clean", state=ns.state or "riverpod", result=ns.result or "future",
                   model=ns.model or "freezed", features_dir=ns.dir, force=ns.force)
    if interactive:
        print(style.bold(f"fgen {__version__} init") + style.dim(f"  project: {project.package} ({project.root})\n"))
        opts.arch = choose("Architecture", [(v.id, v.label) for v in catalog.sorted_archs()], opts.arch)
        opts.state = choose("State management", [(v.id, v.label) for v in catalog.sorted_states()], opts.state)
        if catalog.archs[opts.arch].meta.get("uses_result", True):
            opts.result = choose("Error handling", list(RESULT_MODES.items()), opts.result)
        opts.model = choose("Models", list(MODEL_MODES.items()), opts.model)
        if not ns.no_router:
            ns.no_router = not confirm("Set up routing (" + ("GetX pages" if opts.state == "getx" else "go_router") + ")?")
    opts.validate(catalog)
    router = default_router(opts.state, ns.no_router)

    changes, messages = plan_init(catalog, project, opts, router, ns.force)
    print(style.bold(f"\ninit: {opts.arch} + {opts.state} · result: {opts.effective_result(catalog)} · "
                     f"models: {opts.model} · router: {router}"))
    _print_plan(changes.all())
    _print_messages(messages)
    if not _write_and_finish(project, changes.all(), ns, interactive):
        return 0

    project.save_config({"arch": opts.arch, "state": opts.state, "result": opts.result, "model": opts.model,
                         "router": router, "features_dir": opts.features_dir})
    print(style.dim(f"Saved your choices to {project.config_path.relative_to(project.root).as_posix()}"))
    print(style.bold("\nNext steps"))
    print("  - set BASE_URL in env/dev.json, env/staging.json and env/prod.json")
    print("  - run with:  flutter run --dart-define-from-file=env/dev.json")
    print("  - add features with 'fgen <name>' and screens with 'fgen page <name>'; they are routed automatically")
    return 0


# --------------------------------------------------------------------------- page / widget
def _names(raw: list[str], what: str) -> list[Names]:
    names = [parse_name(n) for n in split_names(raw)]
    if not names:
        raise ValueError(f"give at least one {what} name")
    return names


def cmd_page(args: list[str], project: Project) -> int:
    p = argparse.ArgumentParser(prog="fgen page", description="Add screen(s) and register them in the router made by 'fgen init'.")
    p.add_argument("names", nargs="+", help="page name(s): 'settings', 'about,contact'")
    p.add_argument("--in", dest="feature", help="feature folder to put the screen in (default: a folder named after the page)")
    p.add_argument("--stateful", action="store_true", help="StatefulWidget (or ConsumerStatefulWidget with Riverpod)")
    p.add_argument("--path", help="route path (default: /<page-name>); only with a single page")
    p.add_argument("--route-name", help="AppRoutes constant (default: the page name in camelCase); only with a single page")
    p.add_argument("--no-route", action="store_true", help="only create the screen")
    p.add_argument("-d", "--dir", help="features directory (default: lib/features)")
    p.add_argument("-f", "--force", action="store_true", help="overwrite existing screens")
    p.add_argument("-n", "--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("--no-format", action="store_true", help="don't run 'dart format' on the generated files")
    p.add_argument("--templates", help=argparse.SUPPRESS)
    ns = p.parse_args(args)
    _apply_config(ns, project)

    pages = _names(ns.names, "page")
    if len(pages) > 1 and (ns.path or ns.route_name):
        return _fail("--path and --route-name work with a single page")
    catalog = Catalog.load(template_roots(project.root, ns.templates))
    changes = Changes(project)
    messages: list[str] = []
    for page in pages:
        opts = PageOptions(feature=parse_name(ns.feature) if ns.feature else None, features_dir=ns.dir,
                           stateful=ns.stateful, path=ns.path, route_name=ns.route_name,
                           route=not ns.no_route, force=ns.force)
        messages += plan_page(changes, catalog, page, opts)

    _print_plan(changes.all())
    _print_messages(messages)
    _write_and_finish(project, changes.all(), ns, interactive=False)
    return 0


def cmd_widget(args: list[str], project: Project) -> int:
    p = argparse.ArgumentParser(prog="fgen widget", description="Add widget(s) to lib/core/widgets, or to a feature with --in.")
    p.add_argument("names", nargs="+", help="widget name(s): 'primary_button', 'AppCard'")
    p.add_argument("--in", dest="feature", help="put it in <features dir>/<feature>/presentation/widgets")
    p.add_argument("--stateful", action="store_true", help="StatefulWidget")
    p.add_argument("-d", "--dir", help="features directory (default: lib/features)")
    p.add_argument("-f", "--force", action="store_true", help="overwrite existing files")
    p.add_argument("-n", "--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("--no-format", action="store_true", help="don't run 'dart format' on the generated files")
    p.add_argument("--templates", help=argparse.SUPPRESS)
    ns = p.parse_args(args)
    _apply_config(ns, project)

    catalog = Catalog.load(template_roots(project.root, ns.templates))
    changes = Changes(project)
    feature = parse_name(ns.feature) if ns.feature else None
    for widget in _names(ns.names, "widget"):
        plan_widget(changes, catalog, widget, feature, ns.dir, ns.stateful, ns.force)
    _print_plan(changes.all())
    _write_and_finish(project, changes.all(), ns, interactive=False)
    return 0


# --------------------------------------------------------------------------- model
def _read_json_interactively() -> str:
    print(style.cyan("?") + style.bold(" Paste the JSON sample") + style.dim(" (it is read as soon as it is complete; Ctrl+D / Ctrl+Z+Enter ends)"))
    buffer: list[str] = []
    while True:
        try:
            line = input()
        except EOFError:
            break
        except KeyboardInterrupt:
            print()
            raise _Abort from None
        buffer.append(line)
        try:
            json.loads("\n".join(buffer))
            break
        except json.JSONDecodeError:
            continue
    return "\n".join(buffer)


def _model_target(ns: argparse.Namespace, project: Project, stem: str) -> str:
    if ns.output:
        rel = PurePosixPath(ns.output.replace("\\", "/"))
        if rel.suffix != ".dart" or not rel.parts or rel.parts[0] != "lib" or ".." in rel.parts:
            raise ValueError("--output must be a .dart file inside lib/ (e.g. lib/core/models/user.dart)")
        return rel.as_posix()
    if ns.feature:
        base = f"{ns.dir.rstrip('/')}/{parse_name(ns.feature).snake}"
        if (project.root / base / "models").is_dir():
            folder = "models"
        elif (project.root / base / "data" / "models").is_dir():
            folder = "data/models"
        else:
            folder = "models" if project.config.get("arch") == "simple" else "data/models"
        return f"{base}/{folder}/{stem}.dart"
    return f"lib/core/models/{stem}.dart"


def cmd_model(args: list[str], project: Project) -> int:
    p = argparse.ArgumentParser(
        prog="fgen model",
        description="Generate Dart model classes (fromJson / toJson / copyWith, or freezed) from a JSON sample. "
                    "Nested objects become their own classes.",
        epilog="examples:\n"
               "  fgen model User --file user.json\n"
               "  fgen model Product --json '{\"id\": 1, \"title\": \"Pen\", \"tags\": [\"a\"]}' --in shop\n"
               "  curl -s https://api.example.com/users/1 | fgen model User -m plain\n"
               "  fgen model User          (then paste the JSON)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("name", help="class name, e.g. User or UserModel (the file is named after it)")
    source = p.add_mutually_exclusive_group()
    source.add_argument("--json", help="the JSON sample as a string")
    source.add_argument("--file", help="read the JSON sample from a file")
    p.add_argument("-m", "--model", choices=list(MODEL_MODES), help="freezed or plain (default: the project's choice)")
    where = p.add_mutually_exclusive_group()
    where.add_argument("--in", dest="feature", help="put it in that feature's models folder")
    where.add_argument("-o", "--output", help="output .dart file (default: lib/core/models/<name>.dart)")
    p.add_argument("--nullable", action="store_true", help="make every field nullable (safer for loose APIs)")
    p.add_argument("-d", "--dir", help="features directory (default: lib/features)")
    p.add_argument("-f", "--force", action="store_true", help="overwrite the file if it exists")
    p.add_argument("-n", "--dry-run", action="store_true", help="print the generated code, write nothing")
    p.add_argument("--pub", action="store_true", help="run 'flutter pub add' for missing packages")
    p.add_argument("--build", action="store_true", help="run build_runner afterwards (freezed)")
    p.add_argument("--no-format", action="store_true", help="don't run 'dart format' on the generated file")
    p.add_argument("--templates", help=argparse.SUPPRESS)
    ns = p.parse_args(args)
    _apply_config(ns, project)

    if ns.json is not None:
        raw = ns.json
    elif ns.file:
        raw = Path(ns.file).read_text(encoding="utf-8-sig")
    elif not sys.stdin.isatty():
        raw = sys.stdin.read()
    else:
        raw = _read_json_interactively()
    try:
        sample = json.loads(raw)
    except json.JSONDecodeError as e:
        return _fail(f"invalid JSON: {e}")

    names = parse_name(ns.name)
    if ns.model is None:
        ns.model = project.config.get("model") or ("freezed" if project.has_package("freezed_annotation") else "plain")
    rel = _model_target(ns, project, names.snake)
    stem = PurePosixPath(rel).stem
    code = generate_model(sample, names.pascal, stem, freezed=ns.model == "freezed", all_nullable=ns.nullable)

    path = project.root / rel
    action = "create" if not path.exists() else ("overwrite" if ns.force else "skip")
    f = PlannedFile(path=path, rel=rel, content=code, layer="model", action=action)
    if ns.dry_run:
        print(style.dim(f"// {rel} ({ns.model})\n"))
        print(code)
    else:
        print(style.bold(f"model {names.pascal} ({ns.model})"))
        _print_plan([f])
    if action == "skip" and not ns.dry_run:
        return _fail(f"{rel} already exists; use --force to overwrite it")
    _write_and_finish(project, [f], ns, interactive=False)
    return 0


# --------------------------------------------------------------------------- assets
def cmd_assets(args: list[str], project: Project) -> int:
    p = argparse.ArgumentParser(
        prog="fgen assets",
        description="Write constants for every file under assets/ (one class per top folder: AppImages, AppIcons, ...) "
                    "and add the folders to 'flutter: assets:' in pubspec.yaml. Run it again whenever files change.",
    )
    p.add_argument("--dir", dest="assets_dir", default="assets", help="assets folder (default: assets)")
    p.add_argument("-o", "--output", default="lib/core/constants/app_assets.dart", help="output file (default: lib/core/constants/app_assets.dart)")
    p.add_argument("--no-pubspec", action="store_true", help="don't touch pubspec.yaml")
    p.add_argument("-f", "--force", action="store_true", help="overwrite the output file even if it was not made by fgen")
    p.add_argument("-n", "--dry-run", action="store_true", help="print the plan, write nothing")
    p.add_argument("--templates", help=argparse.SUPPRESS)
    ns = p.parse_args(args)

    assets_dir = ns.assets_dir.replace("\\", "/").strip("/")
    files = assets_mod.scan(project.root, assets_dir)
    if not files:
        return _fail(f"no asset files found under {assets_dir}/")
    content = assets_mod.render(assets_mod.group_constants(files, assets_dir))

    changes = Changes(project)
    rel = ns.output.replace("\\", "/")
    path = project.root / rel
    current = changes.read(rel)
    if current is None:
        changes.add(PlannedFile(path=path, rel=rel, content=content, layer="assets", action="create"))
    elif assets_mod.GENERATED_MARK not in current and not ns.force:
        return _fail(f"{rel} exists and was not generated by fgen; use --force to replace it or -o to pick another file")
    elif current != content:
        changes.edit(rel, content)

    added: list[str] = []
    if not ns.no_pubspec:
        pubspec = changes.read("pubspec.yaml") or ""
        text, added = assets_mod.add_to_pubspec(pubspec, assets_mod.folders(files))
        if added:
            changes.edit("pubspec.yaml", text)

    groups = assets_mod.group_constants(files, assets_dir)
    print(style.bold(f"{len(files)} asset(s): ") + ", ".join(f"{g} ({len(c)})" for g, c in groups.items()))
    if not changes.all():
        print(style.green("Already up to date."))
        return 0
    _print_plan(changes.all())
    _print_messages([f"pubspec.yaml: added {e}" for e in added])
    ns.no_format = True  # the generated file is already formatted
    _write_and_finish(project, changes.all(), ns, interactive=False)
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

    project_error: str | None = None
    try:
        project: Project | None = load_project(start)
    except ProjectError as e:
        project, project_error = None, str(e)

    commands = {"init": cmd_init, "page": cmd_page, "widget": cmd_widget, "model": cmd_model, "assets": cmd_assets}
    try:
        if argv and argv[0] == "list":
            return cmd_list(project, extra_templates)
        if argv and (argv[0] == "eject" or argv[0] in commands):
            rest = argv[1:]
            for flag in ("-C", "--project", "--templates"):
                while flag in rest[:-1]:
                    i = rest.index(flag)
                    del rest[i:i + 2]
            if argv[0] == "eject":
                return cmd_eject(rest, project)
            if extra_templates:
                rest += ["--templates", extra_templates]
            if project is None and not ({"-h", "--help"} & set(rest)):
                return _fail(project_error or "not inside a Flutter/Dart project (pubspec.yaml not found)", 2)
            return commands[argv[0]](rest, project)  # type: ignore[arg-type]

        ns = build_parser().parse_args(argv)
        if project is None:
            return _fail(project_error or "not inside a Flutter/Dart project (pubspec.yaml not found)", 2)
        return cmd_generate(ns, project)
    except _Abort:
        return 130
    except (GeneratorError, TemplateError, ValueError, ModelError, assets_mod.AssetsError, OSError) as e:
        return _fail(str(e))
