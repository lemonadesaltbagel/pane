#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 lemonadesaltbagel
"""Code-origin audit (research/plan-open-core.md, goal O1).

Compares pane's code (Sources, Tests, scripts) with the third-party projects in refs/ (studied for research; never
committed) and reports every passage that looks copied, with the project's licence.

  python3 scripts/code-origin.py [--k 50] [--min 80] [--out research/code-origin.md]

How: comments are stripped and code is tokenized; names become a placeholder (so renamed variables still match), as
do strings and numbers. Every run of K tokens is fingerprinted (winnowed for the reference projects). A fingerprint
found in three or more unrelated projects is a common idiom and ignored. Matches are merged into passages; each
passage also gets a verbatim score: the share of its 20-token runs that match with the original names kept.
"""
import argparse, collections, os, re, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTS = {".swift", ".m", ".mm", ".c", ".h", ".cpp", ".cc", ".hpp", ".lua", ".js", ".ts"}
SKIP_DIRS = {".git", "node_modules", ".build", "build", "Pods", "Carthage", "DerivedData", "vendor"}

KEYWORDS = set("""
let var func if else guard return for in while switch case default break continue struct class enum protocol extension
import public private fileprivate internal static self Self init deinit nil true false try catch throw throws rethrows do as
is where defer final override mutating lazy weak unowned inout some any typealias associatedtype subscript get set willSet
didSet async await actor nonisolated open repeat fallthrough convenience required dynamic indirect
int char void float double long short unsigned signed const typedef union sizeof goto extern volatile register inline
NULL YES NO id super interface implementation end property synthesize selector
local function then elseif and or not until
""".split())

TOKEN = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|[A-Za-z_][A-Za-z0-9_]*|\d+(?:\.\d+)?'
                   r'|==|!=|<=|>=|->|&&|\|\||\?\?|\.\.\.|\.\.<|[{}()\[\];,.:?!<>=+\-*/%&|^~@#$\\]')

