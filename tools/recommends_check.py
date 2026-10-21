#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""recommends_check.py - which "Recommends" are missing under a program?

The cards install without Recommends (APT::Install-Recommends "false").
That keeps them small, but a program can then lack a part it only
recommends - a Qt platform plugin, a browser engine, a codec - and fail
to start. This lists, for each package named, every package it depends
on (all levels, as installed) and the Recommends among them that are not
installed.

Read-only. On the tablet, as the normal user:

    python3 recommends_check.py qutebrowser
    python3 recommends_check.py qutebrowser mpv imv
    python3 recommends_check.py --all          every package on the card

"a | b" counts as met when either is installed, also through a package
that Provides it. Output: one block per package that recommends
something missing, the program's own Recommends marked with "*".
"""
import subprocess
import sys

FIELDS = "${Package}\t${db:Status-Abbrev}\t${Depends}\t${Pre-Depends}\t${Recommends}\t${Provides}\n"


def parse_rel(field):
    """'a (>= 1) | b:any, c' -> [['a', 'b'], ['c']]"""
    groups = []
    for part in field.split(","):
        alts = []
        for alt in part.split("|"):
            name = alt.strip().split(" ")[0].split("(")[0].split(":")[0]
            if name:
                alts.append(name)
        if alts:
            groups.append(alts)
    return groups


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    out = subprocess.run(["dpkg-query", "-W", "-f", FIELDS],
                         capture_output=True, text=True, check=True).stdout
    pkgs, provided = {}, set()
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) < 6 or not p[1].startswith("ii"):
            continue
        name = p[0]
        pkgs[name] = {"dep": parse_rel(p[2]) + parse_rel(p[3]), "rec": parse_rel(p[4])}
        for g in parse_rel(p[5]):
            provided.update(g)

    def present(name):
        return name in pkgs or name in provided

    if args == ["--all"]:
        roots = sorted(pkgs)
    else:
        roots = args
        for r in roots:
            if r not in pkgs:
                print(f"{r}: not installed")
        roots = [r for r in roots if r in pkgs]

    for root in roots:
        # every installed package root depends on, any level
        seen, todo = {root}, [root]
        while todo:
            for group in pkgs[todo.pop()]["dep"]:
                for alt in group:
                    if alt in pkgs and alt not in seen:
                        seen.add(alt)
                        todo.append(alt)
        report = []
        for name in sorted(seen, key=lambda n: (n != root, n)):
            missing = [" | ".join(g) for g in pkgs[name]["rec"]
                       if not any(present(a) for a in g)]
            if missing:
                mark = "*" if name == root else " "
                report.append(f"  {mark} {name}: " + ", ".join(missing))
        if args == ["--all"]:
            if report and report[0].lstrip().startswith("*"):
                print(report[0].replace("* ", "", 1).strip())
            continue
        print(f"## {root}: {len(seen) - 1} packages below it; "
              f"{len(report)} with missing Recommends")
        print("\n".join(report) if report else "  none missing")


if __name__ == "__main__":
    main()
