"""Name normalisation and case conversion for feature names."""

from __future__ import annotations

import re
from dataclasses import dataclass

DART_RESERVED = {
    "abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class",
    "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum",
    "export", "extends", "extension", "external", "factory", "false", "final", "finally", "for",
    "function", "get", "hide", "if", "implements", "import", "in", "interface", "is", "late",
    "library", "mixin", "new", "null", "of", "on", "operator", "part", "required", "rethrow",
    "return", "sealed", "set", "show", "static", "super", "switch", "sync", "this", "throw",
    "true", "try", "type", "typedef", "var", "void", "when", "while", "with", "yield",
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

    def as_dict(self) -> dict[str, str]:
        return {
            "snake": self.snake,
            "pascal": self.pascal,
            "camel": self.camel,
            "kebab": self.kebab,
            "title": self.title,
        }


def parse_name(raw: str) -> Names:
    snake = to_snake(raw)
    if not _SNAKE.match(snake):
        raise ValueError(
            f"invalid feature name '{raw}': use letters, digits and separators, starting with a letter"
        )
    if snake in DART_RESERVED:
        raise ValueError(f"invalid feature name '{raw}': '{snake}' is a reserved word in Dart")
    return Names(snake)


def split_names(values: list[str]) -> list[str]:
    """Accept 'auth,profile', 'auth, profile' and 'auth profile' forms."""
    out: list[str] = []
    for value in values:
        for piece in re.split(r"[,\s]+", value):
            if piece and piece not in out:
                out.append(piece)
    return out


def lower_first(s: str) -> str:
    return s[:1].lower() + s[1:]
