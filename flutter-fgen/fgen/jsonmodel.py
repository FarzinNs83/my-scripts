"""Dart model classes from a JSON sample ('fgen model')."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .naming import Names, to_snake

# Words that cannot be used as a Dart identifier.
_RESERVED = {
    "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum",
    "extends", "false", "final", "finally", "for", "if", "in", "is", "new", "null", "rethrow", "return",
    "super", "switch", "this", "throw", "true", "try", "var", "void", "while", "with",
}
# Members a model already has, so a JSON key cannot become a field with that name.
_TAKEN_MEMBERS = {"hashCode", "runtimeType", "toString", "noSuchMethod", "toJson", "copyWith", "fromJson"}
# dart:core types a nested class must not shadow.
_CORE_TYPES = {
    "BigInt", "Comparable", "DateTime", "Duration", "Enum", "Error", "Exception", "Function", "Future",
    "Iterable", "Iterator", "List", "Map", "Match", "Never", "Null", "Object", "Pattern", "Record",
    "RegExp", "Set", "Sink", "StackTrace", "Stream", "String", "Symbol", "Type", "Uri",
}


class ModelError(Exception):
    pass


# --------------------------------------------------------------------------- inference
@dataclass
class JType:
    kind: str                         # null | int | double | bool | String | dynamic | list | object
    nullable: bool = False
    item: "JType | None" = None       # list item (None for an empty list)
    fields: "dict[str, JType]" = field(default_factory=dict)  # object fields, in sample order
    cls: str = ""                     # object class name, set by _name_classes


def infer(value: object) -> JType:
    if value is None:
        return JType("null", nullable=True)
    if isinstance(value, bool):
        return JType("bool")
    if isinstance(value, int):
        return JType("int")
    if isinstance(value, float):
        return JType("double")
    if isinstance(value, str):
        return JType("String")
    if isinstance(value, list):
        item: JType | None = None
        for element in value:
            t = infer(element)
            item = t if item is None else merge(item, t)
        return JType("list", item=item)
    if isinstance(value, dict):
        return JType("object", fields={str(k): infer(v) for k, v in value.items()})
    raise ModelError(f"unsupported JSON value: {value!r}")


def merge(a: JType, b: JType) -> JType:
    """The type that fits both samples (used for list items and repeated objects)."""
    if a.kind == "null":
        return _with_nullable(b)
    if b.kind == "null":
        return _with_nullable(a)
    nullable = a.nullable or b.nullable
    if a.kind == b.kind and a.kind not in ("list", "object"):
        return JType(a.kind, nullable)
    if {a.kind, b.kind} == {"int", "double"}:
        return JType("double", nullable)
    if a.kind == b.kind == "list":
        if a.item is None or b.item is None:
            item = a.item or b.item
        else:
            item = merge(a.item, b.item)
        return JType("list", nullable, item=item)
    if a.kind == b.kind == "object":
        fields: dict[str, JType] = {}
        for key in [*a.fields, *(k for k in b.fields if k not in a.fields)]:
            if key in a.fields and key in b.fields:
                fields[key] = merge(a.fields[key], b.fields[key])
            else:  # missing from one of the samples
                fields[key] = _with_nullable(a.fields.get(key) or b.fields[key])
        return JType("object", nullable, fields=fields)
    return JType("dynamic", True)


def _with_nullable(t: JType) -> JType:
    return JType(t.kind, True, t.item, dict(t.fields))


# --------------------------------------------------------------------------- naming
def _singular(word: str) -> str:
    if word.endswith("ies") and len(word) > 4:
        return word[:-3] + "y"
    if word.endswith(("ses", "xes", "ches", "shes")):
        return word[:-2]
    if word.endswith("s") and not word.endswith("ss") and len(word) > 3:
        return word[:-1]
    return word


def _identifier_words(key: str) -> str:
    return to_snake(re.sub(r"[^A-Za-z0-9]+", " ", key))


def field_name(key: str, taken: set[str]) -> str:
    snake = _identifier_words(key)
    name = Names(snake).camel if snake else "field"
    if name[0].isdigit():
        name = "n" + name
    if name in _RESERVED or name in _TAKEN_MEMBERS:
        name += "Value"
    base, i = name, 2
    while name in taken:
        name, i = f"{base}{i}", i + 1
    taken.add(name)
    return name


def _class_base(key: str, plural: bool) -> str:
    snake = _identifier_words(key)
    if plural and snake:
        parts = snake.split("_")
        parts[-1] = _singular(parts[-1])
        snake = "_".join(parts)
    if not snake:
        return "Item"
    pascal = Names(snake).pascal
    return "N" + pascal if pascal[0].isdigit() else pascal


def _name_classes(t: JType, name: str, parent: str, used: set[str], out: list[JType]) -> None:
    candidate = name
    if candidate in used or candidate in _CORE_TYPES:
        candidate = parent + name
    final, i = candidate, 2
    while final in used or final in _CORE_TYPES:
        final, i = f"{candidate}{i}", i + 1
    used.add(final)
    t.cls = final
    out.append(t)
    for key, ft in t.fields.items():
        inner, plural = ft, False
        while inner.kind == "list" and inner.item is not None:
            inner, plural = inner.item, True
        if inner.kind == "object":
            _name_classes(inner, _class_base(key, plural), final, used, out)


# --------------------------------------------------------------------------- dart code
def _str(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$") + "'"


def dart_type(t: JType, nullable: bool) -> str:
    if t.kind in ("dynamic", "null"):
        return "dynamic"
    if t.kind == "list":
        inner = dart_type(t.item, t.item.nullable) if t.item else "dynamic"
        base = f"List<{inner}>"
    elif t.kind == "object":
        base = t.cls
    else:
        base = t.kind
    return base + ("?" if nullable else "")


def _var(depth: int) -> str:
    return "e" if depth == 0 else f"e{depth}"


def from_json(t: JType, v: str, nullable: bool, depth: int = 0) -> str:
    q = "?" if nullable else ""
    if t.kind in ("dynamic", "null"):
        return v
    if t.kind == "double":
        return f"({v} as num{q}){q}.toDouble()"
    if t.kind in ("int", "bool", "String"):
        return f"{v} as {t.kind}{q}"
    if t.kind == "object":
        call = f"{t.cls}.fromJson({v} as Map<String, dynamic>)"
        return f"{v} == null ? null : {call}" if nullable else call
    # list
    e = _var(depth)
    inner = from_json(t.item, e, t.item.nullable, depth + 1) if t.item else e
    if inner == e:
        return f"{v} as List<dynamic>{q}"
    return f"({v} as List<dynamic>{q}){q}.map(({e}) => {inner}).toList()"


def to_json(t: JType, x: str, nullable: bool, depth: int = 0) -> str:
    q = "?" if nullable else ""
    if t.kind == "object":
        return f"{x}{q}.toJson()"
    if t.kind == "list" and t.item is not None:
        e = _var(depth)
        inner = to_json(t.item, e, t.item.nullable, depth + 1)
        if inner != e:
            return f"{x}{q}.map(({e}) => {inner}).toList()"
    return x


@dataclass
class _Field:
    key: str
    name: str
    type: JType
    nullable: bool

    @property
    def dart(self) -> str:
        return dart_type(self.type, self.nullable)


def _fields(t: JType, all_nullable: bool) -> list[_Field]:
    taken: set[str] = set()
    return [_Field(key, field_name(key, taken), ft, ft.nullable or ft.kind in ("null", "dynamic") or all_nullable)
            for key, ft in t.fields.items()]


def _plain_class(t: JType, all_nullable: bool) -> str:
    fields = _fields(t, all_nullable)
    c = t.cls
    lines = [f"class {c} {{"]
    if fields:
        lines.append(f"  const {c}({{")
        lines += [f"    {'' if f.nullable else 'required '}this.{f.name}," for f in fields]
        lines.append("  });")
    else:
        lines.append(f"  const {c}();")
    lines += ["", f"  factory {c}.fromJson(Map<String, dynamic> json) {{", f"    return {c}("]
    lines += [f"      {f.name}: {from_json(f.type, f'json[{_str(f.key)}]', f.nullable)}," for f in fields]
    lines += ["    );", "  }", ""]
    lines += [f"  final {f.dart} {f.name};" for f in fields]
    if fields:
        lines.append("")
    lines += ["  Map<String, dynamic> toJson() {", "    return {"]
    lines += [f"      {_str(f.key)}: {to_json(f.type, f.name, f.nullable)}," for f in fields]
    lines += ["    };", "  }"]
    if fields:
        lines += ["", f"  {c} copyWith({{"]
        lines += [f"    {f.dart if f.dart.endswith('?') or f.dart == 'dynamic' else f.dart + '?'} {f.name}," for f in fields]
        lines += ["  }) {", f"    return {c}("]
        lines += [f"      {f.name}: {f.name} ?? this.{f.name}," for f in fields]
        lines += ["    );", "  }"]
    lines.append("}")
    return "\n".join(lines)


def _freezed_class(t: JType, all_nullable: bool) -> str:
    fields = _fields(t, all_nullable)
    c = t.cls
    nested = any(_has_object(f.type) for f in fields)
    lines = ["@freezed", f"abstract class {c} with _${c} {{"]
    if nested:
        lines.append("  @JsonSerializable(explicitToJson: true)")
    if fields:
        lines.append(f"  const factory {c}({{")
        for f in fields:
            key = f"@JsonKey(name: {_str(f.key)}) " if f.name != f.key else ""
            lines.append(f"    {key}{'' if f.nullable else 'required '}{f.dart} {f.name},")
        lines.append(f"  }}) = _{c};")
    else:
        lines.append(f"  const factory {c}() = _{c};")
    lines += ["", f"  factory {c}.fromJson(Map<String, dynamic> json) => _${c}FromJson(json);", "}"]
    return "\n".join(lines)


def _has_object(t: JType) -> bool:
    while t.kind == "list" and t.item is not None:
        t = t.item
    return t.kind == "object"


def generate(sample: object, class_name: str, file_stem: str, freezed: bool, all_nullable: bool = False) -> str:
    """Dart source for `class_name` (plus nested classes) described by the JSON `sample`."""
    root = infer(sample)
    while root.kind == "list":  # an array response: model its items
        if root.item is None:
            raise ModelError("the JSON array is empty; give a sample with at least one item")
        root = root.item
    if root.kind != "object":
        raise ModelError("the JSON sample must be an object (or an array of objects)")

    classes: list[JType] = []
    _name_classes(root, class_name, "", set(), classes)

    if freezed:
        bodies = [_freezed_class(c, all_nullable) for c in classes]
        header = [
            "import 'package:freezed_annotation/freezed_annotation.dart';",
            "",
            f"part '{file_stem}.freezed.dart';",
            f"part '{file_stem}.g.dart';",
        ]
        if any("@JsonKey" in b or "@JsonSerializable" in b for b in bodies):
            # json annotations on factory constructors are fine for freezed, but the analyzer warns about them
            header = ["// ignore_for_file: invalid_annotation_target", "", *header]
    else:
        header = []
        bodies = [_plain_class(c, all_nullable) for c in classes]
    parts = ["\n".join(header)] if header else []
    return "\n\n".join(parts + bodies) + "\n"
