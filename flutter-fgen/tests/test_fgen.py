import tempfile
import unittest
from pathlib import Path

from fgen.assets import AssetsError, add_to_pubspec, group_constants, scan
from fgen.engine import Template, TemplateError
from fgen.generator import RESULT_MODES, Catalog, GeneratorError, Options, plan_feature, required_packages, write
from fgen.jsonmodel import ModelError, infer
from fgen.jsonmodel import generate as generate_model
from fgen.naming import parse_name, split_names, to_snake
from fgen.project import load as load_project
from fgen.scaffold import (
    Changes,
    PageOptions,
    default_router,
    insert_at_marker,
    plan_init,
    plan_page,
    wire_features,
)


class NamingTest(unittest.TestCase):
    def test_to_snake(self):
        for raw in ("UserProfile", "userProfile", "user-profile", "user profile", "USER_PROFILE", " user__profile "):
            self.assertEqual(to_snake(raw), "user_profile", raw)
        self.assertEqual(to_snake("HTTPClient"), "http_client")

    def test_cases(self):
        n = parse_name("user_profile")
        self.assertEqual((n.pascal, n.camel, n.kebab, n.title), ("UserProfile", "userProfile", "user-profile", "User Profile"))

    def test_invalid(self):
        for raw in ("2fa", "class", "", "a$b"):
            with self.assertRaises(ValueError, msg=raw):
                parse_name(raw)

    def test_split(self):
        self.assertEqual(split_names(["auth,profile", "cart", "auth"]), ["auth", "profile", "cart"])


class EngineTest(unittest.TestCase):
    def render(self, src, **ctx):
        return Template(src).render(ctx)

    def test_expressions_and_conditions(self):
        src = "a {{ x }}\n{% if x == 1 %}\none\n{% elif x == 2 %}\ntwo\n{% else %}\nother\n{% endif %}\nend\n"
        self.assertEqual(self.render(src, x=1), "a 1\none\nend\n")
        self.assertEqual(self.render(src, x=2), "a 2\ntwo\nend\n")
        self.assertEqual(self.render(src, x=3), "a 3\nother\nend\n")

    def test_standalone_expression_lines(self):
        src = "start\n    {{ body }}\n{{ empty }}\nend\n"
        self.assertEqual(self.render(src, body="x;\ny;", empty=""), "start\n    x;\n    y;\nend\n")

    def test_dart_syntax_untouched(self):
        src = "class _${{ p }} { final m = {'a': 1}; String s = '${x}'; }\n"
        self.assertEqual(self.render(src, p="Foo"), "class _$Foo { final m = {'a': 1}; String s = '${x}'; }\n")

    def test_errors(self):
        with self.assertRaises(TemplateError):
            Template("{% if x %}no end\n")
        with self.assertRaises(TemplateError):
            Template("{{ missing }}").render({})


class GeneratorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "pubspec.yaml").write_text(
            "name: demo_app\ndependencies:\n  flutter:\n    sdk: flutter\n  dio: ^5.0.0\ndev_dependencies:\n  build_runner: any\n",
            encoding="utf-8",
        )
        self.project = load_project(self.root)
        self.catalog = Catalog.load()

    def tearDown(self):
        self.tmp.cleanup()

    def all_options(self):
        for arch in self.catalog.archs:
            for state in self.catalog.states:
                for result in RESULT_MODES:
                    for model in ("freezed", "plain"):
                        yield Options(arch=arch, state=state, result=result, model=model)

    def test_every_combination_renders_cleanly(self):
        names = parse_name("user_profile")
        for opts in self.all_options():
            opts.validate(self.catalog)
            files = plan_feature(self.catalog, self.project, names, opts)
            self.assertTrue(any(f.rel.endswith("_screen.dart") for f in files), opts)
            for f in files:
                for leftover in ("{{", "{%", "NAME", "$v"):
                    self.assertNotIn(leftover, f.content, f"{opts} {f.rel}")
                self.assertNotIn("NAME", f.rel)

    def test_project_reading(self):
        self.assertEqual(self.project.package, "demo_app")
        self.assertEqual(self.project.dependencies, {"flutter", "dio"})
        self.assertEqual(self.project.dev_dependencies, {"build_runner"})

    def test_existing_files_are_kept_unless_forced(self):
        names = parse_name("auth")
        write(plan_feature(self.catalog, self.project, names, Options()))
        screen = self.root / "lib/features/auth/presentation/screens/auth_screen.dart"
        core = self.root / "lib/core/network/dio_service.dart"
        screen.write_text("// mine\n", encoding="utf-8")
        core.write_text("// mine\n", encoding="utf-8")

        again = plan_feature(self.catalog, self.project, names, Options())
        self.assertTrue(all(f.action == "skip" for f in again))

        forced = {f.rel: f.action for f in plan_feature(self.catalog, self.project, names, Options(force=True))}
        self.assertEqual(forced["lib/features/auth/presentation/screens/auth_screen.dart"], "overwrite")
        self.assertEqual(forced["lib/core/network/dio_service.dart"], "skip")

    def test_only_and_skip_layers(self):
        names = parse_name("auth")
        only = plan_feature(self.catalog, self.project, names, Options(only={"domain"}))
        self.assertEqual({f.layer for f in only}, {"domain"})
        skipped = plan_feature(self.catalog, self.project, names, Options(skip={"presentation", "core"}))
        self.assertEqual({f.layer for f in skipped}, {"domain", "data"})

    def test_required_packages(self):
        files = plan_feature(self.catalog, self.project, parse_name("auth"), Options(state="bloc", result="either"))
        deps, dev, needs_build = required_packages(files, self.project)
        self.assertIn("flutter_bloc", deps)
        self.assertIn("fpdart", deps)
        self.assertIn("get_it", deps)
        self.assertNotIn("dio", deps)  # already in pubspec
        self.assertIn("freezed", dev)
        self.assertNotIn("build_runner", dev)  # already in pubspec
        self.assertTrue(needs_build)

    def test_custom_template_root_overrides_builtin(self):
        custom = self.root / ".fgen" / "templates" / "state" / "riverpod" / "presentation" / "screens"
        custom.mkdir(parents=True)
        (custom / "NAME_screen.dart.tmpl").write_text("// custom {{ pascal }}\n", encoding="utf-8")
        catalog = Catalog.load([self.root / ".fgen" / "templates"])
        files = {f.rel: f for f in plan_feature(catalog, self.project, parse_name("auth"), Options())}
        self.assertEqual(files["lib/features/auth/presentation/screens/auth_screen.dart"].content, "// custom Auth\n")


class ScaffoldTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "pubspec.yaml").write_text("name: demo_app\ndependencies:\n  flutter:\n    sdk: flutter\n", encoding="utf-8")
        (self.root / "lib").mkdir()
        (self.root / "lib/main.dart").write_text("void main() => runApp(const MyApp());\nclass MyHomePage {}\n", encoding="utf-8")
        self.catalog = Catalog.load()

    def tearDown(self):
        self.tmp.cleanup()

    def init(self, **opts):
        project = load_project(self.root)
        router = default_router(opts.get("state", "riverpod"), opts.pop("no_router", False))
        changes, _ = plan_init(self.catalog, project, Options(**opts), router, force=False)
        write(changes.all())
        return load_project(self.root)

    def read(self, rel):
        return (self.root / rel).read_text(encoding="utf-8")

    def test_init_creates_shell_and_routes_home(self):
        self.init()
        for rel in ("lib/app.dart", "lib/core/theme/app_theme.dart", "lib/core/network/dio_client.dart",
                    "lib/core/config/env.dart", "env/dev.json", "lib/features/home/presentation/screens/home_screen.dart"):
            self.assertTrue((self.root / rel).is_file(), rel)
        self.assertIn("static const home = '/';", self.read("lib/core/router/app_routes.dart"))
        self.assertIn("=> const HomeScreen()", self.read("lib/core/router/app_router.dart"))
        self.assertIn("ProviderScope", self.read("lib/main.dart"))  # the counter app was replaced
        self.assertIn("ConsumerWidget", self.read("lib/features/home/presentation/screens/home_screen.dart"))

    def test_every_init_combination_renders_cleanly(self):
        project = load_project(self.root)
        for state in self.catalog.states:
            for arch in self.catalog.archs:
                for no_router in (False, True):
                    changes, _ = plan_init(self.catalog, project, Options(arch=arch, state=state),
                                           default_router(state, no_router), force=False)
                    for f in changes.all():
                        for leftover in ("{{", "{%", "NAME"):
                            self.assertNotIn(leftover, f.content, f"{arch} {state} {f.rel}")

    def test_user_main_is_kept(self):
        (self.root / "lib/main.dart").write_text("void main() {}\n", encoding="utf-8")
        self.init()
        self.assertEqual(self.read("lib/main.dart"), "void main() {}\n")

    def test_page_is_routed_once(self):
        project = self.init()
        changes = Changes(project)
        plan_page(changes, self.catalog, parse_name("about_us"), PageOptions())
        write(changes.all())
        routes = self.read("lib/core/router/app_routes.dart")
        self.assertIn("static const aboutUs = '/about-us';", routes)
        router = self.read("lib/core/router/app_router.dart")
        self.assertIn("import 'package:demo_app/features/about_us/presentation/screens/about_us_screen.dart';", router)

        again = Changes(load_project(self.root))
        messages = plan_page(again, self.catalog, parse_name("about_us"), PageOptions())
        self.assertIn("already routed", messages[0])
        self.assertEqual([f.action for f in again.all()], ["skip"])

    def test_route_conflicts(self):
        project = self.init()
        with self.assertRaises(GeneratorError):
            plan_page(Changes(project), self.catalog, parse_name("start"), PageOptions(path="/"))
        with self.assertRaises(GeneratorError):
            plan_page(Changes(project), self.catalog, parse_name("start"), PageOptions(route_name="home"))

    def test_bloc_feature_is_wired_into_main(self):
        project = self.init(state="bloc")
        names = parse_name("cart")
        changes = Changes(project)
        for f in plan_feature(self.catalog, project, names, Options(state="bloc")):
            changes.add(f)
        messages = wire_features(changes, [names], "lib/features", route=True)
        write(changes.all())
        main = self.read("lib/main.dart")
        self.assertIn("initCartFeature();", main)
        self.assertIn("import 'package:demo_app/features/cart/cart_injection.dart';", main)
        self.assertIn("setupCoreDependencies();", main)
        self.assertEqual(len(messages), 2)

    def test_getx_route_uses_binding(self):
        project = self.init(state="getx")
        names = parse_name("shop")
        changes = Changes(project)
        for f in plan_feature(self.catalog, project, names, Options(state="getx")):
            changes.add(f)
        wire_features(changes, [names], "lib/features", route=True)
        write(changes.all())
        self.assertIn("binding: ShopBinding()", self.read("lib/core/router/app_pages.dart"))

    def test_config_is_saved_and_loaded(self):
        project = load_project(self.root)
        project.save_config({"state": "bloc", "arch": "mvvm"})
        self.assertEqual(load_project(self.root).config, {"state": "bloc", "arch": "mvvm"})

    def test_insert_at_marker(self):
        text = "a\n    // fgen:routes\n"
        self.assertEqual(insert_at_marker(text, "routes", "x;"), "a\n    x;\n    // fgen:routes\n")
        self.assertEqual(insert_at_marker("a\n    x;\n    // fgen:routes\n", "routes", "x;"), "a\n    x;\n    // fgen:routes\n")
        self.assertIsNone(insert_at_marker("a\n", "routes", "x;"))


