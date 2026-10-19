"""A tiny, dependency-free template engine.

Syntax
------
``{{ expr }}``
    Evaluates a Python expression against the context and inserts the result.
    When an expression is the only thing on its line, the line is dropped if the
    result is empty, and every line of a multi-line result is indented to match.

``{% if expr %}`` / ``{% elif expr %}`` / ``{% else %}`` / ``{% endif %}``
    Conditional blocks. A tag that sits alone on its line removes that whole line,
    so templates stay readable without leaving blank lines behind.

``{# comment #}``
    Ignored.
"""

from __future__ import annotations

import builtins
import re
from dataclasses import dataclass, field
from typing import Any, Union

_COMMENT = re.compile(r"\{#.*?#\}", re.S)
# A line holding only a tag, or only an expression.
_STANDALONE = re.compile(
    r"^[ \t]*(\{%(?:(?!%\}).)*%\})[ \t]*\r?\n"
    r"|^([ \t]*)\{\{((?:(?!\}\}).)*)\}\}[ \t]*\r?\n",
    re.M,
)
_TOKEN = re.compile(r"(\{%.*?%\}|\{\{.*?\}\})", re.S)

_SAFE_BUILTINS = {
    name: getattr(builtins, name)
    for name in ("len", "str", "int", "bool", "list", "dict", "any", "all", "sorted", "min", "max")
}


class TemplateError(Exception):
    pass


@dataclass
class _Text:
    value: str


@dataclass
class _Expr:
    expr: str
    indent: str | None = None  # set when the expression is alone on its line


@dataclass
class _If:
    branches: list[tuple[str, list]] = field(default_factory=list)
    otherwise: list | None = None


_Node = Union[_Text, _Expr, _If]


class Template:
    def __init__(self, source: str, name: str = "<template>"):
        self.name = name
        self._nodes = self._parse(self._preprocess(source))

    # ------------------------------------------------------------------ parsing
    @staticmethod
    def _preprocess(source: str) -> str:
        source = _COMMENT.sub("", source)

        def standalone(m: re.Match) -> str:
            if m.group(1):  # tag alone on its line: drop the line, keep the tag
                return m.group(1)
            # expression alone on its line: {{@<indent>@ expr }} is handled by the parser
            return "{{@" + m.group(2) + "@" + m.group(3) + "}}"

        return _STANDALONE.sub(standalone, source)

    def _parse(self, source: str) -> list[_Node]:
        root: list[_Node] = []
        stack: list[tuple[_If, list[_Node]]] = []
        current = root

        for token in _TOKEN.split(source):
            if not token:
                continue
            if token.startswith("{{"):
                inner = token[2:-2]
                if inner.startswith("@"):
                    indent, expr = inner[1:].split("@", 1)
                    current.append(_Expr(expr.strip(), indent))
                else:
                    current.append(_Expr(inner.strip()))
            elif token.startswith("{%"):
                words = token[2:-2].strip()
                keyword, _, arg = words.partition(" ")
                if keyword == "if":
                    node = _If()
                    current.append(node)
                    body: list[_Node] = []
                    node.branches.append((arg.strip(), body))
                    stack.append((node, current))
                    current = body
                elif keyword in ("elif", "else", "endif"):
                    if not stack:
                        raise TemplateError(f"{self.name}: unexpected {{% {keyword} %}}")
                    node, parent = stack[-1]
                    if keyword == "elif":
                        body = []
                        node.branches.append((arg.strip(), body))
                        current = body
                    elif keyword == "else":
                        node.otherwise = []
                        current = node.otherwise
                    else:
                        stack.pop()
                        current = parent
                else:
                    raise TemplateError(f"{self.name}: unknown tag {{% {words} %}}")
            else:
                current.append(_Text(token))

        if stack:
            raise TemplateError(f"{self.name}: missing {{% endif %}}")
        return root

    # ---------------------------------------------------------------- rendering
    def render(self, context: dict[str, Any]) -> str:
        scope = {"__builtins__": _SAFE_BUILTINS}
        out: list[str] = []
        self._render(self._nodes, context, scope, out)
        return "".join(out)

    def _eval(self, expr: str, context: dict[str, Any], scope: dict[str, Any]) -> Any:
        try:
            return eval(expr, scope, context)  # noqa: S307 - templates are trusted local files
        except Exception as e:  # pragma: no cover - message path
            raise TemplateError(f"{self.name}: error in '{expr}': {e}") from e

    def _render(self, nodes: list[_Node], context, scope, out: list[str]) -> None:
        for node in nodes:
            if isinstance(node, _Text):
                out.append(node.value)
            elif isinstance(node, _Expr):
                value = self._eval(node.expr, context, scope)
                text = "" if value is None else str(value)
                if node.indent is None:
                    out.append(text)
                elif text.strip():
                    lines = text.split("\n")
                    out.append("\n".join(node.indent + line if line else line for line in lines) + "\n")
            else:
                for cond, body in node.branches:
                    if self._eval(cond, context, scope):
                        self._render(body, context, scope, out)
                        break
                else:
                    if node.otherwise is not None:
                        self._render(node.otherwise, context, scope, out)


def render_string(source: str, context: dict[str, Any], name: str = "<template>") -> str:
    return Template(source, name).render(context)
