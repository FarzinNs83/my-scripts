"""What every command writes: files from templates, route/nav/env/mock registration, and package lists."""

from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

from . import fields as fieldmod
from .engine import Template
from .naming import Names, parse_name, to_snake
from .project import Changes, Project, ProjectError, insert_at_marker

TEMPLATES = Path(__file__).parent / "templates"
OVERRIDES = ".rgen/templates"  # 'rgen eject' copies the templates here; files found here win

PATHS_FILE = "src/app/paths.ts"
ROUTER_FILE = "src/app/router.tsx"
NAV_FILE = "src/app/nav.ts"
ENV_FILE = "src/lib/env.ts"
MOCK_HANDLERS = "src/mocks/handlers.ts"
TEST_RENDER = "src/test/render.tsx"

DEPS = [
    "react", "react-dom", "react-router", "@tanstack/react-query", "@tanstack/react-query-devtools", "axios",
    "zustand", "zod", "react-hook-form", "@hookform/resolvers", "usehooks-ts", "sonner", "lucide-react",
]
DEV_DEPS = [
    "vite", "@vitejs/plugin-react", "typescript", "@types/react", "@types/react-dom", "@types/node",
    "tailwindcss", "@tailwindcss/vite", "eslint", "@eslint/js", "typescript-eslint", "eslint-plugin-react-hooks",
    "eslint-plugin-react-refresh", "globals", "prettier", "prettier-plugin-tailwindcss",
]
I18N_DEPS = ["i18next", "react-i18next", "i18next-browser-languagedetector"]
MSW_DEPS = ["msw"]
TEST_DEPS = ["vitest", "jsdom", "@testing-library/react", "@testing-library/user-event", "@testing-library/jest-dom"]
LAYOUTS = ("header", "sidebar")

LOGIN_FIELDS = "email:email,password:password"
REGISTER_FIELDS = "name:string,email:email,password:password"


class GeneratorError(Exception):
    pass


# --------------------------------------------------------------------------- templates
def render(project: Project, rel: str, context: dict) -> str:
    override = project.root / OVERRIDES / rel
    path = override if override.is_file() else TEMPLATES / rel
    if not path.is_file():
        raise GeneratorError(f"template '{rel}' not found")
    return Template(path.read_text(encoding="utf-8"), rel).render(context)


def base_context(project: Project) -> dict:
    c = project.config
    return {
        "title": c.get("title", "App"), "i18n": bool(c.get("i18n")), "rtl": bool(c.get("rtl")),
        "sidebar": c.get("layout") == "sidebar", "mocks": bool(c.get("mocks")), "tests": bool(c.get("tests")),
        "pm": project.pm, "name": project.package.get("name") or Names(to_snake(project.root.name) or "app").kebab,
    }


def _tree(project: Project, changes: Changes, folder: str, dest: str, context: dict, name: str = "",
          skip: tuple[str, ...] = ()) -> None:
    """Render every template under templates/<folder> into <dest>, replacing NAME in file names."""
    root = TEMPLATES / folder
    for path in sorted(root.rglob("*.tmpl")):
        rel = path.relative_to(root).as_posix()
        target = rel[: -len(".tmpl")].replace("NAME", name)
        if target in skip:
            continue
        changes.add(f"{dest}/{target}".lstrip("/"), render(project, f"{folder}/{rel}", context))