class JsonModelTest(unittest.TestCase):
    SAMPLE = [
        {"id": 1, "first_name": "A", "score": 2, "tags": ["x"], "address": {"city": "T"},
         "orders": [{"total": 1.5}], "class": "vip", "2fa": True, "email": None},
        {"id": 2, "first_name": "B", "score": 2.5, "tags": [], "address": {"city": "S"},
         "orders": [], "class": "a", "2fa": False, "email": "b@x.io", "extra": 1},
    ]

    def test_merge(self):
        t = infer(self.SAMPLE)
        item = t.item
        self.assertEqual(item.fields["score"].kind, "double")      # int + double
        self.assertEqual(item.fields["email"].kind, "String")      # null + String
        self.assertTrue(item.fields["email"].nullable)
        self.assertTrue(item.fields["extra"].nullable)            # missing from one sample
        self.assertEqual(item.fields["orders"].item.fields["total"].kind, "double")

    def test_plain(self):
        code = generate_model(self.SAMPLE, "User", "user", freezed=False)
        self.assertIn("class User {", code)
        self.assertIn("class Address {", code)
        self.assertIn("class Order {", code)                      # singular of 'orders'
        self.assertIn("firstName: json['first_name'] as String,", code)
        self.assertIn("score: (json['score'] as num).toDouble(),", code)
        self.assertIn("final String classValue;", code)            # reserved word
        self.assertIn("final bool n2fa;", code)                    # starts with a digit
        self.assertIn("'orders': orders.map((e) => e.toJson()).toList(),", code)
        self.assertIn("this.email,", code)
        self.assertIn("User copyWith({", code)

    def test_freezed(self):
        code = generate_model(self.SAMPLE, "User", "user", freezed=True)
        self.assertTrue(code.startswith("// ignore_for_file: invalid_annotation_target"))
        self.assertIn("part 'user.freezed.dart';", code)
        self.assertIn("@JsonKey(name: 'first_name') required String firstName,", code)
        self.assertIn("@JsonSerializable(explicitToJson: true)", code)

    def test_nested_names_do_not_clash(self):
        code = generate_model({"type": {"a": 1}, "item": {"b": 1}, "items": [{"c": 1}]}, "Box", "box", freezed=False)
        self.assertIn("class BoxType {", code)                     # 'Type' is a dart:core class
        self.assertIn("class Item {", code)
        self.assertIn("class BoxItem {", code)

    def test_nullable_flag_and_errors(self):
        code = generate_model({"id": 1}, "A", "a", freezed=False, all_nullable=True)
        self.assertIn("final int? id;", code)
        for bad in ([], 3, [1, 2]):
            with self.assertRaises(ModelError):
                generate_model(bad, "A", "a", freezed=False)


class AssetsTest(unittest.TestCase):
    def test_constants(self):
        files = ["assets/data.json", "assets/images/logo.png", "assets/images/logo.svg",
                 "assets/images/404.png", "assets/icons/social/google-g.svg"]
        groups = group_constants(files, "assets")
        self.assertEqual(list(groups), ["AppAssets", "AppIcons", "AppImages"])
        self.assertEqual(dict(groups["AppImages"]), {"logoPng": "assets/images/logo.png", "logoSvg": "assets/images/logo.svg",
                                                     "asset404": "assets/images/404.png"})
        self.assertEqual(groups["AppIcons"], [("socialGoogleG", "assets/icons/social/google-g.svg")])

    def test_scan_skips_fonts_hidden_and_variants(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in ("assets/a.png", "assets/2.0x/a.png", "assets/f.ttf", "assets/.DS_Store"):
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text("x")
            self.assertEqual(scan(root, "assets"), ["assets/a.png"])

    def test_pubspec_new_section(self):
        text, added = add_to_pubspec("name: x\n", ["assets/"])
        self.assertEqual(text, "name: x\n\nflutter:\n  assets:\n    - assets/\n")
        self.assertEqual(added, ["assets/"])

    def test_pubspec_without_assets_key(self):
        src = "name: x\nflutter:\n  uses-material-design: true\n  # assets:\n  #   - images/a.png\n"
        text, _ = add_to_pubspec(src, ["assets/images/"])
        self.assertIn("flutter:\n  assets:\n    - assets/images/\n  uses-material-design: true", text)

    def test_pubspec_existing_list(self):
        src = "flutter:\n  assets:\n    - assets/images/\n  fonts:\n    - family: A\n"
        text, added = add_to_pubspec(src, ["assets/images/", "assets/icons/"])
        self.assertEqual(added, ["assets/icons/"])
        self.assertIn("    - assets/images/\n    - assets/icons/\n  fonts:", text)
        with self.assertRaises(AssetsError):
            add_to_pubspec("flutter:\n  assets: [a/]\n", ["b/"])


if __name__ == "__main__":
    unittest.main()
