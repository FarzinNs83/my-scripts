import contextlib
import io
import json
import re
import tempfile
import unittest
from pathlib import Path

from rgen import catalog
from rgen.cli import main
from rgen.fields import FieldError, parse_fields
from rgen.jsonmodel import ModelError, generate
from rgen.naming import parse_name, pluralize
from rgen.project import insert_at_marker


def run(*args: str) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = main(list(args))
    return code, out.getvalue()


class NamingTest(unittest.TestCase):
    def test_cases_and_plural(self):
        n = parse_name("OrderItem")
        self.assertEqual((n.kebab, n.camel, n.pascal, n.title), ("order-item", "orderItem", "OrderItem", "Order Item"))
        self.assertEqual(n.plural.kebab, "order-items")
        self.assertEqual([pluralize(w) for w in ("category", "box", "day", "user")], ["categories", "boxes", "days", "users"])

    def test_invalid(self):
        for raw in ("2fa", "class", "", "a$b"):
            with self.assertRaises(ValueError, msg=raw):
                parse_name(raw)


class FieldsTest(unittest.TestCase):
    def test_parse(self):
        f = parse_fields("title,price:number,status:enum(draft|live),notes:text?,ok:boolean")
        self.assertEqual([(x.name, x.type, x.optional) for x in f],
                         [("title", "string", False), ("price", "number", False), ("status", "enum", False),
                          ("notes", "text", True), ("ok", "bool", False)])
        self.assertEqual(f[2].options, ("draft", "live"))
        self.assertIn("z.enum(['draft', 'live']", f[2].zod)
        self.assertEqual(f[3].zod, "z.string().optional()")

    def test_errors(self):
        for spec in ("a:nope", "role:enum()", "a,a", "id:string", "9x:string"):
            with self.assertRaises(FieldError, msg=spec):
                parse_fields(spec)


class ModelTest(unittest.TestCase):
    def test_nested_schemas_declared_first(self):
        code = generate({"id": 1, "user-name": "a", "tags": ["x"], "address": {"city": "c"},
                         "items": [{"n": 1}, {"n": 2.5, "x": None}]}, "Order")
        self.assertLess(code.index("export const itemSchema"), code.index("export const orderSchema"))
        self.assertLess(code.index("export const addressSchema"), code.index("export const orderSchema"))
        self.assertIn("'user-name': z.string()", code)
        self.assertIn("x: z.unknown(),", code)  # unknown already allows null and a missing key
        self.assertIn("items: z.array(itemSchema)", code)

    def test_bad_sample(self):
        with self.assertRaises(ModelError):
            generate([], "X")
        with self.assertRaises(ModelError):
            generate(3, "X")


class MarkerTest(unittest.TestCase):
    def test_insert(self):
        text = "a\n  // rgen:routes\n"
        once = insert_at_marker(text, "routes", "x,")
        self.assertEqual(once, "a\n  x,\n  // rgen:routes\n")
        self.assertEqual(insert_at_marker(once, "routes", "x,"), once)
        self.assertIsNone(insert_at_marker("a\n", "routes", "x,"))


class CatalogTest(unittest.TestCase):
    def test_bits(self):
        self.assertEqual(catalog.resolve_bits("split-text"), ("SplitText", True))
        self.assertEqual(catalog.resolve_bits("crtwarp"), ("CRTWarp", True))
        self.assertFalse(catalog.resolve_bits("brand-new-thing")[1])
        self.assertIn("SplitText", catalog.suggest_bits("splt-text"))


class ProjectFlowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "shop"

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, rel: str) -> str:
        return (self.root / rel).read_text(encoding="utf-8")

    def assert_rendered(self):
        for path in self.root.rglob("*"):
            if path.is_file():
                text = path.read_text(encoding="utf-8")
                self.assertNotRegex(text, r"\{\{|\{%", f"unrendered template syntax in {path}")

    def test_full_flow(self):
        code, out = run("-C", self.tmp.name, "init", "shop", "--no-install", "--i18n", "--rtl")
        self.assertEqual(code, 0, out)
        pkg = json.loads(self.read("package.json"))
        self.assertEqual(pkg["scripts"]["build"], "tsc -b && vite build")
        self.assertIn('dir="rtl"', self.read("index.html"))
        self.assertIn("rgen:start", self.read("AGENTS.md"))
        self.assertEqual(self.read("CLAUDE.md").strip(), "@AGENTS.md")
        self.assertTrue((self.root / "src/lib/i18n.ts").is_file())
        self.assertIn("Direction.Provider dir={dir}", self.read("src/app/providers.tsx"))
        self.assertEqual(json.loads(self.read(".rgen/config.json"))["rtl"], True)

        c = str(self.root)
        self.assertEqual(run("-C", c, "auth")[0], 0)
        code, out = run("-C", c, "feature", "product", "--fields",
                        "name,price:number,status:enum(a|b),active:bool,notes:text?", "--protected")
        self.assertEqual(code, 0, out)
        self.assertIn("needs shadcn components", out)  # no components.json in this test
        self.assertEqual(run("-C", c, "page", "product-detail", "--in", "product", "--path", "products/:id")[0], 0)
        self.assertEqual(run("-C", c, "form", "contact", "--fields", "email:email,msg:text")[0], 0)
        self.assertEqual(run("-C", c, "model", "User", "--json", '{"id": 1, "geo": {"lat": 1.5}}')[0], 0)
        self.assertEqual(run("-C", c, "store", "cart-store", "--persist")[0], 0)
        self.assertEqual(run("-C", c, "hook", "useCountdown")[0], 0)
        self.assertEqual(run("-C", c, "component", "UserAvatar", "--in", "product")[0], 0)
        self.assertEqual(run("-C", c, "env", "stripe-key", "--optional")[0], 0)

        paths = self.read("src/app/paths.ts")
        for line in ("login: '/login',", "products: '/products',", "productDetail: '/products/:id',"):
            self.assertIn(line, paths)
        router = self.read("src/app/router.tsx")
        protected = router[router.index("<ProtectedRoute />"):router.index("rgen:protected-routes")]
        self.assertIn("paths.products", protected)
        bare = router[router.index("rgen:routes"):]
        self.assertIn("paths.login", bare[bare.index("pages without the app layout"):])
        self.assertIn("{ label: 'Products', to: paths.products },", self.read("src/app/nav.ts"))
        self.assertIn("VITE_STRIPE_KEY: z.string().optional(),", self.read("src/lib/env.ts"))
        self.assertIn("VITE_STRIPE_KEY=", self.read(".env.example"))
        form = self.read("src/features/product/components/product-form.tsx")
        self.assertIn("import { productInputSchema, type ProductInput } from '../types'", form)
        self.assertIn("Controller, useForm, type Path", form)
        self.assertIn("defaultValues: { name: '', active: false, notes: '', ...defaultValues }", form)
        self.assertIn("useParams", self.read("src/features/product/pages/product-detail-page.tsx"))
        for rel in ("src/stores/cart-store.ts", "src/hooks/use-countdown.ts",
                    "src/features/product/components/user-avatar.tsx", "src/models/user.ts",
                    "src/components/forms/contact-form.tsx", "src/features/auth/components/register-form.tsx"):
            self.assertTrue((self.root / rel).is_file(), rel)
        self.assert_rendered()

        # running a generator again keeps files and does not duplicate registrations
        code, out = run("-C", c, "feature", "product", "--protected")
        self.assertIn("exists, skipped", out)
        self.assertEqual(self.read("src/app/paths.ts").count("products: '/products'"), 1)
        self.assertNotEqual(run("-C", c, "env", "stripe-key")[0], 0)
        self.assertNotEqual(run("-C", c, "page", "products", "--path", "/other")[0], 0)  # paths.products taken

    def test_mocks_tests_detail_paginated(self):
        code, out = run("-C", self.tmp.name, "init", "shop", "--no-install", "--layout", "sidebar")
        self.assertEqual(code, 0, out)
        c = str(self.root)
        self.assertIn("VITE_MOCK_API=true", self.read(".env.development"))
        self.assertIn("onUnhandledFrame", self.read("src/main.tsx"))
        self.assertIn("SidebarProvider", self.read("src/components/layout/app-layout.tsx"))
        self.assertIn("vitest run", self.read("package.json"))
        self.assertIn("npm run test:run", self.read(".github/workflows/ci.yml"))
        self.assertTrue((self.root / ".vscode/extensions.json").is_file())

        self.assertEqual(run("-C", c, "auth")[0], 0)
        self.assertEqual(run("-C", c, "feature", "product", "--fields", "name,active:bool", "--paginated")[0], 0)
        self.assertEqual(run("-C", c, "feature", "flag", "--fields", "on:bool", "--no-detail")[0], 0)
        handlers = self.read("src/mocks/handlers.ts")
        for line in ("import { authHandlers } from '@/features/auth/mocks'", "...productHandlers,", "...flagHandlers,"):
            self.assertIn(line, handlers)
        mocks = self.read("src/features/product/mocks.ts")
        self.assertIn("length: 25", mocks)
        self.assertIn("pageSize: result.pageSize", mocks)
        self.assertIn("`Name ${i}`", mocks)
        self.assertIn("Paginated<Product>", self.read("src/features/product/api.ts"))
        self.assertIn("keepPreviousData", self.read("src/features/product/hooks.ts"))
        self.assertIn("useSearchParams", self.read("src/features/product/pages/product-list-page.tsx"))
        self.assertIn("productDetail: '/products/:id',", self.read("src/app/paths.ts"))
        self.assertIn("href(paths.productDetail", self.read("src/features/product/components/product-table.tsx"))
        self.assertIn("findAllByText(\"Name 1\")", self.read("src/features/product/pages/product-list-page.test.tsx"))
        self.assertFalse((self.root / "src/features/flag/pages/flag-detail-page.tsx").exists())
        flag_form = self.read("src/features/flag/components/flag-form.tsx")
        self.assertNotIn("register,", flag_form)  # only a checkbox: no register()
        self.assertIn("import { Label }", flag_form)
        self.assertIn("'Flag created'", self.read("src/features/flag/pages/flag-list-page.test.tsx"))

        self.assertEqual(run("-C", c, "docker")[0], 0)
        self.assertIn("try_files $uri $uri/ /index.html", self.read("nginx.conf"))
        self.assertIn("npm ci", self.read("Dockerfile"))
        self.assert_rendered()

    def test_no_mocks_no_tests(self):
        code, out = run("-C", self.tmp.name, "init", "shop", "--no-install", "--no-mocks", "--no-tests", "--no-ci")
        self.assertEqual(code, 0, out)
        self.assertFalse((self.root / "src/mocks").exists())
        self.assertFalse((self.root / "src/test").exists())
        self.assertFalse((self.root / ".github").exists())
        self.assertNotIn("VITE_MOCK_API", self.read("src/lib/env.ts"))
        self.assertEqual(run("-C", str(self.root), "feature", "note")[0], 0)
        self.assertFalse((self.root / "src/features/note/mocks.ts").exists())
        self.assertFalse((self.root / "src/features/note/pages/note-list-page.test.tsx").exists())
        self.assert_rendered()

    def test_existing_vite_project(self):
        self.root.mkdir()
        (self.root / "package.json").write_text(json.dumps({"name": "x", "devDependencies": {"vite": "^7"}}))
        (self.root / "src").mkdir()
        (self.root / "src/main.tsx").write_text("old")
        (self.root / "src/App.tsx").write_text("old")
        (self.root / "vite.config.ts").write_text("import react from '@vitejs/plugin-react'\nexport default {}\n")
        code, out = run("-C", str(self.root), "init", "--no-install")
        self.assertEqual(code, 0, out)
        self.assertIn("RouterProvider", self.read("src/main.tsx"))
        self.assertIn("tailwindcss()", self.read("vite.config.ts"))
        self.assertIn("src/App.tsx from the Vite starter is no longer used", out)
        self.assertIn('"@/*"', out)  # tsconfig paths warning

    def test_dry_run_writes_nothing(self):
        code, out = run("-C", self.tmp.name, "init", "shop", "--no-install", "-n")
        self.assertEqual(code, 0, out)
        self.assertIn("dry run", out)
        self.assertFalse(self.root.exists())

    def test_list_json(self):
        code, out = run("list", "--json")
        data = json.loads(out)
        self.assertIn("feature", data["commands"])
        self.assertIn("@react-bits", data["registries"])
        self.assertGreater(sum(len(v) for v in data["react_bits"].values()), 150)


if __name__ == "__main__":
    unittest.main()
