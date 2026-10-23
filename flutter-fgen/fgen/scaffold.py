"""Project scaffolding: 'fgen init', 'fgen page', 'fgen widget', and wiring screens into the router and main()."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from .generator import (
    Catalog,
    GeneratorError,
    Options,
    PlannedFile,
    _render_file,
    _resolve_path,
    build_context,
)
from .naming import Names
from .project import Project

ROUTES_FILE = "lib/core/router/app_routes.dart"
GO_ROUTER_FILE = "lib/core/router/app_router.dart"
GETX_PAGES_FILE = "lib/core/router/app_pages.dart"
MAIN_FILE = "lib/main.dart"
TEST_FILE = "test/widget_test.dart"

ROUTERS = ("go_router", "getx", "none")
_RIVERPOD = ("riverpod", "riverpod_classic")


# --------------------------------------------------------------------------- changes
class Changes:
    """New files plus edits to existing ones, keyed by project-relative path.

    Edits made after a file was planned apply to the planned content, so 'init' can
    create the router and register the first route in the same run.
    """

    def __init__(self, project: Project):
        self.project = project
        self.files: dict[str, PlannedFile] = {}

    def add(self, f: PlannedFile) -> None:
        self.files.setdefault(f.rel, f)

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
        self.files[rel] = PlannedFile(path=path, rel=rel, content=text, layer="edit", action="update",
                                      core=f.core if f else False, newline=newline)

    def all(self) -> list[PlannedFile]:
        return list(self.files.values())


def insert_at_marker(text: str, marker: str, line: str) -> str | None:
    """Put `line` above the `// fgen:<marker>` comment, with the comment's indentation.

    Returns the text unchanged when the line is already there, and None when the marker is missing.
    """
    m = re.search(rf"^([ \t]*)// fgen:{marker}\b.*$", text, re.M)
    if not m:
        return None
    if any(existing.strip() == line.strip() for existing in text.split("\n")):
        return text
    return text[: m.start()] + m.group(1) + line + "\n" + text[m.start():]


def add_import(text: str, uri: str) -> str | None:
    """Add an import right after the last import above `// fgen:imports` (None when the marker is missing)."""
    line = f"import '{uri}';"
    m = re.search(r"^[ \t]*// fgen:imports\b.*$", text, re.M)
    if not m:
        return None
    if line in text:
        return text
    last = None
    for found in re.finditer(r"^import\s.*;[ \t]*$", text[: m.start()], re.M):
        last = found
    if last is None:
        return insert_at_marker(text, "imports", line)
    return text[: last.end()] + "\n" + line + text[last.end():]


# --------------------------------------------------------------------------- wiring
@dataclass
class Route:
    name: str            # AppRoutes constant
    path: str            # '/settings'
    screen: str          # SettingsScreen
    screen_import: str   # package:... uri
    binding: str | None = None         # GetX binding class
    binding_import: str | None = None


def detect_router(changes: Changes) -> str:
    if changes.exists(GO_ROUTER_FILE):
        return "go_router"
    if changes.exists(GETX_PAGES_FILE):
        return "getx"
    return "none"


def register_route(changes: Changes, route: Route) -> str:
    """Add the route to AppRoutes and the router. Returns a short message for the user."""
    kind = detect_router(changes)
    if kind == "none":
        return ""
    router_rel = GO_ROUTER_FILE if kind == "go_router" else GETX_PAGES_FILE
    routes, router = changes.read(ROUTES_FILE), changes.read(router_rel)
    if routes is None or "fgen:routes" not in routes or "fgen:routes" not in (router or ""):
        return f"route not added: no '// fgen:routes' marker in {ROUTES_FILE} / {router_rel}"
    assert router is not None

    if re.search(rf"=>\s*const\s+{route.screen}\(\)", router):
        return f"{route.screen} is already routed"
    if re.search(rf"\bstatic const {route.name}\b", routes):
        raise GeneratorError(f"AppRoutes.{route.name} already exists; pick another name with --route-name")
    if f"'{route.path}';" in routes:
        raise GeneratorError(f"the path '{route.path}' is already used in {ROUTES_FILE}; pass --path")

    routes = insert_at_marker(routes, "routes", f"static const {route.name} = '{route.path}';")
    if kind == "go_router":
        entry = f"GoRoute(path: AppRoutes.{route.name}, builder: (context, state) => const {route.screen}()),"
    else:
        binding = f", binding: {route.binding}()" if route.binding else ""
        entry = f"GetPage(name: AppRoutes.{route.name}, page: () => const {route.screen}(){binding}),"
    router = insert_at_marker(router, "routes", entry)
    for uri in (route.screen_import, route.binding_import):
        if uri and router is not None:
            router = add_import(router, uri) or router
    assert routes is not None and router is not None
    changes.edit(ROUTES_FILE, routes)
    changes.edit(router_rel, router)
    return f"routed {route.screen} at '{route.path}' (AppRoutes.{route.name})"


def register_feature_init(changes: Changes, function: str, uri: str) -> str:
    """Call a feature's DI initialiser (e.g. initAuthFeature) from main()."""
    main = changes.read(MAIN_FILE)
    if main is None or "fgen:features" not in main:
        return ""
    if re.search(rf"\b{function}\(\)", main):
        return ""
    main = insert_at_marker(main, "features", f"{function}();")
    main = add_import(main, uri) if main else None
    if main is None:
        return f"{function}() not added: no '// fgen:imports' marker in {MAIN_FILE}"
    changes.edit(MAIN_FILE, main)
    return f"main() now calls {function}()"