# --------------------------------------------------------------------------- registration
def register_route(changes: Changes, key: str, path: str, module: str, *, protected: bool = False,
                   bare: bool = False, nav_label: str | None = None) -> None:
    paths, router = changes.read(PATHS_FILE), changes.read(ROUTER_FILE)
    if paths is None or router is None or "rgen:paths" not in paths:
        changes.note(f"route not added: {PATHS_FILE} / {ROUTER_FILE} with rgen markers not found (run 'rgen init')")
        return
    existing = re.search(rf"^\s*{key}:\s*'([^']*)'", paths, re.M)
    if existing and existing.group(1) != path:
        raise GeneratorError(f"paths.{key} already exists with '{existing.group(1)}'; pass --path or another name")
    if re.search(rf"^\s*\w+:\s*'{re.escape(path)}',", paths, re.M) and not existing:
        raise GeneratorError(f"the path '{path}' is already used in {PATHS_FILE}; pass --path")
    marker = "bare-routes" if bare else "protected-routes" if protected else "routes"
    new_paths = insert_at_marker(paths, "paths", f"{key}: '{path}',")
    new_router = insert_at_marker(router, marker, f"{{ path: paths.{key}, lazy: page(() => import('{module}')) }},")
    if new_paths is None or new_router is None:
        changes.note(f"route not added: '// rgen:paths' or '// rgen:{marker}' marker missing")
        return
    if new_paths != paths:
        changes.edit(PATHS_FILE, new_paths)
    if new_router != router:
        changes.edit(ROUTER_FILE, new_router)
    where = " (bare)" if bare else " (signed-in only)" if protected else ""
    changes.note(f"route {path} -> {module}{where}")
    nav = changes.read(NAV_FILE)
    if nav_label and nav is not None:
        new_nav = insert_at_marker(nav, "nav", f"{{ label: '{nav_label}', to: paths.{key} }},")
        if new_nav and new_nav != nav:
            changes.edit(NAV_FILE, new_nav)
            changes.note(f"nav link '{nav_label}'")


def register_mocks(changes: Changes, var: str, module: str) -> None:
    """Add a feature's mock handlers to src/mocks/handlers.ts."""
    text = changes.read(MOCK_HANDLERS)
    if text is None:
        return
    new = insert_at_marker(text, "mock-imports", f"import {{ {var} }} from '{module}'")
    new = insert_at_marker(new, "mock-handlers", f"...{var},") if new else None
    if new is None:
        changes.note(f"mock handlers not registered: rgen markers missing in {MOCK_HANDLERS}")
    elif new != text:
        changes.edit(MOCK_HANDLERS, new)
        changes.note(f"fake API: {var} added to {MOCK_HANDLERS}")


def missing_ui(project: Project, components: list[str]) -> list[str]:
    return [c for c in components if not (project.root / "src/components/ui" / f"{c}.tsx").is_file()]


# --------------------------------------------------------------------------- init
I18N_FILES = ("src/lib/i18n.ts", "src/locales/en.json", "src/locales/fa.json", "src/components/language-toggle.tsx")
MOCK_FILES = ("src/mocks/handlers.ts", "src/mocks/utils.ts")
TEST_FILES = ("src/test/setup.ts", "src/test/server.ts", "src/test/render.tsx")


