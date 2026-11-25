"""'--fields name:string,price:number,role:enum(admin|user),bio:text?' -> zod schema, form controls, table cells."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .naming import Names, to_snake

TYPES = {
    "string": "text input",
    "text": "textarea",
    "number": "number input (float)",
    "int": "number input (integer)",
    "bool": "checkbox",
    "date": "date input (YYYY-MM-DD string)",
    "email": "email input",
    "url": "url input",
    "password": "password input",
    "enum(a|b)": "select with the given options",
}
_ALIASES = {"str": "string", "textarea": "text", "float": "number", "integer": "int", "boolean": "bool",
            "checkbox": "bool", "select": "enum"}
_SPEC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?::([a-z]+)(?:\(([^)]*)\))?)?(\?)?$")


class FieldError(ValueError):
    pass


@dataclass
class Field:
    name: str          # camelCase property name
    type: str          # one of TYPES (enum without options)
    optional: bool = False
    options: tuple[str, ...] = ()

    @property
    def label(self) -> str:
        return Names(to_snake(self.name)).title

    # ------------------------------------------------------------------ zod
    @property
    def zod(self) -> str:
        t = self.type
        if t == "enum":
            z = "z.enum([" + ", ".join(_q(o) for o in self.options) + "], { error: 'Pick one' })"
        elif t in ("number", "int"):
            z = "z.number({ error: 'Required' })" + (".int()" if t == "int" else "")
        elif t == "bool":
            z = "z.boolean()"
        elif t == "email":
            z = "z.email()" if not self.optional else "z.union([z.email(), z.literal('')])"
        elif t == "url":
            z = "z.url()" if not self.optional else "z.union([z.url(), z.literal('')])"
        elif self.optional:
            z = "z.string()"
        elif t == "password":
            z = "z.string().min(8, 'At least 8 characters')"
        else:
            z = "z.string().trim().min(1, 'Required')"
        return z + (".optional()" if self.optional and t != "bool" else "")

    # ------------------------------------------------------------------ form
    @property
    def ui(self) -> set[str]:
        return {"text": {"label", "textarea"}, "bool": {"label", "checkbox"}, "enum": {"label", "select"}}.get(
            self.type, {"label", "input"})

    def control(self) -> str:
        n, label = self.name, self.label
        error = f"{{errors.{n} && <p className=\"text-sm text-destructive\">{{errors.{n}.message}}</p>}}"
        if self.type == "bool":
            return "\n".join([
                "<div className=\"grid gap-2\">",
                "  <Controller",
                "    control={control}",
                f"    name=\"{n}\"",
                "    render={({ field }) => (",
                "      <div className=\"flex items-center gap-2\">",
                f"        <Checkbox id=\"{n}\" checked={{field.value ?? false}} onCheckedChange={{(v) => field.onChange(v === true)}} />",
                f"        <Label htmlFor=\"{n}\">{label}</Label>",
                "      </div>",
                "    )}",
                "  />",
                f"  {error}",
                "</div>",
            ])
        if self.type == "enum":
            items = [f"          <SelectItem value={_q(o)}>{Names(to_snake(o)).title or o}</SelectItem>" for o in self.options]
            return "\n".join([
                "<div className=\"grid gap-2\">",
                f"  <Label htmlFor=\"{n}\">{label}</Label>",
                "  <Controller",
                "    control={control}",
                f"    name=\"{n}\"",
                "    render={({ field }) => (",
                "      <Select value={field.value ?? ''} onValueChange={field.onChange}>",
                f"        <SelectTrigger id=\"{n}\" className=\"w-full\" aria-invalid={{!!errors.{n}}}>",
                f"          <SelectValue placeholder=\"Select {label.lower()}\" />",
                "        </SelectTrigger>",
                "        <SelectContent>",
                *(i[2:] for i in items),
                "        </SelectContent>",
                "      </Select>",
                "    )}",
                "  />",
                f"  {error}",
                "</div>",
            ])
        if self.type == "text":
            control = f"<Textarea id=\"{n}\" {{...register('{n}')}} aria-invalid={{!!errors.{n}}} />"
        else:
            html = {"number": "number", "int": "number", "date": "date", "email": "email", "url": "url",
                    "password": "password"}.get(self.type, "text")
            extra = ""
            if self.type in ("number", "int"):
                step = "1" if self.type == "int" else "any"
                extra = f" step=\"{step}\""
                reg = f"{{...register('{n}', {{ setValueAs: (v) => (v === '' || v == null ? undefined : Number(v)) }})}}"
            else:
                reg = f"{{...register('{n}')}}"
            auto = {"email": " autoComplete=\"email\"", "password": " autoComplete=\"current-password\""}.get(self.type, "")
            control = f"<Input id=\"{n}\" type=\"{html}\"{extra}{auto} {reg} aria-invalid={{!!errors.{n}}} />"
        return "\n".join([
            "<div className=\"grid gap-2\">",
            f"  <Label htmlFor=\"{n}\">{label}</Label>",
            f"  {control}",
            f"  {error}",
            "</div>",
        ])

    # ------------------------------------------------------------------ mock data
    def seed(self) -> str:
        """A JS expression for row number `i` in the mock data."""
        return {
            "string": f"`{self.label} ${{i}}`",
            "text": "`Notes for item ${i}`",
            "number": "i * 10.5",
            "int": "i * 3",
            "bool": "i % 2 === 1",
            "date": "`2026-01-${String((i % 28) + 1).padStart(2, '0')}`",
            "email": "`user${i}@example.com`",
            "url": "`https://example.com/${i}`",
            "password": "'secret123'",
            "enum": "([" + ", ".join(_q(o) for o in self.options) + f"] as const)[i % {len(self.options) or 1}]",
        }[self.type]

    def first_seed_text(self) -> str:
        """What the table shows for mock row 1."""
        return {
            "string": f"{self.label} 1", "text": "Notes for item 1", "number": "10.5", "int": "3", "bool": "Yes",
            "date": "2026-01-02", "email": "user1@example.com", "url": "https://example.com/1",
            "password": "••••••", "enum": self.options[1 % len(self.options)] if self.options else "",
        }[self.type]

    # ------------------------------------------------------------------ table
    def cell(self, row: str) -> str:
        v = f"{row}.{self.name}"
        if self.type == "bool":
            return f"{{{v} ? 'Yes' : 'No'}}"
        if self.type == "password":
            return "••••••"
        return f"{{String({v} ?? '')}}"


def _q(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def parse_fields(spec: str | None, default: str = "name:string") -> list[Field]:
    spec = spec or default
    out: list[Field] = []
    seen: set[str] = set()
    for raw in _split(spec):
        m = _SPEC.match(raw.strip())
        if not m:
            raise FieldError(f"bad field '{raw}': use name:type, e.g. price:number, role:enum(admin|user), bio:text?")
        name, type_, opts, optional = m.groups()
        type_ = _ALIASES.get(type_ or "string", type_ or "string")
        if type_ not in {t.split("(")[0] for t in TYPES}:
            raise FieldError(f"unknown field type '{type_}' in '{raw}' (types: {', '.join(TYPES)})")
        options: tuple[str, ...] = ()
        if type_ == "enum":
            options = tuple(o.strip() for o in (opts or "").split("|") if o.strip())
            if not options:
                raise FieldError(f"'{raw}': enum needs options, e.g. role:enum(admin|user)")
        camel = Names(to_snake(name)).camel if to_snake(name) else name
        if camel in seen or camel == "id":
            raise FieldError(f"field '{camel}' is repeated or reserved")
        seen.add(camel)
        out.append(Field(camel, type_, bool(optional), options))
    return out


def _split(spec: str) -> list[str]:
    """Split on commas that are not inside enum(...)."""
    parts, depth, current = [], 0, ""
    for ch in spec:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    parts.append(current)
    return [p for p in (x.strip() for x in parts) if p]


def schema_body(fields: list[Field]) -> str:
    return "\n".join(f"{f.name}: {f.zod}," for f in fields)


def default_values(fields: list[Field]) -> str:
    """Values a blank form starts with: '' for text inputs, false for checkboxes."""
    parts = []
    for f in fields:
        if f.type == "bool":
            parts.append(f"{f.name}: false")
        elif f.type not in ("number", "int", "enum"):
            parts.append(f"{f.name}: ''")
    return ", ".join(parts)


def ui_components(fields: list[Field]) -> list[str]:
    need = {"button"}
    for f in fields:
        need |= f.ui
    return sorted(need)


def ui_imports(fields: list[Field]) -> str:
    need = set(ui_components(fields))
    lines = []
    if "button" in need:
        lines.append("import { Button } from '@/components/ui/button'")
    if "checkbox" in need:
        lines.append("import { Checkbox } from '@/components/ui/checkbox'")
    if "input" in need:
        lines.append("import { Input } from '@/components/ui/input'")
    if "label" in need:
        lines.append("import { Label } from '@/components/ui/label'")
    if "select" in need:
        lines.append("import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'")
    if "textarea" in need:
        lines.append("import { Textarea } from '@/components/ui/textarea'")
    return "\n".join(lines)


def uses_controller(fields: list[Field]) -> bool:
    return any(f.type in ("bool", "enum") for f in fields)
