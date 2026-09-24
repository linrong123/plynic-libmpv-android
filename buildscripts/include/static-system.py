#!/usr/bin/env python3
"""static-system.py — record in SOURCES.json what libmpv.so takes from the NDK.

    include/static-system.py <sources dir> <ndk dir> <prefix/<abi>/libmpv.archive-stats.tsv>...

Every other library in libmpv.so is built here from a pinned source, and
collect-sources.sh publishes that source. A few static archives come with
the NDK itself and are linked in as they are: zlib (the sysroot's libz.a,
FFmpeg and FreeType use it) and the LLVM runtimes libplacebo's and
uchardet's C++ needs (libc++, libc++abi, libunwind) plus compiler-rt's
builtins, which the clang driver adds to every link. This script adds them
to <sources dir>/SOURCES.json under "static_system", with where they come
from, their licence and, per ABI, the archive's sha256 and how many of its
members lld took, and rewrites the SOURCES.json line of SHA256SUMS.

What it records comes from the link itself: scripts/mpv.sh has lld write
--print-archive-stats next to each ABI's libmpv.so. Every archive lld took a
member from must be one of the build prefix's (the pinned dependencies) or
one of the NDK archives below; anything else (another NDK library, a host
library) fails the build until it is classified here.
"""
import glob
import hashlib
import json
import os
import re
import sys

