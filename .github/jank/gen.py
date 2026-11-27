#!/usr/bin/env python3
"""gen.py <hinge-dir> <file.txt>...: writes GatefoldUITests/JankRuns.swift, one test per scenario line."""
import json, os, re, sys

P = "-GatefoldDownloadAll YES -GatefoldNoLatency YES -GatefoldOpenBook gutenberg-pride-and-prejudice -GatefoldGoTo 0.31"
M = "0.35 0.4"
hinge = sys.argv[1]
out = ["import XCTest", "", "@MainActor", "final class JankRuns: JankHuntBase {"]
names = []
for path in sys.argv[2:]:
    group = os.path.basename(path)[:-4]
    for line in open(path):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        name, script = line.split(" :: ", 1)
        script = script.replace("{P}", P).replace("{M}", M)
        fn = "test_" + re.sub(r"\W", "_", f"{group}_{name}")
        names.append(f"{group}-{name}\t{fn}")
        out.append(f"    func {fn}() throws {{ try run({json.dumps(script)}, hingeDir: {json.dumps(hinge)}) }}")
out.append("}")
open("GatefoldUITests/JankRuns.swift", "w").write("\n".join(out) + "\n")
open(".github/jank/names.tsv", "w").write("\n".join(names) + "\n")
print(f"{len(names)} scenarios")