def plan_init(project: Project, changes: Changes, *, title: str, i18n: bool, rtl: bool, fresh: bool,
              layout: str = "header", mocks: bool = True, tests: bool = True, ci: bool = True) -> list[str]:
    """Plan the project files. Returns warnings about an existing project that need a manual step."""
    project.config.update({"title": title, "i18n": i18n, "rtl": rtl, "layout": layout, "mocks": mocks,
                           "tests": tests})
    ctx = base_context(project)
    warnings: list[str] = []
    base = {
        "index.html": "index.html", "public/favicon.svg": "favicon.svg", "vite.config.ts": "vite.config.ts",
        "tsconfig.json": "tsconfig.json", "tsconfig.app.json": "tsconfig.app.json",
        "tsconfig.node.json": "tsconfig.node.json", "eslint.config.js": "eslint.config.js",
        ".prettierrc": "prettierrc", ".gitignore": "gitignore", "src/index.css": "index.css",
        ".vscode/extensions.json": "vscode-extensions.json",
    }
    scripts = {
        "dev": "vite",
        "build": "tsc -b && vite build",
        "preview": "vite preview",
        "lint": "eslint .",
        "typecheck": "tsc -b",
        "format": "prettier --write src",
    }
    if tests:
        scripts.update({"test": "vitest", "test:run": "vitest run"})
    if fresh:
        changes.add("package.json", json.dumps({
            "name": ctx["name"], "private": True, "version": "0.0.0", "type": "module", "scripts": scripts,
        }, indent=2) + "\n")
        for dest, src in base.items():
            changes.add(dest, render(project, f"base/{src}.tmpl", ctx))
    else:
        pkg = json.loads(changes.read("package.json") or "{}")
        missing = {k: v for k, v in scripts.items() if k not in pkg.setdefault("scripts", {})}
        if missing:
            pkg["scripts"].update(missing)
            changes.edit("package.json", json.dumps(pkg, indent=2) + "\n")
        for dest in (".prettierrc", "public/favicon.svg", ".vscode/extensions.json"):
            changes.add(dest, render(project, f"base/{base[dest]}.tmpl", ctx))
        vite_files = ("vite.config.ts", "vite.config.js", "vite.config.mts")
        vite = next((changes.read(f) for f in vite_files if changes.exists(f)), None)
        if vite is None or ("@tailwindcss/vite" not in vite and "'@'" not in vite):
            changes.add("vite.config.ts", render(project, "base/vite.config.ts.tmpl", ctx))
            if vite is not None:
                changes.files["vite.config.ts"].action = "overwrite"
        else:
            if "@tailwindcss/vite" not in vite or "'@'" not in vite:
                warnings.append("vite.config: add the tailwindcss() plugin and the '@' -> ./src alias "
                                "(see templates/base/vite.config.ts)")
            if tests and "test:" not in vite:
                warnings.append("vite.config: add the 'test' block for vitest (see templates/base/vite.config.ts)")
        tsconfig = changes.read("tsconfig.json") or ""
        if '"@/*"' not in tsconfig:
            warnings.append('tsconfig.json and tsconfig.app.json: add "paths": { "@/*": ["./src/*"] } to compilerOptions')
        css = changes.read("src/index.css")
        if css is None or "tailwindcss" not in css:
            changes.add("src/index.css", render(project, "base/index.css.tmpl", ctx))
            if css is not None:
                changes.files["src/index.css"].action = "overwrite"
    if ci:
        changes.add(".github/workflows/ci.yml", render(project, "base/ci.yml.tmpl", ctx))

    app = TEMPLATES / "app"
    for path in sorted(app.rglob("*.tmpl")):
        rel = path.relative_to(app).as_posix()[: -len(".tmpl")]
        if (not i18n and rel in I18N_FILES) or (not tests and rel in TEST_FILES) \
                or (not (mocks or tests) and rel in MOCK_FILES) or (not mocks and rel == "src/mocks/browser.ts"):
            continue
        f = changes.add(rel, render(project, f"app/{rel}.tmpl", ctx))
        if rel == "src/main.tsx" and f.action == "skip" and not fresh:
            f.action = "overwrite"  # the Vite starter's main.tsx is replaced by the router setup
    for stale in ("src/App.tsx", "src/App.css"):
        if (project.root / stale).is_file():
            warnings.append(f"{stale} from the Vite starter is no longer used; delete it")

    env_line = "VITE_API_URL=http://localhost:3000/api\n"
    changes.add(".env.example", env_line + ("VITE_MOCK_API=false\n" if mocks else ""))
    changes.add(".env", env_line)
    if mocks:
        changes.add(".env.development", "# Only for 'npm run dev': true = the fake API in src/mocks answers, "
                                        "false = the real API at VITE_API_URL.\nVITE_MOCK_API=true\n")
    plan_agents(project, changes)
    return warnings


def rtl_css(css: str) -> str:
    """Vazirmatn (self-hosted from npm, Google Fonts is unreliable in Iran) as the first sans font."""
    if "vazirmatn" in css.lower():
        return css
    imp = '@import "@fontsource-variable/vazirmatn";'
    if '@import "tailwindcss";' in css:
        css = css.replace('@import "tailwindcss";', '@import "tailwindcss";\n' + imp, 1)
    else:
        css = imp + "\n" + css
    new, count = re.subn(r"--font-sans:\s*", "--font-sans: 'Vazirmatn Variable', ", css, count=1)
    if count:
        return new
    return css.rstrip() + "\n\n@theme inline {\n  --font-sans: 'Vazirmatn Variable', ui-sans-serif, system-ui, sans-serif;\n}\n"


