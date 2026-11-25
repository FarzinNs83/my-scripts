"""Command line interface."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import __version__
from . import catalog
from . import fields as fieldmod
from . import generator as gen
from .engine import TemplateError
from .jsonmodel import ModelError
from .jsonmodel import generate as generate_model
from .naming import parse_name, split_names
from .project import Changes, Project, ProjectError
from .project import load as load_project


# --------------------------------------------------------------------------- output
class _Style:
    def __init__(self) -> None:
        self.enabled = sys.stdout.isatty() and "NO_COLOR" not in os.environ
        if self.enabled and os.name == "nt":
            os.system("")  # enables ANSI escape handling in the Windows console

    def _wrap(self, code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if self.enabled else text

    def bold(self, t: str) -> str: return self._wrap("1", t)
    def dim(self, t: str) -> str: return self._wrap("2", t)
    def green(self, t: str) -> str: return self._wrap("32", t)
    def yellow(self, t: str) -> str: return self._wrap("33", t)
    def red(self, t: str) -> str: return self._wrap("31", t)


style = _Style()
_COLORS = {"create": style.green, "overwrite": style.yellow, "update": style.yellow, "skip": style.dim}


def _fail(message: str, code: int = 1) -> int:
    print(style.red(f"error: {message}"), file=sys.stderr)
    return code


def _finish(changes: Changes, dry_run: bool) -> None:
    for f in changes.files.values():
        label = "exists, skipped" if f.action == "skip" else f.action
        print(f"  {_COLORS[f.action](label.ljust(16))} {f.rel}")
    for m in changes.messages:
        print(f"  {style.dim('-')} {m}")
    if dry_run:
        print(style.dim("dry run: nothing written"))
    else:
        changes.write()
        changes.project.format([f.rel for f in changes.files.values() if f.action != "skip"])
    if any(f.action == "skip" for f in changes.files.values()):
        print(style.dim("existing files were kept; add -f to overwrite them"))


def _ui(project: Project, components: list[str], ns: argparse.Namespace) -> None:
    """Install the shadcn components the generated code imports, if they are missing."""
    missing = gen.missing_ui(project, components)
    if not missing:
        return
    if ns.no_install or not (project.root / "components.json").is_file():
        print(style.yellow(f"needs shadcn components: rgen ui {' '.join(missing)}"))
        return
    print(style.bold("shadcn components"))
    project.run(project.dlx_cmd("shadcn@latest", "add", *missing, "-y"), ns.dry_run)
    gen.fix_shadcn(project)


def _common(p: argparse.ArgumentParser, install: bool = False) -> None:
    p.add_argument("-n", "--dry-run", action="store_true", help="show what would change, write nothing")
    p.add_argument("-f", "--force", action="store_true", help="overwrite files that already exist")
    if install:
        p.add_argument("--no-install", action="store_true", help="don't install packages / shadcn components")


def _parser(prog: str, description: str) -> argparse.ArgumentParser:
    return argparse.ArgumentParser(prog=f"rgen {prog}", description=description,
                                   formatter_class=argparse.RawDescriptionHelpFormatter)


# --------------------------------------------------------------------------- init
def cmd_init(args: list[str], project: Project) -> int:
    p = _parser("init", "Create a Vite + React + TS project (or upgrade the current one) with Tailwind v4, "
                        "shadcn/ui, React Router, TanStack Query, axios, zustand, react-hook-form + zod, "
                        "dark mode, auth store, error handling, a fake API (MSW), Vitest, CI and AGENTS.md "
                        "for AI tools.")
    p.add_argument("name", nargs="?", help="folder for a new project (default: the current folder)")
    p.add_argument("--title", help="app name shown in the header (default: from the folder name)")
    p.add_argument("--i18n", action="store_true", help="add i18next with English + Persian and a language switch")
    p.add_argument("--rtl", action="store_true", help="Persian/RTL first: dir=rtl, Vazirmatn font, shadcn RTL")
    p.add_argument("--pm", choices=["npm", "pnpm", "yarn", "bun"], help="package manager (default: detected, else npm)")
    p.add_argument("--ui", help=f"shadcn components to add (default: {','.join(catalog.ESSENTIALS)})")
    p.add_argument("--preset", default="nova",
                   help="shadcn style preset: nova, vega, maia, lyra, mira, luma, sera, rhea (default: nova)")
    p.add_argument("--layout", choices=gen.LAYOUTS, default="header",
                   help="header: top navigation (default); sidebar: collapsible side menu for dashboards")
    p.add_argument("--no-mocks", action="store_true", help="no fake API in 'npm run dev' (tests still use MSW)")
    p.add_argument("--no-tests", action="store_true", help="no Vitest / Testing Library setup")
    p.add_argument("--no-ci", action="store_true", help="no GitHub Actions workflow")
    _common(p, install=True)
    ns = p.parse_args(args)
    mocks, tests = not ns.no_mocks, not ns.no_tests

    if ns.name:
        root = (project.root if not project.exists else Path.cwd()) / ns.name
        if root.exists() and any(root.iterdir()) and not (root / "package.json").is_file():
            return _fail(f"{root} exists and is not empty")
        if not ns.dry_run:
            root.mkdir(parents=True, exist_ok=True)
        project = load_project(root) if (root / "package.json").is_file() else Project(root=root.resolve())
    fresh = not project.exists
    if not fresh and not project.has_dep("vite"):
        return _fail("this package.json has no vite dependency; rgen init works on Vite projects or empty folders")
    if ns.pm:
        project.config["pm"] = ns.pm

    title = ns.title or parse_name(project.root.name if project.root.name[:1].isalpha() else "app").title
    title = title.replace("'", "").replace('"', "").replace("{", "").replace("}", "")
    changes = Changes(project, ns.force)
    print(style.bold(f"rgen init: {'new project' if fresh else 'existing project'} in {project.root}"))
    warnings = gen.plan_init(project, changes, title=title, i18n=ns.i18n, rtl=ns.rtl, fresh=fresh,
                             layout=ns.layout, mocks=mocks, tests=tests, ci=not ns.no_ci)
    _finish(changes, ns.dry_run)
    for w in warnings:
        print(style.yellow(f"  ! {w}"))
    if not ns.dry_run:
        project.save_config({k: project.config[k] for k in ("title", "i18n", "rtl", "pm", "layout", "mocks", "tests")
                             if k in project.config})

    deps = gen.DEPS + (gen.I18N_DEPS if ns.i18n else []) + (["@fontsource-variable/vazirmatn"] if ns.rtl else [])
    dev_deps = gen.DEV_DEPS + (gen.MSW_DEPS if mocks or tests else []) + (gen.TEST_DEPS if tests else [])
    if ns.no_install:
        print(style.yellow("\nPackages not installed (--no-install). Run 'rgen init' again without it, or:"))
        print("  " + " ".join(project.install_cmd(deps)))
        print("  " + " ".join(project.install_cmd(dev_deps, dev=True)))
        print("  " + " ".join(project.dlx_cmd("shadcn@latest", "init", "-b", "radix")))
        if mocks:
            print("  " + " ".join(project.dlx_cmd("msw", "init", "public", "--save")))
        return 0

    print(style.bold("\npackages"))
    project.run(project.install_cmd(deps), ns.dry_run)
    project.run(project.install_cmd(dev_deps, dev=True), ns.dry_run)
    if mocks:
        project.run(project.dlx_cmd("msw", "init", "public", "--save"), ns.dry_run)
    print(style.bold("shadcn/ui"))
    if not (project.root / "components.json").is_file():
        project.run(project.dlx_cmd("shadcn@latest", "init", "-b", "radix", "-p", ns.preset, "-y", "--no-monorepo",
                                    "--rtl" if ns.rtl else "--no-rtl"), ns.dry_run)
        if not ns.dry_run and not (project.root / "components.json").is_file():
            return _fail("shadcn init did not create components.json; run it by hand: "
                         + " ".join(project.dlx_cmd("shadcn@latest", "init", "-b", "radix")))
    ui = split_names([ns.ui]) if ns.ui else list(catalog.ESSENTIALS)
    if ns.layout == "sidebar" and "sidebar" not in ui:
        ui.append("sidebar")
    if not ns.dry_run:
        ui = gen.missing_ui(project, ui)
    if ui:
        project.run(project.dlx_cmd("shadcn@latest", "add", *ui, "-y"), ns.dry_run)
    gen.fix_shadcn(project)
    css = project.root / "src/index.css"
    if ns.rtl and css.is_file() and not ns.dry_run:
        css.write_text(gen.rtl_css(css.read_text(encoding="utf-8")), encoding="utf-8")
    if not ns.dry_run:
        project.format(list(changes.files))

    cd = f"cd {ns.name} && " if ns.name else ""
    print(style.green("\nDone.") + f" Start it: {cd}{project.pm} run dev"
          + (" (fake API on: VITE_MOCK_API in .env.development)" if mocks else ""))
    print("Next: rgen auth  |  rgen feature product --fields \"name:string,price:number\"  |  rgen list")
    return 0


# --------------------------------------------------------------------------- generators
def cmd_feature(args: list[str], project: Project) -> int:
    p = _parser("feature", "A CRUD feature in src/features/<name>/: zod types, API calls, TanStack Query hooks, "
                           "a table, a form, a list page with create/edit/delete dialogs, a detail page, routes, "
                           "a nav link, a fake API with sample data (mocks.ts) and a test.\n\nField types: "
                           + ", ".join(fieldmod.TYPES) + " (add ? for optional)")
    p.add_argument("names", nargs="+", help="feature name(s), singular: product, order-item (comma separated ok)")
    p.add_argument("--fields", help="name:type list, e.g. \"title:string,price:number,status:enum(draft|live),notes:text?\"")
    p.add_argument("--endpoint", help="REST endpoint (default: /<plural name>)")
    p.add_argument("--no-ui", action="store_true", help="only types, api and hooks")
    p.add_argument("--protected", action="store_true", help="the page needs a signed-in user")
    p.add_argument("--no-nav", action="store_true", help="don't add a header link")
    p.add_argument("--paginated", action="store_true",
                   help="server-side search + pagination: list() sends ?page&pageSize&q and gets "
                        "{ items, total, page, pageSize }")
    p.add_argument("--no-detail", action="store_true", help="no detail page")
    _common(p, install=True)
    ns = p.parse_args(args)
    gen.require_project(project)
    fields = fieldmod.parse_fields(ns.fields)
    changes = Changes(project, ns.force)
    needed: set[str] = set()
    for name in split_names(ns.names):
        print(style.bold(f"feature {parse_name(name).kebab}"))
        needed |= set(gen.plan_feature(project, changes, name, fields, endpoint=ns.endpoint, ui=not ns.no_ui,
                                       protected=ns.protected, nav=not ns.no_nav, paginated=ns.paginated,
                                       detail=not ns.no_detail))
    _finish(changes, ns.dry_run)
    _ui(project, sorted(needed), ns)
    return 0


def cmd_page(args: list[str], project: Project) -> int:
    p = _parser("page", "A page component, registered as a lazy route in src/app/router.tsx.")
    p.add_argument("name")
    p.add_argument("--in", dest="feature", help="feature folder (default: a feature named after the page)")
    p.add_argument("--path", help="URL path, may hold params: /products/:id (default: /<name>)")
    where = p.add_mutually_exclusive_group()
    where.add_argument("--protected", action="store_true", help="only for signed-in users")
    where.add_argument("--bare", action="store_true", help="without the app layout (header)")
    p.add_argument("--nav", action="store_true", help="add a header link")
    p.add_argument("--no-route", action="store_true", help="don't register a route")
    _common(p)
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project, ns.force)
    gen.plan_page(project, changes, ns.name, feature=ns.feature, path=ns.path, protected=ns.protected,
                  bare=ns.bare, nav=ns.nav, route=not ns.no_route)
    _finish(changes, ns.dry_run)
    return 0


def cmd_form(args: list[str], project: Project) -> int:
    p = _parser("form", "A form: zod schema + react-hook-form + shadcn inputs, with field errors and "
                        "server-side (422) errors shown next to the fields.\n\nField types: "
                        + ", ".join(fieldmod.TYPES) + " (add ? for optional)")
    p.add_argument("name", help="e.g. contact, checkout")
    p.add_argument("--fields", required=True, help="\"email:email,message:text,plan:enum(free|pro),terms:bool\"")
    p.add_argument("--in", dest="feature", help="put it in that feature's components folder")
    _common(p, install=True)
    ns = p.parse_args(args)
    gen.require_project(project)
    fields = fieldmod.parse_fields(ns.fields)
    changes = Changes(project, ns.force)
    dest = f"src/features/{parse_name(ns.feature).kebab}/components" if ns.feature else "src/components/forms"
    gen.plan_form(project, changes, parse_name(ns.name), fields, dest)
    _finish(changes, ns.dry_run)
    _ui(project, fieldmod.ui_components(fields), ns)
    return 0


def cmd_auth(args: list[str], project: Project) -> int:
    p = _parser("auth", "Login and register pages, auth API calls and hooks (useLogin, useRegister, useMe, "
                        "useLogout). Tokens live in src/stores/auth-store.ts; src/lib/api-client.ts sends them "
                        "and refreshes them on 401. Wrap pages with --protected to require sign-in.")
    _common(p, install=True)
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project, ns.force)
    needed = gen.plan_auth(project, changes)
    _finish(changes, ns.dry_run)
    _ui(project, needed, ns)
    return 0


def cmd_simple(kind: str, args: list[str], project: Project) -> int:
    p = _parser(kind, {
        "component": "A React component (src/components/<name>.tsx).",
        "store": "A zustand store (src/stores/<name>-store.ts).",
        "hook": "A custom hook (src/hooks/use-<name>.ts). Check usehooks-ts first.",
    }[kind])
    p.add_argument("name")
    p.add_argument("--in", dest="feature", help="put it in that feature's folder")
    if kind == "store":
        p.add_argument("--persist", action="store_true", help="keep the state in localStorage")
    _common(p)
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project, ns.force)
    if kind == "component":
        gen.plan_component(project, changes, ns.name, ns.feature)
    elif kind == "store":
        gen.plan_store(project, changes, ns.name, ns.feature, ns.persist)
    else:
        gen.plan_hook(project, changes, ns.name, ns.feature)
    _finish(changes, ns.dry_run)
    return 0


def cmd_model(args: list[str], project: Project) -> int:
    p = _parser("model", "zod schemas + TypeScript types from a JSON sample (nested objects become their own "
                         "schemas). The JSON comes from --file, --json or stdin.")
    p.add_argument("name", help="type name, e.g. User")
    src = p.add_mutually_exclusive_group()
    src.add_argument("--file", help="JSON file")
    src.add_argument("--json", help="JSON text")
    p.add_argument("--in", dest="feature", help="put it in src/features/<feature>/models/")
    p.add_argument("--nullable", action="store_true", help="make every field nullish (loose APIs)")
    _common(p)
    ns = p.parse_args(args)
    gen.require_project(project)
    if ns.json is not None:
        raw = ns.json
    elif ns.file:
        raw = Path(ns.file).read_text(encoding="utf-8-sig")
    else:
        if sys.stdin.isatty():
            print(style.dim("Paste the JSON, then Ctrl+D (Ctrl+Z Enter on Windows):"))
        raw = sys.stdin.read()
    try:
        sample = json.loads(raw)
    except json.JSONDecodeError as e:
        return _fail(f"invalid JSON: {e}")
    n = parse_name(ns.name)
    code = generate_model(sample, n.pascal, ns.nullable)
    dest = f"src/features/{parse_name(ns.feature).kebab}/models" if ns.feature else "src/models"
    changes = Changes(project, ns.force)
    changes.add(f"{dest}/{n.kebab}.ts", code)
    if ns.dry_run:
        print(code)
    _finish(changes, ns.dry_run)
    return 0


def cmd_env(args: list[str], project: Project) -> int:
    p = _parser("env", "Add a VITE_ variable to src/lib/env.ts (typed, validated at startup), .env.example and .env.")
    p.add_argument("name", help="e.g. STRIPE_KEY (VITE_ is added)")
    p.add_argument("--default", help="default value")
    p.add_argument("--optional", action="store_true", help="may be missing")
    _common(p)
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project, ns.force)
    key = gen.plan_env(changes, ns.name, ns.default, ns.optional)
    changes.note(f"use it as env.{key}")
    _finish(changes, ns.dry_run)
    return 0


# --------------------------------------------------------------------------- components
def cmd_ui(args: list[str], project: Project) -> int:
    p = _parser("ui", "Add shadcn/ui components or blocks.\n\nComponents: " + ", ".join(catalog.SHADCN)
                + "\nBlocks: " + ", ".join(f"{k} ({v})" for k, v in catalog.SHADCN_BLOCKS.items()))
    p.add_argument("names", nargs="*")
    p.add_argument("--all", action="store_true", help="every shadcn component")
    p.add_argument("--list", action="store_true", help="list components and blocks")
    p.add_argument("-n", "--dry-run", action="store_true")
    p.add_argument("-f", "--force", action="store_true", help="overwrite existing component files")
    ns = p.parse_args(args)
    if ns.list or not (ns.names or ns.all):
        print(style.bold("components: ") + ", ".join(catalog.SHADCN))
        print(style.bold("blocks: ") + ", ".join(f"{k} ({v})" for k, v in catalog.SHADCN_BLOCKS.items()))
        return 0
    gen.require_project(project)
    extra = ["--overwrite"] * ns.force
    targets = ["--all"] if ns.all else split_names(ns.names)
    project.run(project.dlx_cmd("shadcn@latest", "add", *targets, "-y", *extra), ns.dry_run)
    gen.fix_shadcn(project)
    return 0


def cmd_bits(args: list[str], project: Project) -> int:
    p = _parser("bits", "Add React Bits components (reactbits.dev) in TypeScript + Tailwind.\n"
                        "Names are forgiving: split-text, splittext and SplitText all work.")
    p.add_argument("names", nargs="*")
    p.add_argument("--list", nargs="?", const="all", metavar="CATEGORY",
                   help=f"list components ({', '.join(catalog.REACT_BITS)} or all)")
    p.add_argument("--json", action="store_true", help="machine-readable --list")
    p.add_argument("-n", "--dry-run", action="store_true")
    p.add_argument("-f", "--force", action="store_true", help="overwrite existing files; allow unknown names")
    ns = p.parse_args(args)
    if ns.list or not ns.names:
        cats = catalog.REACT_BITS if ns.list in (None, "all") else {ns.list: catalog.REACT_BITS.get(ns.list, [])}
        if ns.json:
            print(json.dumps(cats, indent=2))
        else:
            for cat, names in cats.items():
                print(style.bold(f"{cat} ({len(names)}): ") + ", ".join(names))
            print(style.dim("Preview them at https://reactbits.dev"))
        return 0
    gen.require_project(project)
    targets = []
    for raw in split_names(ns.names):
        name, known = catalog.resolve_bits(raw)
        if not known:
            hints = catalog.suggest_bits(raw)
            if hints and not ns.force:
                return _fail(f"unknown React Bits component '{raw}'; did you mean {', '.join(hints)}?")
            print(style.yellow(f"'{name}' is not in rgen's list; trying it anyway"))
        targets.append(f"@react-bits/{name}-TS-TW")
    project.run(project.dlx_cmd("shadcn@latest", "add", *targets, "-y", "-p", "src/components/bits",
                                *(["--overwrite"] * ns.force)), ns.dry_run)
    print("import them from " + ", ".join(f"'@/components/bits/{t[len('@react-bits/'):-len('-TS-TW')]}'" for t in targets))
    return 0


def cmd_add(args: list[str], project: Project) -> int:
    p = _parser("add", "Add components from any shadcn registry.\n\n" +
                "\n".join(f"  {k:<20} {v}" for k, v in catalog.REGISTRIES.items()) +
                "\n\nExample: rgen add @magicui/marquee @aceternity/3d-card-effect")
    p.add_argument("items", nargs="+", help="@registry/name, a registry URL, or a shadcn name")
    p.add_argument("-n", "--dry-run", action="store_true")
    p.add_argument("-f", "--force", action="store_true", help="overwrite existing files")
    ns = p.parse_args(args)
    gen.require_project(project)
    project.run(project.dlx_cmd("shadcn@latest", "add", *ns.items, "-y", *(["--overwrite"] * ns.force)), ns.dry_run)
    gen.fix_shadcn(project)
    return 0


def cmd_openapi(args: list[str], project: Project) -> int:
    p = _parser("openapi", "Typed API functions and React Query hooks generated by orval from an OpenAPI spec, "
                           "using the app's apiClient. Regenerate later with '<pm> run api'.")
    p.add_argument("spec", help="URL or path of openapi.json / .yaml")
    _common(p, install=True)
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project, ns.force)
    gen.plan_openapi(project, changes, ns.spec)
    _finish(changes, ns.dry_run)
    if ns.no_install:
        print(f"then: {' '.join(project.install_cmd(['orval'], dev=True))} && {project.pm} run api")
        return 0
    if not project.has_dep("orval"):
        project.run(project.install_cmd(["orval"], dev=True), ns.dry_run)
    project.run([project.pm, "run", "api"], ns.dry_run)
    return 0


# --------------------------------------------------------------------------- meta
def cmd_docker(args: list[str], project: Project) -> int:
    p = _parser("docker", "Dockerfile (build with node, serve with nginx), nginx.conf with SPA routing, gzip and "
                          "asset caching, and .dockerignore. VITE_* values are passed as build args.")
    _common(p)
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project, ns.force)
    gen.plan_docker(project, changes)
    _finish(changes, ns.dry_run)
    name = gen.base_context(project)["name"]
    print(f"docker build -t {name} --build-arg VITE_API_URL=https://api.example.com . && docker run -p 8080:80 {name}")
    return 0


def cmd_ai(args: list[str], project: Project) -> int:
    p = _parser("ai", "Write (or refresh) the rgen section in AGENTS.md and point CLAUDE.md at it, so AI "
                      "assistants call rgen instead of writing boilerplate.")
    p.add_argument("-n", "--dry-run", action="store_true")
    ns = p.parse_args(args)
    gen.require_project(project)
    changes = Changes(project)
    gen.plan_agents(project, changes)
    if not changes.files:
        print(style.green("AGENTS.md is up to date."))
        return 0
    _finish(changes, ns.dry_run)
    return 0


COMMANDS = {
    "init": "create or upgrade a Vite + React project with the full stack",
    "feature": "CRUD feature: types, api, query hooks, table, form, list page, route, nav",
    "page": "page + lazy route (params, protected, bare, nav)",
    "form": "zod + react-hook-form + shadcn form from --fields",
    "auth": "login/register pages, auth hooks, token refresh",
    "model": "zod schema + types from a JSON sample",
    "component": "React component",
    "store": "zustand store",
    "hook": "custom hook",
    "env": "typed VITE_ environment variable",
    "ui": "shadcn/ui components and blocks",
    "bits": "React Bits animated components",
    "add": "components from any shadcn registry (@magicui, @aceternity, ...)",
    "openapi": "orval client + React Query hooks from an OpenAPI spec",
    "docker": "Dockerfile + nginx.conf for the built app",
    "ai": "refresh the AGENTS.md / CLAUDE.md instructions",
    "eject": "copy the templates to .rgen/templates to customise them",
    "list": "everything rgen knows (--json for tools)",
}


def cmd_list(args: list[str], project: Project) -> int:
    as_json = "--json" in args
    data = {
        "version": __version__,
        "commands": COMMANDS,
        "field_types": fieldmod.TYPES,
        "shadcn_components": catalog.SHADCN,
        "shadcn_blocks": catalog.SHADCN_BLOCKS,
        "react_bits": catalog.REACT_BITS,
        "registries": catalog.REGISTRIES,
        "project": {"root": str(project.root), "initialised": project.exists and bool(project.config),
                    "config": project.config, "package_manager": project.pm} if project.exists else None,
        "help": "rgen <command> --help shows every option of a command",
    }
    if as_json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0
    print(style.bold(f"rgen {__version__}"))
    for name, text in COMMANDS.items():
        print(f"  {name.ljust(10)} {text}")
    print(style.bold("\nfield types: ") + ", ".join(fieldmod.TYPES))
    print(style.bold("registries: ") + ", ".join(catalog.REGISTRIES))
    print(style.dim("\nrgen <command> --help for options; rgen list --json for tools"))
    return 0


def cmd_eject(args: list[str], project: Project) -> int:
    p = _parser("eject", "Copy the built-in templates to .rgen/templates; edited copies are used instead.")
    p.add_argument("-f", "--force", action="store_true", help="overwrite templates already ejected")
    ns = p.parse_args(args)
    gen.require_project(project)
    copied = gen.eject(project, ns.force)
    print(f"{len(copied)} template(s) copied to {gen.OVERRIDES}/")
    return 0


HELP = """rgen - React project generator (Vite + TS + Tailwind + shadcn/ui + React Router + TanStack Query)