# --------------------------------------------------------------------------- page / widget
def _features_rel(features_dir: str) -> str:
    """'lib/features' -> 'features' (the part used in package: imports)."""
    return "/".join(PurePosixPath(features_dir.replace("\\", "/")).parts[1:])


def _package_uri(project: Project, rel: str) -> str:
    return f"package:{project.package}/{rel[len('lib/'):]}"


def _plan_one(changes: Changes, catalog: Catalog, template: str, rel: str, context: dict[str, Any], force: bool) -> PlannedFile:
    source = catalog.files.get(template)
    if source is None:
        raise GeneratorError(f"template '{template}' not found")
    content = _render_file(source, context) or ""
    path = changes.project.root / rel
    action = "create" if not path.exists() else ("overwrite" if force else "skip")
    f = PlannedFile(path=path, rel=rel, content=content, layer="page", action=action)
    changes.add(f)
    return f


def use_consumer(project: Project) -> bool:
    state = project.config.get("state")
    if state:
        return state in _RIVERPOD
    return project.has_package("flutter_riverpod") or project.has_package("hooks_riverpod")


@dataclass
class PageOptions:
    feature: Names | None = None  # folder under the features dir; defaults to the page itself
    features_dir: str = "lib/features"
    stateful: bool = False
    path: str | None = None
    route_name: str | None = None
    route: bool = True
    force: bool = False
    consumer: bool | None = None  # Consumer widgets; None = decide from the project's state management


def screen_rel(features_dir: str, feature: Names, page: Names) -> str:
    return f"{features_dir.rstrip('/')}/{feature.snake}/presentation/screens/{page.snake}_screen.dart"


def route_for(changes: Changes, features_dir: str, feature: Names, page: Names,
              path: str | None = None, name: str | None = None) -> Route:
    """The Route for a screen, picking up the feature's GetX binding when it has one."""
    project = changes.project
    rel = screen_rel(features_dir, feature, page)
    route = Route(name=name or page.camel, path=path or f"/{page.kebab}", screen=f"{page.pascal}Screen",
                  screen_import=_package_uri(project, rel))
    if re.match(r"^[A-Za-z]:[/\\]", route.path) or "\\" in route.path:
        # Git Bash turns '/auth/login' into 'C:/Program Files/Git/auth/login'
        raise GeneratorError(f"invalid route path '{route.path}'; in Git Bash write it without the leading slash (auth/login)")
    if not route.path.startswith("/"):
        route.path = "/" + route.path
    binding_rel = f"{features_dir.rstrip('/')}/{feature.snake}/presentation/bindings/{feature.snake}_binding.dart"
    if feature == page and changes.exists(binding_rel):
        route.binding = f"{feature.pascal}Binding"
        route.binding_import = _package_uri(project, binding_rel)
    return route