def fix_shadcn(project: Project) -> None:
    """shadcn's sonner.tsx reads the theme from next-themes; point it at this app's ThemeProvider."""
    sonner = project.root / "src/components/ui/sonner.tsx"
    if sonner.is_file() and (project.root / "src/components/theme-provider.tsx").is_file():
        text = sonner.read_text(encoding="utf-8")
        fixed = re.sub(r"""import \{ useTheme \} from ["']next-themes["']""",
                       'import { useTheme } from "@/components/theme-provider"', text)
        if fixed != text:
            sonner.write_text(fixed, encoding="utf-8")


# --------------------------------------------------------------------------- AI instructions
AGENTS_START, AGENTS_END = "<!-- rgen:start -->", "<!-- rgen:end -->"

AGENTS_BLOCK = """<!-- rgen:start -->
## Code generation: use rgen, do not hand-write boilerplate

This project was set up with `rgen` (Vite + React + TypeScript, Tailwind v4, shadcn/ui, React Router,
TanStack Query, axios, zustand, react-hook-form + zod, MSW, Vitest). Generate structure with rgen, then
write only the real logic inside the generated files. Run `rgen list --json` for every command and option.
Add `-n` to any command to preview the files without writing them.

| Need | Command |
| --- | --- |
| CRUD feature (types, API, query hooks, table, form, list + detail pages, routes, nav, fake API, test) | `rgen feature product --fields "name:string,price:number,active:bool,category:enum(a\\|b)"` |
| Server-side search + pagination | add `--paginated` |
| API + hooks only, no UI | add `--no-ui` |
| A page with a route | `rgen page settings [--in feature] [--path /settings/:tab] [--protected] [--bare] [--nav]` |
| A form (zod + react-hook-form + shadcn) | `rgen form contact --fields "email:email,message:text" [--in feature]` |
| Types + zod schema from a JSON response | `rgen model User --file user.json [--in feature]` |
| Login / register / token refresh | `rgen auth` |
| Component / zustand store / hook | `rgen component Avatar`, `rgen store cart --persist`, `rgen hook use-thing` |
| Environment variable | `rgen env STRIPE_KEY --default ""` (typed in src/lib/env.ts) |
| shadcn/ui components or blocks | `rgen ui calendar sheet` / `rgen ui login-03 dashboard-01` |
| Animated components (React Bits) | `rgen bits SplitText Aurora` (`rgen bits --list`) |
| Other registries | `rgen add @magicui/marquee @aceternity/3d-card-effect` |
| Client + hooks from an OpenAPI spec | `rgen openapi https://api.example.com/openapi.json` |
| Dockerfile + nginx for the built app | `rgen docker` |

Field types: string, text, number, int, bool, date, email, url, password, enum(a|b); add `?` for optional.

Conventions
- Feature code lives in `src/features/<name>/` (types.ts, api.ts, hooks.ts, mocks.ts, components/, pages/).
- HTTP goes through `apiClient` (`src/lib/api-client.ts`); errors are `ApiError` (`src/lib/api-error.ts`).
- Server state lives in TanStack Query hooks; client state in zustand stores. No fetch in components.
- Route paths live in `src/app/paths.ts`; use `paths.x` and `href()` instead of string literals.
- `npm run dev` uses the fake API in `src/mocks` while `VITE_MOCK_API=true` (.env.development); when you add
  an endpoint, add its handler to the feature's `mocks.ts` too. Tests use the same handlers.
- Tests: `renderWithProviders` from `src/test/render.tsx`; run `npm run test:run` and `npm run lint` before
  you finish.
- Do not remove the `// rgen:...` marker comments: rgen inserts routes, nav links, env vars and mocks there.
- Before writing a hook, check `usehooks-ts` (useDebounceValue, useLocalStorage, useMediaQuery, ...).
- Before writing a UI component, check shadcn/ui (`rgen ui`) and React Bits (`rgen bits --list`).
<!-- rgen:end -->"""


