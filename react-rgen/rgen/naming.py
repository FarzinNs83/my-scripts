"""Name normalisation and case conversion."""

from __future__ import annotations

import re
from dataclasses import dataclass

JS_RESERVED = {
    "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
    "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof",
    "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void",
    "while", "with", "yield", "let", "static", "implements", "interface", "package", "private",
    "protected", "public", "await",
}

_SNAKE = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+)*$")


def to_snake(raw: str) -> str:
    """'UserProfile', 'user-profile', 'user profile', 'userProfile' -> 'user_profile'."""
    s = raw.strip()
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    s = re.sub(r"[\s\-\.]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s.lower()


def pluralize(word: str) -> str:
    if re.search(r"[^aeiou]y$", word):
        return word[:-1] + "ies"
    if re.search(r"(s|x|z|ch|sh)$", word):
        return word + "es"
    return word + "s"


@dataclass(frozen=True)
class Names:
    snake: str

    @property
    def parts(self) -> list[str]:
        return [p for p in self.snake.split("_") if p]

    @property
    def pascal(self) -> str:
        return "".join(p[0].upper() + p[1:] for p in self.parts)

    @property
    def camel(self) -> str:
        pascal = self.pascal
        return pascal[0].lower() + pascal[1:]

    @property
    def kebab(self) -> str:
        return self.snake.replace("_", "-")

    @property
    def title(self) -> str:
        return " ".join(p[0].upper() + p[1:] for p in self.parts)

    @property
    def plural(self) -> "Names":
        parts = self.parts
        return Names("_".join(parts[:-1] + [pluralize(parts[-1])]))

    def as_dict(self) -> dict[str, str]:
        return {"snake": self.snake, "pascal": self.pascal, "camel": self.camel, "kebab": self.kebab, "title": self.title}


def parse_name(raw: str) -> Names:
    snake = to_snake(raw)
    if not _SNAKE.match(snake):
        raise ValueError(f"invalid name '{raw}': use letters, digits and separators, starting with a letter")
    if snake in JS_RESERVED:
        raise ValueError(f"invalid name '{raw}': '{snake}' is a reserved word")
    return Names(snake)


def split_names(values: list[str]) -> list[str]:
    """Accept 'auth,profile', 'auth, profile' and 'auth profile' forms."""
    out: list[str] = []
    for value in values:
        for piece in re.split(r"[,\s]+", value):
            if piece and piece not in out:
                out.append(piece)
    return out
