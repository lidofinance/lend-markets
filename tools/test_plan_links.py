#!/usr/bin/env python3
"""Link every repository path and test that TEST_PLAN.md cites: a path to its file, a test to its declaring line.

The plan names tests bare. A test without a path is in the first file of its contract's `Tests:` line; a `### `
heading or a numbered acceptance stage that names test files sets them for the lines under it; and a `path: names`
segment (segments split on `;`) overrides that for the segment. In a contract section (a `### ` heading naming a
`src/` file), each member a numbered item names (`fn(types)`, `Event(types)` or a bare name) links to its
declaration: in the section's file first, else in the one `src/` file that declares it; an inherited or unknown name
stays plain. The script drops the links it made before and links the plan again, so the line anchors follow every
edit. With `--check` it changes nothing and exits 1 when the plan is stale or cites a test that its file does not
declare.

usage: tools/test_plan_links.py [--check]    (`make test-plan`, `make test-plan-check`)
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLAN = ROOT / "TEST_PLAN.md"

OWN_LINK = re.compile(r"\[(`[^`]+`)\]\([^)\s]+\)")
CODE = re.compile(r"(`[^`]*`)")
REPO_PATH = re.compile(r"((?:src|test|script)/[A-Za-z0-9_./-]*[A-Za-z0-9_/])(?::(\d+))?")
BARE_PATH = re.compile(r"(?<![\w/.<>-])((?:src|test|script)/[A-Za-z0-9_./-]*[A-Za-z0-9_])")
TEST_NAME = re.compile(r"(?:test|invariant)[A-Za-z0-9_]*")
TEST_FILE = re.compile(r"`(test/[^`]+\.sol)`")
SRC_FILE = re.compile(r"`(src/[^`]+\.sol)`")
MEMBER = re.compile(r"(\w+)(?:\(([^()]*)\))?")
NOT_A_TYPE = {"memory", "calldata", "storage", "indexed", "payable"}

_declarations = {}
_members = {}


def _strip_comments(text):
    """Blanks out comments, keeping every newline so line numbers hold."""
    return re.sub(r"//[^\n]*|/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)


def _param_types(params):
    """Parameter types of a declaration or a plan signature, without data locations, names or qualifiers."""
    types = []
    for param in params.split(","):
        words = [w for w in param.split() if w not in NOT_A_TYPE]
        if words:
            types.append(words[0].split(".")[-1])
    return tuple(types)


def members(path):
    """`(name, parameter types, line, has body)` of every function, constructor, receive/fallback, event, error and
    modifier `path` declares, and `(name, None, line, True)` of its public state variables. Only a bodiless function
    (an interface or abstract declaration) has no body."""
    if path not in _members:
        text = _strip_comments((ROOT / path).read_text())
        found = []
        declaration = r"\b(?:(?:function|event|error|modifier)\s+(\w+)|(constructor|receive|fallback))\s*\("
        for m in re.finditer(declaration, text):
            close = text.index(")", m.end())
            line = text.count("\n", 0, m.start()) + 1
            ends = re.search(r"[{;]", text[close:])
            body = not m.group(0).startswith("function") or (ends is not None and ends.group(0) == "{")
            found.append((m.group(1) or m.group(2), _param_types(text[m.end() : close]), line, body))
        variable = r"^[ \t]*[\w.]+(?:\[\])*[ \t]+(?:\w+[ \t]+)*?public[ \t]+(?:\w+[ \t]+)*?(\w+)[ \t]*(?:=|;)"
        for m in re.finditer(variable, text, re.M):
            found.append((m.group(1), None, text.count("\n", 0, m.start()) + 1, True))
        _members[path] = found
    return _members[path]


def member_link(code, section_files):
    """Link target of the member `code` names, or None. A declaration with a body wins over a bodiless one, and an
    exact signature over a lone name match."""
    match = MEMBER.fullmatch(code)
    if not match:
        return None
    name = match.group(1)
    types = _param_types(match.group(2)) if match.group(2) is not None else None

    def pick(paths, unique):
        hits = [(p, t, line, body) for p in paths for n, t, line, body in members(p) if n == name]
        hits = [h for h in hits if h[3]] or hits
        exact = [h for h in hits if types is not None and h[1] == types]
        for group in (exact, hits):
            if group and (len(group) == 1 or (not unique and group is exact)):
                return group[0]
        return None

    all_src = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "src").rglob("*.sol"))
    hit = pick(section_files, unique=False) or pick(all_src, unique=True)
    return f"{hit[0]}#L{hit[2]}" if hit else None


def link_members(text, section_files):
    """Links each code span of a numbered item: a path to its file, a member to its declaration."""
    out = []
    for piece in CODE.split(quote_bare_paths_outside_code(text)):
        if piece.startswith("`") and piece.endswith("`") and len(piece) > 1:
            target = member_link(piece[1:-1], section_files)
            out.append(f"[{piece}]({target})" if target else link_path(piece))
        else:
            out.append(piece)
    return "".join(out)


def declared_line(path, name):
    """1-based line of `function <name>(` in `path`, or None."""
    if path not in _declarations:
        lines = (ROOT / path).read_text().splitlines() if (ROOT / path).is_file() else []
        found = {}
        for number, line in enumerate(lines, 1):
            match = re.match(r"\s*function\s+(\w+)\s*\(", line)
            if match and match.group(1) not in found:
                found[match.group(1)] = number
        _declarations[path] = found
    return _declarations[path].get(name)


def link_path(code):
    """`path` or `path:N` as a link to the file (and line), when it exists; anything else unchanged."""
    match = REPO_PATH.fullmatch(code[1:-1])
    if not match or not (ROOT / match.group(1)).exists():
        return code
    target = match.group(1) + (f"#L{match.group(2)}" if match.group(2) else "")
    return f"[{code}]({target})"


def quote_bare_paths(text):
    """Puts every existing bare repository path in a code span, so it is linked like the quoted ones."""
    return BARE_PATH.sub(lambda m: f"`{m.group(1)}`" if (ROOT / m.group(1)).exists() else m.group(1), text)


def quote_bare_paths_outside_code(text):
    """`quote_bare_paths` on the text between code spans."""
    pieces = CODE.split(text)
    return "".join(p if p.startswith("`") else quote_bare_paths(p) for p in pieces)


def link_text(text, candidates, problems, number):
    """Links the paths of `text` and, when `candidates` is given, its test names to their declaring line."""
    pieces = CODE.split(quote_bare_paths_outside_code(text))
    out = []
    for piece in pieces:
        if not (piece.startswith("`") and piece.endswith("`") and len(piece) > 1):
            out.append(piece)
            continue
        inner = piece[1:-1]
        if candidates is not None and TEST_NAME.fullmatch(inner):
            hits = [(p, declared_line(p, inner)) for p in candidates]
            hits = [(p, line) for p, line in hits if line]
            if hits:
                out.append(f"[{piece}]({hits[0][0]}#L{hits[0][1]})")
            else:
                problems.append(f"TEST_PLAN.md:{number}: {inner} is not declared in {', '.join(candidates) or '?'}")
                out.append(piece)
            continue
        out.append(link_path(piece))
    return "".join(out)


def link_refs(refs, default, problems, number):
    """The part after ` — `: each `;` segment resolves its test names in its own path, else in `default`."""
    out = []
    for segment in refs.split(";"):
        quoted = quote_bare_paths_outside_code(segment)
        own = TEST_FILE.search(quoted)
        candidates = [own.group(1)] if own else (default or [])
        out.append(link_text(quoted, candidates, problems, number))
    return ";".join(out)


def relink(text):
    problems = []
    default = None
    section_src = []
    out = []
    for number, line in enumerate(text.split("\n"), 1):
        line = OWN_LINK.sub(r"\1", line)
        if line.startswith("## "):
            default = None
            section_src = []
        elif line.startswith("### "):
            default = TEST_FILE.findall(line) or None
            section_src = SRC_FILE.findall(line)
        elif line.startswith("Tests: "):
            first = TEST_FILE.search(line)
            default = [first.group(1)] if first else None
        elif re.match(r"\d+\. .* — `test/", line):
            default = TEST_FILE.findall(line.split(" — ", 1)[1]) or default

        item = re.match(r"(\s*- \[[x \-]\] )(.*)$", line)
        numbered = re.match(r"(\d+\. )(.*)$", line)
        if numbered and section_src:
            line = numbered.group(1) + link_members(numbered.group(2), section_src)
        elif item and " — " in item.group(2):
            head, refs = item.group(2).split(" — ", 1)
            line = (
                item.group(1)
                + link_text(head, None, problems, number)
                + " — "
                + link_refs(refs, default, problems, number)
            )
        else:
            line = link_text(line, None, problems, number)
        out.append(line)
    return "\n".join(out), problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 if TEST_PLAN.md is not up to date")
    args = parser.parse_args()

    current = PLAN.read_text()
    linked, problems = relink(current)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    if args.check:
        if linked != current:
            print("TEST_PLAN.md links are stale: run `make test-plan`", file=sys.stderr)
            return 1
        return 0
    if linked != current:
        PLAN.write_text(linked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