# id -> (archives, relative to the NDK's toolchains/llvm/prebuilt/<host>/,
# as regular expressions), licence, whether libmpv.so exports its symbols
KNOWN = {
    "zlib": ([r"sysroot/usr/lib/[^/]+/libz\.a"], "Zlib", True),
    "llvm-libc++": ([r"sysroot/usr/lib/[^/]+/libc\+\+_static\.a",
                     r"sysroot/usr/lib/[^/]+/libc\+\+abi\.a"],
                    "Apache-2.0 WITH LLVM-exception", False),
    "llvm-libunwind": ([r"lib64/clang/[^/]+/lib/linux/[^/]+/libunwind\.a"],
                       "Apache-2.0 WITH LLVM-exception", False),
    "llvm-compiler-rt-builtins": ([r"lib64/clang/[^/]+/lib/linux/libclang_rt\.builtins-[^/]+-android\.a"],
                                  "Apache-2.0 WITH LLVM-exception", False),
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


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    out, ndk = sys.argv[1], os.path.realpath(sys.argv[2])
    stats = sys.argv[3:]
    tc = glob.glob(os.path.join(ndk, "toolchains", "llvm", "prebuilt", "*"))
    if len(tc) != 1:
        sys.exit(f"static-system: no single toolchains/llvm/prebuilt/<host> under {ndk}")
    tc = tc[0]

    # What the NDK says about itself.
    revision = re.search(r"^Pkg\.Revision\s*=\s*(\S+)", read(os.path.join(ndk, "source.properties")), re.M)
    zlib = re.search(r'^#define ZLIB_VERSION "([^"]+)"', read(os.path.join(tc, "sysroot/usr/include/zlib.h")), re.M)
    android_version = read(os.path.join(tc, "AndroidVersion.txt")).split("\n")
    manifests = glob.glob(os.path.join(tc, "manifest_*.xml"))
    llvm_project = None
    if len(manifests) == 1:
        llvm_project = re.search(r'<project path="toolchain/llvm-project"[^>]*revision="([0-9a-f]{40})"',
                                 read(manifests[0]))
    base = re.search(r"Base revision: \[([0-9a-f]{40})\]", read(os.path.join(tc, "clang_source_info.md")))
    if not (revision and zlib and android_version[0].strip() and llvm_project and base):
        sys.exit(f"static-system: cannot read the NDK's versions under {tc} "
                 "(source.properties, zlib.h, AndroidVersion.txt, manifest_*.xml, clang_source_info.md)")
    ndk_version = revision.group(1)
    clang = android_version[0].strip()
    clang_based_on = android_version[1].strip() if len(android_version) > 1 else ""

    # Which archives lld took members from, per ABI (the directory the stats
    # file is in: prefix/<abi>/).
    prefixes = {os.path.realpath(os.path.dirname(s)) for s in stats}
    linked = {}  # abi -> {relative path: (members, extracted)}
    problems = []
    for s in stats:
        abi = os.path.basename(os.path.dirname(os.path.abspath(s)))
        seen = linked.setdefault(abi, {})
        for line in read(s).splitlines()[1:]:
            members, extracted, path = line.split("\t", 2)
            real = os.path.realpath(path)
            if any(real.startswith(p + os.sep) for p in prefixes):
                continue  # a pinned dependency built here, published by collect-sources.sh
            if not real.startswith(tc + os.sep):
                if int(extracted):
                    problems.append(f"{abi}: {path}: neither the build prefix nor the NDK")
                continue
            rel = os.path.relpath(real, tc)
            m, e = seen.get(rel, (0, 0))
            seen[rel] = (max(m, int(members)), e + int(extracted))

    entries = {}
    for abi, archives in sorted(linked.items()):
        for rel, (members, extracted) in sorted(archives.items()):
            if not extracted:
                continue
            ids = [i for i, (pats, _, _) in KNOWN.items() if any(re.fullmatch(p, rel) for p in pats)]
            if len(ids) != 1:
                problems.append(f"{abi}: NDK archive {rel} ({extracted} of {members} members) is not "
                                "classified in include/static-system.py")
                continue
            entries.setdefault(ids[0], {}).setdefault(abi, []).append(
                {"path": rel, "sha256": sha256(os.path.join(tc, rel)), "members": members,
                 "extracted": extracted})
    if problems:
        sys.exit("static-system:\n  " + "\n  ".join(problems))

    provider = f"Android NDK {ndk_version}"
    llvm_note = (f"the NDK's clang {clang} ({clang_based_on}) runtime, linked statically and hidden "
                 "(--exclude-libs): nothing of it is exported from libmpv.so. Built from AOSP "
                 "toolchain/llvm-project at `commit`, which is upstream LLVM at `upstream_base` plus "
                 "Android's cherry-picks (the NDK's clang_source_info.md lists them)")
    info = {
        "zlib": dict(version=zlib.group(1), upstream="https://android.googlesource.com/platform/external/zlib",
                     note="the NDK sysroot's libz.a, linked as it is (not built here): AOSP's external/zlib, "
                          "i.e. zlib plus Chromium's SIMD code (adler32_simd, crc32_simd, cpu_features). Its "
                          "licence text is in the NDK's sysroot/NOTICE. Its API stays exported from "
                          "libmpv.so, as in plynic.7 and rc1-rc3"),
        "llvm-libc++": dict(note="libc++_static.a and libc++abi.a; " + llvm_note),
        "llvm-libunwind": dict(note=llvm_note),
        "llvm-compiler-rt-builtins": dict(note="libclang_rt.builtins-<arch>-android.a, which the clang driver "
                                               "adds to every link (hidden since v0.41.0-plynic.rc4; "
                                               "rc1-rc3 exported its __emutls_get_address); " + llvm_note),
    }
    for i in ("llvm-libc++", "llvm-libunwind", "llvm-compiler-rt-builtins"):
        info[i].update(version=clang, upstream="https://android.googlesource.com/toolchain/llvm-project",
                       commit=llvm_project.group(1),
                       upstream_base={"repo": "https://github.com/llvm/llvm-project", "commit": base.group(1)})
    static_system = []
    for i, abis in sorted(entries.items()):
        _, license, exported = KNOWN[i]
        e = {"id": i, "version": info[i]["version"], "license": license, "provider": provider,
             "upstream": info[i]["upstream"]}
        for k in ("commit", "upstream_base"):
            if k in info[i]:
                e[k] = info[i][k]
        e.update(exported=exported, note=info[i]["note"], archives=abis)
        static_system.append(e)

    path = os.path.join(out, "SOURCES.json")
    doc = json.load(open(path))
    doc["static_system"] = static_system
    json.dump(doc, open(path, "w"), indent=2)
    digest = sha256(path)
    sums = os.path.join(out, "SHA256SUMS")
    lines = [l for l in read(sums).splitlines() if not l.endswith("  SOURCES.json")]
    with open(sums, "w") as f:
        f.write("".join(l + "\n" for l in lines) + f"{digest}  SOURCES.json\n")
    for e in static_system:
        print(f"static-system: {e['id']} {e['version']} ({e['license']}): "
              + ", ".join(f"{abi} {sum(a['extracted'] for a in arcs)}" for abi, arcs in sorted(e["archives"].items()))
              + " members")


if __name__ == "__main__":
    main()