def plan_agents(project: Project, changes: Changes) -> None:
    current = changes.read("AGENTS.md")
    if current is None:
        changes.add("AGENTS.md", "# Agent instructions\n\n" + AGENTS_BLOCK + "\n")
    else:
        if AGENTS_START in current and AGENTS_END in current:
            start, end = current.index(AGENTS_START), current.index(AGENTS_END) + len(AGENTS_END)
            text = current[:start] + AGENTS_BLOCK + current[end:]
        else:
            text = current.rstrip() + "\n\n" + AGENTS_BLOCK + "\n"
        if text != current:
            changes.edit("AGENTS.md", text)
    claude = changes.read("CLAUDE.md")
    if claude is None:
        changes.add("CLAUDE.md", "@AGENTS.md\n")
    elif "@AGENTS.md" not in claude:
        changes.edit("CLAUDE.md", claude.rstrip() + "\n\n@AGENTS.md\n")


# --------------------------------------------------------------------------- feature
def _feature_dir(feature: str) -> str:
    return f"src/features/{parse_name(feature).kebab}"


def plan_form(project: Project, changes: Changes, name: Names, fields: list[fieldmod.Field], dest: str, *,
              schema_from: str | None = None, schema_name: str | None = None, values_type: str | None = None) -> None:
    """A <name>-form.tsx. With schema_from the schema is imported (feature/auth); otherwise it is inline."""
    controller = fieldmod.uses_controller(fields)
    defaults = fieldmod.default_values(fields)
    ctx = {
        **base_context(project),
        "n": name,
        "schema_inline": schema_from is None,
        "schema_name": schema_name or f"{name.camel}FormSchema",
        "values_type": values_type or f"{name.pascal}FormValues",
        "schema_from": schema_from or "",
        "schema_body": fieldmod.schema_body(fields),
        "rhf_imports": ", ".join(["Controller"] * controller + ["useForm", "type Path"]),
        "ui_imports": fieldmod.ui_imports(fields),
        "controller": controller,
        "uses_register": any(f.type not in ("bool", "enum") for f in fields),
        "defaults_expr": f"{{ {defaults}, ...defaultValues }}" if defaults else "defaultValues",
        "controls": "\n".join(f.control() for f in fields),
    }
    changes.add(f"{dest}/{name.kebab}-form.tsx", render(project, "form/NAME-form.tsx.tmpl", ctx))


def plan_feature(project: Project, changes: Changes, raw: str, fields: list[fieldmod.Field], *, endpoint: str | None,
                 ui: bool, protected: bool, nav: bool, paginated: bool = False, detail: bool = True) -> list[str]:
    """Returns the shadcn components the feature needs."""
    n = parse_name(raw)
    p = n.plural
    dest = _feature_dir(raw)
    module = f"@/features/{n.kebab}"
    detail = detail and ui
    ctx = {**base_context(project), "n": n, "p": p, "endpoint": endpoint or f"/{p.kebab}",
           "schema_body": fieldmod.schema_body(fields), "paginated": paginated, "detail": detail,
           "seed": "\n".join(f"{f.name}: {f.seed()}," for f in fields), "seed_count": 25 if paginated else 5}
    for rel in ("types.ts", "api.ts", "hooks.ts", "index.ts"):
        changes.add(f"{dest}/{rel}", render(project, f"feature/{rel}.tmpl", ctx))
    if changes.exists(MOCK_HANDLERS):
        changes.add(f"{dest}/mocks.ts", render(project, "feature/mocks.ts.tmpl", ctx))
        register_mocks(changes, f"{n.camel}Handlers", f"{module}/mocks")
    if not ui:
        return []

    heads = "\n".join(f"<TableHead>{f.label}</TableHead>" for f in fields)
    cells = [f"<TableCell>{f.cell('item')}</TableCell>" for f in fields]
    if detail:
        link = f"<Link to={{href(paths.{n.camel}Detail, {{ id: item.id }})}} className=\"font-medium hover:underline\">"
        cells[0] = f"<TableCell>\n  {link}\n    {fields[0].cell('item')}\n  </Link>\n</TableCell>"
    changes.add(f"{dest}/components/{n.kebab}-table.tsx", render(
        project, "feature/components/NAME-table.tsx.tmpl", {**ctx, "heads": heads, "cells": "\n".join(cells)}))
    plan_form(project, changes, n, fields, f"{dest}/components", schema_from="../types",
              schema_name=f"{n.camel}InputSchema", values_type=f"{n.pascal}Input")
    changes.add(f"{dest}/pages/{n.kebab}-list-page.tsx", render(project, "feature/pages/NAME-list-page.tsx.tmpl", ctx))
    register_route(changes, p.camel, f"/{p.kebab}", f"{module}/pages/{n.kebab}-list-page",
                   protected=protected, nav_label=p.title if nav else None)
    needed = set(fieldmod.ui_components(fields)) | {"table", "dialog", "alert-dialog"}
    if paginated:
        needed.add("input")

    if detail:
        title_field = next((f for f in fields if f.type == "string"), None)
        heading = f"{{String(data.{title_field.name} ?? '')}}" if title_field else f"{n.title} #{{data.id}}"
        rows = "\n".join(
            f"<dt className=\"text-sm text-muted-foreground\">{f.label}</dt>\n<dd>{f.cell('data')}</dd>" for f in fields)
        changes.add(f"{dest}/pages/{n.kebab}-detail-page.tsx", render(
            project, "feature/pages/NAME-detail-page.tsx.tmpl", {**ctx, "heading": heading, "rows": rows}))
        register_route(changes, f"{n.camel}Detail", f"/{p.kebab}/:id", f"{module}/pages/{n.kebab}-detail-page",
                       protected=protected)
        needed.add("card")

    if changes.exists(TEST_RENDER) and changes.exists(MOCK_HANDLERS):
        has_required = any(not f.optional and f.type != "bool" for f in fields)
        first = fields[0].first_seed_text()
        changes.add(f"{dest}/pages/{n.kebab}-list-page.test.tsx", render(
            project, "feature/pages/NAME-list-page.test.tsx.tmpl",
            {**ctx, "first_value": json.dumps(first, ensure_ascii=False), "has_required": has_required}))
    return sorted(needed)