def plan_page(changes: Changes, catalog: Catalog, page: Names, opts: PageOptions) -> list[str]:
    project = changes.project
    feature = opts.feature or page
    rel = screen_rel(opts.features_dir, feature, page)
    context = {**page.as_dict(), "pkg": project.package, "stateful": opts.stateful,
               "consumer": use_consumer(project) if opts.consumer is None else opts.consumer}
    _plan_one(changes, catalog, "page/NAME_screen.dart.tmpl", rel, context, opts.force)
    if not opts.route:
        return []
    message = register_route(changes, route_for(changes, opts.features_dir, feature, page, opts.path, opts.route_name))
    return [message] if message else []


def plan_widget(changes: Changes, catalog: Catalog, widget: Names, feature: Names | None,
                features_dir: str, stateful: bool, force: bool) -> None:
    if feature:
        rel = f"{features_dir.rstrip('/')}/{feature.snake}/presentation/widgets/{widget.snake}.dart"
    else:
        rel = f"lib/core/widgets/{widget.snake}.dart"
    context = {**widget.as_dict(), "pkg": changes.project.package, "stateful": stateful}
    _plan_one(changes, catalog, "widget/NAME.dart.tmpl", rel, context, force)


# --------------------------------------------------------------------------- init
def default_router(state: str, no_router: bool) -> str:
    if no_router:
        return "none"
    return "getx" if state == "getx" else "go_router"


def _is_flutter_create_default(text: str) -> bool:
    """main.dart / widget_test.dart of the counter app that 'flutter create' writes."""
    return any(mark in text for mark in ("_incrementCounter", "MyHomePage", "Counter increments smoke test"))


def plan_init(catalog: Catalog, project: Project, opts: Options, router: str, force: bool) -> tuple[Changes, list[str]]:
    if router not in ROUTERS:
        raise GeneratorError(f"unknown router '{router}' (available: {', '.join(ROUTERS)})")
    home = Names("home")
    changes = Changes(project)
    context = build_context(project, home, opts, catalog)
    context.update({
        "init": True,
        "router": router,
        "uses_sl": opts.state in ("bloc", "cubit", "provider"),
        "app_title": Names(project.package).title if re.fullmatch(r"[a-z][a-z0-9_]*", project.package) else project.package,
        "home_import": _package_uri(project, screen_rel(opts.features_dir, home, home)),
    })
    conditions = opts.conditions(catalog) | {"init"}
    messages: list[str] = []

    # shared lib/core files (never overwritten), then the app shell
    for prefix, target, is_core in (("core", "lib/core/", True), ("init", "", False)):
        for rel, source in catalog.under(prefix).items():
            out = _resolve_path(rel, conditions, home.snake)
            if out is None:
                continue
            content = _render_file(source, context)
            if content is None:
                continue
            out = target + out
            path = project.root / out
            if not path.exists():
                action = "create"
            elif force and not is_core:
                action = "overwrite"
            elif out in (MAIN_FILE, TEST_FILE) and _is_flutter_create_default(path.read_text(encoding="utf-8")):
                action = "overwrite"
            else:
                action = "skip"
                if out in (MAIN_FILE, TEST_FILE):
                    messages.append(f"{out} was changed by you, so it was kept; use --force to replace it")
            changes.add(PlannedFile(path=path, rel=out, content=content, layer="core" if is_core else "app",
                                    action=action, core=is_core))

    page = PageOptions(features_dir=opts.features_dir, path="/", route=router != "none", force=force,
                       consumer=opts.state in _RIVERPOD)
    messages += plan_page(changes, catalog, home, page)
    changes.files = dict(sorted(changes.files.items(), key=lambda kv: (kv[1].core, kv[0])))
    return changes, messages


def wire_features(changes: Changes, features: list[Names], features_dir: str, route: bool) -> list[str]:
    """After generating features: route their screens and call their DI initialisers from main()."""
    messages: list[str] = []
    for names in features:
        base = f"{features_dir.rstrip('/')}/{names.snake}"
        if route and changes.exists(screen_rel(features_dir, names, names)):
            try:
                message = register_route(changes, route_for(changes, features_dir, names, names))
            except GeneratorError as e:
                message = f"route not added: {e}"
            if message:
                messages.append(message)
        injection = f"{base}/{names.snake}_injection.dart"
        if changes.exists(injection):
            message = register_feature_init(changes, f"init{names.pascal}Feature", _package_uri(changes.project, injection))
            if message:
                messages.append(message)
    return messages
