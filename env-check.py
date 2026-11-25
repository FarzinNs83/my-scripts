#!/usr/bin/env python3
"""Compare development configuration keys without printing their values."""

import argparse
import json
import re
import sys
from pathlib import Path


ENV_TEMPLATES = (".env.example", ".env.sample", ".env.template", ".env.dist", "example.env", "env.example")
ASSIGNMENT = re.compile(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*")


def read_dotenv(path):
    keys = {}
    duplicates = set()
    quote = None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if quote is None:
            match = ASSIGNMENT.match(line)
            if not match:
                continue
            key = match[1]
            if key in keys:
                duplicates.add(key)
            value = line[match.end():].strip()
            keys[key] = bool(value and not value.startswith("#"))
            if value[:1] not in ("'", '"', "`"):
                continue
            quote = value[0]
            line = value[1:]
            if re.match(re.escape(quote) + r"\s*(?:#.*)?$", line):
                keys[key] = False
        closing = re.search(r"(?:^|[^\\])(?:\\\\)*" + re.escape(quote), line)
        if closing:
            quote = None
    if quote is not None:
        raise ValueError(f"Unterminated quoted value in {path}")
    return keys, duplicates


def read_config(path):
    if path.suffix.lower() != ".json":
        return read_dotenv(path)

    duplicates = set()

    def collect(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                duplicates.add(key)
            result[key] = value
        return result

    try:
        values = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=collect)
    except json.JSONDecodeError as error:
        raise ValueError(f"Invalid JSON in {path} at line {error.lineno}, column {error.colno}") from None
    if not isinstance(values, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    if any(isinstance(value, (dict, list)) for value in values.values()):
        raise ValueError(f"Expected scalar configuration values in {path}")
    return {key: value is not None and value != "" for key, value in values.items()}, duplicates


def find_inputs(root, args):
    if args.template:
        template = root / args.template
    else:
        template = next((root / name for name in ENV_TEMPLATES if (root / name).is_file()), None)
        if template is None and (root / "env" / "dev.json").is_file():
            template = root / "env" / "dev.json"
        if template is None:
            raise ValueError(f"No .env template or env/dev.json in {root}; pass --template.")

    if args.files:
        return template, [[root / name] for name in args.files]
    if template.suffix.lower() == ".json":
        if args.mode:
            raise ValueError("Use --file to select a Flutter environment file.")
        files = sorted(path for path in template.parent.glob("*.json") if path != template and path.is_file())
        if not files:
            raise ValueError("No other JSON environments found; pass --file.")
        return template, [[path] for path in files]

    names = [".env"]
    if args.mode:
        names += [".env.local", f".env.{args.mode}", f".env.{args.mode}.local"]
    files = [root / name for name in names if (root / name).is_file()]
    if not files:
        raise ValueError("No configuration files found. Looked for " + ", ".join(names) + ".")
    return template, [files]


def show_issue(label, keys):
    if keys:
        print(f"  {label}: " + ", ".join(sorted(keys)))


def compare(template, groups, strict):
    expected, duplicates = read_config(template)
    if not expected:
        raise ValueError(f"No configuration keys in {template}")
    print(f"Template: {template}")
    show_issue("Duplicate keys in template", duplicates)
    failed = bool(duplicates)
    for files in groups:
        actual = {}
        repeated = False
        print("Checking " + " + ".join(map(str, files)))
        for path in files:
            keys, duplicates = read_config(path)
            if duplicates:
                show_issue(f"Duplicate keys in {path.name}", duplicates)
                repeated = True
            actual.update(keys)
        missing = expected.keys() - actual.keys()
        empty = {key for key in expected.keys() & actual.keys() if not actual[key]}
        extra = actual.keys() - expected.keys()
        show_issue("Missing", missing)
        show_issue("Empty", empty)
        show_issue("Undocumented", extra)
        if not (missing or empty or extra or repeated):
            print(f"  OK ({len(actual)} keys)")
        failed |= bool(missing or empty or repeated or (strict and extra))
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", nargs="?", default=".", type=Path, help="project directory (default: current directory)")
    parser.add_argument("--template", type=Path, help="reference dotenv or JSON file, relative to the project")
    parser.add_argument("--file", dest="files", action="append", type=Path, help="file to check; repeat to compare each independently")
    parser.add_argument("--mode", help="check the merged Vite env files for this mode")
    parser.add_argument("--strict", action="store_true", help="also fail on undocumented keys")
    args = parser.parse_args()
    if args.mode and (args.files or not re.fullmatch(r"[A-Za-z0-9_-]+", args.mode)):
        parser.error("pass a simple mode name and use either --mode or --file")
    try:
        template, groups = find_inputs(args.project.resolve(), args)
        return compare(template, groups, args.strict)
    except (OSError, ValueError) as error:
        print(f"env-check: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