def plan_page(project: Project, changes: Changes, raw: str, *, feature: str | None, path: str | None,
              protected: bool, bare: bool, nav: bool, route: bool) -> None:
    n = parse_name(raw)
    dest = f"{_feature_dir(feature or raw)}/pages"
    url = path or f"/{n.kebab}"
    if not url.startswith("/"):
        url = "/" + url  # Git Bash turns a leading '/' into a Windows path, so it may be left out
    params = re.findall(r":(\w+)", url)
    params_jsx = " ".join(f"{p}: {{{p}}}" for p in params)
    ctx = {**base_context(project), "n": n, "params": params, "params_jsx": params_jsx}
    rel = f"{dest}/{n.kebab}-page.tsx"
    changes.add(rel, render(project, "page/NAME-page.tsx.tmpl", ctx))
    if route:
        module = "@/" + rel[len("src/"):-len(".tsx")]
        register_route(changes, n.camel, url, module, protected=protected, bare=bare,
                       nav_label=n.title if nav and not params else None)


def plan_auth(project: Project, changes: Changes) -> list[str]:
    dest = "src/features/auth"
    login, register = fieldmod.parse_fields(LOGIN_FIELDS), fieldmod.parse_fields(REGISTER_FIELDS)
    ctx = {**base_context(project), "login_body": fieldmod.schema_body(login),
           "register_body": fieldmod.schema_body(register)}
    mocks = changes.exists(MOCK_HANDLERS)
    _tree(project, changes, "auth", dest, ctx, skip=() if mocks else ("mocks.ts",))
    if mocks:
        register_mocks(changes, "authHandlers", "@/features/auth/mocks")
        changes.note("fake login: any email with the password 'password'")
    plan_form(project, changes, parse_name("login"), login, f"{dest}/components", schema_from="../types",
              schema_name="loginSchema", values_type="LoginValues")
    plan_form(project, changes, parse_name("register"), register, f"{dest}/components", schema_from="../types",
              schema_name="registerSchema", values_type="RegisterValues")
    register_route(changes, "login", "/login", "@/features/auth/pages/login-page", bare=True)
    register_route(changes, "register", "/register", "@/features/auth/pages/register-page", bare=True)
    return ["button", "card", "input", "label"]