def strip_comments(text, lua=False):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    if lua:
        text = re.sub(r"--\[\[.*?\]\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
        text = re.sub(r"--[^\n]*", "", text)
    return text

def tokenize(path):
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return [], []
    text = strip_comments(text, lua=path.endswith(".lua"))
    norm, raw = [], []
    for line_no, line in enumerate(text.split("\n"), 1):
        for m in TOKEN.finditer(line):
            t = m.group(0)
            if t[0] in "\"'":
                n = "S"
            elif t[0].isdigit():
                n = "N"
            elif (t[0].isalpha() or t[0] == "_") and t not in KEYWORDS:
                n = "I"
            else:
                n = t
            norm.append((n, line_no))
            raw.append(t)
    return norm, raw

def files(root):
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in names:
            if os.path.splitext(name)[1] in EXTS:
                yield os.path.join(base, name)

def kgrams(tokens, k):
    """Hashes of every k-token run (index = start position)."""
    seq = [t for t, _ in tokens]
    return [zlib.crc32(" ".join(seq[i:i + k]).encode()) for i in range(max(0, len(seq) - k + 1))]

def winnow(hashes, w):
    picked, last = [], -1
    for i in range(max(0, len(hashes) - w + 1)):
        window = hashes[i:i + w]
        j = i + min(range(w), key=lambda x: (window[x], -x))
        if j != last:
            picked.append(j)
            last = j
    return picked

def licence(project_dir):
    for name in sorted(os.listdir(project_dir)):
        if re.match(r"(?i)^(licen[cs]e|copying)", name):
            head = open(os.path.join(project_dir, name), encoding="utf-8", errors="ignore").read(600)
            for key, label in [("AFFERO", "AGPL-3.0"), ("LESSER GENERAL", "LGPL"), ("GENERAL PUBLIC LICENSE\n                       Version 2", "GPL-2.0"),
                               ("Version 2, June 1991", "GPL-2.0"), ("GENERAL PUBLIC LICENSE", "GPL-3.0"), ("MIT License", "MIT"),
                               ("The MIT License", "MIT"), ("Permission is hereby granted", "MIT-style"), ("unencumbered", "Public domain"),
                               ("Apache License", "Apache-2.0"), ("BSD", "BSD")]:
                if key in head:
                    return label
            return "custom (" + name + ")"
    return "none (all rights reserved)"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, default=50)
    ap.add_argument("--w", type=int, default=6)
    ap.add_argument("--min", type=int, default=80, help="smallest passage reported, in tokens")
    ap.add_argument("--out", default=os.path.join(ROOT, "research/code-origin.md"))
    ap.add_argument("--ours", action="append", help="folders of our code to check (default: Sources, Tests, scripts)")
    args = ap.parse_args()
    refs = os.path.join(ROOT, "refs")
    projects = sorted(d for d in os.listdir(refs) if os.path.isdir(os.path.join(refs, d)))
    licences = {p: licence(os.path.join(refs, p)) for p in projects}

    index = collections.defaultdict(list)  # hash -> [(project, file, pos)]
    ref_tokens = {}
    total_ref = 0
    for p in projects:
        for f in files(os.path.join(refs, p)):
            norm, raw = tokenize(f)
            if len(norm) < args.k:
                continue
            rel = os.path.relpath(f, refs)
            ref_tokens[rel] = (norm, raw)
            total_ref += len(norm)
            hashes = kgrams(norm, args.k)
            for pos in winnow(hashes, args.w):
                index[hashes[pos]].append((p, rel, pos))
    # Idioms: in three or more projects.
    common = {h for h, hits in index.items() if len({p for p, _, _ in hits}) >= 3}

    ours = []
    for top in args.ours or ["Sources", "Tests", "scripts"]:
        ours += list(files(top if os.path.isabs(top) else os.path.join(ROOT, top)))
    passages = []
    for f in sorted(ours):
        norm, raw = tokenize(f)
        if len(norm) < args.k:
            continue
        hashes = kgrams(norm, args.k)
        hits = collections.defaultdict(list)  # (project, ref file) -> [(our pos, ref pos)]
        for i, h in enumerate(hashes):
            if h in common or h not in index:
                continue
            for p, rel, rpos in index[h]:
                hits[(p, rel)].append((i, rpos))
        for (p, rel), pairs in hits.items():
            pairs.sort()
            start = prev = pairs[0][0]
            rstart = pairs[0][1]
            regions = []
            for i, r in pairs[1:] + [(10**12, 0)]:
                if i - prev <= args.k:
                    prev = i
                    continue
                regions.append((start, prev + args.k, rstart))
                start, prev, rstart = i, i, r
            for a, b, rpos in regions:
                size = b - a
                if size < args.min:
                    continue
                # Verbatim score: 20-token runs with the original names, ours found in the reference file.
                rraw = ref_tokens[rel][1]
                ref_runs = {" ".join(rraw[j:j + 20]) for j in range(max(0, len(rraw) - 19))}
                ours_runs = [" ".join(raw[j:j + 20]) for j in range(a, max(a, b - 19))]
                verbatim = sum(r in ref_runs for r in ours_runs) / max(1, len(ours_runs))
                rnorm = ref_tokens[rel][0]
                passages.append({
                    "ours": os.path.relpath(f, ROOT), "lines": (norm[a][1], norm[min(b, len(norm)) - 1][1]),
                    "project": p, "ref": rel, "ref_line": rnorm[min(rpos, len(rnorm) - 1)][1],
                    "tokens": size, "verbatim": verbatim, "licence": licences[p],
                })
    passages.sort(key=lambda x: (-x["verbatim"], -x["tokens"]))
    copyleft = lambda l: l.startswith(("GPL", "AGPL", "LGPL", "none", "custom"))
    with open(args.out, "w") as out:
        out.write("# Code-origin audit\n\n")
        out.write(f"Generated by `scripts/code-origin.py` (k={args.k}, passages ≥ {args.min} tokens; common idioms, "
                  f"in 3+ projects, ignored). {len(ours)} of pane's files against {len(projects)} projects "
                  f"({total_ref:,} tokens).\n\n")
        out.write("**Verbatim** is the share of the passage's 20-token runs that match with the original names kept. "
                  "Near 0, the structure is similar but the code isn't the same; near 1, a copy.\n\n")
        out.write("| Project | Licence |\n|---|---|\n")
        for p in projects:
            out.write(f"| {p} | {licences[p]} |\n")
        out.write(f"\n## Passages ({len(passages)})\n\n")
        if not passages:
            out.write("None.\n")
        else:
            out.write("| pane | Lines | Matches | Licence | Tokens | Verbatim |\n|---|---|---|---|---|---|\n")
            for x in passages:
                flag = " ⚠️" if copyleft(x["licence"]) and (x["verbatim"] >= 0.3 or x["tokens"] >= 200) else ""
                out.write(f"| `{x['ours']}` | {x['lines'][0]}–{x['lines'][1]} | {x['project']}: `{x['ref']}`:{x['ref_line']} | "
                          f"{x['licence']}{flag} | {x['tokens']} | {x['verbatim']:.0%} |\n")
    print(f"{len(passages)} passages; written to {os.path.relpath(args.out, ROOT)}")
    for x in passages[:15]:
        print(f"  {x['verbatim']:.0%} {x['tokens']:4d} {x['ours']}:{x['lines'][0]}-{x['lines'][1]} ~ {x['project']} {x['ref']}:{x['ref_line']} [{x['licence']}]")

if __name__ == "__main__":
    main()
