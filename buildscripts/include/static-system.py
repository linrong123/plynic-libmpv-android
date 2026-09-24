#!/usr/bin/env python3
"""static-system.py — record in SOURCES.json what the jar's .so files take from the NDK.

    include/static-system.py <sources dir> <ndk dir> <stats.tsv>=<binary.so>...

    e.g. prefix/arm64-v8a/libmpv.archive-stats.tsv=prefix/arm64-v8a/lib/libmpv.so
         prefix/arm64-v8a/libmediakitandroidhelper.archive-stats.tsv=<apk>/lib/arm64-v8a/libmediakitandroidhelper.so

Each pair is one binary of one ABI: lld's --print-archive-stats of its link
(the ABI is the directory the stats file is in, prefix/<abi>/, and its name
is <binary without .so>.archive-stats.tsv) and the binary itself. libmpv.so
gets its stats from scripts/mpv.sh, libmediakitandroidhelper.so from
include/helper.cmake.

Every other library in libmpv.so is built here from a pinned source, and
collect-sources.sh publishes that source. What the NDK itself brings in
statically, as it is, is the LLVM runtime: libc++ (libc++_static.a,
libc++abi.a) and libunwind for libplacebo's and uchardet's C++ in libmpv.so
and for the helper's, and compiler-rt's builtins, which the clang driver
adds to every link. This script adds them to <sources dir>/SOURCES.json under
"static_system": where they come from, their licence and, per binary and
ABI, each archive's sha256, how many of its members lld took, and how many
of its definitions the binary exports (read from its dynamic symbol table,
not assumed). "binaries" records, per binary and ABI, the NDK revision, the
compilers its .comment section names and its dynamic export count. It
rewrites the SOURCES.json line of SHA256SUMS.

The build fails when lld took code from an archive that is neither the
build prefix's (the pinned dependencies) nor one of the NDK archives below -
the NDK sysroot's libz.a included: zlib is built here (scripts/zlib.sh) -,
when a binary exports anything of those archives, or when a binary was
compiled or linked by another clang than this NDK's (a helper built with
the Android Gradle Plugin's default NDK, say, or an NDK archive that the
platform build compiled, like the sysroot's libz.a with its clang 15.0.1).
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

# id -> (archives, relative to the NDK's toolchains/llvm/prebuilt/<host>/,
# as regular expressions), licence
KNOWN = {
    "llvm-libc++": ([r"sysroot/usr/lib/[^/]+/libc\+\+_static\.a",
                     r"sysroot/usr/lib/[^/]+/libc\+\+abi\.a"],
                    "Apache-2.0 WITH LLVM-exception"),
    "llvm-libunwind": ([r"lib64/clang/[^/]+/lib/linux/[^/]+/libunwind\.a"],
                       "Apache-2.0 WITH LLVM-exception"),
    "llvm-compiler-rt-builtins": ([r"lib64/clang/[^/]+/lib/linux/libclang_rt\.builtins-[^/]+-android\.a"],
                                  "Apache-2.0 WITH LLVM-exception"),
}
# Known NDK archives that must not be linked, with the reason.
REFUSED = {
    r"sysroot/usr/lib/[^/]+/libz\.a": "zlib comes from the build prefix (scripts/zlib.sh), not the NDK sysroot",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    if len(sys.argv) < 4 or any("=" not in a for a in sys.argv[3:]):
        sys.exit(__doc__)
    out, ndk = sys.argv[1], os.path.realpath(sys.argv[2])
    pairs = [a.split("=", 1) for a in sys.argv[3:]]
    tc = glob.glob(os.path.join(ndk, "toolchains", "llvm", "prebuilt", "*"))
    if len(tc) != 1:
        sys.exit(f"static-system: no single toolchains/llvm/prebuilt/<host> under {ndk}")
    tc = tc[0]
    nm, readelf = os.path.join(tc, "bin", "llvm-nm"), os.path.join(tc, "bin", "llvm-readelf")

    # What the NDK says about itself.
    revision = re.search(r"^Pkg\.Revision\s*=\s*(\S+)", read(os.path.join(ndk, "source.properties")), re.M)
    android_version = read(os.path.join(tc, "AndroidVersion.txt")).split("\n")
    manifests = glob.glob(os.path.join(tc, "manifest_*.xml"))
    llvm_project = None
    if len(manifests) == 1:
        llvm_project = re.search(r'<project path="toolchain/llvm-project"[^>]*revision="([0-9a-f]{40})"',
                                 read(manifests[0]))
    base = re.search(r"Base revision: \[([0-9a-f]{40})\]", read(os.path.join(tc, "clang_source_info.md")))
    if not (revision and android_version[0].strip() and llvm_project and base):
        sys.exit(f"static-system: cannot read the NDK's versions under {tc} "
                 "(source.properties, AndroidVersion.txt, manifest_*.xml, clang_source_info.md)")
    ndk_version = revision.group(1)
    clang = android_version[0].strip()
    clang_based_on = android_version[1].strip() if len(android_version) > 1 else ""
    # How this NDK's clang signs the objects it compiles (.comment):
    # "Android (<build>, based on r450784d1) clang version 14.0.7 (<repo> <commit>)"
    ndk_clang = re.compile(r"Android \(\d+, %s\) clang version %s \(\S+ %s\)"
                           % (re.escape(clang_based_on), re.escape(clang), llvm_project.group(1)))

    prefixes = {os.path.realpath(os.path.dirname(s)) for s, _ in pairs}
    problems = []
    entries = {}   # id -> binary -> abi -> [archive record]
    binaries = {}  # binary -> abi -> what the link says
    archive_defs = {}
    for stats, binary in pairs:
        abi = os.path.basename(os.path.dirname(os.path.abspath(stats)))
        name = os.path.basename(binary)
        if os.path.basename(stats) != name[: -len(".so")] + ".archive-stats.tsv":
            sys.exit(f"static-system: {stats} is not the archive statistics of {binary}")
        exports = set(run(nm, "-D", "--defined-only", "--format=just-symbols", binary).split())
        comment = {m.group(1).strip() for m in re.finditer(r"^\s*\[\s*[0-9a-f]+\]\s(.*)$",
                                                             run(readelf, "-p", ".comment", binary), re.M)}
        compilers = sorted(c for c in comment if "clang version" in c)
        linkers = sorted(c for c in comment if c.startswith("Linker:"))
        foreign = [c for c in compilers if not ndk_clang.fullmatch(c)]
        if not compilers or foreign:
            problems.append(f"{name} {abi}: compiled by {foreign or 'no clang named in .comment'}, "
                            f"not the NDK's clang {clang} ({clang_based_on})")
        if linkers != [f"Linker: LLD {clang}"]:
            problems.append(f"{name} {abi}: linked by {linkers or 'no linker named in .comment'}, "
                            f"not the NDK's LLD {clang}")
        binaries.setdefault(name, {})[abi] = {"ndk": ndk_version, "compilers": compilers,
                                              "linker": linkers[0] if linkers else None,
                                              "exports": len(exports)}

        linked = {}  # path relative to the NDK toolchain -> (members, extracted)
        for line in read(stats).splitlines()[1:]:
            members, extracted, path = line.split("\t", 2)
            real = os.path.realpath(path)
            if any(real.startswith(p + os.sep) for p in prefixes):
                continue  # a pinned dependency built here, published by collect-sources.sh
            if not real.startswith(tc + os.sep):
                if int(extracted):
                    problems.append(f"{name} {abi}: {path}: neither the build prefix nor this NDK")
                continue
            rel = os.path.relpath(real, tc)
            m, e = linked.get(rel, (0, 0))
            linked[rel] = (max(m, int(members)), e + int(extracted))

        for rel, (members, extracted) in sorted(linked.items()):
            if not extracted:
                continue
            refused = [why for pat, why in REFUSED.items() if re.fullmatch(pat, rel)]
            if refused:
                problems.append(f"{name} {abi}: NDK archive {rel} is linked ({extracted} members): {refused[0]}")
                continue
            ids = [i for i, (pats, _) in KNOWN.items() if any(re.fullmatch(p, rel) for p in pats)]
            if len(ids) != 1:
                problems.append(f"{name} {abi}: NDK archive {rel} ({extracted} of {members} members) is not "
                                "classified in include/static-system.py")
                continue
            path = os.path.join(tc, rel)
            if path not in archive_defs:
                archive_defs[path] = set(run(nm, "--defined-only", "--extern-only", "--format=just-symbols",
                                             path).split())
            leaked = sorted(exports & archive_defs[path])
            rec = {"path": rel, "sha256": sha256(path), "members": members, "extracted": extracted,
                   "exported": len(leaked)}
            if leaked:
                # The LLVM runtime must stay inside the binary: exported, it
                # is offered to every other library in the process
                # (Flutter's engine, other plugins' libc++).
                rec["exported_sample"] = leaked[:5]
                problems.append(f"{name} {abi}: exports {len(leaked)} definitions of {rel} "
                                f"({', '.join(leaked[:5])}{', ...' if len(leaked) > 5 else ''})")
            entries.setdefault(ids[0], {}).setdefault(name, {}).setdefault(abi, []).append(rec)
    if problems:
        sys.exit("static-system:\n  " + "\n  ".join(problems))

    provider = f"Android NDK {ndk_version}"
    llvm_note = (f"the NDK's clang {clang} ({clang_based_on}) runtime, linked statically as it is (not built "
                 "here) and hidden: libmpv.so passes the archives to --exclude-libs (scripts/mpv.sh), the "
                 "helper links with --exclude-libs,ALL (include/helper.cmake); `exported` and each archive's "
                 "`exported` are read from the binaries' dynamic symbol tables. Built from AOSP "
                 "toolchain/llvm-project at `commit`, which is upstream LLVM at `upstream_base` plus "
                 "Android's cherry-picks (the NDK's clang_source_info.md lists them)")
    notes = {
        "llvm-libc++": "libc++_static.a and libc++abi.a; " + llvm_note,
        "llvm-libunwind": llvm_note,
        "llvm-compiler-rt-builtins": "libclang_rt.builtins-<arch>-android.a, which the clang driver adds to "
                                     "every link (hidden in libmpv.so since v0.41.0-plynic.rc4, in the helper "
                                     "since rc5); " + llvm_note,
    }
    static_system = []
    for i, per_binary in sorted(entries.items()):
        _, license = KNOWN[i]
        exported = any(a["exported"] for abis in per_binary.values() for arcs in abis.values() for a in arcs)
        static_system.append({
            "id": i, "version": clang, "license": license, "provider": provider,
            "upstream": "https://android.googlesource.com/toolchain/llvm-project",
            "commit": llvm_project.group(1),
            "upstream_base": {"repo": "https://github.com/llvm/llvm-project", "commit": base.group(1)},
            "exported": exported, "note": notes[i],
            "binaries": {b: dict(sorted(abis.items())) for b, abis in sorted(per_binary.items())},
        })

    path = os.path.join(out, "SOURCES.json")
    doc = json.load(open(path))
    doc["static_system"] = static_system
    doc["binaries"] = {b: dict(sorted(abis.items())) for b, abis in sorted(binaries.items())}
    json.dump(doc, open(path, "w"), indent=2)
    digest = sha256(path)
    sums = os.path.join(out, "SHA256SUMS")
    lines = [l for l in read(sums).splitlines() if not l.endswith("  SOURCES.json")]
    with open(sums, "w") as f:
        f.write("".join(l + "\n" for l in lines) + f"{digest}  SOURCES.json\n")
    for b, abis in sorted(binaries.items()):
        print(f"static-system: {b}: NDK {ndk_version}, clang {clang}; exports "
              + ", ".join(f"{abi} {v['exports']}" for abi, v in sorted(abis.items())))
    for e in static_system:
        for b, abis in e["binaries"].items():
            print(f"static-system: {e['id']} {e['version']} ({e['license']}) in {b}: "
                  + ", ".join(f"{abi} {sum(a['extracted'] for a in arcs)} members" for abi, arcs in abis.items())
                  + f"; exported: {'YES' if e['exported'] else 'none'}")


if __name__ == "__main__":
    main()