usage: rgen <command> [options]      rgen <command> --help

{commands}

examples
  rgen init my-app --rtl --i18n --layout sidebar
  rgen auth
  rgen feature product --fields "name:string,price:number,status:enum(draft|live),notes:text?" --paginated
  rgen page settings --protected --nav
  rgen form contact --fields "email:email,message:text"
  rgen bits SplitText Aurora
  rgen add @magicui/marquee
"""


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    argv = list(sys.argv[1:] if argv is None else argv)
    start = Path.cwd()
    if len(argv) >= 2 and argv[0] in ("-C", "--project"):
        start, argv = Path(argv[1]), argv[2:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(HELP.format(commands="\n".join(f"  {k.ljust(10)} {v}" for k, v in COMMANDS.items())))
        return 0
    if argv[0] in ("-V", "--version"):
        print(__version__)
        return 0
    command, rest = argv[0], argv[1:]
    handlers = {
        "init": cmd_init, "feature": cmd_feature, "page": cmd_page, "form": cmd_form, "auth": cmd_auth,
        "model": cmd_model, "env": cmd_env, "ui": cmd_ui, "bits": cmd_bits, "add": cmd_add,
        "openapi": cmd_openapi, "docker": cmd_docker, "ai": cmd_ai, "list": cmd_list, "eject": cmd_eject,
        "component": lambda a, p: cmd_simple("component", a, p),
        "store": lambda a, p: cmd_simple("store", a, p),
        "hook": lambda a, p: cmd_simple("hook", a, p),
    }
    if command not in handlers:
        return _fail(f"unknown command '{command}' (see rgen --help)", 2)
    try:
        project = load_project(start)
        return handlers[command](rest, project)
    except KeyboardInterrupt:
        return 130
    except (gen.GeneratorError, ProjectError, TemplateError, ModelError, ValueError, OSError) as e:
        return _fail(str(e))
