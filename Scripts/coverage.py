#!/usr/bin/env python3
"""Coverage gauge for the APlay product Swift modules.

Counts only the product Swift targets (APlay, APlayExtras and the three
vendored codec wrappers), excluding tests, MacTests and the vendored C
libraries. Line == fully uncovered (every segment of the line is 0).
"""
import json
import os
import subprocess
import sys

MODULES = ("APlay", "APlayExtras", "APlayWavPack", "APlayVorbis", "APlaySpeex",
           "APlayMidi")

# Product source roots, relative to the repository root. Anything outside these
# roots (tests, MacTests, APlayDemo, derived files, vendored C) is ignored.
ROOTS = (
    ("APlay", "APlay/"),
    ("APlayExtras", "APlayExtras/"),
    ("APlayWavPack", "Sources/APlayWavPack/"),
    ("APlayVorbis", "Sources/APlayVorbis/"),
    ("APlaySpeex", "Sources/APlaySpeex/"),
    ("APlayMidi", "Sources/APlayMidi/"),
)


def module_of(path: str, repo: str) -> str | None:
    rel = os.path.relpath(path, repo)
    if not rel.endswith(".swift") or rel.startswith(".."):
        return None
    for m, root in ROOTS:
        if rel == root.rstrip("/") or rel.startswith(root):
            return m
    return None


def repo_root() -> str:
    return subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=True).stdout.strip()


def main(profdata: str, binary: str) -> int:
    # .xctest is a bundle; the real executable lives in Contents/MacOS/.
    if binary.endswith(".xctest"):
        cand = f"{binary}/Contents/MacOS/{binary.rsplit('/', 1)[-1][:-7]}"
        if os.path.exists(cand):
            binary = cand
    out = subprocess.run(
        ["xcrun", "llvm-cov", "export", "-format=text",
         f"-instr-profile={profdata}", binary],
        capture_output=True, text=True, check=True)
    data = json.loads(out.stdout)["data"][0]
    repo = repo_root()

    totals = {m: [0, 0] for m in MODULES}          # covered, total
    files = {m: [] for m in MODULES}
    for f in data["files"]:
        m = module_of(f["filename"], repo)
        if not m:
            continue
        ls = f["summary"]["lines"]
        c, t = ls["covered"], ls["count"]
        totals[m][0] += c
        totals[m][1] += t
        fs = f["summary"]["functions"]
        files[m].append((f["filename"], c, t,
                         100.0 * c / t if t else 100.0,
                         fs["covered"], fs["count"]))

    gc, gt = 0, 0
    print(f"{'module':<14}{'covered':>9}{'total':>9}{'pct':>9}")
    for m in MODULES:
        c, t = totals[m]
        gc += c
        gt += t
        print(f"{m:<14}{c:>9}{t:>9}{100.0*c/t:>8.2f}%")
    print(f"{'TOTAL':<14}{gc:>9}{gt:>9}{100.0*gc/gt:>8.2f}%")
    if len(sys.argv) > 3 and sys.argv[3] == "--gaps":
        for m in MODULES:
            print(f"\n--- {m} least-covered files ---")
            for path, c, t, pct, fc, ft in sorted(files[m], key=lambda x: x[3])[:8]:
                print(f"  {pct:6.2f}%  {c:>4}/{t:<5} fn {fc}/{ft}  {path.split('/APlay/')[-1]}")
    return 0 if gc * 100 >= gt * 90 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
