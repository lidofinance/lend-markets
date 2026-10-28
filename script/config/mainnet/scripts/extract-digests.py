"""Turn Section 6 of the Cyfrin Lido Lend report into digests.txt.

Usage: python3 extract-digests.py <report.pdf> [digests.txt]

One row per in-scope file, "<0xkeccak256>  <path>", lido-lend and lido-lend-irm paths prefixed with
lib/lido-lend/ and lib/lido-lend-irm/, sorted by path, no trailing newline. The keccak256 of the file's
bytes is the aggregate root printed in the report.
"""
import re
import sys

import pypdf

report = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else "digests.txt"

text = "\n".join(page.extract_text() for page in pypdf.PdfReader(report).pages)
start = text.index("lido-lend-markets (25 files)")
end = text.index("7 Executive Summary", start)

PREFIX = {"lido-lend-markets": "", "lido-lend": "lib/lido-lend/", "lido-lend-irm": "lib/lido-lend-irm/"}
prefix, path, digest, rows = None, "", "", {}
for line in (l.strip() for l in text[start:end].splitlines()):
    if not line or line == "File keccak256" or re.fullmatch(r"\d{1,2}", line):  # page numbers
        continue
    header = re.match(r"^(lido-lend(?:-markets|-irm)?) \(\d+ files\)$", line)
    if header:
        prefix = PREFIX[header[1]]
        continue
    row = re.match(r"^(.*?)\s*(0x[0-9a-f]+)$", line)
    if row:
        path += row[1].strip()
        digest = row[2]
    elif re.fullmatch(r"[0-9a-f]+", line) and digest:
        digest += line  # digest wrapped onto the next line
    else:
        path += line  # path wrapped onto the next line
        continue
    if len(digest) == 66:
        rows[prefix + path] = digest
        path = digest = ""

assert len(rows) == 53, f"{len(rows)} rows parsed, 53 expected"
with open(out, "w") as f:
    f.write("\n".join(f"{d}  {p}" for p, d in sorted(rows.items())))
print(f"{len(rows)} rows -> {out}")