# --------------------------------------------------------------------------- small files
def plan_component(project: Project, changes: Changes, raw: str, feature: str | None) -> str:
    n = parse_name(raw)
    dest = f"{_feature_dir(feature)}/components" if feature else "src/components"
    rel = f"{dest}/{n.kebab}.tsx"
    changes.add(rel, render(project, "component/NAME.tsx.tmpl", {"n": n}))
    return rel


def plan_store(project: Project, changes: Changes, raw: str, feature: str | None, persist: bool) -> str:
    n = parse_name(re.sub(r"[-_ ]?store$", "", raw, flags=re.I) or raw)
    dest = _feature_dir(feature) if feature else "src/stores"
    rel = f"{dest}/{n.kebab}-store.ts"
    changes.add(rel, render(project, "store/NAME-store.ts.tmpl", {"n": n, "persist": persist}))
    return rel


def plan_hook(project: Project, changes: Changes, raw: str, feature: str | None) -> str:
    base = re.sub(r"^use[-_ ]?", "", to_snake(raw)) or raw
    n = parse_name("use_" + base)
    dest = f"{_feature_dir(feature)}/hooks" if feature else "src/hooks"
    rel = f"{dest}/{n.kebab}.ts"
    changes.add(rel, render(project, "hook/NAME.ts.tmpl", {"fn": n.camel}))
    return rel


def plan_env(changes: Changes, raw: str, default: str | None, optional: bool) -> str:
    key = to_snake(raw).upper()
    if not re.match(r"^[A-Z][A-Z0-9_]*$", key):
        raise GeneratorError(f"invalid variable name '{raw}'")
    if not key.startswith("VITE_"):
        key = "VITE_" + key
    env = changes.read(ENV_FILE)
    if env is None or "rgen:env" not in env:
        raise GeneratorError(f"{ENV_FILE} with a '// rgen:env' marker not found (run 'rgen init')")
    if re.search(rf"^\s*{key}:", env, re.M):
        raise GeneratorError(f"{key} is already in {ENV_FILE}")
    zod = "z.string()"
    if default is not None:
        zod += f".default({json.dumps(default)})"
    elif optional:
        zod += ".optional()"
    else:
        zod += ".min(1)"
    changes.edit(ENV_FILE, insert_at_marker(env, "env", f"{key}: {zod},"))  # type: ignore[arg-type]
    for f in (".env.example", ".env"):
        text = changes.read(f)
        if f == ".env.example" and text is None:
            text = ""
        if text is None or re.search(rf"^{key}=", text, re.M):
            continue
        new = (text.rstrip("\n") + "\n" if text.strip() else "") + f"{key}={default or ''}\n"
        if changes.exists(f):
            changes.edit(f, new)
        else:
            changes.add(f, new)
    return key


def plan_openapi(project: Project, changes: Changes, spec: str) -> None:
    ctx = {"spec": spec.replace("\\", "/").replace("'", "\\'")}
    changes.add("orval.config.ts", render(project, "openapi/orval.config.ts.tmpl", ctx))
    changes.add("src/lib/orval-mutator.ts", render(project, "openapi/orval-mutator.ts.tmpl", ctx))
    pkg = changes.read("package.json")
    if pkg is not None:
        data = json.loads(pkg)
        scripts = data.setdefault("scripts", {})
        if scripts.get("api") != "orval":
            scripts["api"] = "orval"
            changes.edit("package.json", json.dumps(data, indent=2) + "\n")


def plan_docker(project: Project, changes: Changes) -> None:
    ctx = base_context(project)
    for dest, src in (("Dockerfile", "Dockerfile"), ("nginx.conf", "nginx.conf"), (".dockerignore", "dockerignore")):
        changes.add(dest, render(project, f"docker/{src}.tmpl", ctx))


def eject(project: Project, force: bool) -> list[str]:
    target = project.root / OVERRIDES
    copied = []
    for path in sorted(TEMPLATES.rglob("*.tmpl")):
        rel = path.relative_to(TEMPLATES).as_posix()
        dest = target / rel
        if dest.exists() and not force:
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
        copied.append(f"{OVERRIDES}/{rel}")
    return copied


def require_project(project: Project) -> None:
    if not project.exists:
        raise ProjectError("not inside a project (package.json not found); run 'rgen init' first")
