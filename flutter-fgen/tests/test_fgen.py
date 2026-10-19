import tempfile
import unittest
from pathlib import Path

from fgen.engine import Template, TemplateError
from fgen.generator import RESULT_MODES, Catalog, Options, plan_feature, required_packages, write
from fgen.naming import parse_name, split_names, to_snake
from fgen.project import load as load_project


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


if __name__ == "__main__":
    unittest.main()
