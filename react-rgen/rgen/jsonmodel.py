"""zod schemas + TypeScript types from a JSON sample ('rgen model').

The type inference (infer / merge / class naming) is the same as fgen's jsonmodel.py.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .naming import Names, to_snake


class ModelError(Exception):
    pass


@dataclass
class JType:
    kind: str                         # null | int | double | bool | String | dynamic | list | object
    nullable: bool = False
    item: "JType | None" = None
    fields: "dict[str, JType]" = field(default_factory=dict)
    cls: str = ""


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
        item = (a.item or b.item) if a.item is None or b.item is None else merge(a.item, b.item)
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


def _singular(word: str) -> str:
    if word.endswith("ies") and len(word) > 4:
        return word[:-3] + "y"
    if word.endswith(("ses", "xes", "ches", "shes")):
        return word[:-2]
    if word.endswith("s") and not word.endswith("ss") and len(word) > 3:
        return word[:-1]
    return word


def _class_base(key: str, plural: bool) -> str:
    snake = to_snake(re.sub(r"[^A-Za-z0-9]+", " ", key))
    if plural and snake:
        parts = snake.split("_")
        parts[-1] = _singular(parts[-1])
        snake = "_".join(parts)
    if not snake:
        return "Item"
    pascal = Names(snake).pascal
    return "N" + pascal if pascal[0].isdigit() else pascal


def _name_classes(t: JType, name: str, parent: str, used: set[str], out: list[JType]) -> None:
    candidate = name if name not in used else parent + name
    final, i = candidate, 2
    while final in used:
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


# --------------------------------------------------------------------------- zod
_IDENT = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$]*$")


def schema_var(cls: str) -> str:
    return cls[0].lower() + cls[1:] + "Schema"


def zod_type(t: JType) -> str:
    if t.kind in ("null", "dynamic"):
        return "z.unknown()"
    base = {
        "String": "z.string()",
        "int": "z.number()",  # a sample's 2 may be 2.5 in the next response
        "double": "z.number()",
        "bool": "z.boolean()",
    }.get(t.kind)
    if base is None and t.kind == "list":
        base = f"z.array({zod_type(t.item) if t.item else 'z.unknown()'})"
    if base is None:
        base = schema_var(t.cls)
    return base + (".nullish()" if t.nullable else "")


def _key(k: str) -> str:
    return k if _IDENT.match(k) else "'" + k.replace("\\", "\\\\").replace("'", "\\'") + "'"


def generate(sample: object, class_name: str, all_nullable: bool = False) -> str:
    """TypeScript source with a zod schema and an inferred type for `class_name` and its nested objects."""
    root = infer(sample)
    while root.kind == "list":
        if root.item is None:
            raise ModelError("the JSON array is empty; give a sample with at least one item")
        root = root.item
    if root.kind != "object":
        raise ModelError("the JSON sample must be an object (or an array of objects)")
    root.nullable = False

    classes: list[JType] = []
    _name_classes(root, class_name, "", set(), classes)

    blocks = []
    for c in reversed(classes):  # nested schemas first, so every reference is already declared
        lines = [f"export const {schema_var(c.cls)} = z.object({{"]
        for key, ft in c.fields.items():
            z = zod_type(ft)
            if all_nullable and not z.endswith(".nullish()") and z != "z.unknown()":
                z += ".nullish()"
            lines.append(f"  {_key(key)}: {z},")
        lines.append("})")
        lines.append(f"export type {c.cls} = z.infer<typeof {schema_var(c.cls)}>")
        blocks.append("\n".join(lines))
    return "import { z } from 'zod'\n\n" + "\n\n".join(blocks) + "\n"
