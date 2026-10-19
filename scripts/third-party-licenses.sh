#!/usr/bin/env bash
# Regenerates THIRD_PARTY_LICENSES.md from the Rust core's dependency graph.
#
# Reads `cargo metadata` for the macOS build (aarch64-apple-darwin, Cargo.lock as
# committed), follows normal and build dependencies (not dev ones), and takes the
# licence texts and copyright lines from the crates' own files in ~/.cargo.
# Needs only cargo and python3. The crate sources must already be downloaded; if
# they aren't, run `cargo fetch` in core/ once.
#
# Usage: scripts/third-party-licenses.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/THIRD_PARTY_LICENSES.md"
export PATH="$HOME/.cargo/bin:$PATH"

META="$(mktemp)"
trap 'rm -f "$META"' EXIT
cargo metadata --format-version 1 --offline --locked \
    --filter-platform aarch64-apple-darwin \
    --manifest-path "$ROOT/core/Cargo.toml" > "$META"

python3 -I - "$META" "$OUT" <<'PY'
import collections, json, os, re, sys

meta_path, out_path = sys.argv[1], sys.argv[2]
meta = json.load(open(meta_path))
packages = {p["id"]: p for p in meta["packages"]}
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
root = meta["resolve"]["root"]

# Everything that ends up in, or generates code for, the shipped library.
crates, stack = set(), [root]
while stack:
    pid = stack.pop()
    if pid in crates:
        continue
    crates.add(pid)
    for dep in nodes[pid]["deps"]:
        if any(k["kind"] != "dev" for k in dep["dep_kinds"]):
            stack.append(dep["pkg"])
crates.discard(root)

# Where a crate offers a choice, Tint takes the earliest licence in this list.
PREFERENCE = ["MIT", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause", "Zlib",
              "Unicode-3.0", "MPL-2.0"]

def parse(expr):
    """SPDX expression -> nested ("OR"|"AND", [...]) tuples and licence ids."""
    tokens = re.findall(r"\(|\)|[^\s()]+", expr.replace("/", " OR "))
    pos = 0
    def term():
        nonlocal pos
        tok = tokens[pos]; pos += 1
        if tok == "(":
            node = disjunction(); pos += 1
            return node
        if pos < len(tokens) and tokens[pos] == "WITH":
            tok += " WITH " + tokens[pos + 1]; pos += 2
        return tok
    def conjunction():
        nonlocal pos
        parts = [term()]
        while pos < len(tokens) and tokens[pos] == "AND":
            pos += 1; parts.append(term())
        return parts[0] if len(parts) == 1 else ("AND", parts)
    def disjunction():
        nonlocal pos
        parts = [conjunction()]
        while pos < len(tokens) and tokens[pos] == "OR":
            pos += 1; parts.append(conjunction())
        return parts[0] if len(parts) == 1 else ("OR", parts)
    return disjunction()

def rank(lic):
    return PREFERENCE.index(lic) if lic in PREFERENCE else len(PREFERENCE)

def choose(node):
    """The set of licences Tint complies with for one expression."""
    if isinstance(node, str):
        return [node]
    op, parts = node
    if op == "AND":
        return sorted({lic for part in parts for lic in choose(part)}, key=rank)
    options = [choose(part) for part in parts]
    return min(options, key=lambda lics: max(rank(l) for l in lics))

LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notice|mpl|mit|apache|bsd|zlib|unicode)", re.I)

def licence_files(pkg):
    """The crate's licence files, else the ones at its git workspace root."""
    directory = os.path.dirname(pkg["manifest_path"])
    for _ in range(3):
        found = sorted(os.path.join(directory, f) for f in os.listdir(directory)
                       if LICENSE_FILE.match(f) and os.path.isfile(os.path.join(directory, f)))
        if found or not (pkg["source"] or "").startswith("git+"):
            return found
        directory = os.path.dirname(directory)
    return []

SIGNATURES = {
    "MIT": "Permission is hereby granted, free of charge",
    "Apache-2.0": "Apache License",
    "BSD-3-Clause": "Neither the name",
    "Zlib": "This software is provided 'as-is'",
    "Unicode-3.0": "UNICODE LICENSE V3",
    "MPL-2.0": "Mozilla Public License Version 2.0",
}
COPYRIGHT = re.compile(r"^\s*(copyright\s+(\(c\)|©|\d{4}|the\b)|©)", re.I)
PLACEHOLDER = re.compile(r"\[yyyy\]|\{yyyy\}|<year>|\[year\]", re.I)

def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()

rows = collections.defaultdict(list)       # chosen licences -> crates
notices = {}                               # crate -> copyright lines
candidates = collections.defaultdict(collections.Counter)  # licence -> text -> count
for pid in crates:
    pkg = packages[pid]
    declared = pkg["license"] or "(none declared)"
    chosen = choose(parse(pkg["license"])) if pkg["license"] else ["(none declared)"]
    rows[" AND ".join(chosen)].append(pkg)
    lines = []
    for path in licence_files(pkg):
        text = read(path)
        for line in text.splitlines():
            if COPYRIGHT.match(line) and not PLACEHOLDER.search(line):
                line = line.strip()
                if line not in lines:
                    lines.append(line)
        matches = [lic for lic, sig in SIGNATURES.items() if sig in text]
        if "Unicode-3.0" in matches:  # its wording includes the MIT grant
            matches = ["Unicode-3.0"]
        if len(matches) == 1:
            # Drop the crate's own copyright lines; they are listed per crate.
            body = "\n".join(l for l in text.rstrip().splitlines()
                             if not (matches[0] != "Unicode-3.0" and COPYRIGHT.match(l)))
            candidates[matches[0]][body.lstrip("\n")] += 1
    notices[f"{pkg['name']} {pkg['version']}"] = lines

def mpl_note(pkg):
    if pkg["source"] == "registry+https://github.com/rust-lang/crates.io-index":
        return (f"Unmodified. Source: https://crates.io/crates/{pkg['name']}/{pkg['version']}"
                + (f" and {pkg['repository']}" if pkg["repository"] else ""))
    return f"Source: {pkg['repository'] or pkg['source']}"

out = []
out.append("# Third-party licences\n")
out.append("Tint's own code is under the MIT licence (see [LICENSE](LICENSE)). The app links a "
           "Rust library, `floe_core`, built from the crates below. This file lists every crate in "
           "that library's dependency graph for the macOS build (aarch64-apple-darwin), including "
           "build-time crates. Crates are grouped by the licence Tint uses them under; where a "
           "crate offers a choice, the Declared licence column shows all of it.\n")
out.append("The Swift app has no third-party package dependencies.\n")
out.append("Generated by `scripts/third-party-licenses.sh` from `core/Cargo.lock`. "
           "Don't edit by hand; rerun the script after changing dependencies.\n")

order = sorted(rows, key=lambda k: (-len(rows[k]), k))
out.append("## Contents\n")
for key in order:
    anchor = re.sub(r"[^a-z0-9 -]", "", key.lower()).replace(" ", "-")
    count = len(rows[key])
    out.append(f"- [{key}](#{anchor}): {count} crate{'s' if count != 1 else ''}")
out.append("- [Copyright notices](#copyright-notices)")
out.append("- [Licence texts](#licence-texts)\n")

for key in order:
    out.append(f"## {key}\n")
    if "MPL-2.0" in key:
        out.append("These crates are covered by the Mozilla Public License 2.0. Tint uses them "
                   "unmodified, as published on crates.io; their source code is available "
                   "at the links below.\n")
    out.append("| Crate | Version | Declared licence | Repository |")
    out.append("|---|---|---|---|")
    for pkg in sorted(rows[key], key=lambda p: (p["name"], p["version"])):
        repo = pkg["repository"] or f"https://crates.io/crates/{pkg['name']}"
        out.append(f"| {pkg['name']} | {pkg['version']} | {pkg['license'] or '(none)'} | {repo} |")
    out.append("")
    if "MPL-2.0" in key:
        for pkg in sorted(rows[key], key=lambda p: p["name"]):
            out.append(f"- {pkg['name']} {pkg['version']}: {mpl_note(pkg)}")
        if any(p["name"] == "priority-queue" for p in rows[key]):
            out.append("- priority-queue is offered under LGPL-3.0-or-later OR MPL-2.0; "
                       "Tint uses it under MPL-2.0.")
        out.append("")

out.append("## Copyright notices\n")
out.append("Copyright lines found in each crate's licence files. Crates not listed ship "
           "no copyright line of their own; their authors are named in their repositories.\n")
for name in sorted(notices):
    if notices[name]:
        out.append(f"**{name}**\n")
        out.extend(f"    {line}" for line in notices[name])
        out.append("")

out.append("## Licence texts\n")
used = sorted({lic for key in rows for lic in key.split(" AND ")}, key=rank)
for lic in used:
    out.append(f"### {lic}\n")
    if not candidates[lic]:
        out.append(f"No {lic} text was found in the crate sources; see https://spdx.org/licenses/{lic}.html\n")
        continue
    text, _ = sorted(candidates[lic].items(), key=lambda kv: (-kv[1], kv[0]))[0]
    if lic in ("MIT", "BSD-3-Clause", "Zlib"):
        out.append("Each crate's copyright holders are listed under Copyright notices above.\n")
    out.append("```text")
    out.append(text)
    out.append("```\n")

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(out).rstrip() + "\n")
print(f"Wrote {out_path}: {len(crates)} crates, licences: {', '.join(used)}")
PY
